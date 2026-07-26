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
