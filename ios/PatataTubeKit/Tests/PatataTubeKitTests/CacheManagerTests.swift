import Testing
import Foundation
@testable import PatataTubeKit

private final class RangeDownloadProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) static var payload = Data("0123456789".utf8)
    nonisolated(unsafe) static var etag = "\"test-video\""
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var delayByRange: [String: TimeInterval] = [:]
    nonisolated(unsafe) static var responseOverride:
        ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func reset(payload: Data = Data("0123456789".utf8)) {
        lock.withLock {
            self.payload = payload
            etag = "\"test-video\""
            requests = []
            delayByRange = [:]
            responseOverride = nil
        }
    }

    static func setDelays(_ delays: [String: TimeInterval]) {
        lock.withLock { delayByRange = delays }
    }

    static func recordedRequests() -> [URLRequest] {
        lock.withLock { requests }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let result = try Self.lock.withLock {
                Self.requests.append(request)
                if let responseOverride = Self.responseOverride {
                    return try responseOverride(request)
                }
                return try Self.response(for: request)
            }
            let delay = Self.lock.withLock {
                Self.delayByRange[
                    request.value(forHTTPHeaderField: "Range") ?? ""
                ] ?? 0
            }
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            client?.urlProtocol(self, didReceive: result.0, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.1)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func response(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        if request.value(forHTTPHeaderField: "Range") == nil {
            let data = Data([0xAA, 0xBB])
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Length": "\(data.count)"]
                )!,
                data
            )
        }

        guard let header = request.value(forHTTPHeaderField: "Range"),
              header.hasPrefix("bytes=")
        else { throw URLError(.badServerResponse) }
        let parts = header.dropFirst("bytes=".count).split(separator: "-")
        guard parts.count == 2,
              let start = Int(parts[0]),
              let end = Int(parts[1]),
              start >= 0,
              end >= start,
              end < payload.count
        else { throw URLError(.badServerResponse) }
        let body = payload.subdata(in: start..<(end + 1))
        return (
            HTTPURLResponse(
                url: request.url!,
                statusCode: 206,
                httpVersion: nil,
                headerFields: [
                    "Accept-Ranges": "bytes",
                    "Content-Range": "bytes \(start)-\(end)/\(payload.count)",
                    "Content-Length": "\(body.count)",
                    "ETag": etag,
                ]
            )!,
            body
        )
    }
}

// Sends a response + partial body but never finishes, so a download stays
// in-flight until the task is explicitly cancelled.
private final class HangingDownloadProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // A task built from resume data may have no request URL; fall back so
        // resume-driven downloads still flow through this protocol.
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://resumed.invalid/")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Length": "1000000"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data([0x00, 0x01]))
        // Intentionally never call urlProtocolDidFinishLoading.
    }

    override func stopLoading() {}
}

