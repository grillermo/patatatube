import Foundation

/// Thrown by a download whose transfer was paused. Distinct from
/// `CancellationError` so callers can tell "the user paused this, its partial
/// bytes are still on disk" from "the user cancelled, everything was wiped".
public struct DownloadPausedError: Error, Equatable, Sendable {
    public init() {}
}

/// A download the user paused. Carries everything needed to restart the
/// transfer, because the HLS path keeps no partial state on disk to recover
/// its parameters from.
public struct PausedDownload: Codable, Equatable, Identifiable, Sendable {
    public let videoID: Int
    public let versionID: Int?
    public let remoteURL: URL
    /// True when `remoteURL` is an HLS master playlist and resuming must go
    /// through `downloadHLS` rather than `download`.
    public let isHLS: Bool
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
        isHLS: Bool,
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
        self.isHLS = isHLS
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

/// Paused downloads, persisted as `paused-downloads.json` in the cache root.
///
/// Mirrors `DownloadCompletionHistoryStore`: load in `init`, rewrite the whole
/// file on every mutation, best-effort throughout. No capacity cap — entries
/// only ever appear and disappear by explicit user action.
struct PausedDownloadStore {
    private let url: URL
    private let fileManager: FileManager
    private(set) var entries: [PausedDownload]

    init(root: URL, fileManager: FileManager = .default) {
        self.url = root.appendingPathComponent("paused-downloads.json")
        self.fileManager = fileManager
        self.entries = (try? Data(contentsOf: url)).flatMap {
            try? JSONDecoder().decode([PausedDownload].self, from: $0)
        } ?? []
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
