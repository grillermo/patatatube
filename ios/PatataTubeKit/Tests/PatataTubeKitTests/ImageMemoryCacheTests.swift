import XCTest
@testable import PatataTubeKit

final class ImageMemoryCacheTests: XCTestCase {
    func testMissReturnsNil() {
        let cache = ImageMemoryCache()
        XCTAssertNil(cache.data(for: "/videos/1/preview"))
    }

    func testStoreThenHit() {
        let cache = ImageMemoryCache()
        let bytes = Data([0xFF, 0xD8, 0xFF])
        cache.store(bytes, for: "/videos/1/preview")
        XCTAssertEqual(cache.data(for: "/videos/1/preview"), bytes)
    }

    func testKeysAreIndependent() {
        let cache = ImageMemoryCache()
        cache.store(Data([1]), for: "a")
        cache.store(Data([2]), for: "b")
        XCTAssertEqual(cache.data(for: "a"), Data([1]))
        XCTAssertEqual(cache.data(for: "b"), Data([2]))
    }

    func testSharedInstanceIsStable() {
        ImageMemoryCache.shared.store(Data([9]), for: "shared-key")
        XCTAssertEqual(ImageMemoryCache.shared.data(for: "shared-key"), Data([9]))
    }
}
