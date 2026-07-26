import XCTest
@testable import PatataTubeKit

private final class ConcurrentETagURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var oldBody = Data()
    nonisolated(unsafe) private static var newBody = Data()
    nonisolated(unsafe) private static var windowRequestCount = 0
    nonisolated(unsafe) private static var pendingOld:
        (ConcurrentETagURLProtocol, URLRequest)?
    nonisolated(unsafe) private static var oldRangeStarted =
        DispatchSemaphore(value: 0)

    static func configure(old: Data, new: Data) {
        lock.withLock {
            oldBody = old
            newBody = new
            windowRequestCount = 0
            pendingOld = nil
            oldRangeStarted = DispatchSemaphore(value: 0)
        }
    }

    static func waitForOldRange(timeout: DispatchTime) -> DispatchTimeoutResult {
        let semaphore = lock.withLock { oldRangeStarted }
        return semaphore.wait(timeout: timeout)
    }

    static func releaseOldRange() {
        let pending = lock.withLock {
            let value = pendingOld
            pendingOld = nil
            return value
        }
        guard let (protocolInstance, request) = pending else { return }
        protocolInstance.respond(request: request, body: oldBody, etag: "\"e1\"")
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let range = request.value(forHTTPHeaderField: "Range")
        if range == "bytes=0-0" {
            respond(request: request, body: Self.oldBody, etag: "\"e1\"")
            return
        }

        let requestNumber = Self.lock.withLock {
            Self.windowRequestCount += 1
            return Self.windowRequestCount
        }
        if requestNumber == 1 {
            let semaphore = Self.lock.withLock {
                Self.pendingOld = (self, request)
                return Self.oldRangeStarted
            }
            semaphore.signal()
            return
        }
        respond(request: request, body: Self.newBody, etag: "\"e2\"")
    }

    override func stopLoading() {}

    private func respond(request: URLRequest, body: Data, etag: String) {
        do {
            let (response, data) = try rangedResponse(
                request: request,
                fullBody: body,
                etag: etag
            )
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

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

    func testHLSStorageFailureEvictsAndRetriesBeforePassingThrough() async throws {
        let playlist = Data(
            "#EXTM3U\n#EXTINF:6.0,\nblocked/segment.m4s\n#EXT-X-ENDLIST\n".utf8
        )
        let segment = Data(repeating: 8, count: 64)
        MockURLProtocol.stub(
            path: "/videos/5/hls/video.m3u8",
            data: playlist
        )
        MockURLProtocol.stub(
            path: "/videos/5/hls/blocked/segment.m4s",
            data: segment
        )

        let base = try XCTUnwrap(proxy.hlsURL(videoId: 5, versionId: nil))
            .deletingLastPathComponent()
        _ = try await get(base.appendingPathComponent("video.m3u8"))

        let hash = SegmentCache.packageHash(forPlaylist: playlist)
        let blocker = cache.segments.videoDir(videoId: 5)
            .appendingPathComponent(hash, isDirectory: true)
            .appendingPathComponent("blocked")
        try Data([1]).write(to: blocker)

        let segmentURL = base.appendingPathComponent("blocked/segment.m4s")
        let (first, firstResponse) = try await get(segmentURL)
        XCTAssertEqual(firstResponse.statusCode, 200)
        XCTAssertEqual(first, segment)

        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let (cached, cachedResponse) = try await get(segmentURL)
        XCTAssertEqual(cachedResponse.statusCode, 200)
        XCTAssertEqual(cached, segment)
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

    func testMP4PrepareFailureServesBoundedWindowUncached() async throws {
        let mp4Root = root.appendingPathComponent("mp4", isDirectory: true)
        try FileManager.default.removeItem(at: mp4Root)
        try Data().write(to: mp4Root)

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
    }

    func testMP4ETagChangeUsesReplacementEntityTotal() async throws {
        let original = Data(repeating: 1, count: 1000)
        let replacement = Data((0..<600).map { UInt8($0 % 251) })
        var isProbe = true
        MockURLProtocol.handler = { request in
            defer { isProbe = false }
            return try rangedResponse(
                request: request,
                fullBody: isProbe ? original : replacement,
                etag: isProbe ? "\"e1\"" : "\"e2\""
            )
        }

        let url = proxy.mp4URL(videoId: 9, versionId: nil)!
        let (data, response) = try await get(url, range: "bytes=100-299")

        XCTAssertEqual(response.statusCode, 206)
        XCTAssertEqual(data, replacement.subdata(in: 100..<300))
        XCTAssertEqual(
            response.value(forHTTPHeaderField: "Content-Range"),
            "bytes 100-299/600"
        )
        let manifest = await cache.ranges.manifest(key: "9")
        XCTAssertEqual(manifest?.totalByteCount, 600)
        XCTAssertEqual(manifest?.etag, "\"e2\"")
    }

    func testHLSCachedAssetsAreScopedByVersionWhenPlaylistBytesMatch() async throws {
        let media = Data("#EXTM3U\n#EXTINF:6.0,\nsegment.m4s\n#EXT-X-ENDLIST\n".utf8)
        let segment1 = Data(repeating: 1, count: 32)
        let segment2 = Data(repeating: 2, count: 32)
        MockURLProtocol.handler = { request in
            let components = URLComponents(
                url: try XCTUnwrap(request.url),
                resolvingAgainstBaseURL: false
            )
            let version = components?.queryItems?
                .first(where: { $0.name == "version_id" })?.value
            let data: Data
            switch (request.url?.path, version) {
            case ("/videos/5/hls/video.m3u8", "1"):
                data = media
            case ("/videos/5/hls/video.m3u8", "2"):
                data = media
            case ("/videos/5/hls/segment.m4s", "1"):
                data = segment1
            case ("/videos/5/hls/segment.m4s", "2"):
                data = segment2
            default:
                throw URLError(.resourceUnavailable)
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                data
            )
        }

        let v1 = try XCTUnwrap(proxy.hlsURL(videoId: 5, versionId: 1))
            .deletingLastPathComponent()
        let v2 = try XCTUnwrap(proxy.hlsURL(videoId: 5, versionId: 2))
            .deletingLastPathComponent()
        _ = try await get(v1.appendingPathComponent("video.m3u8"))
        let (firstV1, _) = try await get(v1.appendingPathComponent("segment.m4s"))
        _ = try await get(v2.appendingPathComponent("video.m3u8"))
        let (firstV2, _) = try await get(v2.appendingPathComponent("segment.m4s"))
        XCTAssertEqual(firstV1, segment1)
        XCTAssertEqual(firstV2, segment2)

        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let (cachedV1, response) = try await get(
            v1.appendingPathComponent("segment.m4s")
        )
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(cachedV1, segment1)
    }

    func testConcurrentOldResponseCannotCommitUnderNewETag() async throws {
        let oldBody = Data(repeating: 1, count: 1_000)
        let newBody = Data(repeating: 2, count: 600)
        await proxy.stop()
        ConcurrentETagURLProtocol.configure(old: oldBody, new: newBody)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConcurrentETagURLProtocol.self]
        proxy = StreamProxy(
            cache: cache,
            credentials: credentials,
            session: URLSession(configuration: configuration)
        )
        await proxy.start()

        let url = try XCTUnwrap(proxy.mp4URL(videoId: 9, versionId: nil))
        let fetchWindow: @Sendable () async throws -> (Data, HTTPURLResponse) = {
            var request = URLRequest(url: url)
            request.setValue("bytes=100-299", forHTTPHeaderField: "Range")
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, response as! HTTPURLResponse)
        }
        let oldRequest = Task { try await fetchWindow() }
        XCTAssertEqual(
            ConcurrentETagURLProtocol.waitForOldRange(timeout: .now() + 2),
            .success
        )

        let (newResponseData, newResponse) = try await fetchWindow()
        XCTAssertEqual(newResponse.statusCode, 206)
        XCTAssertEqual(newResponseData, newBody.subdata(in: 100..<300))

        ConcurrentETagURLProtocol.releaseOldRange()
        let (oldResponseData, oldResponse) = try await oldRequest.value
        XCTAssertEqual(oldResponse.statusCode, 206)
        XCTAssertEqual(oldResponseData, newBody.subdata(in: 100..<300))

        let manifest = await cache.ranges.manifest(key: "9")
        XCTAssertEqual(manifest?.etag, "\"e2\"")
        let cached = try await cache.ranges.read(
            key: "9",
            range: DownloadByteRange(start: 100, end: 299)
        )
        XCTAssertEqual(cached, newBody.subdata(in: 100..<300))
    }

    func testMP4StorageFailureEvictsRecreatesAndRetriesOnce() async throws {
        let body = Data((0..<1_000).map { UInt8($0 % 251) })
        await proxy.stop()
        ConcurrentETagURLProtocol.configure(old: body, new: body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConcurrentETagURLProtocol.self]
        proxy = StreamProxy(
            cache: cache,
            credentials: credentials,
            session: URLSession(configuration: configuration)
        )
        await proxy.start()

        let url = try XCTUnwrap(proxy.mp4URL(videoId: 9, versionId: nil))
        let fetchWindow: @Sendable () async throws -> (Data, HTTPURLResponse) = {
            var request = URLRequest(url: url)
            request.setValue("bytes=100-299", forHTTPHeaderField: "Range")
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, response as! HTTPURLResponse)
        }
        let request = Task { try await fetchWindow() }
        XCTAssertEqual(
            ConcurrentETagURLProtocol.waitForOldRange(timeout: .now() + 2),
            .success
        )

        let dataURL = cache.ranges.entryDir(key: "9")
            .appendingPathComponent("data.bin")
        try FileManager.default.removeItem(at: dataURL)
        try FileManager.default.createDirectory(
            at: dataURL,
            withIntermediateDirectories: true
        )
        ConcurrentETagURLProtocol.releaseOldRange()

        let (responseData, response) = try await request.value
        XCTAssertEqual(response.statusCode, 206)
        XCTAssertEqual(responseData, body.subdata(in: 100..<300))
        let cached = try await cache.ranges.read(
            key: "9",
            range: DownloadByteRange(start: 100, end: 299)
        )
        XCTAssertEqual(cached, body.subdata(in: 100..<300))
    }

    func testInitialMasterIsCachedAfterMediaPlaylistEstablishesHash() async throws {
        let masterData = Data("#EXTM3U\nvideo.m3u8\n".utf8)
        let mediaData = Data("#EXTM3U\n#EXTINF:6.0,\nsegment_00000.m4s\n#EXT-X-ENDLIST\n".utf8)
        MockURLProtocol.stub(path: "/videos/5/hls/master.m3u8", data: masterData)
        MockURLProtocol.stub(path: "/videos/5/hls/video.m3u8", data: mediaData)

        let master = proxy.hlsURL(videoId: 5, versionId: nil)!
        _ = try await get(master)
        let mediaURL = master.deletingLastPathComponent().appendingPathComponent("video.m3u8")
        _ = try await get(mediaURL)

        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let (cachedMaster, response) = try await get(master)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(cachedMaster, masterData)
    }
}

private func rangedResponse(
    request: URLRequest,
    fullBody: Data,
    etag: String
) throws -> (HTTPURLResponse, Data) {
    guard let header = request.value(forHTTPHeaderField: "Range"),
          header.hasPrefix("bytes=")
    else {
        throw URLError(.badServerResponse)
    }
    let bounds = header.dropFirst("bytes=".count)
        .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    guard bounds.count == 2,
          let start = Int(bounds[0]),
          start >= 0,
          start < fullBody.count
    else {
        throw URLError(.badServerResponse)
    }
    let requestedEnd = bounds[1].isEmpty ? fullBody.count - 1 : Int(bounds[1])
    guard let requestedEnd, requestedEnd >= start else {
        throw URLError(.badServerResponse)
    }
    let end = min(requestedEnd, fullBody.count - 1)
    let data = fullBody.subdata(in: start..<(end + 1))
    let headers = [
        "Content-Range": "bytes \(start)-\(end)/\(fullBody.count)",
        "ETag": etag,
        "Accept-Ranges": "bytes",
        "Content-Length": "\(data.count)",
    ]
    return (
        HTTPURLResponse(
            url: request.url!,
            statusCode: 206,
            httpVersion: nil,
            headerFields: headers
        )!,
        data
    )
}
