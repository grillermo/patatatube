import Foundation

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) private static var stubs: [String: (URLRequest) throws -> (HTTPURLResponse, Data)] = [:]
    nonisolated(unsafe) private static var requestCounts: [String: Int] = [:]
    private static let lock = NSLock()

    /// Serves a ranged body in chunks so a test can act (pause, cancel) part
    /// way through a transfer. Set by `stubRangedChunked`; takes precedence
    /// over `handler` while it is installed.
    nonisolated(unsafe) private static var chunkedPlan: (
        (URLRequest) throws -> (
            response: HTTPURLResponse,
            body: Data,
            chunkSize: Int,
            afterChunk: (Int) -> Bool
        )
    )?
    /// Every `Range` header seen, in request order — how a test proves a
    /// resumed transfer asked for the bytes it did not already have.
    nonisolated(unsafe) private static var ranges: [String] = []

    private let cancelLock = NSLock()
    private var isCancelled = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let plan = MockURLProtocol.chunkedPlan {
            startChunkedLoading(plan)
            return
        }
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {
        cancelLock.withLock { isCancelled = true }
    }

    private func startChunkedLoading(
        _ plan: (URLRequest) throws -> (
            response: HTTPURLResponse,
            body: Data,
            chunkSize: Int,
            afterChunk: (Int) -> Bool
        )
    ) {
        do {
            let planned = try plan(request)
            client?.urlProtocol(
                self,
                didReceive: planned.response,
                cacheStoragePolicy: .notAllowed
            )
            var offset = 0
            while offset < planned.body.count {
                if cancelLock.withLock({ isCancelled }) { return }
                let end = min(offset + planned.chunkSize, planned.body.count)
                client?.urlProtocol(self, didLoad: planned.body.subdata(in: offset..<end))
                offset = end
                // `afterChunk` returning false cuts the response short. A
                // cancel requested from inside it cannot be relied on to reach
                // `stopLoading` while this thread is still in `startLoading`,
                // so the stub severs the connection itself — which is what the
                // client sees when a real transfer is cancelled mid-body.
                guard planned.afterChunk(offset) else {
                    client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
                    return
                }
            }
            if cancelLock.withLock({ isCancelled }) { return }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    /// Serves `fullBody` honoring `Range`, delivered `chunkSize` bytes at a
    /// time, calling `afterChunk` with the number of bytes delivered so far.
    static func stubRangedChunked(
        path: String,
        fullBody: Data,
        etag: String,
        chunkSize: Int,
        afterChunk: @escaping (Int) -> Bool
    ) {
        lock.withLock {
            chunkedPlan = { request in
                guard request.url?.path == path else {
                    throw URLError(.resourceUnavailable)
                }
                let header = request.value(forHTTPHeaderField: "Range") ?? ""
                lock.withLock { ranges.append(header) }
                guard header.hasPrefix("bytes=") else {
                    throw URLError(.badServerResponse)
                }
                let bounds = header.dropFirst("bytes=".count)
                    .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                guard bounds.count == 2, let start = Int(bounds[0]) else {
                    throw URLError(.badServerResponse)
                }
                let requestedEnd = bounds[1].isEmpty
                    ? fullBody.count - 1
                    : Int(bounds[1])
                guard let requestedEnd,
                      start >= 0,
                      start < fullBody.count,
                      requestedEnd >= start
                else {
                    throw URLError(.badServerResponse)
                }
                let end = min(requestedEnd, fullBody.count - 1)
                let body = fullBody.subdata(in: start..<(end + 1))
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 206,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Range": "bytes \(start)-\(end)/\(fullBody.count)",
                        "ETag": etag,
                        "Accept-Ranges": "bytes",
                        "Content-Length": "\(body.count)",
                    ]
                )!
                return (response, body, chunkSize, afterChunk)
            }
        }
    }

    /// Every `Range` header served by `stubRangedChunked`, in request order.
    static func recordedRanges() -> [String] {
        lock.withLock { ranges }
    }

    static func stub(path: String, data: Data) {
        register(path: path) { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                data
            )
        }
    }

    static func stubRanged(path: String, fullBody: Data, etag: String) {
        register(path: path) { request in
            guard let header = request.value(forHTTPHeaderField: "Range"),
                  header.hasPrefix("bytes=")
            else {
                throw URLError(.badServerResponse)
            }
            let bounds = header.dropFirst("bytes=".count)
                .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard bounds.count == 2, let start = Int(bounds[0]) else {
                throw URLError(.badServerResponse)
            }
            let requestedEnd = bounds[1].isEmpty ? fullBody.count - 1 : Int(bounds[1])
            guard let requestedEnd,
                  start >= 0,
                  start < fullBody.count,
                  requestedEnd >= start
            else {
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
    }

    /// Fails the first `failures` requests for `path` with `error`, then
    /// serves `data` with a 200. Lets a test prove a fetch retried rather
    /// than gave up.
    static func stubFailing(
        path: String,
        failures: Int,
        error: Error = URLError(.networkConnectionLost),
        data: Data
    ) {
        let remaining = Counter(failures)
        register(path: path) { request in
            if remaining.decrementIfPositive() {
                throw error
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
    }

    /// Always answers `path` with `status` and an empty body.
    static func stubStatus(path: String, status: Int) {
        register(path: path) { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
    }

    /// Exposes the raw stub registration so a test can script per-attempt
    /// responses. Requests are counted like every other stub.
    static func registerCounting(
        path: String,
        response: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) {
        register(path: path, response: response)
    }

    static func requestCount(path: String) -> Int {
        lock.withLock { requestCounts[path, default: 0] }
    }

    static func reset() {
        lock.withLock {
            stubs = [:]
            requestCounts = [:]
            handler = nil
            chunkedPlan = nil
            ranges = []
        }
    }

    private static func register(
        path: String,
        response: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) {
        lock.withLock {
            stubs[path] = response
            handler = { request in
                guard let path = request.url?.path else {
                    throw URLError(.badURL)
                }
                return try lock.withLock {
                    requestCounts[path, default: 0] += 1
                    guard let stub = stubs[path] else {
                        throw URLError(.resourceUnavailable)
                    }
                    return try stub(request)
                }
            }
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int

    init(_ value: Int) { self.value = value }

    /// Returns true (and consumes one) while the counter is above zero.
    func decrementIfPositive() -> Bool {
        lock.withLock {
            guard value > 0 else { return false }
            value -= 1
            return true
        }
    }
}

func mockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

func jsonResponse(_ url: URL, status: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!
}

extension URLRequest {
    func httpBodyData() -> Data {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
