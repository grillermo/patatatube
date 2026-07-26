import XCTest
@testable import PatataTubeKit

final class SegmentCacheTests: XCTestCase {
    private var root: URL!
    private var cache: SegmentCache!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        cache = SegmentCache(root: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testStoreAndFetch() async throws {
        try await cache.store(videoId: 7, hash: "abc", asset: "segment_00001.m4s", data: Data([1, 2, 3]))
        let data = await cache.cachedData(videoId: 7, hash: "abc", asset: "segment_00001.m4s")
        XCTAssertEqual(data, Data([1, 2, 3]))
    }

    func testNestedAssetPath() async throws {
        try await cache.store(videoId: 7, hash: "abc", asset: "subtitles/es.vtt", data: Data([9]))
        let data = await cache.cachedData(videoId: 7, hash: "abc", asset: "subtitles/es.vtt")
        XCTAssertEqual(data, Data([9]))
        let assets = await cache.cachedAssets(videoId: 7, hash: "abc")
        XCTAssertEqual(assets, ["subtitles/es.vtt"])
    }

    func testRejectsTraversal() async {
        await XCTAssertThrowsErrorAsync(
            try await self.cache.store(videoId: 7, hash: "abc", asset: "../evil", data: Data([1]))
        )
        let escaped = await cache.cachedData(videoId: 7, hash: "abc", asset: "../evil")
        XCTAssertNil(escaped)
    }

    func testDropOtherPackages() async throws {
        try await cache.store(videoId: 7, hash: "old", asset: "a.m4s", data: Data([1]))
        try await cache.store(videoId: 7, hash: "new", asset: "a.m4s", data: Data([2]))
        await cache.dropOtherPackages(videoId: 7, keeping: "new")
        let old = await cache.cachedData(videoId: 7, hash: "old", asset: "a.m4s")
        let new = await cache.cachedData(videoId: 7, hash: "new", asset: "a.m4s")
        XCTAssertNil(old)
        XCTAssertEqual(new, Data([2]))
    }

    func testPackageHashStableAndDistinct() {
        let a = SegmentCache.packageHash(forPlaylist: Data("one".utf8))
        let b = SegmentCache.packageHash(forPlaylist: Data("one".utf8))
        let c = SegmentCache.packageHash(forPlaylist: Data("two".utf8))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(a.count, 16)
    }
}

func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
