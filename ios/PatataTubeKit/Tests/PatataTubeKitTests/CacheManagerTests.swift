import Foundation
import Testing
@testable import PatataTubeKit

private func cacheRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("cache-manager-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Suite("Cache manager storage")
struct CacheManagerTests {
    @Test func localURLUsesIDAndVersion() throws {
        let root = try cacheRoot()
        let manager = CacheManager(root: root)

        #expect(manager.localURL(for: 5).lastPathComponent == "5.mp4")
        #expect(manager.localURL(for: 5, versionId: 2).lastPathComponent == "5.v2.mp4")
    }

    @Test func previewStoreAndLookupUsesMovieID() throws {
        let root = try cacheRoot()
        let manager = CacheManager(root: root)
        let path = "https://img.test/poster.png"

        manager.storePreview(Data([0x01, 0x02]), for: 7, path: path)

        let url = try #require(manager.cachedPreviewURL(for: 7, path: path))
        #expect(url.lastPathComponent.hasPrefix("7.preview."))
        #expect(url.pathExtension == "png")
        #expect(try Data(contentsOf: url) == Data([0x01, 0x02]))
        #expect(manager.cachedPreviewURL(for: 8, path: path) == nil)
    }

    @Test func posterStoreAndLookupUsesStableKey() throws {
        let root = try cacheRoot()
        let manager = CacheManager(root: root)
        let key = "/library/shows/bluey/poster.jpg"

        manager.storeShowPoster(Data([0xAA]), for: key)

        let url = try #require(manager.cachedShowPosterURL(for: key))
        #expect(url.pathExtension == "jpg")
        #expect(try Data(contentsOf: url) == Data([0xAA]))
        #expect(manager.cachedShowPosterURL(for: "/other/poster.jpg") == nil)
    }

    @Test func removeCachedDeletesOnlyRequestedVersion() throws {
        let root = try cacheRoot()
        let manager = CacheManager(root: root)
        let base = manager.localURL(for: 7)
        let version = manager.localURL(for: 7, versionId: 2)
        try Data([0x01]).write(to: base)
        try Data([0x02]).write(to: version)

        manager.removeCached(id: 7, versionId: 2)

        #expect(FileManager.default.fileExists(atPath: base.path))
        #expect(!FileManager.default.fileExists(atPath: version.path))
    }

    @Test func hasAnyCachedFindsBaseAndVersionedFilesButNotPreviews() throws {
        let root = try cacheRoot()
        let manager = CacheManager(root: root)
        try Data([0x01]).write(to: root.appendingPathComponent("21.v3.mp4"))
        try Data([0x01]).write(to: root.appendingPathComponent("22.preview.jpg"))

        #expect(manager.hasAnyCached(id: 21))
        #expect(!manager.hasAnyCached(id: 22))
        #expect(!manager.hasAnyCached(id: 2))
    }

    @Test func removeAllCachedKeepsCoversAndOtherVideos() throws {
        let root = try cacheRoot()
        let manager = CacheManager(root: root)
        for name in ["23.mp4", "23.v1.mp4", "24.mp4", "23.preview.jpg", "poster.a.jpg"] {
            try Data([0x01]).write(to: root.appendingPathComponent(name))
        }

        manager.removeAllCached(id: 23)

        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("23.mp4").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("23.v1.mp4").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("24.mp4").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("23.preview.jpg").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("poster.a.jpg").path))
    }

    @Test func clearAllVideosKeepsCoversAndClearsRecentDownloads() throws {
        let root = try cacheRoot()
        var history = DownloadCompletionHistoryStore(root: root)
        history.record(DownloadCompletion(videoID: 1, versionID: nil, completedAt: .now))
        for name in ["1.mp4", "2.v5.mp4", "1.preview.jpg", "poster.a.jpg"] {
            try Data([0x01]).write(to: root.appendingPathComponent(name))
        }
        let manager = CacheManager(root: root)

        manager.clearAllVideos()

        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("1.mp4").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("2.v5.mp4").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("1.preview.jpg").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("poster.a.jpg").path))
        #expect(manager.recentDownloads().isEmpty)
    }

    @Test func clearAllCoversKeepsVideos() throws {
        let root = try cacheRoot()
        for name in ["1.preview.jpg", "poster.a.png", "1.mp4"] {
            try Data([0x01]).write(to: root.appendingPathComponent(name))
        }
        let manager = CacheManager(root: root)

        manager.clearAllCovers()

        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("1.preview.jpg").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("poster.a.png").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("1.mp4").path))
    }
}
