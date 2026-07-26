import XCTest
@testable import PatataTubeKit

final class CacheStatisticsCollectorTests: XCTestCase {
    private let fileManager = FileManager.default
    private let blockSize = 4096

    private func makeRoot() -> URL {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ url: URL, sizeInBlocks blocks: Int = 1) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(count: blockSize * blocks).write(to: url)
    }

    /// Builds one entry of every recognized kind, each sized `blockSize`
    /// (or a known multiple) so allocation-size accounting is exact.
    private func makeFixture() throws -> (videos: URL, stream: URL, lists: URL, tmp: URL) {
        let videos = makeRoot()
        let stream = makeRoot()
        let lists = makeRoot()
        let tmp = makeRoot()

        try write(videos.appendingPathComponent("1.mp4"))
        try write(videos.appendingPathComponent("hls-2/master.m3u8"))
        try write(videos.appendingPathComponent("3.preview.abc.jpg"))
        try write(videos.appendingPathComponent("poster.def.png"))
        try write(videos.appendingPathComponent(".downloads/key1/manifest.json"))
        try write(videos.appendingPathComponent(".downloads/key2/manifest.json"))
        try write(videos.appendingPathComponent("5.resume"))
        try write(videos.appendingPathComponent("download-completions.json"))
        try write(videos.appendingPathComponent("mystery.dat"))

        try write(stream.appendingPathComponent("hls/10/seg.m4s"))
        try write(stream.appendingPathComponent("mp4/3:9/data.bin"))

        try write(lists.appendingPathComponent("all.json"))
        try write(lists.appendingPathComponent("children.json"))

        try write(tmp.appendingPathComponent("patatatube-seed-abc/part.bin"))

        return (videos, stream, lists, tmp)
    }

    private func stat(_ stats: [CacheStat], _ id: String) -> CacheStat {
        stats.first { $0.id == id }!
    }

    func testEveryRowIsAccounted() async throws {
        let fixture = try makeFixture()
        defer {
            for root in [fixture.videos, fixture.stream, fixture.lists, fixture.tmp] {
                try? fileManager.removeItem(at: root)
            }
        }
        let collector = CacheStatisticsCollector(
            videosRoot: fixture.videos,
            streamRoot: fixture.stream,
            videoListRoot: fixture.lists,
            tmpRoot: fixture.tmp
        )
        let stats = await collector.collect()
        let unit = Int64(blockSize)

        XCTAssertEqual(stat(stats, "proxy.hls").byteCount, unit)
        XCTAssertEqual(stat(stats, "proxy.hls").itemCount, 1)
        XCTAssertEqual(stat(stats, "proxy.mp4").byteCount, unit)
        XCTAssertEqual(stat(stats, "proxy.mp4").itemCount, 1)

        XCTAssertEqual(stat(stats, "videos.mp4").byteCount, unit)
        XCTAssertEqual(stat(stats, "videos.mp4").itemCount, 1)
        XCTAssertEqual(stat(stats, "videos.hls").byteCount, unit)
        XCTAssertEqual(stat(stats, "videos.hls").itemCount, 1)
        XCTAssertEqual(stat(stats, "videos.covers").byteCount, unit * 2)
        XCTAssertEqual(stat(stats, "videos.covers").itemCount, 2)
        XCTAssertEqual(stat(stats, "videos.partial").byteCount, unit * 3)
        XCTAssertEqual(stat(stats, "videos.partial").itemCount, 3)
        XCTAssertEqual(stat(stats, "videos.history").byteCount, unit)
        XCTAssertEqual(stat(stats, "videos.history").itemCount, 1)

        XCTAssertEqual(stat(stats, "lists").byteCount, unit * 2)
        XCTAssertEqual(stat(stats, "lists").itemCount, 2)
        XCTAssertEqual(stat(stats, "staging").byteCount, unit)
        XCTAssertEqual(stat(stats, "staging").itemCount, 1)
    }

    func testUnrecognizedFileLandsInOther() async throws {
        let fixture = try makeFixture()
        defer {
            for root in [fixture.videos, fixture.stream, fixture.lists, fixture.tmp] {
                try? fileManager.removeItem(at: root)
            }
        }
        let collector = CacheStatisticsCollector(
            videosRoot: fixture.videos,
            streamRoot: fixture.stream,
            videoListRoot: fixture.lists,
            tmpRoot: fixture.tmp
        )
        let stats = await collector.collect()
        XCTAssertEqual(stat(stats, "other").byteCount, Int64(blockSize))
        XCTAssertEqual(stat(stats, "other").itemCount, 1)
    }

    func testRowsSumToTotalExcludingProxyTotal() async throws {
        let fixture = try makeFixture()
        defer {
            for root in [fixture.videos, fixture.stream, fixture.lists, fixture.tmp] {
                try? fileManager.removeItem(at: root)
            }
        }
        let collector = CacheStatisticsCollector(
            videosRoot: fixture.videos,
            streamRoot: fixture.stream,
            videoListRoot: fixture.lists,
            tmpRoot: fixture.tmp
        )
        let stats = await collector.collect()
        let expected = stats
            .filter { $0.id != "proxy.total" && $0.id != "total" }
            .reduce(Int64(0)) { $0 + $1.byteCount }
        XCTAssertEqual(stat(stats, "total").byteCount, expected)
        XCTAssertGreaterThan(expected, 0)
    }

    func testMissingRootsProduceZeroesAndNeverThrow() async {
        let missing = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let collector = CacheStatisticsCollector(
            videosRoot: missing.appendingPathComponent("videos"),
            streamRoot: missing.appendingPathComponent("stream"),
            videoListRoot: missing.appendingPathComponent("lists"),
            tmpRoot: missing.appendingPathComponent("tmp")
        )
        let stats = await collector.collect()
        for stat in stats {
            XCTAssertEqual(stat.byteCount, 0, "\(stat.id) expected zero bytes")
            XCTAssertEqual(stat.itemCount, 0, "\(stat.id) expected zero items")
        }
    }

    func testProxyTotalCarriesBudgetAndSumsComponents() async throws {
        let fixture = try makeFixture()
        defer {
            for root in [fixture.videos, fixture.stream, fixture.lists, fixture.tmp] {
                try? fileManager.removeItem(at: root)
            }
        }
        let collector = CacheStatisticsCollector(
            videosRoot: fixture.videos,
            streamRoot: fixture.stream,
            videoListRoot: fixture.lists,
            tmpRoot: fixture.tmp
        )
        let stats = await collector.collect()
        let proxyTotal = stat(stats, "proxy.total")
        XCTAssertEqual(proxyTotal.budgetBytes, StreamCache.defaultBudgetBytes)
        XCTAssertEqual(
            proxyTotal.byteCount,
            stat(stats, "proxy.hls").byteCount + stat(stats, "proxy.mp4").byteCount
        )
        XCTAssertEqual(
            proxyTotal.itemCount,
            stat(stats, "proxy.hls").itemCount + stat(stats, "proxy.mp4").itemCount
        )
    }
}
