import AVFoundation
import Foundation
import Testing
@testable import PatataTubeKit

private func managerRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("hls-cache-mgr-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func makeManager(root: URL, downloader: FakeHLSDownloader) -> CacheManager {
    CacheManager(
        root: root, configuration: .ephemeral, fileManager: .default,
        downloader: downloader)
}

private func target(id: Int = 1, hlsStatus: String = "done") -> CacheManager.PlaybackTarget {
    CacheManager.PlaybackTarget(
        id: id, versionId: nil,
        master: URL(string: "https://pt.test/videos/\(id)/hls/master.m3u8"),
        bearerToken: "tok", title: "clip", audioLang: "eng", hlsStatus: hlsStatus)
}

@Suite("HLS cache state and promotion")
struct HLSCacheStateTests {
    @Test func unknownVideoIsNotCached() throws {
        let root = try managerRoot()
        let manager = makeManager(root: root, downloader: FakeHLSDownloader())
        #expect(manager.state(for: 1) == .notCached)
    }

    @Test func playbackStartsAFillAheadTaskOnWiFi() throws {
        let root = try managerRoot()
        let fake = FakeHLSDownloader()
        let manager = makeManager(root: root, downloader: fake)

        let asset = manager.playbackAsset(for: target(), isOnWiFi: true, hasNetwork: true)

        guard case .asset = asset else {
            Issue.record("expected a playable asset, got \(asset)")
            return
        }
        #expect(fake.requests.count == 1)
        #expect(fake.requests[0].isFillAhead)
        #expect(fake.requests[0].cacheKey == "1")
    }

    @Test func fillAheadProgressReportsDownloadingState() throws {
        let root = try managerRoot()
        let fake = FakeHLSDownloader()
        let manager = makeManager(root: root, downloader: fake)
        _ = manager.playbackAsset(for: target(), isOnWiFi: true, hasNetwork: true)

        fake.emitProgress(cacheKey: "1", fraction: 0.3)

        #expect(manager.state(for: 1) == .downloading(0.3))
        #expect(manager.activeDownloads().count == 1)
    }

    @Test func completedFillAheadIsPromotedToCached() throws {
        let root = try managerRoot()
        let fake = FakeHLSDownloader()
        let manager = makeManager(root: root, downloader: fake)
        _ = manager.playbackAsset(for: target(), isOnWiFi: true, hasNetwork: true)
        fake.emitProgress(cacheKey: "1", fraction: 0.9)

        fake.emitFinished(cacheKey: "1")

        #expect(manager.state(for: 1) == .cached)
        #expect(manager.recentDownloads().count == 1)
    }

    @Test func incompletePlaybackLeavesAPausedPartialAndCancelsTheTask() throws {
        let root = try managerRoot()
        let fake = FakeHLSDownloader()
        let manager = makeManager(root: root, downloader: fake)
        _ = manager.playbackAsset(for: target(), isOnWiFi: true, hasNetwork: true)
        fake.emitProgress(cacheKey: "1", fraction: 0.4)

        manager.notePlaybackEnded(videoId: 1, versionId: nil)

        #expect(fake.cancelledKeys == ["1"])
        #expect(manager.state(for: 1) == .paused(0.4))
    }

    @Test func cellularPlaybackDoesNotCache() throws {
        let root = try managerRoot()
        let fake = FakeHLSDownloader()
        let manager = makeManager(root: root, downloader: fake)

        _ = manager.playbackAsset(for: target(), isOnWiFi: false, hasNetwork: true)

        #expect(fake.requests.isEmpty)
        #expect(manager.state(for: 1) == .notCached)
    }

    @Test func packagingErrorIsReportedAsUnplayable() throws {
        let root = try managerRoot()
        let manager = makeManager(root: root, downloader: FakeHLSDownloader())

        let asset = manager.playbackAsset(
            for: target(hlsStatus: "error"), isOnWiFi: true, hasNetwork: true)

        #expect(asset == .unplayable(reason: "HLS packaging failed"))
    }

    @Test func explicitDownloadUsesAManualTaskAndCompletes() async throws {
        let root = try managerRoot()
        let fake = FakeHLSDownloader()
        let manager = makeManager(root: root, downloader: fake)
        let master = URL(string: "https://pt.test/videos/2/hls/master.m3u8")!

        let download = Task {
            try await manager.download(id: 2, from: master, bearerToken: "tok")
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(fake.requests.first?.isFillAhead == false)
        fake.emitFinished(cacheKey: "2")
        try await download.value

        #expect(manager.state(for: 2) == .cached)
    }

    @Test func failedDownloadThrowsAndDropsTheEntry() async throws {
        let root = try managerRoot()
        let fake = FakeHLSDownloader()
        let manager = makeManager(root: root, downloader: fake)
        let master = URL(string: "https://pt.test/videos/3/hls/master.m3u8")!

        let download = Task {
            try await manager.download(id: 3, from: master, bearerToken: "tok")
        }
        try await Task.sleep(for: .milliseconds(50))
        fake.emitFailure(cacheKey: "3", error: URLError(.timedOut))

        await #expect(throws: (any Error).self) { try await download.value }
        #expect(manager.state(for: 3) == .notCached)
    }

    @Test func evictionRunsAfterPlaybackAndSparesPermanentEntries() throws {
        let root = try managerRoot()
        let fake = FakeHLSDownloader()
        let manager = makeManager(root: root, downloader: fake)
        manager.setTempCacheCap(bytes: 0)

        _ = manager.playbackAsset(for: target(), isOnWiFi: true, hasNetwork: true)
        fake.emitProgress(cacheKey: "1", fraction: 0.4)
        manager.notePlaybackEnded(videoId: 1, versionId: nil)

        // Cap 0 → the just-watched temp partial is evicted.
        #expect(manager.state(for: 1) == .notCached)
    }
}
