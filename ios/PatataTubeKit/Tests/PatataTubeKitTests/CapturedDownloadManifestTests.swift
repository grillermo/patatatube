// CapturedDownloadManifestTests.swift
import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Captured download manifest")
struct CapturedDownloadManifestTests {
    private func manifest() -> CapturedDownloadManifest {
        .make(videoId: 7, versionId: 2,
              remoteURL: URL(string: "https://srv.test/videos/7/stream?version_id=2")!,
              totalByteCount: 100, etag: "\"v7\"")
    }

    @Test func cacheKeyMatchesSegmentedFormat() {
        #expect(manifest().cacheKey == "7:2")
        #expect(CapturedDownloadManifest.make(
            videoId: 7, versionId: nil,
            remoteURL: URL(string: "https://srv.test/videos/7/stream")!,
            totalByteCount: 100, etag: "\"v7\"").cacheKey == "7")
    }

    @Test func captureCoalescesAndTracksProgress() {
        var m = manifest()
        #expect(m.progress == 0)
        m.capture(.init(start: 0, end: 49))
        m.capture(.init(start: 50, end: 99))
        #expect(m.capturedRanges == [.init(start: 0, end: 99)])
        #expect(m.progress == 1)
        #expect(m.isComplete)
    }

    @Test func codableRoundTrip() throws {
        var m = manifest()
        m.capture(.init(start: 10, end: 40))
        let data = try JSONEncoder().encode(m)
        let decoded = try JSONDecoder().decode(CapturedDownloadManifest.self, from: data)
        #expect(decoded == m)
    }
}
