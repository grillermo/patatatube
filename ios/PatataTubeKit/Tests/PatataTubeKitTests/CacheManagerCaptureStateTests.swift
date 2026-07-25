import AVFoundation
import Foundation
import Testing
@testable import PatataTubeKit

@Suite("CacheManager capture state", .serialized)
struct CacheManagerCaptureStateTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmcapture-\(UUID().uuidString)")
    }

    @Test func persistedPartialReportsDownloadingProgress() throws {
        let base = root()
        // Write a half-complete capture manifest to disk BEFORE the manager is
        // created, so its cold-start seed of the in-memory capture cache picks it
        // up (state(for:) no longer reads the manifest from disk on every call).
        let store = CapturedDownloadStore(root: base)
        var m = CapturedDownloadManifest.make(
            videoId: 42, versionId: nil,
            remoteURL: URL(string: "https://srv.test/videos/42/stream")!,
            totalByteCount: 100, etag: "\"v42\"")
        m.capture(.init(start: 0, end: 49))
        try store.write(m)
        let manager = CacheManager(root: base, configuration: .ephemeral)
        if case let .downloading(progress) = manager.state(for: 42) {
            #expect(abs(progress - 0.5) < 0.001)
        } else {
            Issue.record("expected .downloading, got \(manager.state(for: 42))")
        }
    }

    @Test func ineligibleCaptureReturnsPlainNonCapturingAsset() {
        let manager = CacheManager(root: root(), configuration: .ephemeral)
        let remote = URL(string: "https://srv.test/videos/50/stream")!
        // A library/HLS video must never get a capturing (ptcapture://) asset:
        // its watch can't finalize, so capturing would orphan a partial.
        let asset = manager.captureAsset(
            videoId: 50, remoteURL: remote, bearerToken: "t",
            isEligibleForCapture: false)
        #expect(asset.url.scheme == "https")
        #expect(manager.state(for: 50) == .notCached)
    }

    @Test func eligibleCaptureReturnsCapturingAsset() {
        let manager = CacheManager(root: root(), configuration: .ephemeral)
        let remote = URL(string: "https://srv.test/videos/51/stream")!
        let asset = manager.captureAsset(
            videoId: 51, remoteURL: remote, bearerToken: "t",
            isEligibleForCapture: true)
        #expect(asset.url.scheme == CaptureManager.scheme)
    }

    @Test func removeAllCachedClearsCapturePartial() throws {
        let base = root()
        let manager = CacheManager(root: base, configuration: .ephemeral)
        let store = CapturedDownloadStore(root: base)
        var m = CapturedDownloadManifest.make(
            videoId: 43, versionId: nil,
            remoteURL: URL(string: "https://srv.test/videos/43/stream")!,
            totalByteCount: 100, etag: "\"v43\"")
        m.capture(.init(start: 0, end: 9))
        try store.write(m)
        manager.removeAllCached(id: 43)
        #expect(manager.state(for: 43) == .notCached)
    }
}
