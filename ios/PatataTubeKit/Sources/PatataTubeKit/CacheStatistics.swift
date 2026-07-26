import Foundation

/// One row in the Settings statistics section. `budgetBytes` is non-nil only
/// for the derived `proxy.total` row, which has an enforced LRU cap.
public struct CacheStat: Sendable, Identifiable, Equatable {
    public let id: String
    public let label: String
    public let byteCount: Int64
    public let itemCount: Int
    public let budgetBytes: Int64?

    public init(id: String, label: String, byteCount: Int64, itemCount: Int, budgetBytes: Int64?) {
        self.id = id
        self.label = label
        self.byteCount = byteCount
        self.itemCount = itemCount
        self.budgetBytes = budgetBytes
    }
}

/// Classifies a top-level entry of `Documents/videos/` using the same
/// filename conventions `CacheManager` uses to find/clear its own files.
enum CacheEntryKind: Equatable {
    case mp4
    case hls
    case cover
    case partial
    case history
    case other

    static func classify(name: String) -> CacheEntryKind {
        if name == "download-completions.json" { return .history }
        if name == ".downloads" { return .partial }
        if name.hasSuffix(".resume") { return .partial }
        if name.hasPrefix("hls-") { return .hls }
        if name.hasSuffix(".mp4") { return .mp4 }
        if name.contains(".preview.") || name.hasPrefix("poster.") { return .cover }
        return .other
    }
}