private final class HangingRangeProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let value = request.value(forHTTPHeaderField: "Range"),
              value.hasPrefix("bytes=")
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let bounds = value.dropFirst("bytes=".count).split(separator: "-")
        guard bounds.count == 2,
              let start = Int(bounds[0]),
              let end = Int(bounds[1])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let body = Data([UInt8(start % 255)])
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 206,
            httpVersion: nil,
            headerFields: [
                "Accept-Ranges": "bytes",
                "Content-Range": "bytes \(start)-\(end)/12",
                "Content-Length": "\(end - start + 1)",
                "ETag": "\"hanging\"",
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        if start == 0 && end == 0 {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

private final class ResumableFailureProtocol: URLProtocol {
    private static let condition = NSCondition()
    nonisolated(unsafe) private static var stalledSegmentStopped = false
    private var isStalledSegment = false

    static let resumeMarker = Data([0xFA, 0x11])

    static func reset() {
        condition.withLock {
            stalledSegmentStopped = false
        }
    }

    static func waitForStalledSegmentToStop() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(5)
        while !stalledSegmentStopped {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let value = request.value(forHTTPHeaderField: "Range"),
              value.hasPrefix("bytes=")
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let bounds = value.dropFirst("bytes=".count).split(separator: "-")
        guard bounds.count == 2,
              let start = Int(bounds[0]),
              let end = Int(bounds[1])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 206,
            httpVersion: nil,
            headerFields: [
                "Accept-Ranges": "bytes",
                "Content-Range": "bytes \(start)-\(end)/12",
                "Content-Length": "\(end - start + 1)",
                "ETag": "\"resumable\"",
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data([UInt8(start % 255)]))

        if start == 0 && end == 0 {
            client?.urlProtocolDidFinishLoading(self)
        } else if start == 0 {
            Thread.sleep(forTimeInterval: 0.02)
            client?.urlProtocol(
                self,
                didFailWithError: NSError(
                    domain: NSURLErrorDomain,
                    code: URLError.networkConnectionLost.rawValue,
                    userInfo: [
                        NSURLSessionDownloadTaskResumeData: Self.resumeMarker,
                    ]
                )
            )
        } else {
            isStalledSegment = true
        }
    }

    override func stopLoading() {
        guard isStalledSegment else { return }
        Self.condition.withLock {
            Self.stalledSegmentStopped = true
            Self.condition.broadcast()
        }
    }
}

private final class SegmentFailureProtocol: URLProtocol {
    private static let condition = NSCondition()
    nonisolated(unsafe) private static var stalledSegmentStarted = false
    nonisolated(unsafe) private static var stalledSegmentStopped = false

    private var isStalledSegment = false

    static func reset() {
        condition.withLock {
            stalledSegmentStarted = false
            stalledSegmentStopped = false
        }
    }

    static func waitForStalledSegmentToStop() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(2)
        while !stalledSegmentStopped {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let range = request.value(forHTTPHeaderField: "Range") else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if range == "bytes=0-0" {
            send(range: range, body: Data([0x00]), etag: "\"original\"")
            return
        }
        if range == "bytes=0-1" {
            isStalledSegment = true
            Self.condition.withLock {
                Self.stalledSegmentStarted = true
                Self.condition.broadcast()
            }
            let response = rangeResponse(
                range: range,
                bodyCount: 2,
                etag: "\"original\""
            )
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data([0x00, 0x01]))
            return
        }

        Self.condition.lock()
        let deadline = Date().addingTimeInterval(2)
        while !Self.stalledSegmentStarted {
            guard Self.condition.wait(until: deadline) else {
                Self.condition.unlock()
                client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
                return
            }
        }
        Self.condition.unlock()
        send(range: range, body: Data([0x02, 0x03]), etag: "\"changed\"")
    }

    override func stopLoading() {
        guard isStalledSegment else { return }
        Self.condition.withLock {
            Self.stalledSegmentStopped = true
            Self.condition.broadcast()
        }
    }

    private func send(range: String, body: Data, etag: String) {
        let response = rangeResponse(
            range: range,
            bodyCount: body.count,
            etag: etag
        )
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func rangeResponse(
        range: String,
        bodyCount: Int,
        etag: String
    ) -> HTTPURLResponse {
        let bounds = range.dropFirst("bytes=".count).split(separator: "-")
        let start = Int(bounds[0])!
        let end = Int(bounds[1])!
        return HTTPURLResponse(
            url: request.url!,
            statusCode: 206,
            httpVersion: nil,
            headerFields: [
                "Accept-Ranges": "bytes",
                "Content-Range": "bytes \(start)-\(end)/4",
                "Content-Length": "\(bodyCount)",
                "ETag": etag,
            ]
        )!
    }
}

// Ensures the first request has started before cancellation, then holds the
// retry response until the first protocol instance stops. The cancelled task's
// completion can therefore collide with the registered retry before it ends.
private final class CancelThenRetryDownloadProtocol: URLProtocol {
    private static let condition = NSCondition()
    nonisolated(unsafe) private static var segmentRequestCount = 0
    nonisolated(unsafe) private static var firstRequestStopped = false

    private var requestNumber = 0

    static func reset() {
        condition.withLock {
            segmentRequestCount = 0
            firstRequestStopped = false
        }
    }

    static func waitForFirstRequestToStart() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(2)
        while segmentRequestCount == 0 {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let range = request.value(forHTTPHeaderField: "Range") else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if range == "bytes=0-0" {
            let body = Data([0x01])
            let response = rangeResponse(range: range, bodyCount: body.count)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        requestNumber = Self.condition.withLock {
            Self.segmentRequestCount += 1
            Self.condition.broadcast()
            return Self.segmentRequestCount
        }

        let body = Data([0x01, 0x02, 0x03, 0x04])
        let response = rangeResponse(range: range, bodyCount: body.count)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        if requestNumber == 1 {
            client?.urlProtocol(self, didLoad: Data([0x00]))
            return
        }

        Self.condition.lock()
        while !Self.firstRequestStopped {
            Self.condition.wait()
        }
        Self.condition.unlock()

        Thread.sleep(forTimeInterval: 0.1)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        guard requestNumber == 1 else { return }
        Thread.sleep(forTimeInterval: 0.1)
        Self.condition.withLock {
            Self.firstRequestStopped = true
            Self.condition.broadcast()
        }
    }

    private func rangeResponse(range: String, bodyCount: Int) -> HTTPURLResponse {
        let bounds = range.dropFirst("bytes=".count).split(separator: "-")
        let start = Int(bounds[0])!
        let end = Int(bounds[1])!
        return HTTPURLResponse(
            url: request.url!,
            statusCode: 206,
            httpVersion: nil,
            headerFields: [
                "Accept-Ranges": "bytes",
                "Content-Range": "bytes \(start)-\(end)/4",
                "Content-Length": "\(bodyCount)",
                "ETag": "\"retry\"",
            ]
        )!
    }
}

private final class StalledProbeProtocol: URLProtocol {
    private static let condition = NSCondition()
    nonisolated(unsafe) private static var probeStarted = false
    nonisolated(unsafe) private static var probeStopped = false

    static func reset() {
        condition.withLock {
            probeStarted = false
            probeStopped = false
        }
    }

    static func waitForProbeToStart() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(2)
        while !probeStarted {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    static func waitForProbeToStop() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(2)
        while !probeStopped {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.condition.withLock {
            Self.probeStarted = true
            Self.condition.broadcast()
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 206,
            httpVersion: nil,
            headerFields: [
                "Accept-Ranges": "bytes",
                "Content-Range": "bytes 0-0/4",
                "Content-Length": "1",
                "ETag": "\"stalled\"",
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data([0x01]))
        // A complete probe response body was delivered, but the request itself
        // remains genuinely stalled until URLSession cancels it.
    }

    override func stopLoading() {
        Self.condition.withLock {
            Self.probeStopped = true
            Self.condition.broadcast()
        }
    }
}

private final class OwnershipRaceProtocol: URLProtocol {
    private static let condition = NSCondition()
    nonisolated(unsafe) private static var retrySegmentStarted = false
    nonisolated(unsafe) private static var allowRetrySegment = false

    static func reset() {
        condition.withLock {
            retrySegmentStarted = false
            allowRetrySegment = false
        }
    }

    static func waitForRetrySegmentToStart() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(5)
        while !retrySegmentStarted {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    static func releaseRetrySegment() {
        condition.withLock {
            allowRetrySegment = true
            condition.broadcast()
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let range = request.value(forHTTPHeaderField: "Range") else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let isRetry = request.url!.lastPathComponent == "retry"
        let body: Data
        if range == "bytes=0-0" {
            body = Data([isRetry ? 0xB0 : 0xA0])
        } else {
            body = isRetry
                ? Data([0xB0, 0xB1, 0xB2, 0xB3])
                : Data([0xA0, 0xA1, 0xA2, 0xA3])
        }
        let bounds = range.dropFirst("bytes=".count).split(separator: "-")
        let start = Int(bounds[0])!
        let end = Int(bounds[1])!
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 206,
            httpVersion: nil,
            headerFields: [
                "Accept-Ranges": "bytes",
                "Content-Range": "bytes \(start)-\(end)/4",
                "Content-Length": "\(body.count)",
                "ETag": isRetry ? "\"retry\"" : "\"first\"",
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        if isRetry && range != "bytes=0-0" {
            Self.condition.lock()
            Self.retrySegmentStarted = true
            Self.condition.broadcast()
            while !Self.allowRetrySegment {
                Self.condition.wait()
            }
            Self.condition.unlock()
        }

        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class BlockingSegmentFileManager: FileManager, @unchecked Sendable {
    enum BlockPoint {
        case manifestDirectory
        case segmentMove
    }

    private let condition = NSCondition()
    private let cacheKey: String
    private let blockPoint: BlockPoint
    private var claimedBlock = false
    private var isBlocked = false
    private var released = false
    private var manifestDirectoryCalls = 0

    init(cacheKey: String, blockPoint: BlockPoint) {
        self.cacheKey = cacheKey
        self.blockPoint = blockPoint
        super.init()
    }

    func waitUntilBlocked() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(5)
        while !isBlocked {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func manifestDirectoryCallCount() -> Int {
        condition.withLock { manifestDirectoryCalls }
    }

    func releaseBlockedMutation() {
        condition.withLock {
            released = true
            condition.broadcast()
        }
    }

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        let isAttemptDirectory = url.lastPathComponent == cacheKey
            && url.deletingLastPathComponent().lastPathComponent == ".downloads"
        if isAttemptDirectory {
            condition.withLock {
                manifestDirectoryCalls += 1
                condition.broadcast()
            }
            blockIfNeeded(.manifestDirectory)
        }
        try super.createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: attributes
        )
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if dstURL.lastPathComponent == "segment-0.part",
           dstURL.deletingLastPathComponent().lastPathComponent == cacheKey {
            blockIfNeeded(.segmentMove)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }

    private func blockIfNeeded(_ point: BlockPoint) {
        condition.lock()
        defer { condition.unlock() }
        guard point == blockPoint, !claimedBlock else { return }
        claimedBlock = true
        isBlocked = true
        condition.broadcast()
        while !released {
            condition.wait()
        }
    }
}

private final class TrackingCancellationFence:
    CacheManagerCancellationFencing,
    @unchecked Sendable
{
    private let condition = NSCondition()
    private let blockedMutationCompletion: Int?
    private let pausesCancellationAfterRequest: Bool
    private var cancellationRequestCounts: [String: Int] = [:]
    private var mutationKeys: Set<String> = []
    private var observedRequests: Set<String> = []
    private var mutationCompletionCount = 0
    private var isBlockedAfterMutation = false
    private var releaseMutationCompletion = false
    private var releaseCancellation = false
    private var terminalClaimAttempted = false

    init(
        blockedMutationCompletion: Int? = nil,
        pausesCancellationAfterRequest: Bool = false
    ) {
        self.blockedMutationCompletion = blockedMutationCompletion
        self.pausesCancellationAfterRequest = pausesCancellationAfterRequest
    }

    func beginCancellation(cacheKey: String) {
        condition.lock()
        cancellationRequestCounts[cacheKey, default: 0] += 1
        observedRequests.insert(cacheKey)
        condition.broadcast()
        while mutationKeys.contains(cacheKey) {
            condition.wait()
        }
        while pausesCancellationAfterRequest, !releaseCancellation {
            condition.wait()
        }
        condition.unlock()
    }

    func endCancellation(cacheKey: String) {
        condition.withLock {
            let remaining = (cancellationRequestCounts[cacheKey] ?? 1) - 1
            cancellationRequestCounts[cacheKey] = remaining > 0 ? remaining : nil
        }
    }

    func isCancellationRequested(cacheKey: String) -> Bool {
        condition.withLock {
            (cancellationRequestCounts[cacheKey] ?? 0) > 0
        }
    }

    func performMutation(
        cacheKey: String,
        _ mutation: () throws -> Void
    ) throws {
        condition.lock()
        guard (cancellationRequestCounts[cacheKey] ?? 0) == 0 else {
            condition.unlock()
            throw CancellationError()
        }
        mutationKeys.insert(cacheKey)
        condition.unlock()

        let result = Result { try mutation() }

        condition.lock()
        mutationKeys.remove(cacheKey)
        let cancelled = (cancellationRequestCounts[cacheKey] ?? 0) > 0
        condition.broadcast()
        condition.unlock()

        if cancelled {
            throw CancellationError()
        }
        try result.get()

        condition.lock()
        mutationCompletionCount += 1
        if mutationCompletionCount == blockedMutationCompletion {
            isBlockedAfterMutation = true
            condition.broadcast()
            while !releaseMutationCompletion {
                condition.wait()
            }
        }
        condition.unlock()
    }

    func performTerminalClaim(
        cacheKey: String,
        _ claim: () -> Bool
    ) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        terminalClaimAttempted = true
        condition.broadcast()
        guard (cancellationRequestCounts[cacheKey] ?? 0) == 0 else {
            return false
        }
        return claim()
    }

    func waitForCancellationRequest(cacheKey: String) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(5)
        while !observedRequests.contains(cacheKey) {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func waitUntilBlockedAfterMutation() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(5)
        while !isBlockedAfterMutation {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func releaseBlockedMutationCompletion() {
        condition.withLock {
            releaseMutationCompletion = true
            condition.broadcast()
        }
    }

    func waitForTerminalClaimAttempt() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(1)
        while !terminalClaimAttempted {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func releasePausedCancellation() {
        condition.withLock {
            releaseCancellation = true
            condition.broadcast()
        }
    }
}

private func rangeDownloadConfig() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RangeDownloadProtocol.self]
    return config
}

private func hangingDownloadConfig() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [HangingDownloadProtocol.self]
    return config
}

private func hangingRangeConfig() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [HangingRangeProtocol.self]
    return config
}

private func segmentFailureConfig() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SegmentFailureProtocol.self]
    return config
}

private func resumableFailureConfig() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ResumableFailureProtocol.self]
    return config
}

private func cancelThenRetryDownloadConfig() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CancelThenRetryDownloadProtocol.self]
    return config
}

private func stalledProbeConfig() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StalledProbeProtocol.self]
    return config
}

