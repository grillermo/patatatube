import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Legacy HLS cleanup")
struct CacheManagerLegacyHLSTests {
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-hls-\(UUID().uuidString)")
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    @Test func removesPackagesAndStagingAndReportsTheirIDs() throws {
        let root = temporaryRoot()
        try touch(root.appendingPathComponent("hls-7/master.m3u8"))
        try touch(root.appendingPathComponent("hls-9_v2/master.m3u8"))
        try touch(root.appendingPathComponent(".hls-tmp/12/video.m3u8"))
        try touch(root.appendingPathComponent("5.mp4"))
        let manager = CacheManager(root: root)

        let ids = manager.removeLegacyHLSPackages()

        #expect(ids == [7, 9, 12])
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!left.contains { $0.hasPrefix("hls-") || $0 == ".hls-tmp" })
        #expect(left.contains("5.mp4"))
    }

    @Test func skipsVideosAlreadyOnDiskAsMP4() throws {
        let root = temporaryRoot()
        try touch(root.appendingPathComponent("hls-5/master.m3u8"))
        try touch(root.appendingPathComponent("5.mp4"))
        let manager = CacheManager(root: root)

        #expect(manager.removeLegacyHLSPackages() == [])
    }

    @Test func includesDroppedPausedHLSDownloadsOnce() throws {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode([3]).write(
            to: root.appendingPathComponent("paused-hls-dropped.json"))
        let manager = CacheManager(root: root)

        #expect(manager.removeLegacyHLSPackages() == [3])
        #expect(manager.removeLegacyHLSPackages() == [])
    }
}
