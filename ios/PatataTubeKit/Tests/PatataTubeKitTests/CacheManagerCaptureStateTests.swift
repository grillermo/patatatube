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
        let manager = CacheManager(root: base, configuration: .ephemeral)
        // Write a half-complete capture manifest directly via the store.
        let store = CapturedDownloadStore(root: base)
        var m = CapturedDownloadManifest.make(
            videoId: 42, versionId: nil,
            remoteURL: URL(string: "https://srv.test/videos/42/stream")!,
            totalByteCount: 100, etag: "\"v42\"")
        m.capture(.init(start: 0, end: 49))
        try store.write(m)
        if case let .downloading(progress) = manager.state(for: 42) {
            #expect(abs(progress - 0.5) < 0.001)
        } else {
            Issue.record("expected .downloading, got \(manager.state(for: 42))")
        }
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
