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

    func testWrongSecretIs404() async throws {
        let good = proxy.mp4URL(videoId: 5, versionId: nil)!
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

    // MARK: - Listener liveness

    /// A listener that dies on its own — iOS reclaiming the socket during
    /// suspension — must not leave `port` advertising a dead address, or every
    /// proxied URL points at nothing.
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

    /// Called before every play, so the common case must be a no-op: rebinding a
    /// healthy proxy would invalidate the URL of whatever is already playing.
    func testEnsureRunningKeepsPortWhenAlreadyServing() async throws {
        let port = try XCTUnwrap(proxy.port)
        await proxy.ensureRunning()
        XCTAssertEqual(proxy.port, port)
    }

    private func pollUntil(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
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
