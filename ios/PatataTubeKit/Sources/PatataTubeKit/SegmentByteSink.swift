import Foundation

/// Append-only writer for one segment's part file. The part file is the
/// durable record of a segment's progress: pause simply stops appending,
/// and resume re-requests from `byteCount`. No URLSession resume data.
///
/// URLSession's own resume blob is not a substitute: it lives in a private
/// temp file that `cancel(byProducingResumeData:)` refuses to hand back for a
/// deliberate pause, so every byte was lost. Writing straight to the part file
/// makes the bytes ours, and `Range: bytes=(start+byteCount)-(end)` plus
/// `If-Range` is all a resume needs.
///
/// **The disk write never runs on the caller's thread.** `append` is called
/// from the URLSession delegate queue, and that queue is shared by the *whole*
/// session — the plain download path and the HLS fetches deliver their
/// callbacks on it too. A synchronous write there would make one slow volume
/// stall every download in the app. So `append` accounts for the bytes
/// synchronously (`byteCount` is correct the instant it returns) and hands the
/// actual write to this sink's own serial queue.
///
/// Backpressure is a bounded amount of queued data, not an unbounded buffer:
/// past `maxPendingByteCount` in flight, `append` writes synchronously and the
/// network path slows to the speed of the disk, which is the correct outcome.
final class SegmentByteSink: @unchecked Sendable {
    /// How many bytes may sit queued for the writer before `append` stops
    /// returning early and blocks on the write instead.
    static let maxPendingByteCount: Int64 = 8 * 1_048_576

    private let handle: FileHandle
    private let queue: DispatchQueue
    private let state = NSLock()
    private var count: Int64
    private var pendingByteCount: Int64 = 0
    private var writeFailure: Error?
    private var isClosed = false

    /// Bytes this segment's part file holds (or is committed to hold once the
    /// queued writes drain). Safe to read from the delegate queue.
    var byteCount: Int64 { state.withLock { count } }

    /// False once `close()` has drained and released the file handle. Lets a
    /// caller (and a test) prove a replaced sink was actually torn down rather
    /// than leaked with its handle still open on the part file.
    var isOpen: Bool { state.withLock { !isClosed } }

    init(
        partURL: URL,
        expectedOffset: Int64,
        fileManager: FileManager = .default
    ) throws {
        if !fileManager.fileExists(atPath: partURL.path) {
            guard expectedOffset == 0,
                  fileManager.createFile(atPath: partURL.path, contents: nil)
            else {
                throw SegmentedDownloadError.lengthMismatch(
                    expected: expectedOffset,
                    actual: -1
                )
            }
        }
        let size = ((try fileManager.attributesOfItem(atPath: partURL.path)[.size])
            as? NSNumber)?.int64Value ?? -1
        // A short file means the manifest and the disk disagree; re-requesting
        // from `expectedOffset` would leave a hole, so refuse instead.
        guard size >= expectedOffset else {
            throw SegmentedDownloadError.lengthMismatch(
                expected: expectedOffset,
                actual: size
            )
        }
        handle = try FileHandle(forWritingTo: partURL)
        // Anything past the offset the server is about to re-send is dropped:
        // a pause can land mid-write, and keeping those bytes would duplicate
        // them behind the resumed range.
        try handle.truncate(atOffset: UInt64(expectedOffset))
        try handle.seekToEnd()
        count = expectedOffset
        queue = DispatchQueue(
            label: "patatatube.segment-sink.\(partURL.lastPathComponent)",
            target: .global(qos: .utility)
        )
    }

    /// Accounts for `data` immediately and schedules the write. Throws the
    /// first failure a previously scheduled write hit, so an I/O error still
    /// reaches the segment's failure path — just one chunk later.
    func append(_ data: Data) throws {
        guard !data.isEmpty else { return }
        let decision: (blocked: Bool, failure: Error?) = state.withLock {
            if let writeFailure { return (false, writeFailure) }
            guard !isClosed else {
                return (false, SegmentedDownloadError.sinkClosed)
            }
            count += Int64(data.count)
            pendingByteCount += Int64(data.count)
            return (pendingByteCount >= Self.maxPendingByteCount, nil)
        }
        if let failure = decision.failure { throw failure }

        // Captured strongly on purpose: a scheduled write must land even if the
        // owner drops its reference first. No cycle — the sink does not hold
        // the closure, the queue does, and only until it runs.
        let write = {
            do {
                try self.handle.write(contentsOf: data)
                self.state.withLock { self.pendingByteCount -= Int64(data.count) }
            } catch {
                self.state.withLock {
                    self.pendingByteCount -= Int64(data.count)
                    if self.writeFailure == nil { self.writeFailure = error }
                }
            }
        }
        // Past the pending cap the write happens inline: the transfer must not
        // be allowed to outrun the disk into unbounded memory.
        if decision.blocked {
            queue.sync(execute: write)
            if let failure = state.withLock({ writeFailure }) { throw failure }
        } else {
            queue.async(execute: write)
        }
    }

    /// Drains every scheduled write and closes the file. This barrier is
    /// required, not merely tidy: the caller marks the segment complete right
    /// after, and assembly reads the part file straight afterwards — it must
    /// not read a file the writer has not finished.
    ///
    /// There is deliberately no `fsync`. Assembly reads back through the same
    /// page cache, which outlives the process, and a part file truncated by a
    /// kernel panic is self-correcting: `startIncompleteSegments` sizes the
    /// file on disk and rewrites the manifest to match it.
    func close() {
        state.withLock { isClosed = true }
        queue.sync { try? handle.close() }
    }

    /// The first write error this sink hit, if any. Read after `close` to find
    /// a failure that a later `append` never got the chance to report.
    var failure: Error? { state.withLock { writeFailure } }
}
