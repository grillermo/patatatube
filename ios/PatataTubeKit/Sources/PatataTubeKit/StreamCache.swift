import Foundation

/// Owner of the temporary stream cache: HLS segment store + MP4 range store +
/// LRU budget. One instance is shared by the playback proxy (read-through
/// writes) and the download manager (seeding, promotion).
public final class StreamCache: @unchecked Sendable {
    public static let defaultBudgetBytes: Int64 = 10 * 1024 * 1024 * 1024

    public let root: URL
    let ranges: RangeStore
    let segments: SegmentCache
    let lru: StreamCacheLRU

    public init(root: URL? = nil, budgetBytes: Int64 = StreamCache.defaultBudgetBytes) {
        let fileManager = FileManager.default
        let resolved = root ?? fileManager
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("stream", isDirectory: true)
        self.root = resolved
        let hlsRoot = resolved.appendingPathComponent("hls", isDirectory: true)
        let mp4Root = resolved.appendingPathComponent("mp4", isDirectory: true)
        try? fileManager.createDirectory(at: hlsRoot, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: mp4Root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directory = resolved
        try? directory.setResourceValues(values)
        self.segments = SegmentCache(root: hlsRoot)
        self.ranges = RangeStore(root: mp4Root)
        self.lru = StreamCacheLRU(managedDirs: [hlsRoot, mp4Root], budgetBytes: budgetBytes)
    }

    /// Record use of an entry and enforce the budget off the caller's path.
    func touchAndEnforce(entryDir: URL) {
        Task.detached(priority: .utility) { [lru] in
            await lru.touch(entryDir)
            await lru.enforce()
        }
    }

    public func removeVideo(id: Int) async {
        await segments.removeAll(videoId: id)
        let mp4Root = root.appendingPathComponent("mp4", isDirectory: true)
        let children = (try? FileManager.default.contentsOfDirectory(
            at: mp4Root, includingPropertiesForKeys: nil
        )) ?? []
        for child in children {
            let name = child.lastPathComponent
            if name == "\(id)" || name.hasPrefix("\(id):") {
                await ranges.remove(key: name)
            }
        }
    }
}
