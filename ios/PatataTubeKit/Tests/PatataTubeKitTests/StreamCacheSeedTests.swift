import XCTest
@testable import PatataTubeKit

final class StreamCacheSeedTests: XCTestCase {
    private var root: URL!
    private var cache: StreamCache!
    private var store: SegmentedDownloadStore!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        cache = StreamCache(root: root.appendingPathComponent("stream"))
        store = SegmentedDownloadStore(root: root.appendingPathComponent("videos"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeManifest(
        total: Int64,
        streams: Int
    ) throws -> SegmentedDownloadManifest {
        try SegmentedDownloadManifest.make(
            videoId: 1,
            versionId: nil,
            remoteURL: URL(string: "https://u.test/videos/1/stream")!,
            requestedStreamCount: streams,
            totalByteCount: total,
            etag: "\"e\""
        )
    }

    func testSeedsPrefixesFromCachedRanges() async throws {
        // 100 bytes, 2 segments: [0-49], [50-99]. Cache 0-29 and 50-99.
        try await cache.ranges.prepare(
            key: "1",
            etag: "\"e\"",
            totalByteCount: 100
        )
        try await cache.ranges.write(
            key: "1",
            at: 0,
            data: Data(repeating: 1, count: 30)
        )
        try await cache.ranges.write(
            key: "1",
            at: 50,
            data: Data(repeating: 2, count: 50)
        )
        let manifest = try makeManifest(total: 100, streams: 2)

        let seeded = await cache.seedSegments(manifest: manifest, into: store)

        XCTAssertEqual(seeded.segments[0].persistedByteCount, 30)
        XCTAssertFalse(seeded.segments[0].isComplete)
        XCTAssertEqual(seeded.segments[1].persistedByteCount, 50)
        XCTAssertTrue(seeded.segments[1].isComplete)
        let part0 = try Data(
            contentsOf: store.partURL(cacheKey: "1", index: 0)
        )
        XCTAssertEqual(part0, Data(repeating: 1, count: 30))
        let part1 = try Data(
            contentsOf: store.partURL(cacheKey: "1", index: 1)
        )
        XCTAssertEqual(part1, Data(repeating: 2, count: 50))

        // Manifest is persisted so later resume sees seeded state.
        let loaded = try store.load(cacheKey: "1")
        XCTAssertEqual(loaded, seeded)
    }

    func testIgnoresCachedRunThatDoesNotStartAtSegmentStart() async throws {
        try await cache.ranges.prepare(
            key: "1",
            etag: "\"e\"",
            totalByteCount: 100
        )
        try await cache.ranges.write(
            key: "1",
            at: 10,
            data: Data(repeating: 1, count: 20)
        )
        let manifest = try makeManifest(total: 100, streams: 1)

        let seeded = await cache.seedSegments(manifest: manifest, into: store)

        XCTAssertEqual(seeded, manifest)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: store.partURL(cacheKey: "1", index: 0).path
            )
        )
    }

    func testNoSeedOnETagMismatch() async throws {
        try await cache.ranges.prepare(
            key: "1",
            etag: "\"other\"",
            totalByteCount: 100
        )
        try await cache.ranges.write(
            key: "1",
            at: 0,
            data: Data(repeating: 1, count: 100)
        )
        let manifest = try makeManifest(total: 100, streams: 1)

        let seeded = await cache.seedSegments(manifest: manifest, into: store)

        XCTAssertEqual(seeded, manifest)
    }

    func testNoSeedOnTotalByteCountMismatch() async throws {
        try await cache.ranges.prepare(
            key: "1",
            etag: "\"e\"",
            totalByteCount: 101
        )
        try await cache.ranges.write(
            key: "1",
            at: 0,
            data: Data(repeating: 1, count: 100)
        )
        let manifest = try makeManifest(total: 100, streams: 1)

        let seeded = await cache.seedSegments(manifest: manifest, into: store)

        XCTAssertEqual(seeded, manifest)
    }

    func testCopyRejectsEntityReplacedAfterManifestRead() async throws {
        try await cache.ranges.prepare(
            key: "1",
            etag: "\"e\"",
            totalByteCount: 100
        )
        try await cache.ranges.write(
            key: "1",
            at: 0,
            data: Data(repeating: 1, count: 10)
        )
        let current = await cache.ranges.manifest(key: "1")
        let observed = try XCTUnwrap(current)

        try await cache.ranges.prepare(
            key: "1",
            etag: "\"replacement\"",
            totalByteCount: 100
        )
        try await cache.ranges.write(
            key: "1",
            at: 0,
            data: Data(repeating: 2, count: 10)
        )

        let destination = root.appendingPathComponent("copied.bin")
        FileManager.default.createFile(
            atPath: destination.path,
            contents: nil
        )
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        let copied = try await cache.ranges.copyRange(
            key: "1",
            range: DownloadByteRange(start: 0, end: 9),
            expectedETag: observed.etag,
            expectedTotalByteCount: observed.totalByteCount,
            to: handle
        )

        XCTAssertFalse(copied)
        XCTAssertEqual(
            try Data(contentsOf: destination),
            Data()
        )
    }
}
