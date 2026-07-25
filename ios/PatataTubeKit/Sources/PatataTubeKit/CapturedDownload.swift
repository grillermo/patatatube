import Foundation

struct CapturedDownloadManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    let videoId: Int
    let versionId: Int?
    let remoteURL: URL
    let totalByteCount: Int64
    let etag: String
    var capturedRanges: [DownloadByteRange]

    var cacheKey: String { versionId.map { "\(videoId):\($0)" } ?? "\(videoId)" }

    var progress: Double {
        guard totalByteCount > 0 else { return 0 }
        let covered = CapturedRanges.coveredBytes(capturedRanges)
        return min(max(Double(covered) / Double(totalByteCount), 0), 1)
    }

    var isComplete: Bool { CapturedRanges.isComplete(capturedRanges, total: totalByteCount) }

    static func make(
        videoId: Int,
        versionId: Int?,
        remoteURL: URL,
        totalByteCount: Int64,
        etag: String
    ) -> CapturedDownloadManifest {
        CapturedDownloadManifest(
            schemaVersion: currentSchemaVersion,
            videoId: videoId,
            versionId: versionId,
            remoteURL: remoteURL,
            totalByteCount: totalByteCount,
            etag: etag,
            capturedRanges: []
        )
    }

    mutating func capture(_ range: DownloadByteRange) {
        capturedRanges = CapturedRanges.inserting(range, into: capturedRanges)
    }
}

struct CapturedDownloadStore: @unchecked Sendable {
    let root: URL
    private let fileManager: FileManager

    init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    private var downloadsRoot: URL {
        root.appendingPathComponent(".downloads", isDirectory: true)
    }
    func directory(cacheKey: String) -> URL {
        downloadsRoot.appendingPathComponent(cacheKey, isDirectory: true)
    }
    func manifestURL(cacheKey: String) -> URL {
        directory(cacheKey: cacheKey).appendingPathComponent("capture.json")
    }
    func partURL(cacheKey: String) -> URL {
        directory(cacheKey: cacheKey).appendingPathComponent("capture.part")
    }

    func write(_ manifest: CapturedDownloadManifest) throws {
        let dir = directory(cacheKey: manifest.cacheKey)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL(cacheKey: manifest.cacheKey), options: .atomic)
    }

    func load(cacheKey: String) throws -> CapturedDownloadManifest {
        let data = try Data(contentsOf: manifestURL(cacheKey: cacheKey))
        let manifest = try JSONDecoder().decode(CapturedDownloadManifest.self, from: data)
        guard manifest.cacheKey == cacheKey,
              manifest.schemaVersion == CapturedDownloadManifest.currentSchemaVersion else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return manifest
    }

    func manifests() -> [CapturedDownloadManifest] {
        let dirs = (try? fileManager.contentsOfDirectory(
            at: downloadsRoot, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { try? load(cacheKey: $0.lastPathComponent) }
    }

    func remove(cacheKey: String) {
        try? fileManager.removeItem(at: manifestURL(cacheKey: cacheKey))
        try? fileManager.removeItem(at: partURL(cacheKey: cacheKey))
        // Leave the directory if the segmented downloader also uses it.
        try? fileManager.removeItem(at: directory(cacheKey: cacheKey))
    }

    func ensureSparseFile(cacheKey: String, totalByteCount: Int64) throws {
        let dir = directory(cacheKey: cacheKey)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = partURL(cacheKey: cacheKey)
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(totalByteCount))
        }
    }

    func writeRange(cacheKey: String, offset: Int64, data: Data) throws {
        let handle = try FileHandle(forWritingTo: partURL(cacheKey: cacheKey))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
    }

    func readRange(cacheKey: String, range: DownloadByteRange) throws -> Data {
        let handle = try FileHandle(forReadingFrom: partURL(cacheKey: cacheKey))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.start))
        return try handle.read(upToCount: Int(range.length)) ?? Data()
    }

    func publish(cacheKey: String, to destination: URL) throws {
        let part = partURL(cacheKey: cacheKey)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: part)
        } else {
            try fileManager.moveItem(at: part, to: destination)
        }
        remove(cacheKey: cacheKey)
    }
}
