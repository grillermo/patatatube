import XCTest
@testable import PatataTubeKit

final class CacheManagerHLSTests: XCTestCase {
    private var root: URL!
    private var cache: CacheManager!
    private var streamCache: StreamCache!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        streamCache = StreamCache(root: root.appendingPathComponent("stream"))
        cache = CacheManager(
            root: root.appendingPathComponent("videos"),
            configuration: configuration,
            streamCache: streamCache
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        MockURLProtocol.reset()
        super.tearDown()
    }

    private let master = """
    #EXTM3U
    #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",LANGUAGE="es",NAME="Spanish",DEFAULT=YES,AUTOSELECT=YES,FORCED=NO,URI="subtitles/es.m3u8"
    #EXT-X-STREAM-INF:BANDWIDTH=2000000
    video.m3u8

    """

    private let media = """
    #EXTM3U
    #EXT-X-MAP:URI="init.mp4"
    #EXTINF:6.0,
    segment_00000.m4s
    #EXT-X-ENDLIST

    """

    private let subtitles = """
    #EXTM3U
    #EXTINF:12.0,
    es.vtt
    #EXT-X-ENDLIST

    """

    func testDownloadHLSFetchesAllAssetsAndPromotes() async throws {
        MockURLProtocol.stub(
            path: "/videos/5/hls/master.m3u8",
            data: Data(master.utf8)
        )
        MockURLProtocol.stub(
            path: "/videos/5/hls/video.m3u8",
            data: Data(media.utf8)
        )
        MockURLProtocol.stub(
            path: "/videos/5/hls/subtitles/es.m3u8",
            data: Data(subtitles.utf8)
        )
        MockURLProtocol.stub(path: "/videos/5/hls/init.mp4", data: Data([1]))
        MockURLProtocol.stub(
            path: "/videos/5/hls/segment_00000.m4s",
            data: Data([2])
        )
        MockURLProtocol.stub(
            path: "/videos/5/hls/subtitles/es.vtt",
            data: Data([3])
        )

        try await cache.downloadHLS(
            id: 5,
            versionId: nil,
            masterURL: URL(string: "https://u.test/videos/5/hls/master.m3u8")!,
            bearerToken: "tok"
        )

        let directory = cache.offlineHLSDir(for: 5, versionId: nil)
        let assets = [
            "master.m3u8",
            "video.m3u8",
            "subtitles/es.m3u8",
            "init.mp4",
            "segment_00000.m4s",
            "subtitles/es.vtt",
        ]
        for asset in assets {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(asset).path
                ),
                "missing \(asset)"
            )
        }
        XCTAssertEqual(cache.state(for: 5), .cached)
        XCTAssertNotNil(cache.offlineHLSMasterURL(for: 5, versionId: nil))
    }

    func testDownloadHLSReusesStreamedSegments() async throws {
        let packageHash = SegmentCache.packageHash(
            forPlaylist: Data(media.utf8)
        )
        try await streamCache.segments.store(
            videoId: 5,
            hash: packageHash,
            asset: "segment_00000.m4s",
            data: Data([9])
        )
        MockURLProtocol.stub(
            path: "/videos/5/hls/master.m3u8",
            data: Data(master.utf8)
        )
        MockURLProtocol.stub(
            path: "/videos/5/hls/video.m3u8",
            data: Data(media.utf8)
        )
        MockURLProtocol.stub(
            path: "/videos/5/hls/subtitles/es.m3u8",
            data: Data(subtitles.utf8)
        )
        MockURLProtocol.stub(path: "/videos/5/hls/init.mp4", data: Data([1]))
        MockURLProtocol.stub(
            path: "/videos/5/hls/subtitles/es.vtt",
            data: Data([3])
        )

        try await cache.downloadHLS(
            id: 5,
            versionId: nil,
            masterURL: URL(string: "https://u.test/videos/5/hls/master.m3u8")!,
            bearerToken: "tok"
        )

        let segment = cache.offlineHLSDir(for: 5, versionId: nil)
            .appendingPathComponent("segment_00000.m4s")
        XCTAssertEqual(try Data(contentsOf: segment), Data([9]))
    }

    func testCallerCancellationAtCompletedProgressPreventsPromotion() async {
        MockURLProtocol.stub(
            path: "/videos/5/hls/master.m3u8",
            data: Data(master.utf8)
        )
        MockURLProtocol.stub(
            path: "/videos/5/hls/video.m3u8",
            data: Data(media.utf8)
        )
        MockURLProtocol.stub(
            path: "/videos/5/hls/subtitles/es.m3u8",
            data: Data(subtitles.utf8)
        )
        MockURLProtocol.stub(path: "/videos/5/hls/init.mp4", data: Data([1]))
        MockURLProtocol.stub(
            path: "/videos/5/hls/segment_00000.m4s",
            data: Data([2])
        )
        MockURLProtocol.stub(
            path: "/videos/5/hls/subtitles/es.vtt",
            data: Data([3])
        )

        let cache = cache!
        let download = Task(priority: .background) {
            try await cache.downloadHLS(
                id: 5,
                versionId: nil,
                masterURL: URL(
                    string: "https://u.test/videos/5/hls/master.m3u8"
                )!,
                bearerToken: "tok"
            )
        }

        var cancelledAtCompletedProgress = false
        for _ in 0..<10_000 {
            if case .downloading(let progress) = cache.state(for: 5),
               progress == 1
            {
                cancelledAtCompletedProgress = true
                download.cancel()
                break
            }
            await Task.yield()
        }

        guard cancelledAtCompletedProgress else {
            download.cancel()
            _ = try? await download.value
            XCTFail("did not observe completed progress before promotion")
            return
        }
        do {
            try await download.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertNil(cache.offlineHLSMasterURL(for: 5, versionId: nil))
    }

    func testRemoveCachedDeletesOfflineHLS() throws {
        let directory = cache.offlineHLSDir(for: 5, versionId: nil)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data([1]).write(
            to: directory.appendingPathComponent("master.m3u8")
        )
        XCTAssertEqual(cache.state(for: 5), .cached)

        cache.removeCached(id: 5)

        XCTAssertEqual(cache.state(for: 5), .notCached)
    }

    func testDownloadFailureDoesNotPromotePartialPackage() async {
        MockURLProtocol.stub(
            path: "/videos/5/hls/master.m3u8",
            data: Data(master.utf8)
        )
        MockURLProtocol.stub(
            path: "/videos/5/hls/video.m3u8",
            data: Data(media.utf8)
        )
        MockURLProtocol.stub(
            path: "/videos/5/hls/subtitles/es.m3u8",
            data: Data(subtitles.utf8)
        )
        MockURLProtocol.stub(
            path: "/videos/5/hls/segment_00000.m4s",
            data: Data([2])
        )
        MockURLProtocol.stub(
            path: "/videos/5/hls/subtitles/es.vtt",
            data: Data([3])
        )

        do {
            try await cache.downloadHLS(
                id: 5,
                versionId: nil,
                masterURL: URL(
                    string: "https://u.test/videos/5/hls/master.m3u8"
                )!,
                bearerToken: "tok"
            )
            XCTFail("expected download to fail")
        } catch {}

        XCTAssertNil(cache.offlineHLSMasterURL(for: 5, versionId: nil))
        XCTAssertEqual(cache.state(for: 5), .notCached)
    }

    func testExternalActivityClaimDoesNotOverwriteExistingDownload() {
        XCTAssertTrue(
            cache.beginExternalActivity(
                key: "5",
                videoId: 5,
                versionId: nil,
                totalUnits: 10_000
            )
        )
        cache.updateExternalActivity(key: "5", completedUnits: 2_500)

        XCTAssertFalse(
            cache.beginExternalActivity(
                key: "5",
                videoId: 5,
                versionId: nil,
                totalUnits: 10_000
            )
        )
        XCTAssertEqual(cache.state(for: 5), .downloading(0.25))
        cache.endExternalActivity(key: "5")
    }

    func testCancelDuringHLSDownloadPreventsPromotion() async {
        await assertCancellationPreventsPromotion {
            $0.cancel(id: 5)
        }
    }

    func testClearAllVideosDuringHLSDownloadPreventsPromotion() async {
        await assertCancellationPreventsPromotion {
            $0.clearAllVideos()
        }
    }

    private func assertCancellationPreventsPromotion(
        _ cancel: (CacheManager) -> Void
    ) async {
        let blockedRequestStarted = expectation(
            description: "asset request started"
        )
        let releaseRequest = DispatchSemaphore(value: 0)
        let responses = [
            "/videos/5/hls/master.m3u8": Data(master.utf8),
            "/videos/5/hls/video.m3u8": Data(media.utf8),
            "/videos/5/hls/subtitles/es.m3u8": Data(subtitles.utf8),
            "/videos/5/hls/init.mp4": Data([1]),
            "/videos/5/hls/segment_00000.m4s": Data([2]),
            "/videos/5/hls/subtitles/es.vtt": Data([3]),
        ]
        MockURLProtocol.handler = { request in
            guard let url = request.url,
                  let data = responses[url.path]
            else {
                throw URLError(.resourceUnavailable)
            }
            if url.path == "/videos/5/hls/init.mp4" {
                blockedRequestStarted.fulfill()
                releaseRequest.wait()
            }
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                data
            )
        }

        let cache = cache!
        let download = Task {
            try await cache.downloadHLS(
                id: 5,
                versionId: nil,
                masterURL: URL(
                    string: "https://u.test/videos/5/hls/master.m3u8"
                )!,
                bearerToken: "tok"
            )
        }
        await fulfillment(of: [blockedRequestStarted], timeout: 2)

        cancel(cache)
        XCTAssertEqual(cache.state(for: 5), .notCached)
        releaseRequest.signal()

        do {
            try await download.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertNil(cache.offlineHLSMasterURL(for: 5, versionId: nil))
    }
}
