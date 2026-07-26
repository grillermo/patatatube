import XCTest
@testable import PatataTubeKit

final class StreamProxyTests: XCTestCase {
    private var root: URL!
    private var cache: StreamCache!
    private var credentials: CredentialStore!
    private var proxy: StreamProxy!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        cache = StreamCache(root: root)
        credentials = InMemoryCredentialStore()
        credentials.baseURL = URL(string: "https://upstream.test")
        credentials.token = "tok"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        proxy = StreamProxy(
            cache: cache,
            credentials: credentials,
            session: URLSession(configuration: config)
        )
        await proxy.start()
    }

    override func tearDown() async throws {
        await proxy.stop()
        try? FileManager.default.removeItem(at: root)
        MockURLProtocol.reset()
        try await super.tearDown()
    }

    private func get(_ url: URL, range: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, response as! HTTPURLResponse)
    }

    func testHLSSegmentReadThroughCachesAndServesFromDiskSecondTime() async throws {
        let playlist = "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:6.0,\nsegment_00000.m4s\n#EXT-X-ENDLIST\n"
        MockURLProtocol.stub(path: "/videos/5/hls/master.m3u8", data: Data("#EXTM3U\nvideo.m3u8\n".utf8))
        MockURLProtocol.stub(path: "/videos/5/hls/video.m3u8", data: Data(playlist.utf8))
        MockURLProtocol.stub(path: "/videos/5/hls/segment_00000.m4s", data: Data(repeating: 4, count: 64))

        let master = proxy.hlsURL(videoId: 5, versionId: nil)!
        _ = try await get(master)
        let mediaURL = master.deletingLastPathComponent().appendingPathComponent("video.m3u8")
        _ = try await get(mediaURL)
        let segURL = master.deletingLastPathComponent().appendingPathComponent("segment_00000.m4s")
        let (first, response) = try await get(segURL)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(first, Data(repeating: 4, count: 64))

        let upstreamCallsAfterFirst = MockURLProtocol.requestCount(path: "/videos/5/hls/segment_00000.m4s")
        let (second, _) = try await get(segURL)
        XCTAssertEqual(second, first)
        XCTAssertEqual(
            MockURLProtocol.requestCount(path: "/videos/5/hls/segment_00000.m4s"),
            upstreamCallsAfterFirst
        )
    }

    func testWrongSecretIs404() async throws {
        let good = proxy.hlsURL(videoId: 5, versionId: nil)!
        let bad = URL(string: good.absoluteString.replacingOccurrences(of: proxy.secret, with: "nope"))!
        let (_, response) = try await get(bad)
        XCTAssertEqual(response.statusCode, 404)
    }

    func testMP4RangeReadThroughFillsHolesAndServes206() async throws {
        let body = Data((0..<1000).map { UInt8($0 % 251) })
        MockURLProtocol.stubRanged(path: "/videos/9/stream", fullBody: body, etag: "\"e1\"")

        let url = proxy.mp4URL(videoId: 9, versionId: nil)!
        let (data, response) = try await get(url, range: "bytes=100-299")
        XCTAssertEqual(response.statusCode, 206)
        XCTAssertEqual(data, body.subdata(in: 100..<300))
        XCTAssertEqual(
            response.value(forHTTPHeaderField: "Content-Range"),
            "bytes 100-299/1000"
        )

        let count = MockURLProtocol.requestCount(path: "/videos/9/stream")
        _ = try await get(url, range: "bytes=100-299")
        XCTAssertEqual(MockURLProtocol.requestCount(path: "/videos/9/stream"), count)
    }

    func testMP4OpenEndedRangeCappedAt8MB() async throws {
        let body = Data(repeating: 6, count: 9 * 1024 * 1024)
        MockURLProtocol.stubRanged(path: "/videos/9/stream", fullBody: body, etag: "\"e1\"")
        let url = proxy.mp4URL(videoId: 9, versionId: nil)!
        let (data, response) = try await get(url, range: "bytes=0-")
        XCTAssertEqual(response.statusCode, 206)
        XCTAssertEqual(data.count, 8 * 1024 * 1024)
        XCTAssertEqual(
            response.value(forHTTPHeaderField: "Content-Range"),
            "bytes 0-\(8 * 1024 * 1024 - 1)/\(9 * 1024 * 1024)"
        )
    }
}
