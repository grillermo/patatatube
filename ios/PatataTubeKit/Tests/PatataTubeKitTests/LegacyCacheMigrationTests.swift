import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Legacy cache migration")
struct LegacyCacheMigrationTests {
    private func paused(_ id: Int, version: Int? = nil, url: String) -> PausedDownload {
        PausedDownload(
            videoID: id, versionID: version, remoteURL: URL(string: url)!, streamCount: 3,
            previewURL: URL(string: "https://srv.test/p/\(id).jpg"), showPosterKey: nil,
            showPosterURL: nil, progress: 0.5, transferredByteCount: 50, totalByteCount: 100
        )
    }

    @Test func deletesTheOldStreamCachePartFilesAndResumeData() throws {
        let videos = temporaryVideosRoot("migrate")
        let stream = temporaryVideosRoot("old-stream")
        let fm = FileManager.default
        try fm.createDirectory(at: stream.appendingPathComponent("mp4/3"), withIntermediateDirectories: true)
        try fm.createDirectory(at: videos.appendingPathComponent(".downloads/9"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: videos.appendingPathComponent("9.resume"))
        try Data("x".utf8).write(to: videos.appendingPathComponent("9.mp4"))

        LegacyCacheMigration.run(videosRoot: videos, legacyStreamRoot: stream, now: Date())

        #expect(!fm.fileExists(atPath: stream.path))
        #expect(!fm.fileExists(atPath: videos.appendingPathComponent(".downloads").path))
        #expect(!fm.fileExists(atPath: videos.appendingPathComponent("9.resume").path))
        #expect(fm.fileExists(atPath: videos.appendingPathComponent("9.mp4").path))
    }

    @Test func pausedDownloadsBecomePausedPinnedEntriesFromZero() throws {
        let videos = temporaryVideosRoot("migrate")
        var legacy = PausedDownloadStore(root: videos)
        legacy.insert(paused(5, url: "https://srv.test/videos/5/stream"))
        legacy.insert(paused(6, version: 2, url: "https://srv.test/videos/6/stream?version_id=2"))
        legacy.insert(paused(7, url: "https://srv.test/videos/7/master.m3u8"))

        let converted = LegacyCacheMigration.run(videosRoot: videos, legacyStreamRoot: nil, now: Date())

        #expect(Set(converted) == ["5", "6:2"])
        let manifests = MediaStore.loadManifests(storeRoot: MediaStore.storeRoot(videosRoot: videos))
        let five = try #require(manifests.first { $0.key == "5" })
        #expect(five.identity == nil)
        #expect(five.committed.runs.isEmpty)
        #expect(five.pin?.paused == true)
        #expect(five.pin?.job.streamCount == 3)
        #expect(five.pin?.job.previewURL == URL(string: "https://srv.test/p/5.jpg"))
        #expect(PausedDownloadStore(root: videos).entries.isEmpty)
        // The HLS one is dropped and recorded for re-download, as before.
        #expect(PausedDownloadStore.droppedHLSVideoIDs(root: videos) == [7])
    }

    @Test func skipsAPausedDownloadWhoseFileLanded() throws {
        let videos = temporaryVideosRoot("migrate")
        var legacy = PausedDownloadStore(root: videos)
        legacy.insert(paused(5, url: "https://srv.test/videos/5/stream"))
        try Data("x".utf8).write(to: videos.appendingPathComponent("5.mp4"))
        #expect(LegacyCacheMigration.run(videosRoot: videos, legacyStreamRoot: nil, now: Date()).isEmpty)
    }

    @Test func runningTwiceIsHarmless() throws {
        let videos = temporaryVideosRoot("migrate")
        var legacy = PausedDownloadStore(root: videos)
        legacy.insert(paused(5, url: "https://srv.test/videos/5/stream"))
        _ = LegacyCacheMigration.run(videosRoot: videos, legacyStreamRoot: nil, now: Date())
        #expect(LegacyCacheMigration.run(videosRoot: videos, legacyStreamRoot: nil, now: Date()).isEmpty)
        #expect(MediaStore.loadManifests(storeRoot: MediaStore.storeRoot(videosRoot: videos)).count == 1)
    }

    @Test func keepsALegacyEntryWhoseManifestCouldNotBeWritten() throws {
        let videos = temporaryVideosRoot("migrate")
        var legacy = PausedDownloadStore(root: videos)
        legacy.insert(paused(5, url: "https://srv.test/videos/5/stream"))
        legacy.insert(paused(6, url: "https://srv.test/videos/6/stream"))
        // A plain file where entry 5's directory belongs makes its write fail.
        let storeRoot = MediaStore.storeRoot(videosRoot: videos)
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: storeRoot.appendingPathComponent("5"))

        let converted = LegacyCacheMigration.run(videosRoot: videos, legacyStreamRoot: nil, now: Date())

        #expect(converted == ["6"])
        #expect(PausedDownloadStore(root: videos).entries.map(\.id) == ["5"])
    }
}
