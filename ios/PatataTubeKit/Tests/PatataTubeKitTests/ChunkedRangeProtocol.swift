import Foundation

/// Serves a ranged body **in chunks**, so a test can act (pause, cut the
/// connection) part way through a transfer. `MockURLProtocol` delivers a whole
/// body in one `didLoad`, which cannot express "half a segment arrived".
///
/// Deliberately a separate class with **per-path** state rather than an
/// addition to `MockURLProtocol`: Swift Testing runs tests in parallel, and
/// `MockURLProtocol`'s single static handler is already shared by every test
/// that uses it. Keying on the request path lets two chunked tests run at the
/// same time without clobbering each other, and keeps them clear of everyone
/// else's stubs.
final class ChunkedRangeProtocol: URLProtocol {
    struct Plan {
        let fullBody: Data
        let etag: String
        let chunkSize: Int
        let failureError: Error
        /// Called with the bytes delivered so far. Returning false cuts the
        /// response short with `failureError`.
        let afterChunk: (Int) -> Bool
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var plans: [String: Plan] = [:]
    nonisolated(unsafe) private static var rangesByPath: [String: [String]] = [:]

    static func stub(path: String, plan: Plan) {
        lock.withLock {
            plans[path] = plan
            rangesByPath[path] = []
        }
    }

    /// Every `Range` header served for `path`, in request order — how a test
    /// proves a resumed transfer asked only for the bytes it lacked.
    static func recordedRanges(path: String) -> [String] {
        lock.withLock { rangesByPath[path] ?? [] }
    }

    static func reset(path: String) {
        lock.withLock {
            plans[path] = nil
            rangesByPath[path] = nil
        }
    }

    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChunkedRangeProtocol.self]
        return config
    }

    private let cancelLock = NSLock()
    private var isCancelled = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func stopLoading() {
        cancelLock.withLock { isCancelled = true }
    }

    /// Delivers synchronously, on the thread CFNetwork calls this on.
    ///
    /// Tempting to hand the loop to a private queue so it stops occupying a
    /// pooled loader thread — but `URLProtocolClient` callbacks are only
    /// honoured from the client thread, so an async loop's `didLoad` calls sit
    /// unprocessed until that thread frees up. That made things strictly
    /// worse. The stall this stub allows is bounded by the test, and every
    /// blocking stub in this target now releases its semaphore on the way out.
    override func startLoading() {
        guard let path = request.url?.path,
              let plan = Self.lock.withLock({ Self.plans[path] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let header = request.value(forHTTPHeaderField: "Range") ?? ""
        Self.lock.withLock { Self.rangesByPath[path, default: []].append(header) }

        guard header.hasPrefix("bytes="),
              let bounds = Self.parseRange(header, totalByteCount: plan.fullBody.count)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let body = plan.fullBody.subdata(in: bounds.start..<(bounds.end + 1))
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 206,
            httpVersion: nil,
            headerFields: [
                "Content-Range":
                    "bytes \(bounds.start)-\(bounds.end)/\(plan.fullBody.count)",
                "ETag": plan.etag,
                "Accept-Ranges": "bytes",
                "Content-Length": "\(body.count)",
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        var offset = 0
        while offset < body.count {
            if cancelLock.withLock({ isCancelled }) { return }
            let end = min(offset + plan.chunkSize, body.count)
            client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
            offset = end
            // Client callbacks reach the session's delegate queue
            // asynchronously. Without a pause this loop outruns that queue and
            // a failure delivered at the end overtakes the body — URLSession
            // then discards the response the delegate never consumed and the
            // bytes vanish, which no real transfer does.
            Thread.sleep(forTimeInterval: 0.002)
            guard plan.afterChunk(offset) else {
                // Let the bytes already handed over drain before the failure.
                Thread.sleep(forTimeInterval: 0.1)
                client?.urlProtocol(self, didFailWithError: plan.failureError)
                return
            }
        }
        if cancelLock.withLock({ isCancelled }) { return }
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func parseRange(
        _ header: String,
        totalByteCount: Int
    ) -> (start: Int, end: Int)? {
        let bounds = header.dropFirst("bytes=".count)
            .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int(bounds[0]) else { return nil }
        let requestedEnd = bounds[1].isEmpty
            ? totalByteCount - 1
            : Int(bounds[1])
        guard let requestedEnd,
              start >= 0,
              start < totalByteCount,
              requestedEnd >= start
        else { return nil }
        return (start, min(requestedEnd, totalByteCount - 1))
    }
}
