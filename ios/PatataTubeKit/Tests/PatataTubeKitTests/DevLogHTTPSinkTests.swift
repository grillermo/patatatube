import XCTest
@testable import PatataTubeKit

/// Records every request the sink makes and answers with a scripted status.
private final class RequestRecorder: URLProtocol {
    struct Capture {
        let body: Data
        let authorization: String?
    }

    nonisolated(unsafe) private static var statuses: [Int] = []
    nonisolated(unsafe) private static var captures: [Capture] = []
    nonisolated(unsafe) private static var networkError = false
    private static let lock = NSLock()

    static func reset(statuses: [Int], networkError: Bool = false) {
        lock.withLock {
            self.statuses = statuses
            self.captures = []
            self.networkError = networkError
        }
    }

    static var captured: [Capture] {
        lock.withLock { captures }
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RequestRecorder.self]
        return config
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        // URLProtocol strips httpBody into a stream; read it back out.
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(contentsOf: buffer[0..<read])
            }
            stream.close()
        } else if let data = request.httpBody {
            body = data
        }

        let status: Int
        let fail: Bool
        (status, fail) = Self.lock.withLock {
            Self.captures.append(
                Capture(body: body, authorization: request.value(forHTTPHeaderField: "Authorization"))
            )
            let next = Self.statuses.isEmpty ? 200 : Self.statuses.removeFirst()
            return (next, Self.networkError)
        }

        if fail {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class DevLogHTTPSinkTests: XCTestCase {
    private let baseURL = URL(string: "https://patatatube.test")!

    /// Held for the duration of the test: the sink's completion handlers capture
    /// `self` weakly (in the app, `DevLogCore` owns it), so a sink that is only
    /// a temporary would deallocate before any retry could fire.
    private var sink: DevLogHTTPSink!

    override func tearDown() {
        sink = nil
        super.tearDown()
    }

    @discardableResult
    private func makeSink() -> DevLogHTTPSink {
        sink = DevLogHTTPSink(
            baseURL: baseURL, token: "test-secret", sessionID: "SESSION",
            configuration: RequestRecorder.makeConfiguration()
        )
        return sink
    }

    private func record(_ seq: UInt64, _ msg: String = "m") -> DevLogRecord {
        DevLogRecord(ts: Date(timeIntervalSince1970: 0), seq: seq, session: "SESSION",
                     kind: .play, msg: msg, src: "f.swift:1", fn: "f()", meta: [:])
    }

    /// The sink is fire-and-forget, so wait for the request count to settle.
    private func waitForRequests(_ expected: Int, timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if RequestRecorder.captured.count >= expected { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        // Give any erroneous extra request a chance to show up.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    func testPostsBatchToDevlogEndpointWithBearerToken() throws {
        RequestRecorder.reset(statuses: [204])
        makeSink().write([record(1, "a"), record(2, "b")])
        waitForRequests(1)

        let captures = RequestRecorder.captured
        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures[0].authorization, "Bearer test-secret")

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: captures[0].body) as? [String: Any]
        )
        XCTAssertEqual(json["session"] as? String, "SESSION")
        let records = try XCTUnwrap(json["records"] as? [[String: Any]])
        XCTAssertEqual(records.map { $0["msg"] as? String }, ["a", "b"])
        XCTAssertEqual(records.map { $0["seq"] as? UInt64 }, [1, 2])
    }

    func testSplitsBatchesLargerThanTheServerLimit() throws {
        RequestRecorder.reset(statuses: [204, 204])
        let count = DevLogHTTPSink.maxRecordsPerRequest + 10
        makeSink().write((1...count).map { record(UInt64($0)) })
        waitForRequests(2)

        let captures = RequestRecorder.captured
        XCTAssertEqual(captures.count, 2, "must not post more than the server accepts at once")

        let counts = try captures.map { capture -> Int in
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: capture.body) as? [String: Any]
            )
            return (json["records"] as? [[String: Any]])?.count ?? 0
        }
        XCTAssertEqual(counts, [DevLogHTTPSink.maxRecordsPerRequest, 10])
    }

    func testRetriesOnceOnServerErrorThenGivesUp() {
        RequestRecorder.reset(statuses: [500, 500])
        makeSink().write([record(1)])
        waitForRequests(2)

        XCTAssertEqual(RequestRecorder.captured.count, 2,
                       "one retry only — a retry storm would poison the evidence")
    }

    func testDoesNotRetryClientErrors() {
        RequestRecorder.reset(statuses: [401])
        makeSink().write([record(1)])
        waitForRequests(1)

        XCTAssertEqual(RequestRecorder.captured.count, 1,
                       "the server will never accept this batch; retrying blocks the queue")
    }

    func testABlockedBatchDoesNotBlockTheNextOne() {
        RequestRecorder.reset(statuses: [401, 204])
        let sink = makeSink()
        sink.write([record(1, "blocked")])
        waitForRequests(1)
        sink.write([record(2, "next")])
        waitForRequests(2)

        let bodies = RequestRecorder.captured.map { String(decoding: $0.body, as: UTF8.self) }
        XCTAssertEqual(bodies.count, 2)
        XCTAssertTrue(bodies[0].contains("blocked"))
        XCTAssertTrue(bodies[1].contains("next"))
    }

    func testNetworkFailureRetriesOnceAndDoesNotCrash() {
        RequestRecorder.reset(statuses: [], networkError: true)
        makeSink().write([record(1)])
        waitForRequests(2)

        XCTAssertEqual(RequestRecorder.captured.count, 2)
    }

    func testDropsOldestBatchesWhenTheBacklogIsFull() throws {
        // Every request fails, so nothing drains and the backlog fills.
        RequestRecorder.reset(statuses: [], networkError: true)
        let sink = makeSink()
        for i in 1...(DevLogHTTPSink.maxBacklogBatches + 20) {
            sink.write([record(UInt64(i), "m\(i)")])
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        // The point is that it stays bounded and alive, not the exact count.
        XCTAssertTrue(sink.backlogCountForTesting <= DevLogHTTPSink.maxBacklogBatches)
    }

    func testEmptyBatchPostsNothing() {
        RequestRecorder.reset(statuses: [204])
        makeSink().write([])
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertTrue(RequestRecorder.captured.isEmpty)
    }
}
