import XCTest
@testable import PatataTubeKit

final class StreamCacheTests: XCTestCase {
    func testLayoutAndRemoveVideo() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = StreamCache(root: root)
                try await cache.ranges.prepare(key: "3:9", etag: "\"e\"", totalByteCount: 10)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("mp4/3:9/data.bin").path))

        await cache.removeVideo(id: 3)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("mp4/3:9").path))
    }
}
