import Foundation
import Testing
@testable import PatataTubeKit

private func entry(
    _ key: String, kind: HLSCacheEntry.Kind, bytes: Int64, playedAt: TimeInterval
) -> HLSCacheEntry {
    HLSCacheEntry(
        cacheKey: key, videoId: Int(key.prefix(1)) ?? 0, versionId: nil,
        bookmark: Data([0x1]), kind: kind, isComplete: false,
        fractionComplete: 0.5, byteCount: bytes,
        lastPlayedAt: Date(timeIntervalSince1970: playedAt), audioLang: nil)
}

@Suite("HLS cache eviction")
struct HLSCacheEvictionTests {
    @Test func noEvictionWhenUnderCap() {
        let keys = CacheEvictor.keysToEvict(
            entries: [entry("1", kind: .temp, bytes: 100, playedAt: 1)],
            capBytes: 1_000, protectedKeys: [])
        #expect(keys.isEmpty)
    }

    @Test func evictsOldestTempFirstUntilUnderCap() {
        let entries = [
            entry("1", kind: .temp, bytes: 400, playedAt: 30),
            entry("2", kind: .temp, bytes: 400, playedAt: 10),
            entry("3", kind: .temp, bytes: 400, playedAt: 20),
        ]
        let keys = CacheEvictor.keysToEvict(
            entries: entries, capBytes: 900, protectedKeys: [])
        #expect(keys == ["2"])
    }

    @Test func evictsMultipleWhenOneIsNotEnough() {
        let entries = [
            entry("1", kind: .temp, bytes: 400, playedAt: 30),
            entry("2", kind: .temp, bytes: 400, playedAt: 10),
            entry("3", kind: .temp, bytes: 400, playedAt: 20),
        ]
        let keys = CacheEvictor.keysToEvict(
            entries: entries, capBytes: 500, protectedKeys: [])
        #expect(keys == ["2", "3"])
    }

    @Test func permanentEntriesAreNeitherEvictedNorCounted() {
        let entries = [
            entry("1", kind: .permanent, bytes: 5_000, playedAt: 1),
            entry("2", kind: .temp, bytes: 100, playedAt: 2),
        ]
        let keys = CacheEvictor.keysToEvict(
            entries: entries, capBytes: 1_000, protectedKeys: [])
        #expect(keys.isEmpty)
    }

    @Test func protectedKeysAreSkippedEvenWhenOldest() {
        let entries = [
            entry("1", kind: .temp, bytes: 400, playedAt: 10),
            entry("2", kind: .temp, bytes: 400, playedAt: 20),
        ]
        let keys = CacheEvictor.keysToEvict(
            entries: entries, capBytes: 500, protectedKeys: ["1"])
        #expect(keys == ["2"])
    }

    @Test func zeroCapEvictsEveryUnprotectedTemp() {
        let entries = [
            entry("1", kind: .temp, bytes: 1, playedAt: 10),
            entry("2", kind: .permanent, bytes: 1, playedAt: 20),
        ]
        let keys = CacheEvictor.keysToEvict(
            entries: entries, capBytes: 0, protectedKeys: [])
        #expect(keys == ["1"])
    }
}