private func ownershipRaceConfig() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [OwnershipRaceProtocol.self]
    return config
}

private func tempRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("cache-\(UUID().uuidString)")
}

@Suite(.serialized)
struct CacheManagerTests {

    @Test func localURLUsesIdAndMp4() {
        let manager = CacheManager(root: tempRoot(), configuration: rangeDownloadConfig())
        #expect(manager.localURL(for: 5).lastPathComponent == "5.mp4")
    }

    @Test func stateIsNotCachedThenCachedAfterDownload() async throws {
        let root = tempRoot()
        let manager = CacheManager(root: root, configuration: rangeDownloadConfig())
        #expect(manager.state(for: 11) == .notCached)

        RangeDownloadProtocol.reset(payload: Data([0x00, 0x01, 0x02, 0x03]))
        try await manager.download(id: 11, from: URL(string: "https://srv.test/videos/11/stream")!)

        #expect(manager.state(for: 11) == .cached)
        let saved = try Data(contentsOf: manager.localURL(for: 11))
        #expect(saved == Data([0x00, 0x01, 0x02, 0x03]))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("11.resume").path))
    }

    @Test func downloadAlsoCachesPreview() async throws {
        let root = tempRoot()
        let manager = CacheManager(root: root, configuration: rangeDownloadConfig())
        #expect(manager.cachedPreviewURL(for: 12) == nil)

        RangeDownloadProtocol.reset(payload: Data([0x00, 0x01]))
        try await manager.download(
            id: 12,
            from: URL(string: "https://srv.test/videos/12/stream")!,
            preview: URL(string: "https://img.test/thumb.jpg")!
        )

        let previewURL = try #require(manager.cachedPreviewURL(for: 12))
        #expect(previewURL.pathExtension == "jpg")
        #expect(try Data(contentsOf: previewURL) == Data([0xAA, 0xBB]))
    }

