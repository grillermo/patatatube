import Foundation

public struct DownloadActivity: Equatable, Identifiable, Sendable {
    public let videoID: Int
    public let versionID: Int?
    public let progress: Double
    public let transferredByteCount: Int64
    public let totalByteCount: Int64?
    public let bytesPerSecond: Double?

    public init(
        videoID: Int,
        versionID: Int?,
        progress: Double,
        transferredByteCount: Int64,
        totalByteCount: Int64?,
        bytesPerSecond: Double?
    ) {
        self.videoID = videoID
        self.versionID = versionID
        self.progress = progress
        self.transferredByteCount = transferredByteCount
        self.totalByteCount = totalByteCount
        self.bytesPerSecond = bytesPerSecond
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
    /// Reported speed is averaged over the most recent samples in this window so
    /// the UI number stays readable instead of jumping every callback.
    static let averagingWindow: TimeInterval = 2.5

    private let videoID: Int
    private let versionID: Int?
    private var totalByteCount: Int64?
    private var samples: [(bytes: Int64, date: Date)]
    private(set) var activity: DownloadActivity

    init(videoID: Int, versionID: Int?, totalByteCount: Int64?, now: Date) {
        self.videoID = videoID
        self.versionID = versionID
        self.totalByteCount = totalByteCount
        self.samples = [(0, now)]
        self.activity = DownloadActivity(
            videoID: videoID,
            versionID: versionID,
            progress: 0,
            transferredByteCount: 0,
            totalByteCount: totalByteCount,
            bytesPerSecond: nil
        )
    }

    mutating func establishResumeSamplingBaseline(
        totalBytesWritten: Int64,
        bytesWritten: Int64
    ) {
        let currentWrite = max(bytesWritten, 0)
        let baseline = totalBytesWritten > currentWrite
            ? totalBytesWritten - currentWrite
            : 0
        let anchorDate = samples.last?.date ?? Date()
        samples = [(baseline, anchorDate)]
    }

    mutating func record(
        transferredByteCount: Int64,
        progress: Double,
        totalByteCount: Int64? = nil,
        now: Date
    ) {
        let clampedTransferredByteCount = max(transferredByteCount, 0)
        // Ignore out-of-order callbacks so the sample window stays monotonic.
        if now >= (samples.last?.date ?? now) {
            samples.append((clampedTransferredByteCount, now))
            let cutoff = now.addingTimeInterval(-Self.averagingWindow)
            // Keep the newest sample plus everything within the window.
            samples.removeAll { $0.date < cutoff }
        }
        let rate = averagedRate() ?? activity.bytesPerSecond
        activity = DownloadActivity(
            videoID: videoID,
            versionID: versionID,
            progress: min(max(progress, 0), 1),
            transferredByteCount: clampedTransferredByteCount,
            totalByteCount: totalByteCount ?? self.totalByteCount,
            bytesPerSecond: rate
        )
        self.totalByteCount = totalByteCount ?? self.totalByteCount
    }

    private func averagedRate() -> Double? {
        guard let oldest = samples.first, let newest = samples.last else { return nil }
        let span = newest.date.timeIntervalSince(oldest.date)
        let byteDelta = newest.bytes - oldest.bytes
        guard span > 0, byteDelta > 0 else { return nil }
        return Double(byteDelta) / span
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
