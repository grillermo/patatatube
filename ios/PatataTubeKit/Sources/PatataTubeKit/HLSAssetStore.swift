import Foundation

/// One cached HLS package. The `.movpkg` location is chosen by AVFoundation, so
/// it is stored as a bookmark and never assumed to exist: iOS may purge these
/// packages, and a moved package must never be resurrected from a stale path.
struct HLSCacheEntry: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Written by watching. LRU-evictable.
        case temp
        /// The user asked for it (or a watch completed it). Never evicted.
        case permanent
    }

    let cacheKey: String
    let videoId: Int
    let versionId: Int?
    var bookmark: Data
    var kind: Kind
    var isComplete: Bool
    /// Time-based, as reported by AVFoundation — not a byte ratio.
    var fractionComplete: Double
    var byteCount: Int64
    var lastPlayedAt: Date
    /// Audio language the package was built with. A different server-side choice
    /// makes this package stale.
    var audioLang: String?
}

/// The cache index. Disk bookkeeping only — no AVFoundation, no networking, so
/// every rule here is unit-testable.
final class HLSAssetStore: @unchecked Sendable {
    private let root: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var index: [String: HLSCacheEntry]

    init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
        self.index = Self.load(indexURL: Self.indexURL(root: root), fileManager: fileManager)
    }

    private static func indexURL(root: URL) -> URL {
        root.appendingPathComponent("hls-cache", isDirectory: true)
            .appendingPathComponent("index.json")
    }

    /// A corrupt or missing index is an empty cache, never a crash: the packages
    /// it described are unreachable without their bookmarks anyway.
    private static func load(indexURL: URL, fileManager: FileManager) -> [String: HLSCacheEntry] {
        guard let data = try? Data(contentsOf: indexURL),
              let entries = try? JSONDecoder().decode([HLSCacheEntry].self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.cacheKey, $0) })
    }

    private func persistLocked() {
        let url = Self.indexURL(root: root)
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Array(index.values)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func entries() -> [HLSCacheEntry] {
        lock.withLock { Array(index.values) }
    }

    func entry(cacheKey: String) -> HLSCacheEntry? {
        lock.withLock { index[cacheKey] }
    }

    func upsert(_ entry: HLSCacheEntry) {
        lock.withLock {
            index[entry.cacheKey] = entry
            persistLocked()
        }
    }

    /// Drops the row *and* deletes the package it points at.
    func remove(cacheKey: String) {
        let entry = lock.withLock { () -> HLSCacheEntry? in
            let entry = index.removeValue(forKey: cacheKey)
            persistLocked()
            return entry
        }
        guard let entry, let url = resolveWithoutPruning(entry) else { return }
        try? fileManager.removeItem(at: url)
    }

    func removeAll() {
        for entry in entries() { remove(cacheKey: entry.cacheKey) }
    }

    static func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData()
    }

    /// The package's current location, or nil when it is gone — in which case the
    /// row is dropped so `state(for:)` reports `.notCached` from then on.
    func resolve(_ entry: HLSCacheEntry) -> URL? {
        guard let url = resolveWithoutPruning(entry) else {
            lock.withLock {
                index.removeValue(forKey: entry.cacheKey)
                persistLocked()
            }
            return nil
        }
        return url
    }

    private func resolveWithoutPruning(_ entry: HLSCacheEntry) -> URL? {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: entry.bookmark, bookmarkDataIsStale: &stale),
            fileManager.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    /// Bytes a `.movpkg` occupies. Walked on demand (task end, eviction scan),
    /// never per progress callback.
    func directorySize(of url: URL) -> Int64 {
        guard let walker = fileManager.enumerator(
            at: url, includingPropertiesForKeys: [.fileAllocatedSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let child as URL in walker {
            let size = (try? child.resourceValues(forKeys: [.fileAllocatedSizeKey]))?
                .fileAllocatedSize ?? 0
            total += Int64(size)
        }
        return total
    }
}
