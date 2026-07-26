import Foundation

/// LRU policy for the temporary watch cache. Pure selection: the caller deletes.
enum CacheEvictor {
    /// Cache keys to drop so `temp` entries fit inside `capBytes`.
    ///
    /// `permanent` entries are what the user asked to keep — they are neither
    /// counted against the cap nor evicted. `protectedKeys` are keys with a live
    /// download task; evicting one would delete a package AVFoundation is
    /// writing to.
    static func keysToEvict(
        entries: [HLSCacheEntry], capBytes: Int64, protectedKeys: Set<String>
    ) -> [String] {
        let temps = entries.filter { $0.kind == .temp }
        var total = temps.reduce(Int64(0)) { $0 + $1.byteCount }
        guard total > capBytes else { return [] }

        var victims: [String] = []
        for candidate in temps
            .filter({ !protectedKeys.contains($0.cacheKey) })
            .sorted(by: { $0.lastPlayedAt < $1.lastPlayedAt })
        {
            guard total > capBytes else { break }
            victims.append(candidate.cacheKey)
            total -= candidate.byteCount
        }
        return victims
    }
}