    @Test func previewStoreAndLookupUsesMovieID() throws {
        let manager = CacheManager(root: tempRoot(), configuration: rangeDownloadConfig())
        #expect(manager.cachedPreviewURL(for: 44) == nil)

        manager.storePreview(Data([0xAA, 0xBB]), for: 44,
                             path: "/videos/44/preview.jpg")

        let url = try #require(manager.cachedPreviewURL(for: 44))
        #expect(url.lastPathComponent == "44.preview.jpg")
        #expect(try Data(contentsOf: url) == Data([0xAA, 0xBB]))
        #expect(manager.cachedPreviewURL(for: 45) == nil)
    }

    @Test func previewFailureStillCachesVideo() async throws {
        let root = tempRoot()
        let manager = CacheManager(root: root, configuration: rangeDownloadConfig())
        RangeDownloadProtocol.reset(payload: Data([0x09]))
        RangeDownloadProtocol.responseOverride = { req in
            if req.url!.host == "img.test" { throw URLError(.timedOut) }
            return try RangeDownloadProtocol.response(for: req)
        }
        try await manager.download(
            id: 13,
            from: URL(string: "https://srv.test/videos/13/stream")!,
            preview: URL(string: "https://img.test/thumb.jpg")!
        )
        #expect(manager.state(for: 13) == .cached)
        #expect(manager.cachedPreviewURL(for: 13) == nil)
    }

