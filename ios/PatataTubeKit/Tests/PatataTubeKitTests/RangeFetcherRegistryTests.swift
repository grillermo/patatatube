import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Range fetcher registry")
struct RangeFetcherRegistryTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-\(UUID().uuidString)")
    }
    private let remote = URL(string: "https://srv.test/videos/7/stream")!

    private func makeRegistry() -> RangeFetcherRegistry {
        RangeFetcherRegistry(
            store: CapturedDownloadStore(root: root()), session: mockSession())
    }

    @Test func sameKeyReturnsSameFetcher() {
        let registry = makeRegistry()
        let a = registry.fetcher(
            videoId: 7, versionId: nil, remoteURL: remote,
            bearerToken: "t", onProgress: { _, _ in })
        let b = registry.fetcher(
            videoId: 7, versionId: nil, remoteURL: remote,
            bearerToken: "t", onProgress: { _, _ in })
        #expect(a === b)
        #expect(registry.existing(cacheKey: "7") === a)
    }

    @Test func versionedKeysAreDistinct() {
        let registry = makeRegistry()
        let plain = registry.fetcher(
            videoId: 7, versionId: nil, remoteURL: remote,
            bearerToken: "t", onProgress: { _, _ in })
        let versioned = registry.fetcher(
            videoId: 7, versionId: 3, remoteURL: remote,
            bearerToken: "t", onProgress: { _, _ in })
        #expect(plain !== versioned)
        #expect(registry.existing(cacheKey: "7:3") === versioned)
    }

    @Test func removeDropsTheFetcher() {
        let registry = makeRegistry()
        _ = registry.fetcher(
            videoId: 7, versionId: nil, remoteURL: remote,
            bearerToken: "t", onProgress: { _, _ in })
        registry.remove(cacheKey: "7")
        #expect(registry.existing(cacheKey: "7") == nil)
    }

    @Test func concurrencyDropsToOneWhilePlaybackIsRecent() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(RangeFetcher.effectiveConcurrency(
            requested: 4, lastPlayerRequestAt: now.addingTimeInterval(-2), now: now) == 1)
    }

    @Test func concurrencyRestoresAfterPlaybackGoesQuiet() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(RangeFetcher.effectiveConcurrency(
            requested: 4, lastPlayerRequestAt: now.addingTimeInterval(-60), now: now) == 4)
        #expect(RangeFetcher.effectiveConcurrency(
            requested: 4, lastPlayerRequestAt: nil, now: now) == 4)
    }
}
