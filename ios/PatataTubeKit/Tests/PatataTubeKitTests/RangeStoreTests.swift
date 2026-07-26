import XCTest
@testable import PatataTubeKit

final class RangeStoreTests: XCTestCase {
    private var root: URL!
    private var store: RangeStore!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        store = RangeStore(root: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func r(_ start: Int64, _ end: Int64) -> DownloadByteRange {
        .init(start: start, end: end)
    }

    func testWriteThenReadRoundTrip() async throws {
        try await store.prepare(key: "1", etag: "\"a\"", totalByteCount: 100)
        try await store.write(key: "1", at: 10, data: Data(repeating: 7, count: 20))

        let data = try await store.read(key: "1", range: r(10, 29))

        XCTAssertEqual(data, Data(repeating: 7, count: 20))
    }

    func testReadReturnsNilForUncachedRange() async throws {
        try await store.prepare(key: "1", etag: "\"a\"", totalByteCount: 100)
        try await store.write(key: "1", at: 10, data: Data(repeating: 7, count: 20))

        let data = try await store.read(key: "1", range: r(10, 40))

        XCTAssertNil(data)
    }

    func testManifestPersistsAcrossInstances() async throws {
        try await store.prepare(key: "1", etag: "\"a\"", totalByteCount: 100)
        try await store.write(key: "1", at: 0, data: Data(repeating: 1, count: 50))

        let reopened = RangeStore(root: root)
        let manifest = await reopened.manifest(key: "1")

        XCTAssertEqual(manifest?.etag, "\"a\"")
        XCTAssertEqual(manifest?.ranges.runs, [r(0, 49)])
    }

    func testPrepareWithNewEtagResetsEntry() async throws {
        try await store.prepare(key: "1", etag: "\"a\"", totalByteCount: 100)
        try await store.write(key: "1", at: 0, data: Data(repeating: 1, count: 50))
        try await store.prepare(key: "1", etag: "\"b\"", totalByteCount: 100)

        let manifest = await store.manifest(key: "1")

        XCTAssertEqual(manifest?.ranges.runs, [])
        XCTAssertEqual(manifest?.etag, "\"b\"")
    }

    func testWriteOutsideEntityThrows() async throws {
        try await store.prepare(key: "1", etag: "\"a\"", totalByteCount: 100)

        await XCTAssertThrowsErrorAsync {
            try await self.store.write(key: "1", at: 90, data: Data(repeating: 7, count: 20))
        }

        let manifest = await store.manifest(key: "1")
        XCTAssertEqual(manifest?.ranges.runs, [])
    }

    func testCorruptManifestWipesEntry() async throws {
        try await store.prepare(key: "1", etag: "\"a\"", totalByteCount: 100)
        let manifestURL = store.entryDir(key: "1").appendingPathComponent("ranges.json")
        try Data("not json".utf8).write(to: manifestURL)

        let reopened = RangeStore(root: root)
        let manifest = await reopened.manifest(key: "1")

        XCTAssertNil(manifest)
    }

    func testManifestWithOutOfBoundsRunWipesEntry() async throws {
        try await store.prepare(key: "1", etag: "\"a\"", totalByteCount: 100)
        let manifestURL = store.entryDir(key: "1").appendingPathComponent("ranges.json")
        try Data("""
        {"etag":"\\\"a\\\"","totalByteCount":100,"ranges":{"runs":[{"start":0,"end":100}]}}
        """.utf8).write(to: manifestURL)

        let manifest = await store.manifest(key: "1")

        XCTAssertNil(manifest)
    }

    func testReadReturnsNilWhenDataFileWasTruncated() async throws {
        try await store.prepare(key: "1", etag: "\"a\"", totalByteCount: 100)
        try await store.write(key: "1", at: 0, data: Data(repeating: 7, count: 20))
        let handle = try FileHandle(forWritingTo: store.entryDir(key: "1").appendingPathComponent("data.bin"))
        try handle.truncate(atOffset: 10)
        try handle.close()

        let data = try await store.read(key: "1", range: r(0, 19))

        XCTAssertNil(data)
    }

    func testCopyRangeChunked() async throws {
        try await store.prepare(key: "1", etag: "\"a\"", totalByteCount: 3_000_000)
        try await store.write(key: "1", at: 0, data: Data(repeating: 9, count: 3_000_000))
        let output = root.appendingPathComponent("out.bin")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)

        let copied = try await store.copyRange(key: "1", range: r(0, 2_999_999), to: handle)

        try handle.close()
        let size = try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int
        XCTAssertTrue(copied)
        XCTAssertEqual(size, 3_000_000)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {}
}
