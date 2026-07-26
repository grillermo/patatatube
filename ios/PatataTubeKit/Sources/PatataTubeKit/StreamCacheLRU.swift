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

    func enforce() {
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
        guard total > budgetBytes else { return }
        for entry in entries.sorted(by: { $0.accessed < $1.accessed }) {
            try? fileManager.removeItem(at: entry.dir)
            total -= entry.size
            if total <= budgetBytes { break }
        }
    }

    private func accessDate(of dir: URL) -> Date {
        let marker = dir.appendingPathComponent(".access")
        let path = fileManager.fileExists(atPath: marker.path) ? marker.path : dir.path
        let attrs = try? fileManager.attributesOfItem(atPath: path)
        return (attrs?[.modificationDate] as? Date) ?? .distantPast
    }

    private func directorySize(_ dir: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}
