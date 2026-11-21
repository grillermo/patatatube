import Foundation

/// Thrown by a download whose transfer was paused. Distinct from
/// `CancellationError` so callers can tell "the user paused this, its partial
/// bytes are still on disk" from "the user cancelled, everything was wiped".
public struct DownloadPausedError: Error, Equatable, Sendable {
    public init() {}
}

/// A download the user paused. Carries everything needed to restart the
/// transfer.
public struct PausedDownload: Codable, Equatable, Identifiable, Sendable {
    public let videoID: Int
    public let versionID: Int?
    public let remoteURL: URL
    public let streamCount: Int
    public let previewURL: URL?
    public let showPosterKey: String?
    public let showPosterURL: URL?
    /// Progress at the moment of pausing, so the frozen row still renders.
    public let progress: Double
    public let transferredByteCount: Int64
    public let totalByteCount: Int64?

    public init(
        videoID: Int,
        versionID: Int?,
        remoteURL: URL,
        streamCount: Int,
        previewURL: URL?,
        showPosterKey: String?,
        showPosterURL: URL?,
        progress: Double,
        transferredByteCount: Int64,
        totalByteCount: Int64?
    ) {
        self.videoID = videoID
        self.versionID = versionID
        self.remoteURL = remoteURL
        self.streamCount = streamCount
        self.previewURL = previewURL
        self.showPosterKey = showPosterKey
        self.showPosterURL = showPosterURL
        self.progress = progress
        self.transferredByteCount = transferredByteCount
        self.totalByteCount = totalByteCount
    }

    /// The `CacheManager` cache key, so this store is keyed exactly like
    /// `inFlight`, `tasksByKey`, and `segmentedAttempts`.
    public var id: String { versionID.map { "\(videoID):\($0)" } ?? "\(videoID)" }
}

/// 2.8's paused downloads (`paused-downloads.json`). Read only by
/// `LegacyCacheMigration`, which turns each entry into a paused, pinned
/// `MediaStore` entry and empties the file; it also still records 2.8 HLS
/// pauses for `CacheManager.removeLegacyHLSPackages`.
struct PausedDownloadStore {
    private let url: URL
    private let fileManager: FileManager
    private(set) var entries: [PausedDownload]

    init(root: URL, fileManager: FileManager = .default) {
        self.url = root.appendingPathComponent("paused-downloads.json")
        self.fileManager = fileManager
        let decoded = (try? Data(contentsOf: url)).flatMap {
            try? JSONDecoder().decode([PausedDownload].self, from: $0)
        } ?? []
        // A 2.8-era pause of an HLS download stored its master playlist URL.
        // There is no HLS path any more: drop those entries and record their
        // ids, which CacheManager.removeLegacyHLSPackages re-downloads.
        let isHLS: (PausedDownload) -> Bool = { $0.remoteURL.pathExtension == "m3u8" }
        self.entries = decoded.filter { !isHLS($0) }
        let dropped = decoded.filter(isHLS).map(\.videoID)
        if !dropped.isEmpty {
            Self.recordDroppedHLS(dropped, root: root)
            persist()
        }
    }

    private static func droppedURL(root: URL) -> URL {
        root.appendingPathComponent("paused-hls-dropped.json")
    }

    private static func recordDroppedHLS(_ ids: [Int], root: URL) {
        let merged = Set(droppedHLSVideoIDs(root: root)).union(ids)
        guard let data = try? JSONEncoder().encode(merged.sorted()) else { return }
        try? data.write(to: droppedURL(root: root), options: .atomic)
    }

    /// Video ids whose paused HLS download was dropped at load, ascending.
    static func droppedHLSVideoIDs(root: URL) -> [Int] {
        (try? Data(contentsOf: droppedURL(root: root)))
            .flatMap { try? JSONDecoder().decode([Int].self, from: $0) } ?? []
    }

    static func clearDroppedHLS(root: URL) {
        try? FileManager.default.removeItem(at: droppedURL(root: root))
    }

    func contains(_ key: String) -> Bool {
        entries.contains { $0.id == key }
    }

    func entry(_ key: String) -> PausedDownload? {
        entries.first { $0.id == key }
    }

    mutating func insert(_ entry: PausedDownload) {
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        persist()
    }

    mutating func remove(_ key: String) {
        guard contains(key) else { return }
        entries.removeAll { $0.id == key }
        persist()
    }

    mutating func removeAll() {
        entries = []
        try? fileManager.removeItem(at: url)
    }

    private func persist() {
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
