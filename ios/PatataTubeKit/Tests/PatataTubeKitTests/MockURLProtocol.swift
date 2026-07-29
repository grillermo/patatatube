import Foundation

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) private static var stubs: [String: (URLRequest) throws -> (HTTPURLResponse, Data)] = [:]
    nonisolated(unsafe) private static var requestCounts: [String: Int] = [:]
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
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
    override func stopLoading() {}

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

    static func requestCount(path: String) -> Int {
        lock.withLock { requestCounts[path, default: 0] }
    }

    static func reset() {
        lock.withLock {
            stubs = [:]
            requestCounts = [:]
            handler = nil
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