    @Test func downloadThrowsOnBadStatus() async {
        let manager = CacheManager(root: tempRoot(), configuration: rangeDownloadConfig())
        RangeDownloadProtocol.reset()
        RangeDownloadProtocol.responseOverride = {
            (jsonResponse($0.url!, status: 404), Data())
        }
        await #expect(throws: APIError.badStatus(404)) {
            try await manager.download(id: 1, from: URL(string: "https://srv.test/x")!)
        }
    }

    @Test func cancelThrowsAndReturnsToNotCached() async {
        let root = tempRoot()
        let manager = CacheManager(root: root, configuration: hangingRangeConfig())

        let task = Task {
            try await manager.download(id: 21, from: URL(string: "https://srv.test/videos/21/stream")!)
        }

        // Let the download start and register as in-flight before cancelling.
        while manager.state(for: 21) == .notCached { await Task.yield() }

        manager.cancel(id: 21)

        await #expect(throws: Error.self) { try await task.value }
        #expect(manager.state(for: 21) == .notCached)
        #expect(!FileManager.default.fileExists(atPath: manager.localURL(for: 21).path))
    }

    @Test func explicitCancelRemovesSegmentedScratchAndRetryStartsFresh() async {
        let root = tempRoot()
        let manager = CacheManager(root: root, configuration: hangingRangeConfig())
        let task = Task {
            try await manager.download(
                id: 63,
                from: URL(string: "https://srv.test/videos/63/stream")!,
                streamCount: 3
            )
        }
        while manager.state(for: 63) == .notCached { await Task.yield() }

        manager.cancel(id: 63)

        await #expect(throws: Error.self) { try await task.value }
        #expect(manager.state(for: 63) == .notCached)
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".downloads/63").path
        ))
    }

    @Test func cancelThenImmediateSameKeyRetryCompletesIndependently() async throws {
        CancelThenRetryDownloadProtocol.reset()
        let root = tempRoot()
        let manager = CacheManager(root: root, configuration: cancelThenRetryDownloadConfig())
        let remote = URL(string: "https://srv.test/videos/22/stream")!

        let first = Task {
            try await manager.download(id: 22, versionId: 3, from: remote)
        }
        while manager.state(for: 22, versionId: 3) == .notCached { await Task.yield() }
        guard CancelThenRetryDownloadProtocol.waitForFirstRequestToStart() else {
            Issue.record("The first download never reached the URL protocol")
            return
        }

        manager.cancel(id: 22, versionId: 3)
        let retry = Task {
            try await manager.download(id: 22, versionId: 3, from: remote)
        }

        try await retry.value
        await #expect(throws: Error.self) { try await first.value }
        #expect(manager.state(for: 22, versionId: 3) == .cached)
        #expect(try Data(contentsOf: manager.localURL(for: 22, versionId: 3))
                == Data([0x01, 0x02, 0x03, 0x04]))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("22:3.resume").path
        ))
    }

    @Test func cancelPromptlyFinishesDownloadAwaitingStalledFreshProbe() async {
        StalledProbeProtocol.reset()
        let manager = CacheManager(root: tempRoot(), configuration: stalledProbeConfig())
        let download = Task {
            try await manager.download(
                id: 23,
                from: URL(string: "https://srv.test/videos/23/stalled")!
            )
        }
        guard StalledProbeProtocol.waitForProbeToStart() else {
            Issue.record("The stalled probe never started")
            manager.cancel(id: 23)
            return
        }

        manager.cancel(id: 23)

        let finishedPromptly = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try await download.value
                    return false
                } catch is CancellationError {
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(200))
                return false
            }
            let result = await group.next() ?? false
            if !result {
                download.cancel()
            }
            group.cancelAll()
            while await group.next() != nil {}
            return result
        }

        #expect(finishedPromptly)
        #expect(StalledProbeProtocol.waitForProbeToStop())
        #expect(manager.state(for: 23) == .notCached)
    }

    @Test func cancelledProbeCannotOverwriteImmediateRetryManifest() async throws {
        OwnershipRaceProtocol.reset()
        let root = tempRoot()
        let fileManager = BlockingSegmentFileManager(
            cacheKey: "24",
            blockPoint: .manifestDirectory
        )
        let cancellationFence = TrackingCancellationFence()
        let manager = CacheManager(
            root: root,
            configuration: ownershipRaceConfig(),
            fileManager: fileManager,
            cancellationFence: cancellationFence
        )
        defer {
            fileManager.releaseBlockedMutation()
            OwnershipRaceProtocol.releaseRetrySegment()
        }
        let first = Task {
            try await manager.download(
                id: 24,
                from: URL(string: "https://srv.test/videos/24/first")!
            )
        }
        guard fileManager.waitUntilBlocked() else {
            Issue.record("The first manifest write never reached its mutation window")
            manager.cancel(id: 24)
            return
        }

        let retry = Task {
            manager.cancel(id: 24)
            return try await manager.download(
                id: 24,
                from: URL(string: "https://srv.test/videos/24/retry")!
            )
        }
        guard cancellationFence.waitForCancellationRequest(cacheKey: "24") else {
            Issue.record("Cancellation never reached the scratch-mutation fence")
            return
        }
        #expect(fileManager.manifestDirectoryCallCount() == 1)
        fileManager.releaseBlockedMutation()

        await #expect(throws: CancellationError.self) { try await first.value }
        guard OwnershipRaceProtocol.waitForRetrySegmentToStart() else {
            Issue.record("The retry segment never started")
            retry.cancel()
            return
        }
        let manifest = try SegmentedDownloadStore(root: root).load(cacheKey: "24")
        #expect(manifest.remoteURL.lastPathComponent == "retry")
        #expect(manifest.etag == "\"retry\"")

        OwnershipRaceProtocol.releaseRetrySegment()
        try await retry.value
        #expect(try Data(contentsOf: manager.localURL(for: 24))
                == Data([0xB0, 0xB1, 0xB2, 0xB3]))
    }

    @Test func cancelledSegmentCannotRecreateImmediateRetryScratch() async throws {
        OwnershipRaceProtocol.reset()
        let root = tempRoot()
        let fileManager = BlockingSegmentFileManager(
            cacheKey: "25",
            blockPoint: .segmentMove
        )
        let cancellationFence = TrackingCancellationFence(
            pausesCancellationAfterRequest: true
        )
        let manager = CacheManager(
            root: root,
            configuration: ownershipRaceConfig(),
            fileManager: fileManager,
            cancellationFence: cancellationFence
        )
        defer {
            fileManager.releaseBlockedMutation()
            cancellationFence.releasePausedCancellation()
            OwnershipRaceProtocol.releaseRetrySegment()
        }
        let first = Task {
            try await manager.download(
                id: 25,
                from: URL(string: "https://srv.test/videos/25/first")!
            )
        }
        guard fileManager.waitUntilBlocked() else {
            Issue.record("The first segment never reached its filesystem mutation window")
            manager.cancel(id: 25)
            return
        }

        let retry = Task {
            manager.cancel(id: 25)
            return try await manager.download(
                id: 25,
                from: URL(string: "https://srv.test/videos/25/retry")!
            )
        }
        guard cancellationFence.waitForCancellationRequest(cacheKey: "25") else {
            Issue.record("Cancellation never reached the scratch-mutation fence")
            return
        }
        #expect(fileManager.manifestDirectoryCallCount() == 1)
        fileManager.releaseBlockedMutation()

        let terminalFailureWasOrdered =
            cancellationFence.waitForTerminalClaimAttempt()
        cancellationFence.releasePausedCancellation()

        #expect(
            terminalFailureWasOrdered,
            "Segment failure bypassed cancellation ordering"
        )
        await #expect(throws: CancellationError.self) { try await first.value }
        guard OwnershipRaceProtocol.waitForRetrySegmentToStart() else {
            Issue.record("The retry segment never started")
            retry.cancel()
            return
        }
        #expect(!FileManager.default.fileExists(
            atPath: root
                .appendingPathComponent(".downloads/25/segment-0.part")
                .path
        ))

        OwnershipRaceProtocol.releaseRetrySegment()
        try await retry.value
        #expect(try Data(contentsOf: manager.localURL(for: 25))
            == Data([0xB0, 0xB1, 0xB2, 0xB3]))
    }

    @Test func cancelAfterFinalMutationWinsBeforeTerminalClaim() async throws {
        OwnershipRaceProtocol.reset()
        let root = tempRoot()
        let cancellationFence = TrackingCancellationFence(
            blockedMutationCompletion: 3,
            pausesCancellationAfterRequest: true
        )
        let manager = CacheManager(
            root: root,
            configuration: ownershipRaceConfig(),
            fileManager: .default,
            cancellationFence: cancellationFence
        )
        defer {
            cancellationFence.releaseBlockedMutationCompletion()
            cancellationFence.releasePausedCancellation()
            OwnershipRaceProtocol.releaseRetrySegment()
        }

        let first = Task {
            try await manager.download(
                id: 26,
                from: URL(string: "https://srv.test/videos/26/first")!
            )
        }
        guard cancellationFence.waitUntilBlockedAfterMutation() else {
            Issue.record("The first attempt never reached the post-mutation window")
            manager.cancel(id: 26)
            return
        }

        let retry = Task {
            manager.cancel(id: 26)
            return try await manager.download(
                id: 26,
                from: URL(string: "https://srv.test/videos/26/retry")!
            )
        }
        guard cancellationFence.waitForCancellationRequest(cacheKey: "26") else {
            Issue.record("Cancellation intent was not recorded")
            return
        }

        cancellationFence.releaseBlockedMutationCompletion()
        let terminalClaimWasOrdered =
            cancellationFence.waitForTerminalClaimAttempt()
        cancellationFence.releasePausedCancellation()

        #expect(terminalClaimWasOrdered)
        await #expect(throws: CancellationError.self) { try await first.value }
        guard OwnershipRaceProtocol.waitForRetrySegmentToStart() else {
            Issue.record("The retry segment never started")
            retry.cancel()
            return
        }
        #expect(!FileManager.default.fileExists(
            atPath: manager.localURL(for: 26).path
        ))
        let manifest = try SegmentedDownloadStore(root: root).load(cacheKey: "26")
        #expect(manifest.remoteURL.lastPathComponent == "retry")
        #expect(manifest.etag == "\"retry\"")

        OwnershipRaceProtocol.releaseRetrySegment()
        try await retry.value
        #expect(try Data(contentsOf: manager.localURL(for: 26))
            == Data([0xB0, 0xB1, 0xB2, 0xB3]))
    }

    @Test func testDownloadSendsBearerToken() async throws {
        RangeDownloadProtocol.reset(payload: Data("video".utf8))
        let root = tempRoot()
        let manager = CacheManager(root: root, configuration: rangeDownloadConfig())
        try await manager.download(id: 7,
                                   from: URL(string: "https://example.test/videos/7/stream")!,
                                   preview: URL(string: "https://example.test/videos/7/preview")!,
                                   bearerToken: "secret")
        let requests = RangeDownloadProtocol.recordedRequests()
        #expect(requests.count == 3)
        #expect(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer secret"
        })
    }

    @Test func fourStreamsSendExactRangesAndAssembleOriginalBytes() async throws {
        let payload = Data((0..<23).map { UInt8($0) })
        RangeDownloadProtocol.reset(payload: payload)
        RangeDownloadProtocol.setDelays([
            "bytes=0-4": 0.04,
            "bytes=5-10": 0.03,
            "bytes=11-16": 0.02,
            "bytes=17-22": 0.01,
        ])
        let root = tempRoot()
        let manager = CacheManager(root: root, configuration: rangeDownloadConfig())

        try await manager.download(
            id: 50,
            from: URL(string: "https://srv.test/videos/50/stream")!,
            bearerToken: "secret",
            streamCount: 4
        )

        let requests = RangeDownloadProtocol.recordedRequests()
        let ranges = requests.compactMap {
            $0.value(forHTTPHeaderField: "Range")
        }
        #expect(ranges.first == "bytes=0-0")
        #expect(Set(ranges.dropFirst()) == Set([
            "bytes=0-4",
            "bytes=5-10",
            "bytes=11-16",
            "bytes=17-22",
        ]))
        let segmentRequests = requests.dropFirst()
        #expect(segmentRequests.allSatisfy {
            $0.value(forHTTPHeaderField: "If-Range") == "\"test-video\""
        })
        #expect(segmentRequests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer secret"
        })
        #expect(try Data(contentsOf: manager.localURL(for: 50)) == payload)
        #expect(manager.state(for: 50) == .cached)
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".downloads/50").path
        ))
    }

    @Test func rejectsServerThatIgnoresRangesWithoutPublishingAFile() async {
        RangeDownloadProtocol.reset()
        RangeDownloadProtocol.responseOverride = { request in
            let data = Data("full body".utf8)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Length": "\(data.count)"]
                )!,
                data
            )
        }
        let manager = CacheManager(root: tempRoot(), configuration: rangeDownloadConfig())

        await #expect(throws: SegmentedDownloadError.invalidProbe) {
            try await manager.download(
                id: 51,
                from: URL(string: "https://srv.test/videos/51/stream")!,
                streamCount: 2
            )
        }
        #expect(manager.state(for: 51) == .notCached)
        #expect(!FileManager.default.fileExists(atPath: manager.localURL(for: 51).path))
    }

    @Test func segmentFailurePreservesErrorCancelsSiblingAndRemovesScratch() async {
        SegmentFailureProtocol.reset()
        let root = tempRoot()
        let manager = CacheManager(root: root, configuration: segmentFailureConfig())

        await #expect(throws: SegmentedDownloadError.changedEntity) {
            try await manager.download(
                id: 52,
                from: URL(string: "https://srv.test/videos/52/stream")!,
                streamCount: 2
            )
        }

        #expect(SegmentFailureProtocol.waitForStalledSegmentToStop())
        #expect(manager.state(for: 52) == .notCached)
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".downloads/52").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: manager.localURL(for: 52).path
        ))
    }

    @Test func transportFailurePreservesManifestAndResumeDataAfterSiblingsStop() async throws {
        ResumableFailureProtocol.reset()
        let root = tempRoot()
        let manager = CacheManager(root: root, configuration: resumableFailureConfig())

        await #expect(throws: Error.self) {
            try await manager.download(
                id: 65,
                from: URL(string: "https://srv.test/videos/65/stream")!,
                streamCount: 2
            )
        }

        #expect(ResumableFailureProtocol.waitForStalledSegmentToStop())
        let store = SegmentedDownloadStore(root: root)
        let manifest = try store.load(cacheKey: "65")
        #expect(!manifest.segments[0].isComplete)
        #expect(try Data(contentsOf: store.resumeURL(cacheKey: "65", index: 0))
                == ResumableFailureProtocol.resumeMarker)
        #expect(manager.state(for: 65) == .notCached)
        #expect(!FileManager.default.fileExists(
            atPath: manager.localURL(for: 65).path
        ))
    }

    @Test func removeCachedDeletesOnlyRequestedVersion() throws {
        let root = tempRoot()
        let manager = CacheManager(root: root, configuration: rangeDownloadConfig())
        let base = manager.localURL(for: 7)
        let version = manager.localURL(for: 7, versionId: 2)
        try Data([0x01]).write(to: base)
        try Data([0x02]).write(to: version)

        manager.removeCached(id: 7, versionId: 2)

        #expect(FileManager.default.fileExists(atPath: base.path))
        #expect(!FileManager.default.fileExists(atPath: version.path))
    }

    @Test func hasAnyCachedFindsBaseAndVersionedFiles() throws {
        let root = tempRoot()
        let manager = CacheManager(root: root, configuration: rangeDownloadConfig())
        #expect(manager.hasAnyCached(id: 21) == false)

        try Data([0x01]).write(to: root.appendingPathComponent("21.v3.mp4"))
        #expect(manager.hasAnyCached(id: 21))

        try Data([0x01]).write(to: root.appendingPathComponent("2.mp4"))
        #expect(manager.hasAnyCached(id: 2))
        // id 2 must not match 21.v3.mp4; id 1 must not match either file.
        #expect(manager.hasAnyCached(id: 1) == false)
    }

    @Test func hasAnyCachedIgnoresPreviewFiles() throws {
        let root = tempRoot()
        let manager = CacheManager(root: root, configuration: rangeDownloadConfig())
        try Data([0x01]).write(to: root.appendingPathComponent("22.preview.jpg"))
        #expect(manager.hasAnyCached(id: 22) == false)
    }

    @Test func removeAllCachedDeletesVideosAndResumeDataKeepsPreviews() throws {
        let root = tempRoot()
        let manager = CacheManager(root: root, configuration: rangeDownloadConfig())
        let keep = ["23.preview.jpg", "poster.abc123.jpg", "24.mp4", "24:1.resume"]
        let remove = ["23.mp4", "23.v1.mp4", "23.v12.mp4", "23.resume", "23:4.resume"]
        for name in keep + remove {
            try Data([0x01]).write(to: root.appendingPathComponent(name))
        }
        let store = SegmentedDownloadStore(root: root)
        for versionId in [nil, 4] as [Int?] {
            let manifest = try SegmentedDownloadManifest.make(
                videoId: 23,
                versionId: versionId,
                remoteURL: URL(string: "https://srv.test/videos/23/stream")!,
                requestedStreamCount: 2,
                totalByteCount: 4,
                etag: "\"remove\""
            )
            try store.write(manifest)
        }
        let keptManifest = try SegmentedDownloadManifest.make(
            videoId: 24,
            versionId: 1,
            remoteURL: URL(string: "https://srv.test/videos/24/stream")!,
            requestedStreamCount: 2,
            totalByteCount: 4,
            etag: "\"keep\""
        )
        try store.write(keptManifest)

        manager.removeAllCached(id: 23)

        for name in remove {
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path),
                    "should have deleted \(name)")
        }
        for name in keep {
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path),
                    "should have kept \(name)")
        }
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".downloads/23").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".downloads/23:4").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".downloads/24:1").path
        ))
        #expect(manager.state(for: 23) == .notCached)
    }

    @Test func resumeInterruptedRequestsOnlyIncompleteManifestSegments() async throws {
        let payload = Data("abcdefghijkl".utf8)
        RangeDownloadProtocol.reset(payload: payload)
        let root = tempRoot()
        let store = SegmentedDownloadStore(root: root)
        var manifest = try SegmentedDownloadManifest.make(
            videoId: 62,
            versionId: nil,
            remoteURL: URL(string: "https://srv.test/videos/62/stream")!,
            requestedStreamCount: 3,
            totalByteCount: 12,
            etag: "\"test-video\""
        )
        manifest.segments[0].isComplete = true
        manifest.segments[0].persistedByteCount = 4
        try store.write(manifest)
        try payload.subdata(in: 0..<4).write(
            to: store.partURL(cacheKey: "62", index: 0)
        )
        try store.write(manifest)
        let manager = CacheManager(root: root, configuration: rangeDownloadConfig())

        #expect(manager.resumeInterrupted(bearerToken: "secret") == [62])

        for _ in 0..<500 where manager.state(for: 62) != .cached {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(manager.state(for: 62) == .cached)
        let ranges = RangeDownloadProtocol.recordedRequests().compactMap {
            $0.value(forHTTPHeaderField: "Range")
        }
        #expect(!ranges.contains("bytes=0-3"))
        #expect(Set(ranges) == Set(["bytes=4-7", "bytes=8-11"]))
        let requests = RangeDownloadProtocol.recordedRequests()
        #expect(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer secret"
        })
        #expect(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "If-Range") == "\"test-video\""
        })
        #expect(try Data(contentsOf: manager.localURL(for: 62)) == payload)
    }

    @Test func downloadResumesStoredManifestUsingOriginalRanges() async throws {
        let payload = Data("abcdefghijkl".utf8)
        RangeDownloadProtocol.reset(payload: payload)
        let root = tempRoot()
        let store = SegmentedDownloadStore(root: root)
        var manifest = try SegmentedDownloadManifest.make(
            videoId: 64,
            versionId: nil,
            remoteURL: URL(string: "https://srv.test/videos/64/original")!,
            requestedStreamCount: 3,
            totalByteCount: 12,
            etag: "\"test-video\""
        )
        manifest.segments[0].isComplete = true
        manifest.segments[0].persistedByteCount = 4
        try store.write(manifest)
        try payload.subdata(in: 0..<4).write(
            to: store.partURL(cacheKey: "64", index: 0)
        )
        try store.write(manifest)
        let manager = CacheManager(root: root, configuration: rangeDownloadConfig())

        try await manager.download(
            id: 64,
            from: URL(string: "https://srv.test/videos/64/new")!,
            streamCount: 1
        )

        let requests = RangeDownloadProtocol.recordedRequests()
        let ranges = requests.compactMap {
            $0.value(forHTTPHeaderField: "Range")
        }
        #expect(Set(ranges) == Set(["bytes=4-7", "bytes=8-11"]))
        #expect(requests.allSatisfy {
            $0.url?.lastPathComponent == "original"
        })
        #expect(try Data(contentsOf: manager.localURL(for: 64)) == payload)
    }

    @Test func resumeInterruptedRestartsPendingResumeFiles() {
        let root = tempRoot()
        let manager = CacheManager(root: root, configuration: hangingDownloadConfig())
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? Data([0xFF, 0xEE]).write(to: root.appendingPathComponent("31.resume"))
        try? Data([0xFF, 0xEE]).write(to: root.appendingPathComponent("32:4.resume"))

        let resumed = Set(manager.resumeInterrupted())

        #expect(resumed == [31, 32])
        #expect(manager.state(for: 31) == .downloading(0))
        #expect(manager.state(for: 32, versionId: 4) == .downloading(0))

        manager.cancel(id: 31)
        manager.cancel(id: 32, versionId: 4)
    }

    @Test func resumeInterruptedDropsStaleResumeWhenAlreadyCached() {
        let root = tempRoot()
        let manager = CacheManager(root: root, configuration: rangeDownloadConfig())
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? Data([0x01]).write(to: root.appendingPathComponent("33.mp4"))
        try? Data([0xFF]).write(to: root.appendingPathComponent("33.resume"))

        let resumed = manager.resumeInterrupted()

        #expect(resumed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("33.resume").path))
        #expect(manager.state(for: 33) == .cached)
    }

    @Test func resumeInterruptedSkipsLiveInFlightTask() async {
        let root = tempRoot()
        let manager = CacheManager(root: root, configuration: hangingRangeConfig())
        let task = Task {
            try await manager.download(id: 34, from: URL(string: "https://srv.test/videos/34/stream")!)
        }
        while manager.state(for: 34) == .notCached { await Task.yield() }
        // A stale resume file for the same key must not spawn a second task.
        try? Data([0xFF]).write(to: root.appendingPathComponent("34.resume"))

        #expect(manager.resumeInterrupted().isEmpty)

        manager.cancel(id: 34)
        _ = try? await task.value
    }

    @Test func showPosterStoreAndLookup() throws {
        let manager = CacheManager(root: tempRoot(), configuration: rangeDownloadConfig())
        let key = "/library/shows/bluey/poster.png"
        #expect(manager.cachedShowPosterURL(for: key) == nil)

        manager.storeShowPoster(Data([0x01, 0x02]), for: key)

        let url = try #require(manager.cachedShowPosterURL(for: key))
        #expect(url.pathExtension == "png")
        #expect(try Data(contentsOf: url) == Data([0x01, 0x02]))
        // A different key must not resolve to this poster.
        #expect(manager.cachedShowPosterURL(for: "/other/poster.png") == nil)
    }

    @Test func showPosterStoreAndLookupUsesShowID() throws {
        let manager = CacheManager(root: tempRoot(), configuration: rangeDownloadConfig())
        manager.storeShowPoster(Data([0x01]), for: "Bluey")

        let url = try #require(manager.cachedShowPosterURL(for: "Bluey"))
        #expect(try Data(contentsOf: url) == Data([0x01]))
        #expect(manager.cachedShowPosterURL(for: "Other Show") == nil)
    }

    @Test func showPosterKeyIsStableAndExtSanitized() throws {
        let root = tempRoot()
        let manager = CacheManager(root: root, configuration: rangeDownloadConfig())
        let key = "https://img.test/poster?size=big"
        manager.storeShowPoster(Data([0xAA]), for: key)
        manager.storeShowPoster(Data([0xBB]), for: key)

        let url = try #require(manager.cachedShowPosterURL(for: key))
        #expect(url.pathExtension == "jpg")
        #expect(try Data(contentsOf: url) == Data([0xBB]))
        let posters = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("poster.") }
        #expect(posters.count == 1)
    }

    @Test func downloadAlsoCachesShowPoster() async throws {
        let manager = CacheManager(root: tempRoot(), configuration: rangeDownloadConfig())
        RangeDownloadProtocol.reset(payload: Data([0x00]))
        RangeDownloadProtocol.responseOverride = { req in
            if req.url!.host == "img.test" {
                return (jsonResponse(req.url!), Data([0xCC]))
            }
            return try RangeDownloadProtocol.response(for: req)
        }
        try await manager.download(
            id: 31,
            from: URL(string: "https://srv.test/videos/31/stream")!,
            showPosterKey: "/library/shows/bluey/poster.jpg",
            showPoster: URL(string: "https://img.test/poster.jpg")!
        )
        let url = try #require(manager.cachedShowPosterURL(for: "/library/shows/bluey/poster.jpg"))
        #expect(try Data(contentsOf: url) == Data([0xCC]))
    }

    @Test func showPosterFailureStillCachesVideo() async throws {
        let manager = CacheManager(root: tempRoot(), configuration: rangeDownloadConfig())
        RangeDownloadProtocol.reset(payload: Data([0x09]))
        RangeDownloadProtocol.responseOverride = { req in
            if req.url!.host == "img.test" { throw URLError(.timedOut) }
            return try RangeDownloadProtocol.response(for: req)
        }
        try await manager.download(
            id: 32,
            from: URL(string: "https://srv.test/videos/32/stream")!,
            showPosterKey: "k",
            showPoster: URL(string: "https://img.test/poster.jpg")!
        )
        #expect(manager.state(for: 32) == .cached)
        #expect(manager.cachedShowPosterURL(for: "k") == nil)
    }

    @Test func downloadSkipsPosterFetchWhenAlreadyCached() async throws {
        let manager = CacheManager(root: tempRoot(), configuration: rangeDownloadConfig())
        manager.storeShowPoster(Data([0x01]), for: "k2")
        var posterRequests = 0
        RangeDownloadProtocol.reset(payload: Data([0x00]))
        RangeDownloadProtocol.responseOverride = { req in
            if req.url!.host == "img.test" { posterRequests += 1 }
            return try RangeDownloadProtocol.response(for: req)
        }
        try await manager.download(
            id: 33,
            from: URL(string: "https://srv.test/videos/33/stream")!,
            showPosterKey: "k2",
            showPoster: URL(string: "https://img.test/poster.jpg")!
        )
        #expect(posterRequests == 0)
        let url = try #require(manager.cachedShowPosterURL(for: "k2"))
        #expect(try Data(contentsOf: url) == Data([0x01]))
    }
}
