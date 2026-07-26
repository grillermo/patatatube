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

    /// Pre-fills segmented-download part files from streamed bytes. Only
    /// prefixes count (the resume machinery models "bytes from segment
    /// start"); only applies when the cached entity matches the probe.
    func seedSegments(
        manifest: SegmentedDownloadManifest,
        into store: SegmentedDownloadStore
    ) async -> SegmentedDownloadManifest {
        let key = manifest.cacheKey
        guard
            let cached = await ranges.manifest(key: key),
            cached.etag == manifest.etag,
            cached.totalByteCount == manifest.totalByteCount
        else {
            return manifest
        }

        var seeded = manifest
        var didSeed = false

        for index in seeded.segments.indices {
            let segment = seeded.segments[index]
            let prefix = cached.ranges.prefixLength(
                from: segment.range.start,
                limit: segment.range.length
            )
            guard prefix > 0 else { continue }

            let part = store.partURL(cacheKey: key, index: segment.index)
            do {
                try FileManager.default.createDirectory(
                    at: part.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                FileManager.default.createFile(
                    atPath: part.path,
                    contents: nil
                )
                let handle = try FileHandle(forWritingTo: part)
                defer { try? handle.close() }

                let range = DownloadByteRange(
                    start: segment.range.start,
                    end: segment.range.start + prefix - 1
                )
                guard try await ranges.copyRange(
                    key: key,
                    range: range,
                    to: handle
                ) else {
                    try? FileManager.default.removeItem(at: part)
                    continue
                }
                try handle.synchronize()
            } catch {
                try? FileManager.default.removeItem(at: part)
                continue
            }

            seeded.segments[index].persistedByteCount = prefix
            if prefix == segment.range.length {
                seeded.segments[index].isComplete = true
            }
            didSeed = true
        }

        guard didSeed else { return manifest }
        do {
            try store.write(seeded)
            return seeded
        } catch {
            return manifest
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
