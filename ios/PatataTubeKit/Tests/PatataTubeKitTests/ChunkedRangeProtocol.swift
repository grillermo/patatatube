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
        /// False (default): the loop runs synchronously inside `startLoading`.
        /// True: it runs on a global queue, so `stopLoading` is delivered
        /// while the transfer is still going.
        var asyncDelivery: Bool = false
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var plans: [String: Plan] = [:]
    nonisolated(unsafe) private static var rangesByPath: [String: [String]] = [:]
    nonisolated(unsafe) private static var stoppedByPath: [String: [String]] = [:]
    nonisolated(unsafe) private static var deliveredByPath: [String: Int] = [:]

    static func stub(path: String, plan: Plan) {
        lock.withLock {
            plans[path] = plan
            rangesByPath[path] = []
            stoppedByPath[path] = []
            deliveredByPath[path] = 0
        }
    }

    /// Every `Range` header served for `path`, in request order — how a test
    /// proves a resumed transfer asked only for the bytes it lacked.
    static func recordedRanges(path: String) -> [String] {
        lock.withLock { rangesByPath[path] ?? [] }
    }

    /// Range headers whose response the client cancelled before it ended.
    static func stoppedRanges(path: String) -> [String] {
        lock.withLock { stoppedByPath[path] ?? [] }
    }

    /// Body bytes handed to clients for `path`, probes (`bytes=0-0`) excluded.
    static func deliveredByteCount(path: String) -> Int {
        lock.withLock { deliveredByPath[path] ?? 0 }
    }

    static func reset(path: String) {
        lock.withLock {
            plans[path] = nil
            rangesByPath[path] = nil
            stoppedByPath[path] = nil
            deliveredByPath[path] = nil
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

    /// Default (`Plan.asyncDelivery == false`): delivers synchronously, on the
    /// thread CFNetwork calls this on. `URLProtocolClient` callbacks are only
    /// honoured from the client thread, so those `didLoad` calls sit
    /// unprocessed until `startLoading` returns, and `stopLoading` cannot run
    /// mid-transfer. The stall is bounded by the test, and every blocking stub
    /// in this target releases its semaphore on the way out.
    ///
    /// With `asyncDelivery`, the headers go out here and the body loop runs on
    /// a global queue, so the client thread is free: bytes reach the delegate
    /// as they are sent and `stopLoading` (a cancel) is seen between chunks.
    /// Needed to test cancellation; it also changes timing for others, so it
    /// is opt-in.
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

        if plan.asyncDelivery {
            DispatchQueue.global().async { [self] in deliver(body: body, header: header, path: path, plan: plan) }
        } else {
            deliver(body: body, header: header, path: path, plan: plan)
        }
    }

    private func deliver(body: Data, header: String, path: String, plan: Plan) {
        var offset = 0
        while offset < body.count {
            if cancelLock.withLock({ isCancelled }) {
                Self.lock.withLock { Self.stoppedByPath[path, default: []].append(header) }
                return
            }
            let end = min(offset + plan.chunkSize, body.count)
            client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
            if header != "bytes=0-0" {
                Self.lock.withLock { Self.deliveredByPath[path, default: 0] += end - offset }
            }
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
