import Foundation

public struct DownloadActivity: Equatable, Identifiable, Sendable {
    public let videoID: Int
    public let versionID: Int?
    public let progress: Double
    public let transferredByteCount: Int64
    public let totalByteCount: Int64?

    public init(
        videoID: Int,
        versionID: Int?,
        progress: Double,
        transferredByteCount: Int64,
        totalByteCount: Int64?
    ) {
        self.videoID = videoID
        self.versionID = versionID
        self.progress = progress
        self.transferredByteCount = transferredByteCount
        self.totalByteCount = totalByteCount
    }

    public var id: String { versionID.map { "\(videoID):\($0)" } ?? "\(videoID)" }
}

public struct DownloadCompletion: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let videoID: Int
    public let versionID: Int?
    public let completedAt: Date

    public init(videoID: Int, versionID: Int?, completedAt: Date) {
        self.videoID = videoID
        self.versionID = versionID
        self.completedAt = completedAt
    }

    public var id: String { versionID.map { "\(videoID):\($0)" } ?? "\(videoID)" }
}

struct DownloadActivityAccumulator {
    private let videoID: Int
    private let versionID: Int?
    private var totalByteCount: Int64?
    private(set) var activity: DownloadActivity

    init(videoID: Int, versionID: Int?, totalByteCount: Int64?) {
        self.videoID = videoID
        self.versionID = versionID
        self.totalByteCount = totalByteCount
        self.activity = DownloadActivity(
            videoID: videoID,
            versionID: versionID,
            progress: 0,
            transferredByteCount: 0,
            totalByteCount: totalByteCount
        )
    }

    mutating func record(
        transferredByteCount: Int64,
        progress: Double,
        totalByteCount: Int64? = nil
    ) {
        let clampedTransferredByteCount = max(transferredByteCount, 0)
        activity = DownloadActivity(
            videoID: videoID,
            versionID: versionID,
            progress: min(max(progress, 0), 1),
            transferredByteCount: clampedTransferredByteCount,
            totalByteCount: totalByteCount ?? self.totalByteCount
        )
        self.totalByteCount = totalByteCount ?? self.totalByteCount
    }
}

struct DownloadCompletionHistoryStore {
    private let url: URL
    private let fileManager: FileManager
    private(set) var entries: [DownloadCompletion]

    init(root: URL, fileManager: FileManager = .default) {
        self.url = root.appendingPathComponent("download-completions.json")
        self.fileManager = fileManager
        let loaded = ((try? Data(contentsOf: url)).flatMap {
            try? JSONDecoder().decode([DownloadCompletion].self, from: $0)
        } ?? []).sorted { $0.completedAt > $1.completedAt }
        self.entries = Array(loaded.prefix(3))
        if entries.count != loaded.count {
            persist()
        }
    }

    mutating func record(_ entry: DownloadCompletion) {
        entries.removeAll { $0.id == entry.id }
        entries = Array(([entry] + entries)
            .sorted { $0.completedAt > $1.completedAt }
            .prefix(3))
        persist()
    }

    mutating func prune(_ isPlayable: (DownloadCompletion) -> Bool) -> [DownloadCompletion] {
        let retained = entries.filter(isPlayable)
        if retained != entries {
            entries = retained
            persist()
        }
        return entries
    }

    mutating func clear() {
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
