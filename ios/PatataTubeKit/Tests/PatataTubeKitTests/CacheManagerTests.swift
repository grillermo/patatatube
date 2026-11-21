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
                    url: request.url ?? URL(string: "https://resumed.invalid/")!,
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

private func rangeDownloadConfig() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RangeDownloadProtocol.self]
    return config
}

private func hangingRangeConfig() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [HangingRangeProtocol.self]
    return config
}

// Fails the first request for the 0-3 segment with a transport error, then
// serves it correctly. Every other range succeeds on the first try. Models a
// single transient network blip on one of several parallel segments.
private final class SegmentBlipThenSucceedProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var attemptsByRange: [String: Int] = [:]

    static let total = 8

    static func reset() {
        lock.withLock { attemptsByRange = [:] }
    }

    static func attempts(forRange range: String) -> Int {
        lock.withLock { attemptsByRange[range] ?? 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let range = request.value(forHTTPHeaderField: "Range"),
              range.hasPrefix("bytes=")
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let bounds = range.dropFirst("bytes=".count).split(separator: "-")
        guard bounds.count == 2,
              let start = Int(bounds[0]),
              let end = Int(bounds[1])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let attempt = Self.lock.withLock { () -> Int in
            let next = (Self.attemptsByRange[range] ?? 0) + 1
            Self.attemptsByRange[range] = next
            return next
        }
        let body = Data((start...end).map { UInt8($0) })
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 206,
            httpVersion: nil,
            headerFields: [
                "Accept-Ranges": "bytes",
                "Content-Range": "bytes \(start)-\(end)/\(Self.total)",
                "Content-Length": "\(body.count)",
                "ETag": "\"blip\"",
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if range == "bytes=0-3" && attempt == 1 {
            client?.urlProtocol(self, didLoad: body.prefix(1))
            client?.urlProtocol(self, didFailWithError: NSError(
                domain: NSURLErrorDomain,
                code: URLError.networkConnectionLost.rawValue
            ))
            return
        }
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func segmentBlipConfig() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SegmentBlipThenSucceedProtocol.self]
    return config
}

private func tempRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("cache-\(UUID().uuidString)")
}

@Suite(.serialized)
struct CacheManagerTests {
    private func splittingManager(root: URL, configuration: URLSessionConfiguration) -> CacheManager {
        CacheManager(root: root, configuration: configuration, fileManager: .default,
                     fetchTuning: DownloadTuning(minPiece: 1))
    }

    @Test func localURLUsesIdAndMp4() {
        let manager = CacheManager(root: tempRoot(), configuration: rangeDownloadConfig())
        #expect(manager.localURL(for: 5).lastPathComponent == "5.mp4")
        #expect(manager.localURL(for: 5, versionId: 2).lastPathComponent == "5.v2.mp4")
    }

    @Test func stateIsNotCachedThenCachedAfterDownload() async throws {
        let root = tempRoot()
        let manager = CacheManager(root: root, configuration: rangeDownloadConfig())
        #expect(manager.state(for: 11) == .notCached)
        RangeDownloadProtocol.reset(payload: Data([0x00, 0x01, 0x02, 0x03]))
        try await manager.download(id: 11, from: URL(string: "https://srv.test/videos/11/stream")!)
        #expect(manager.state(for: 11) == .cached)
        #expect(try Data(contentsOf: manager.localURL(for: 11)) == Data([0x00, 0x01, 0x02, 0x03]))
        await manager.settleStoreWork()
        #expect(await manager.mediaStore.manifest(key: "11") == nil, "promotion removes the entry")
        #expect(manager.recentDownloads().map(\.videoID) == [11])
    }

    @Test func downloadAlsoCachesPreview() async throws {
        let manager = CacheManager(root: tempRoot(), configuration: rangeDownloadConfig())
        #expect(manager.cachedPreviewURL(for: 12, path: "https://img.test/thumb.jpg") == nil)
        RangeDownloadProtocol.reset(payload: Data([0x00, 0x01]))
        try await manager.download(
            id: 12,
            from: URL(string: "https://srv.test/videos/12/stream")!,
            preview: URL(string: "https://img.test/thumb.jpg")!
        )
        let previewURL = try #require(manager.cachedPreviewURL(for: 12, path: "https://img.test/thumb.jpg"))
        #expect(previewURL.pathExtension == "jpg")
        #expect(try Data(contentsOf: previewURL) == Data([0xAA, 0xBB]))
    }

    @Test func previewStoreAndLookupUsesMovieID() throws {
        let manager = CacheManager(root: tempRoot(), configuration: rangeDownloadConfig())
        #expect(manager.cachedPreviewURL(for: 44, path: "/videos/44/preview.jpg") == nil)
        manager.storePreview(Data([0xAA, 0xBB]), for: 44, path: "/videos/44/preview.jpg")
        let url = try #require(manager.cachedPreviewURL(for: 44, path: "/videos/44/preview.jpg"))
        #expect(try Data(contentsOf: url) == Data([0xAA, 0xBB]))
        #expect(manager.cachedPreviewURL(for: 45, path: "/videos/44/preview.jpg") == nil)
    }

