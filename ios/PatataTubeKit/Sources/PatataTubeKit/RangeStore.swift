import Foundation

struct RangeStoreManifest: Codable, Equatable, Sendable {
    let etag: String
    let totalByteCount: Int64
    var ranges: ByteRangeSet
}

/// Sparse on-disk cache of remote MP4 byte ranges. One entry per cache key:
/// `data.bin` written at offsets (APFS keeps holes sparse) plus `ranges.json`
/// recording which runs are committed. Only committed runs are ever served.
actor RangeStore {
    let root: URL
    private let fileManager = FileManager.default

    init(root: URL) {
        self.root = root
    }

    nonisolated func entryDir(key: String) -> URL {
        root.appendingPathComponent(key, isDirectory: true)
    }

    private func dataURL(key: String) -> URL {
        entryDir(key: key).appendingPathComponent("data.bin")
    }

    private func manifestURL(key: String) -> URL {
        entryDir(key: key).appendingPathComponent("ranges.json")
    }

    func manifest(key: String) -> RangeStoreManifest? {
        guard let data = try? Data(contentsOf: manifestURL(key: key)) else { return nil }
        guard let manifest = try? JSONDecoder().decode(RangeStoreManifest.self, from: data),
              isValid(manifest),
              fileManager.fileExists(atPath: dataURL(key: key).path)
        else {
            remove(key: key)
            return nil
        }
        return manifest
    }

    func prepare(key: String, etag: String, totalByteCount: Int64) throws {
        if let existing = manifest(key: key),
           existing.etag == etag, existing.totalByteCount == totalByteCount {
            return
        }

        remove(key: key)
        try fileManager.createDirectory(at: entryDir(key: key), withIntermediateDirectories: true)
        guard fileManager.createFile(atPath: dataURL(key: key).path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try save(
            RangeStoreManifest(etag: etag, totalByteCount: totalByteCount, ranges: ByteRangeSet()),
            key: key
        )
    }

    func write(key: String, at offset: Int64, data: Data) throws {
        guard var manifest = manifest(key: key), !data.isEmpty else { return }
        let (end, overflow) = offset.addingReportingOverflow(Int64(data.count) - 1)
        guard offset >= 0, !overflow, end < manifest.totalByteCount else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: dataURL(key: key))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
        try handle.synchronize()
        manifest.ranges.insert(DownloadByteRange(start: offset, end: end))
        try save(manifest, key: key)
    }

    func read(key: String, range: DownloadByteRange) throws -> Data? {
        guard let manifest = manifest(key: key),
              isValid(range, for: manifest),
              manifest.ranges.contains(range)
        else { return nil }
        let handle = try FileHandle(forReadingFrom: dataURL(key: key))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.start))
        guard let data = try handle.read(upToCount: Int(range.length)), data.count == Int(range.length) else {
            remove(key: key)
            return nil
        }
        return data
    }

    /// Chunked copy of a fully-cached range into `handle` (for download seeding).
    func copyRange(
        key: String,
        range: DownloadByteRange,
        expectedETag: String,
        expectedTotalByteCount: Int64,
        to handle: FileHandle
    ) throws -> Bool {
        guard let manifest = manifest(key: key),
              manifest.etag == expectedETag,
              manifest.totalByteCount == expectedTotalByteCount,
              isValid(range, for: manifest),
              manifest.ranges.contains(range)
        else { return false }
        return try copyCachedRange(key: key, range: range, to: handle)
    }

    func copyRange(
        key: String,
        range: DownloadByteRange,
        to handle: FileHandle
    ) throws -> Bool {
        guard let manifest = manifest(key: key),
              isValid(range, for: manifest),
              manifest.ranges.contains(range)
        else { return false }
        return try copyCachedRange(key: key, range: range, to: handle)
    }

    private func copyCachedRange(
        key: String,
        range: DownloadByteRange,
        to handle: FileHandle
    ) throws -> Bool {
        let input = try FileHandle(forReadingFrom: dataURL(key: key))
        defer { try? input.close() }
        try input.seek(toOffset: UInt64(range.start))

        var remaining = range.length
        while remaining > 0 {
            let chunkSize = Int(min(remaining, 1_048_576))
            guard let chunk = try input.read(upToCount: chunkSize), chunk.count == chunkSize else {
                remove(key: key)
                return false
            }
            try handle.write(contentsOf: chunk)
            remaining -= Int64(chunk.count)
        }
        return true
    }

    func remove(key: String) {
        try? fileManager.removeItem(at: entryDir(key: key))
    }

    private func save(_ manifest: RangeStoreManifest, key: String) throws {
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL(key: key), options: .atomic)
    }

    private func isValid(_ manifest: RangeStoreManifest) -> Bool {
        manifest.totalByteCount > 0 && manifest.ranges.runs.allSatisfy {
            isValid($0, totalByteCount: manifest.totalByteCount)
        }
    }

    private func isValid(_ range: DownloadByteRange, for manifest: RangeStoreManifest) -> Bool {
        isValid(range, totalByteCount: manifest.totalByteCount)
    }

    private func isValid(_ range: DownloadByteRange, totalByteCount: Int64) -> Bool {
        range.start >= 0 && range.end >= range.start && range.end < totalByteCount
    }
}
