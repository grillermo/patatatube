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
final class SegmentByteSink: @unchecked Sendable {
    private let handle: FileHandle
    private(set) var byteCount: Int64

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
        byteCount = expectedOffset
    }

    func append(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try handle.write(contentsOf: data)
        byteCount += Int64(data.count)
    }

    func close() {
        try? handle.synchronize()
        try? handle.close()
    }
}
