import Foundation

/// LRU over the temporary stream cache. Entries are the immediate child
/// directories of the managed roots; eviction granularity is a whole entry
/// (one video's stream cache). Promoted/downloaded files live outside the
/// managed roots, so they are exempt by construction.
actor StreamCacheLRU {
    private let managedDirs: [URL]
    private let budgetBytes: Int64
    private let fileManager = FileManager.default

    init(managedDirs: [URL], budgetBytes: Int64) {
        self.managedDirs = managedDirs
        self.budgetBytes = budgetBytes
    }

    func touch(_ entryDir: URL) {
        let marker = entryDir.appendingPathComponent(".access")
        if !fileManager.fileExists(atPath: marker.path) {
            fileManager.createFile(atPath: marker.path, contents: nil)
        } else {
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: marker.path)
        }
    }

    /// Sweeps are triggered from essentially every proxy operation, and each one
    /// `stat`s every file under every entry to compute the total. Slow sweeps
    /// are logged so the bookkeeping cost on the request path is measurable —
    /// with a full cache this competes for disk I/O with the reads it is meant
    /// to be serving.
    private static let slowSweepThreshold: TimeInterval = 0.1

    func enforce() {
        let startedAt = Date()
        var entries: [(dir: URL, accessed: Date, size: Int64)] = []
        for managed in managedDirs {
            let children = (try? fileManager.contentsOfDirectory(
                at: managed, includingPropertiesForKeys: [.isDirectoryKey]
            )) ?? []
            for child in children {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                else { continue }
                entries.append((child, accessDate(of: child), directorySize(child)))
            }
        }

        var total = entries.reduce(Int64(0)) { $0 + $1.size }

        let sweepSeconds = Date().timeIntervalSince(startedAt)
        if sweepSeconds >= Self.slowSweepThreshold {
            DevLog.event(.cache, "LRU sweep slow", [
                "ms": "\(Int(sweepSeconds * 1000))",
                "entries": "\(entries.count)",
                "total": "\(total)",
                "budget": "\(budgetBytes)",
            ])
        }
        guard total > budgetBytes else { return }

        // Every eviction is logged. Evicting the entry backing the video that is
        // playing right now is a leading hypothesis for the intermittent
        // failures, and nothing else in the app would reveal it.
        DevLog.event(.cache, "LRU over budget", [
            "total": "\(total)", "budget": "\(budgetBytes)", "entries": "\(entries.count)",
        ])
        for entry in entries.sorted(by: { $0.accessed < $1.accessed }) {
            guard (try? fileManager.removeItem(at: entry.dir)) != nil else { continue }
            total -= entry.size
            DevLog.event(.cache, "LRU evicted", [
                "entry": entry.dir.lastPathComponent,
                "bytes": "\(entry.size)",
                "accessed": DevLogEncoding.timestampFormatter.string(from: entry.accessed),
                "remaining": "\(total)",
            ])
            if total <= budgetBytes { break }
        }
    }

    /// Frees one cache entry after a storage write failure. Prefer another
    /// entry so a valid in-flight identity remains intact.
    @discardableResult
    func evictOldest(excluding excluded: URL? = nil) -> Bool {
        var entries: [(dir: URL, accessed: Date)] = []
        for managed in managedDirs {
            let children = (try? fileManager.contentsOfDirectory(
                at: managed,
                includingPropertiesForKeys: [.isDirectoryKey]
            )) ?? []
            for child in children {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory == true
                else {
                    continue
                }
                entries.append((child, accessDate(of: child)))
            }
        }

        let excludedPath = excluded?.standardizedFileURL.path
        for entry in entries.sorted(by: { $0.accessed < $1.accessed })
        where entry.dir.standardizedFileURL.path != excludedPath
        {
            if (try? fileManager.removeItem(at: entry.dir)) != nil {
                DevLog.event(.cache, "evicted for storage failure", [
                    "entry": entry.dir.lastPathComponent,
                    "excluded": excluded?.lastPathComponent ?? "-",
                ])
                return true
            }
        }
        DevLog.event(.cache, "storage-failure eviction found nothing to free", [
            "entries": "\(entries.count)",
            "excluded": excluded?.lastPathComponent ?? "-",
        ])
        return false
    }

    private func accessDate(of dir: URL) -> Date {
        let marker = dir.appendingPathComponent(".access")
        let path = fileManager.fileExists(atPath: marker.path) ? marker.path : dir.path
        let attrs = try? fileManager.attributesOfItem(atPath: path)
        return (attrs?[.modificationDate] as? Date) ?? .distantPast
    }

    private func directorySize(_ dir: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: dir,
            includingPropertiesForKeys: [.fileAllocatedSizeKey, .fileSizeKey]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(
                forKeys: [.fileAllocatedSizeKey, .fileSizeKey]
            )
            total += Int64(values?.fileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }
}
