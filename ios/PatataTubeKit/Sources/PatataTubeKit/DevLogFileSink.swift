import Foundation

/// Appends records as JSONL to a file path.
///
/// Used by Simulator runs, where the app can write directly to the developer's
/// Mac filesystem (the Simulator shares it), so the agent just tails
/// `log/ios.jsonl` with no server or `simctl` plumbing in between. On a real
/// device there is no such path and `DevLogHTTPSink` carries the log instead.
///
/// All writes arrive on `DevLogCore`'s utility queue, one batch at a time, so
/// this type does no locking of its own beyond guarding the handle.
public final class DevLogFileSink: DevLogSink, @unchecked Sendable {
    /// Past this the file is truncated at open. An instrumented app left running
    /// for a day must not fill the developer's disk.
    public static let maxBytes: UInt64 = 64 * 1024 * 1024

    private let lock = NSLock()
    private var handle: FileHandle?
    private let newline = Data("\n".utf8)

    public init?(path: String, maxBytes: UInt64 = DevLogFileSink.maxBytes) {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)

        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        if let size = (try? fm.attributesOfItem(atPath: path)[.size]) as? UInt64, size > maxBytes {
            try? fm.removeItem(atPath: path)
        }
        if !fm.fileExists(atPath: path) {
            guard fm.createFile(atPath: path, contents: nil) else { return nil }
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
        handle.seekToEndOfFile()
        self.handle = handle
    }

    deinit {
        try? handle?.close()
    }

    public func write(_ records: [DevLogRecord]) {
        let encoder = DevLogEncoding.makeEncoder()
        var blob = Data()
        for record in records {
            guard let line = record.jsonLine(using: encoder) else { continue }
            blob.append(line)
            blob.append(newline)
        }
        guard !blob.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }
        // A failed write must not propagate: the observer never breaks the
        // observed. Worst case the run is only in os_log.
        try? handle?.write(contentsOf: blob)
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
    }
}
