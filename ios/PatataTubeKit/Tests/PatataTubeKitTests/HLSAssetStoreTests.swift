import Foundation
import Testing
@testable import PatataTubeKit

private func storeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("hls-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// A real directory so bookmarks resolve.
private func makePackage(in root: URL, named name: String) throws -> URL {
    let url = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try Data(repeating: 0x7, count: 2048).write(to: url.appendingPathComponent("data.bin"))
    return url
}

@Suite("HLS asset store")
struct HLSAssetStoreTests {
    @Test func upsertAndLookupRoundTrip() throws {
        let root = try storeRoot()
        let store = HLSAssetStore(root: root)
        let package = try makePackage(in: root, named: "9.movpkg")
        let bookmark = try #require(HLSAssetStore.makeBookmark(for: package))

        let entry = HLSCacheEntry(
            cacheKey: "9", videoId: 9, versionId: nil, bookmark: bookmark,
            kind: .temp, isComplete: false, fractionComplete: 0.25,
            byteCount: 2048, lastPlayedAt: Date(timeIntervalSince1970: 100),
            audioLang: "eng")
        store.upsert(entry)

        #expect(store.entry(cacheKey: "9") == entry)
        #expect(store.entries().count == 1)
    }

    @Test func indexSurvivesAFreshInstance() throws {
        let root = try storeRoot()
        let package = try makePackage(in: root, named: "4.v2.movpkg")
        let bookmark = try #require(HLSAssetStore.makeBookmark(for: package))
        HLSAssetStore(root: root).upsert(HLSCacheEntry(
            cacheKey: "4:2", videoId: 4, versionId: 2, bookmark: bookmark,
            kind: .permanent, isComplete: true, fractionComplete: 1,
            byteCount: 2048, lastPlayedAt: Date(), audioLang: nil))

        let reopened = HLSAssetStore(root: root)
        #expect(reopened.entry(cacheKey: "4:2")?.kind == .permanent)
        #expect(reopened.entry(cacheKey: "4:2")?.isComplete == true)
    }

    @Test func removeDropsTheRowAndThePackage() throws {
        let root = try storeRoot()
        let store = HLSAssetStore(root: root)
        let package = try makePackage(in: root, named: "5.movpkg")
        store.upsert(HLSCacheEntry(
            cacheKey: "5", videoId: 5, versionId: nil,
            bookmark: try #require(HLSAssetStore.makeBookmark(for: package)),
            kind: .temp, isComplete: false, fractionComplete: 0.1,
            byteCount: 2048, lastPlayedAt: Date(), audioLang: nil))

        store.remove(cacheKey: "5")

        #expect(store.entry(cacheKey: "5") == nil)
        #expect(!FileManager.default.fileExists(atPath: package.path))
    }

    @Test func resolveReturnsNilAndDropsRowWhenPackageIsGone() throws {
        let root = try storeRoot()
        let store = HLSAssetStore(root: root)
        let package = try makePackage(in: root, named: "6.movpkg")
        let entry = HLSCacheEntry(
            cacheKey: "6", videoId: 6, versionId: nil,
            bookmark: try #require(HLSAssetStore.makeBookmark(for: package)),
            kind: .permanent, isComplete: true, fractionComplete: 1,
            byteCount: 2048, lastPlayedAt: Date(), audioLang: nil)
        store.upsert(entry)
        try FileManager.default.removeItem(at: package)

        #expect(store.resolve(entry) == nil)
        #expect(store.entry(cacheKey: "6") == nil)
    }

    @Test func corruptIndexIsTreatedAsEmpty() throws {
        let root = try storeRoot()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("hls-cache"), withIntermediateDirectories: true)
        try Data("not json".utf8).write(
            to: root.appendingPathComponent("hls-cache").appendingPathComponent("index.json"))

        let store = HLSAssetStore(root: root)
        #expect(store.entries().isEmpty)

        let package = try makePackage(in: root, named: "8.movpkg")
        store.upsert(HLSCacheEntry(
            cacheKey: "8", videoId: 8, versionId: nil,
            bookmark: try #require(HLSAssetStore.makeBookmark(for: package)),
            kind: .temp, isComplete: false, fractionComplete: 0,
            byteCount: 2048, lastPlayedAt: Date(), audioLang: nil))
        #expect(HLSAssetStore(root: root).entries().count == 1)
    }

    @Test func directorySizeSumsTheContents() throws {
        let root = try storeRoot()
        let store = HLSAssetStore(root: root)
        let package = try makePackage(in: root, named: "10.movpkg")
        #expect(store.directorySize(of: package) >= 2048)
    }
}