/// Walks every on-disk cache PatataTube maintains and reports byte/item
/// counts per store. Read-only: never deletes or touches anything.
///
/// A separate type rather than a `CacheManager` extension: `CacheManager` is
/// already large and statistics need none of its mutable state, only the
/// naming rules above.
public actor CacheStatisticsCollector {
    private struct Accumulator {
        var byteCount: Int64 = 0
        var itemCount: Int = 0
    }

    private struct VideoRows {
        var mp4 = Accumulator()
        var hls = Accumulator()
        var covers = Accumulator()
        var partial = Accumulator()
        var history = Accumulator()
        var other = Accumulator()
    }

    private let videosRoot: URL
    private let streamRoot: URL
    private let videoListRoot: URL
    private let tmpRoot: URL
    private let fileManager: FileManager
    private let proxyBudgetBytes: Int64

    public init(
        videosRoot: URL,
        streamRoot: URL,
        videoListRoot: URL,
        tmpRoot: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default,
        proxyBudgetBytes: Int64 = StreamCache.defaultBudgetBytes
    ) {
        self.videosRoot = videosRoot
        self.streamRoot = streamRoot
        self.videoListRoot = videoListRoot
        self.tmpRoot = tmpRoot
        self.fileManager = fileManager
        self.proxyBudgetBytes = proxyBudgetBytes
    }

    public func collect() -> [CacheStat] {
        let proxyHLS = scanProxyRoot(streamRoot.appendingPathComponent("hls", isDirectory: true))
        let proxyMP4 = scanProxyRoot(streamRoot.appendingPathComponent("mp4", isDirectory: true))
        let videos = scanVideosRoot()
        let lists = scanFlatDirectory(videoListRoot, matchingExtension: "json")
        let staging = scanStagingRoot()

        var stats: [CacheStat] = [
            CacheStat(
                id: "proxy.hls", label: "Proxy — HLS segments",
                byteCount: proxyHLS.byteCount, itemCount: proxyHLS.itemCount, budgetBytes: nil
            ),
            CacheStat(
                id: "proxy.mp4", label: "Proxy — MP4 ranges",
                byteCount: proxyMP4.byteCount, itemCount: proxyMP4.itemCount, budgetBytes: nil
            ),
            CacheStat(
                id: "videos.mp4", label: "Offline videos",
                byteCount: videos.mp4.byteCount, itemCount: videos.mp4.itemCount, budgetBytes: nil
            ),
            CacheStat(
                id: "videos.hls", label: "Offline HLS packages",
                byteCount: videos.hls.byteCount, itemCount: videos.hls.itemCount, budgetBytes: nil
            ),
            CacheStat(
                id: "videos.covers", label: "Covers",
                byteCount: videos.covers.byteCount, itemCount: videos.covers.itemCount, budgetBytes: nil
            ),
            CacheStat(
                id: "videos.partial", label: "Partial downloads",
                byteCount: videos.partial.byteCount, itemCount: videos.partial.itemCount, budgetBytes: nil
            ),
            CacheStat(
                id: "videos.history", label: "Download history",
                byteCount: videos.history.byteCount, itemCount: videos.history.itemCount, budgetBytes: nil
            ),
            CacheStat(
                id: "lists", label: "Video list cache",
                byteCount: lists.byteCount, itemCount: lists.itemCount, budgetBytes: nil
            ),
            CacheStat(
                id: "staging", label: "Staging temp",
                byteCount: staging.byteCount, itemCount: staging.itemCount, budgetBytes: nil
            ),
            CacheStat(
                id: "other", label: "Other files",
                byteCount: videos.other.byteCount, itemCount: videos.other.itemCount, budgetBytes: nil
            ),
        ]

        let totalBytes = stats.reduce(Int64(0)) { $0 + $1.byteCount }
        let totalItems = stats.reduce(0) { $0 + $1.itemCount }

        // Inserted after the fact so it can sum every other row without
        // double-counting itself; excluded from `total` by construction.
        stats.insert(
            CacheStat(
                id: "proxy.total", label: "Proxy cache total",
                byteCount: proxyHLS.byteCount + proxyMP4.byteCount,
                itemCount: proxyHLS.itemCount + proxyMP4.itemCount,
                budgetBytes: proxyBudgetBytes
            ),
            at: 2
        )
        stats.append(
            CacheStat(id: "total", label: "Total", byteCount: totalBytes, itemCount: totalItems, budgetBytes: nil)
        )
        return stats
    }

    // MARK: - Scanning

    private func scanProxyRoot(_ dir: URL) -> Accumulator {
        let children = (try? fileManager.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        let itemCount = children.reduce(0) { count, child in
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return count + (isDirectory ? 1 : 0)
        }
        return Accumulator(byteCount: recursiveSize(of: dir), itemCount: itemCount)
    }

    private func scanVideosRoot() -> VideoRows {
        var rows = VideoRows()
        let entries = (try? fileManager.contentsOfDirectory(
            at: videosRoot, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []

        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let bytes = recursiveSize(of: entry)

            switch CacheEntryKind.classify(name: entry.lastPathComponent) {
            case .mp4:
                rows.mp4.byteCount += bytes
                rows.mp4.itemCount += 1
            case .hls:
                rows.hls.byteCount += bytes
                rows.hls.itemCount += 1
            case .cover:
                rows.covers.byteCount += bytes
                rows.covers.itemCount += 1
            case .partial:
                rows.partial.byteCount += bytes
                if isDirectory {
                    // `.downloads/`: each child is one in-progress manifest.
                    let manifestDirs = (try? fileManager.contentsOfDirectory(
                        at: entry, includingPropertiesForKeys: nil
                    ))?.count ?? 0
                    rows.partial.itemCount += manifestDirs
                } else {
                    rows.partial.itemCount += 1
                }
            case .history:
                rows.history.byteCount += bytes
                rows.history.itemCount += 1
            case .other:
                rows.other.byteCount += bytes
                rows.other.itemCount += 1
            }
        }
        return rows
    }

    private func scanFlatDirectory(_ dir: URL, matchingExtension ext: String) -> Accumulator {
        let entries = (try? fileManager.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]
        )) ?? []
        var acc = Accumulator()
        for entry in entries where entry.pathExtension == ext {
            acc.byteCount += fileAllocatedSize(entry)
            acc.itemCount += 1
        }
        return acc
    }

    private func scanStagingRoot() -> Accumulator {
        let entries = (try? fileManager.contentsOfDirectory(
            at: tmpRoot, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        var acc = Accumulator()
        for entry in entries where entry.lastPathComponent.hasPrefix("patatatube-seed-") {
            acc.byteCount += recursiveSize(of: entry)
            acc.itemCount += 1
        }
        return acc
    }

    // MARK: - Byte accounting

    private func fileAllocatedSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
    }

    private func recursiveSize(of url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else { return fileAllocatedSize(url) }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isDirectoryKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isDirectoryKey]
            )
            guard values?.isDirectory != true else { continue }
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }
}
