import XCTest
@testable import PatataTubeKit

private func get(_ url: URL, range: String? = nil) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: url)
    if let range { request.setValue(range, forHTTPHeaderField: "Range") }
    let (data, response) = try await URLSession.shared.data(for: request)
    return (data, response as! HTTPURLResponse)
}

final class StreamProxyTests: XCTestCase {
    private var root: URL!
    private var store: MediaStore!
    private var credentials: CredentialStore!
    private var proxy: StreamProxy!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        store = MediaStore(videosRoot: root)
        credentials = InMemoryCredentialStore(baseURL: URL(string: "https://upstream.test"), token: "tok")
        proxy = await makeProxy(store: store, protocolClass: MockURLProtocol.self)
    }

    override func tearDown() async throws {
        await proxy.stop()
        try? FileManager.default.removeItem(at: root)
        MockURLProtocol.reset()
        try await super.tearDown()
    }

    private func makeProxy(store: MediaStore, protocolClass: AnyClass,
                           tuning: StreamProxy.Tuning = StreamProxy.Tuning()) async -> StreamProxy {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [protocolClass]
        let proxy = StreamProxy(store: store, credentials: credentials,
                                session: URLSession(configuration: config), tuning: tuning)
        await proxy.start()
        return proxy
    }

    private func smallTuning(waitWithin: Int64) -> StreamProxy.Tuning {
        var tuning = StreamProxy.Tuning()
        tuning.commitSize = 1024
        tuning.readSize = 1024
        tuning.waitWithin = waitWithin
        return tuning
    }

    func testWrongSecretIs404() async throws {
        let good = proxy.mp4URL(videoId: 5, versionId: nil)!
        let bad = URL(string: good.absoluteString.replacingOccurrences(of: proxy.secret, with: "nope"))!
        let (_, response) = try await get(bad)
        XCTAssertEqual(response.statusCode, 404)
    }

    /// The 2.8 bug: an 8 MB window answered AVPlayer's whole-file request, and
    /// AVPlayer failed the item. The response must cover the whole range.
    func testAWholeFileRequestGetsTheWholeFile() async throws {
        let total = 9 * 1024 * 1024
        let body = sampleBody(total)
        MockURLProtocol.stubRanged(path: "/videos/9/stream", fullBody: body, etag: "\"e1\"")
        let url = try XCTUnwrap(proxy.mp4URL(videoId: 9, versionId: nil))
        let (data, response) = try await get(url, range: "bytes=0-\(total - 1)")
        XCTAssertEqual(response.statusCode, 206)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Length"), "\(total)")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Range"), "bytes 0-\(total - 1)/\(total)")
        XCTAssertEqual(data, body)
    }

    func testAnOpenEndedRangeRunsToTheEnd() async throws {
        let body = sampleBody(1000)
        MockURLProtocol.stubRanged(path: "/videos/10/stream", fullBody: body, etag: "\"e1\"")
        let (data, response) = try await get(proxy.mp4URL(videoId: 10, versionId: nil)!, range: "bytes=100-")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Range"), "bytes 100-999/1000")
        XCTAssertEqual(data, body.subdata(in: 100..<1000))
    }

    func testWatchedBytesAreKeptAndServedFromTheStore() async throws {
        let body = sampleBody(1000)
        MockURLProtocol.stubRanged(path: "/videos/11/stream", fullBody: body, etag: "\"e1\"")
        let url = proxy.mp4URL(videoId: 11, versionId: nil)!
        let (data, _) = try await get(url, range: "bytes=100-299")
        XCTAssertEqual(data, body.subdata(in: 100..<300))
        let count = MockURLProtocol.requestCount(path: "/videos/11/stream")
        let (again, _) = try await get(url, range: "bytes=100-299")
        XCTAssertEqual(again, data)
        XCTAssertEqual(MockURLProtocol.requestCount(path: "/videos/11/stream"), count)
    }

    func testAFinishedFileIsServedWithoutTheServer() async throws {
        let body = sampleBody(1000)
        try body.write(to: store.finishedURL(key: "12"))
        let (data, response) = try await get(proxy.mp4URL(videoId: 12, versionId: nil)!, range: "bytes=10-19")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Range"), "bytes 10-19/1000")
        XCTAssertEqual(data, body.subdata(in: 10..<20))
        XCTAssertEqual(MockURLProtocol.requestCount(path: "/videos/12/stream"), 0)
    }

    /// Part committed, part fetched by this reader, part being fetched by a
    /// download: the response is the original bytes, and the reader fetched
    /// only the gap between the two.
    func testAMixedRangeComesBackByteIdentical() async throws {
        let path = "/videos/14/stream"
        let body = sampleBody(4000)
        ChunkedRangeProtocol.stub(path: path, plan: .init(
            fullBody: body, etag: "\"m\"", chunkSize: 100,
            failureError: URLError(.networkConnectionLost), afterChunk: { _ in true }
        ))
        defer { ChunkedRangeProtocol.reset(path: path) }
        let identity = MediaIdentity(etag: "\"m\"", totalByteCount: 4000)
        let generation = try await store.open(key: "14", identity: identity)
        try await put(store, key: "14", DownloadByteRange(start: 0, end: 999), generation: generation, from: body)
        guard case .granted(let tail) = await store.claim(key: "14", from: 3000, through: 3999, owner: .download, waitWithin: 0)
        else { return XCTFail("tail claim refused") }
        let download = RangeFetcher(
            store: store, key: "14", identity: identity, generation: generation,
            session: URLSession(configuration: ChunkedRangeProtocol.configuration()),
            upstream: UpstreamRequests(url: URL(string: "https://upstream.test\(path)")!, credentials: nil),
            commitSize: 100
        )
        let downloading = Task { try await download.run(claim: tail.id) }
        let chunked = await makeProxy(store: store, protocolClass: ChunkedRangeProtocol.self, tuning: smallTuning(waitWithin: 4000))

        let (data, _) = try await get(chunked.mp4URL(videoId: 14, versionId: nil)!, range: "bytes=0-3999")

        XCTAssertEqual(data, body)
        _ = try await downloading.value
        XCTAssertTrue(ChunkedRangeProtocol.recordedRanges(path: path).contains("bytes=1000-2999"))
        await chunked.stop()
    }

    func testHangingUpCancelsOnlyThatReadersFetcher() async throws {
        let path = "/videos/15/stream"
        let body = sampleBody(200_000)
        ChunkedRangeProtocol.stub(path: path, plan: .init(
            fullBody: body, etag: "\"h\"", chunkSize: 4096,
            failureError: URLError(.networkConnectionLost),
            afterChunk: { _ in Thread.sleep(forTimeInterval: 0.01); return true },
            asyncDelivery: true
        ))
        defer { ChunkedRangeProtocol.reset(path: path) }
        _ = try await store.open(key: "15", identity: MediaIdentity(etag: "\"h\"", totalByteCount: 200_000))
        var tuning = smallTuning(waitWithin: 8192)
        tuning.commitSize = 4096
        let chunked = await makeProxy(store: store, protocolClass: ChunkedRangeProtocol.self, tuning: tuning)
        let url = try XCTUnwrap(chunked.mp4URL(videoId: 15, versionId: nil))

        var requestA = URLRequest(url: url)
        requestA.setValue("bytes=0-199999", forHTTPHeaderField: "Range")
        let (bytesA, _) = try await URLSession.shared.bytes(for: requestA)
        var received = 0
        for try await _ in bytesA {
            received += 1
            if received == 4096 { break }
        }
        async let resultB = get(url, range: "bytes=100000-199999")
        try await Task.sleep(for: .milliseconds(50))
        bytesA.task.cancel()

        let (dataB, _) = try await resultB
        XCTAssertEqual(dataB, body.subdata(in: 100_000..<200_000))
        let stopped = await eventually { ChunkedRangeProtocol.stoppedRanges(path: path).contains("bytes=0-199999") }
        XCTAssertTrue(stopped, "reader A's upstream fetch kept running after it hung up")
        XCTAssertFalse(ChunkedRangeProtocol.stoppedRanges(path: path).contains("bytes=100000-199999"))
        await chunked.stop()
    }

    func testAChangedFileEndsTheResponseAndResetsTheEntry() async throws {
        let body = sampleBody(1000)
        MockURLProtocol.registerCounting(path: "/videos/16/stream") { request in
            let etag = request.value(forHTTPHeaderField: "Range") == "bytes=0-0" ? "\"e1\"" : "\"e2\""
            return try rangedResponse(request: request, fullBody: body, etag: etag)
        }
        do {
            _ = try await get(proxy.mp4URL(videoId: 16, versionId: nil)!, range: "bytes=0-999")
            XCTFail("expected the response to end early")
        } catch {}
        let manifest = await store.manifest(key: "16")
        XCTAssertEqual(manifest?.identity?.etag, "\"e2\"")
        XCTAssertEqual(manifest?.committed.totalBytes, 0)
    }

    func testDownloadingWhileWatchingFetchesEachByteOnce() async throws {
        let path = "/videos/17/stream"
        let total = 64 * 1024
        let body = sampleBody(total)
        ChunkedRangeProtocol.stub(path: path, plan: .init(
            fullBody: body, etag: "\"d\"", chunkSize: 1024,
            failureError: URLError(.networkConnectionLost),
            afterChunk: { _ in Thread.sleep(forTimeInterval: 0.002); return true },
            asyncDelivery: true
        ))
        defer { ChunkedRangeProtocol.reset(path: path) }
        let otherRoot = temporaryVideosRoot("both")
        let manager = CacheManager(
            root: otherRoot, configuration: ChunkedRangeProtocol.configuration(), fileManager: .default,
            fetchTuning: DownloadTuning(minPiece: 8 * 1024, commitSize: 1024)
        )
        let chunked = await makeProxy(store: manager.mediaStore, protocolClass: ChunkedRangeProtocol.self,
                                      tuning: smallTuning(waitWithin: 8 * 1024))

        async let download: Void = manager.download(id: 17, from: URL(string: "https://upstream.test\(path)")!, streamCount: 2)
        let (data, _) = try await get(chunked.mp4URL(videoId: 17, versionId: nil)!, range: "bytes=0-\(total - 1)")
        try await download

        XCTAssertEqual(data, body)
        XCTAssertEqual(try Data(contentsOf: manager.localURL(for: 17)), body)
        XCTAssertLessThan(ChunkedRangeProtocol.deliveredByteCount(path: path), total + total / 4)
        await chunked.stop()
    }

    func testPlaybackDoesNotWaitForADownloadSlot() async throws {
        let gate = DownloadConcurrencyGate(limit: 1)
        await gate.acquire()
        let otherRoot = temporaryVideosRoot("gate")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let manager = CacheManager(root: otherRoot, configuration: config, fileManager: .default, concurrencyGate: gate)
        MockURLProtocol.stubRanged(path: "/videos/18/stream", fullBody: sampleBody(10), etag: "\"g\"")
        let waiting = Task { try await manager.download(id: 18, from: URL(string: "https://upstream.test/videos/18/stream")!) }
        let body = sampleBody(1000)
        MockURLProtocol.stubRanged(path: "/videos/19/stream", fullBody: body, etag: "\"g\"")
        let playing = await makeProxy(store: manager.mediaStore, protocolClass: MockURLProtocol.self)

        let (data, response) = try await get(playing.mp4URL(videoId: 19, versionId: nil)!, range: "bytes=0-999")

        XCTAssertEqual(response.statusCode, 206)
        XCTAssertEqual(data, body)
        gate.release()
        try await waiting.value
        await playing.stop()
    }

    // MARK: - Listener liveness

    func testServerExitClearsPortSoURLsGoNil() async throws {
        XCTAssertNotNil(proxy.port)
        await proxy.server?.stop()
        let cleared = await pollUntil { self.proxy.port == nil }
        XCTAssertTrue(cleared, "port stayed \(proxy.port.map(String.init) ?? "nil") after listener died")
        XCTAssertNil(proxy.mp4URL(videoId: 5, versionId: nil))
    }

    func testEnsureRunningRestartsAfterListenerDies() async throws {
        await proxy.server?.stop()
        _ = await pollUntil { self.proxy.port == nil }
        await proxy.ensureRunning()
        XCTAssertNotNil(proxy.port)
        MockURLProtocol.stubRanged(path: "/videos/5/stream", fullBody: Data(repeating: 1, count: 64), etag: "\"e1\"")
        let url = try XCTUnwrap(proxy.mp4URL(videoId: 5, versionId: nil))
        let (_, response) = try await get(url, range: "bytes=0-9")
        XCTAssertEqual(response.statusCode, 206)
    }

    func testEnsureRunningKeepsPortWhenAlreadyServing() async throws {
        let port = try XCTUnwrap(proxy.port)
        await proxy.ensureRunning()
        XCTAssertEqual(proxy.port, port)
    }

    private func pollUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

private func rangedResponse(request: URLRequest, fullBody: Data, etag: String) throws -> (HTTPURLResponse, Data) {
    guard let header = request.value(forHTTPHeaderField: "Range"), header.hasPrefix("bytes=") else {
        throw URLError(.badServerResponse)
    }
    let bounds = header.dropFirst("bytes=".count).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    guard bounds.count == 2, let start = Int(bounds[0]), start >= 0, start < fullBody.count else {
        throw URLError(.badServerResponse)
    }
    let requestedEnd = bounds[1].isEmpty ? fullBody.count - 1 : Int(bounds[1])
    guard let requestedEnd, requestedEnd >= start else { throw URLError(.badServerResponse) }
    let end = min(requestedEnd, fullBody.count - 1)
    let data = fullBody.subdata(in: start..<(end + 1))
    return (
        HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil, headerFields: [
            "Content-Range": "bytes \(start)-\(end)/\(fullBody.count)",
            "ETag": etag,
            "Accept-Ranges": "bytes",
            "Content-Length": "\(data.count)",
        ])!,
        data
    )
}