    @Test func previewFailureStillCachesVideo() async throws {
        let manager = CacheManager(root: tempRoot(), configuration: rangeDownloadConfig())
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
        #expect(manager.cachedPreviewURL(for: 13, path: "https://img.test/thumb.jpg") == nil)
    }

    @Test func aClientErrorFailsTheDownloadAndUnpinsIt() async throws {
        let manager = CacheManager(root: tempRoot(), configuration: rangeDownloadConfig())
        RangeDownloadProtocol.reset()
        RangeDownloadProtocol.responseOverride = { (jsonResponse($0.url!, status: 404), Data()) }
        await #expect(throws: APIError.badStatus(404)) {
            try await manager.download(id: 1, from: URL(string: "https://srv.test/x")!)
        }
        await manager.settleStoreWork()
        #expect(await manager.mediaStore.manifest(key: "1") == nil)
        #expect(manager.resumeInterrupted() == [])
    }

    @Test func cancelThrowsAndReturnsToNotCached() async {
        let manager = CacheManager(root: tempRoot(), configuration: hangingRangeConfig())
        let task = Task {
            try await manager.download(id: 21, from: URL(string: "https://srv.test/videos/21/stream")!)
        }
        while manager.state(for: 21) == .notCached { await Task.yield() }
        manager.cancel(id: 21)
        await #expect(throws: Error.self) { try await task.value }
        #expect(manager.state(for: 21) == .notCached)
        #expect(!FileManager.default.fileExists(atPath: manager.localURL(for: 21).path))
    }

    @Test func testDownloadSendsBearerToken() async throws {
        RangeDownloadProtocol.reset(payload: Data("video".utf8))
        let manager = CacheManager(root: tempRoot(), configuration: rangeDownloadConfig())
        try await manager.download(id: 7,
                                   from: URL(string: "https://example.test/videos/7/stream")!,
                                   preview: URL(string: "https://example.test/videos/7/preview")!,
                                   bearerToken: "secret")
        let requests = RangeDownloadProtocol.recordedRequests()
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer secret" })
    }

    @Test func fourStreamsSplitTheFileAndReassembleItsBytes() async throws {
        let payload = Data((0..<23).map { UInt8($0) })
        RangeDownloadProtocol.reset(payload: payload)
        let manager = splittingManager(root: tempRoot(), configuration: rangeDownloadConfig())
        try await manager.download(
            id: 50, from: URL(string: "https://srv.test/videos/50/stream")!,
            bearerToken: "secret", streamCount: 4
        )
        let requests = RangeDownloadProtocol.recordedRequests()
        let ranges = requests.compactMap { $0.value(forHTTPHeaderField: "Range") }
        #expect(ranges.first == "bytes=0-0")
        #expect(Set(ranges.dropFirst().prefix(4)) == ["bytes=0-4", "bytes=5-10", "bytes=11-16", "bytes=17-22"])
        #expect(requests.dropFirst().allSatisfy { $0.value(forHTTPHeaderField: "If-Range") == "\"test-video\"" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer secret" })
        #expect(try Data(contentsOf: manager.localURL(for: 50)) == payload)
        #expect(manager.state(for: 50) == .cached)
    }

    @Test func rejectsServerThatIgnoresRangesWithoutPublishingAFile() async {
        RangeDownloadProtocol.reset()
        RangeDownloadProtocol.responseOverride = { request in
            let data = Data("full body".utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Length": "\(data.count)"])!, data)
        }
        let manager = CacheManager(root: tempRoot(), configuration: rangeDownloadConfig())
        await #expect(throws: IdentityProbeError.invalid) {
            try await manager.download(id: 51, from: URL(string: "https://srv.test/videos/51/stream")!, streamCount: 2)
        }
        #expect(manager.state(for: 51) == .notCached)
        #expect(!FileManager.default.fileExists(atPath: manager.localURL(for: 51).path))
    }

    @Test func transientSegmentBlipRetriesAndCompletesDownload() async throws {
        SegmentBlipThenSucceedProtocol.reset()
        // minPiece 4: the 8-byte file splits into 0-3 and 4-7, and neither
        // half is split again, so the retry of 0-3 cannot be stolen into 0-1.
        let manager = CacheManager(root: tempRoot(), configuration: segmentBlipConfig(), fileManager: .default,
                                   fetchTuning: DownloadTuning(minPiece: 4))
        try await manager.download(id: 70, from: URL(string: "https://srv.test/videos/70/stream")!, streamCount: 2)
        let expected = Data((0..<UInt8(SegmentBlipThenSucceedProtocol.total)).map { $0 })
        #expect(try Data(contentsOf: manager.localURL(for: 70)) == expected)
        #expect(manager.state(for: 70) == .cached)
        // The 0-3 range blipped once and was retried in place; nothing had
        // been committed, so the retry asks for the same range again.
        #expect(SegmentBlipThenSucceedProtocol.attempts(forRange: "bytes=0-3") == 2)
        #expect(SegmentBlipThenSucceedProtocol.attempts(forRange: "bytes=4-7") == 1)
    }

    @Test func aVideoWatchedToTheEndReadsAsCached() async throws {
        let manager = CacheManager(root: tempRoot(), configuration: rangeDownloadConfig())
        let body = sampleBody(10)
        let generation = try await manager.mediaStore.open(key: "40", identity: MediaIdentity(etag: "\"w\"", totalByteCount: 10))
        try await put(manager.mediaStore, key: "40", DownloadByteRange(start: 0, end: 9), generation: generation, from: body)
        #expect(manager.state(for: 40) == .cached)
    }

    @Test func aPartlyWatchedVideoIsNotADownload() async throws {
        let manager = CacheManager(root: tempRoot(), configuration: rangeDownloadConfig())
        let generation = try await manager.mediaStore.open(key: "41", identity: MediaIdentity(etag: "\"w\"", totalByteCount: 10))
        try await put(manager.mediaStore, key: "41", DownloadByteRange(start: 0, end: 4), generation: generation, from: sampleBody(10))
        #expect(manager.state(for: 41) == .notCached)
        #expect(manager.activeDownloads().isEmpty)
    }

    @Test func removeCachedDeletesOnlyRequestedVersion() throws {
        let manager = CacheManager(root: tempRoot(), configuration: rangeDownloadConfig())
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
        #expect(manager.hasAnyCached(id: 1) == false)
    }

    @Test func hasAnyCachedIgnoresPreviewFiles() throws {
        let root = tempRoot()
        let manager = CacheManager(root: root, configuration: rangeDownloadConfig())
        try Data([0x01]).write(to: root.appendingPathComponent("22.preview.jpg"))
        #expect(manager.hasAnyCached(id: 22) == false)
    }

    @Test func removeAllCachedDeletesVideosAndStoreEntriesKeepsPreviews() async throws {
        let root = tempRoot()
        let manager = CacheManager(root: root, configuration: rangeDownloadConfig())
        let keep = ["23.preview.jpg", "poster.abc123.jpg", "24.mp4"]
        let remove = ["23.mp4", "23.v1.mp4", "23.v12.mp4"]
        for name in keep + remove {
            try Data([0x01]).write(to: root.appendingPathComponent(name))
        }
        let identity = MediaIdentity(etag: "\"r\"", totalByteCount: 4)
        for key in ["23", "23:4", "24:1"] { _ = try await manager.mediaStore.open(key: key, identity: identity) }

        manager.removeAllCached(id: 23)
        await manager.settleStoreWork()

        for name in remove {
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path), "should have deleted \(name)")
        }
        for name in keep {
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path), "should have kept \(name)")
        }
        #expect(await manager.mediaStore.manifest(key: "23") == nil)
        #expect(await manager.mediaStore.manifest(key: "23:4") == nil)
        #expect(await manager.mediaStore.manifest(key: "24:1") != nil)
        #expect(manager.state(for: 23) == .notCached)
    }

    @Test func clearAllVideosRemovesVideosAndKeepsCovers() async throws {
        let root = tempRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = ["1.mp4", "2.v5.mp4", "1.resume", "2:5.resume", "download-completions.json",
                     "1.preview.jpg", "poster.abc123.jpg"]
        for name in files {
            try Data("x".utf8).write(to: root.appendingPathComponent(name))
        }
        let manager = CacheManager(root: root)
        _ = try await manager.mediaStore.open(key: "3", identity: MediaIdentity(etag: "\"c\"", totalByteCount: 4))

        manager.clearAllVideos()
        await manager.settleStoreWork()

        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
        for gone in ["1.mp4", "2.v5.mp4", "1.resume", "2:5.resume", "download-completions.json"] {
            #expect(!remaining.contains(gone), "should have deleted \(gone)")
        }
        #expect(remaining.contains("1.preview.jpg"))
        #expect(remaining.contains("poster.abc123.jpg"))
        #expect(await manager.mediaStore.manifest(key: "3") == nil)
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

    @Test func clearAllCoversRemovesImagesAndKeepsVideos() throws {
        let root = tempRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["1.preview.jpg", "poster.abc123.png", "1.mp4"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(name))
        }
        let manager = CacheManager(root: root)
        manager.clearAllCovers()
        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!remaining.contains("1.preview.jpg"))
        #expect(!remaining.contains("poster.abc123.png"))
        #expect(remaining.contains("1.mp4"))
    }
}
