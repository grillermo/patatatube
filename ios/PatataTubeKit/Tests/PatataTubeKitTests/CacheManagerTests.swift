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

private func cancelThenRetryDownloadConfig() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CancelThenRetryDownloadProtocol.self]
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

        manager.removeAllCached(id: 23)

        for name in remove {
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path),
                    "should have deleted \(name)")
        }
        for name in keep {
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path),
                    "should have kept \(name)")
        }
        #expect(manager.state(for: 23) == .notCached)
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
