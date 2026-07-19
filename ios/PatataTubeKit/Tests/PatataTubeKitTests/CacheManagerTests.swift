import Testing
import Foundation
@testable import PatataTubeKit

// Dedicated protocol so CacheManagerTests never shares the handler global
// with APIClientTests (which runs concurrently as a separate top-level suite).
private final class MockDownloadProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockDownloadProtocol.handler else {
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
}

// Sends a response + partial body but never finishes, so a download stays
// in-flight until the task is explicitly cancelled.
private final class HangingDownloadProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
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

private func mockDownloadConfig() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockDownloadProtocol.self]
    return config
}

private func hangingDownloadConfig() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [HangingDownloadProtocol.self]
    return config
}

private func tempRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("cache-\(UUID().uuidString)")
}

@Suite(.serialized)
struct CacheManagerTests {

    @Test func localURLUsesIdAndMp4() {
        let manager = CacheManager(root: tempRoot(), configuration: mockDownloadConfig())
        #expect(manager.localURL(for: 5).lastPathComponent == "5.mp4")
    }

    @Test func stateIsNotCachedThenCachedAfterDownload() async throws {
        let root = tempRoot()
        let manager = CacheManager(root: root, configuration: mockDownloadConfig())
        #expect(manager.state(for: 11) == .notCached)

        MockDownloadProtocol.handler = { req in
            (jsonResponse(req.url!), Data([0x00, 0x01, 0x02, 0x03]))
        }
        try await manager.download(id: 11, from: URL(string: "https://srv.test/videos/11/stream")!)

        #expect(manager.state(for: 11) == .cached)
        let saved = try Data(contentsOf: manager.localURL(for: 11))
        #expect(saved == Data([0x00, 0x01, 0x02, 0x03]))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("11.resume").path))
    }

    @Test func downloadAlsoCachesPreview() async throws {
        let root = tempRoot()
        let manager = CacheManager(root: root, configuration: mockDownloadConfig())
        #expect(manager.cachedPreviewURL(for: 12) == nil)

        MockDownloadProtocol.handler = { req in
            let bytes: [UInt8] = req.url!.pathExtension == "jpg" ? [0xAA, 0xBB] : [0x00, 0x01]
            return (jsonResponse(req.url!), Data(bytes))
        }
        try await manager.download(
            id: 12,
            from: URL(string: "https://srv.test/videos/12/stream")!,
            preview: URL(string: "https://img.test/thumb.jpg")!
        )

        let previewURL = try #require(manager.cachedPreviewURL(for: 12))
        #expect(previewURL.pathExtension == "jpg")
        #expect(try Data(contentsOf: previewURL) == Data([0xAA, 0xBB]))
    }

    @Test func previewFailureStillCachesVideo() async throws {
        let root = tempRoot()
        let manager = CacheManager(root: root, configuration: mockDownloadConfig())
        MockDownloadProtocol.handler = { req in
            if req.url!.host == "img.test" { throw URLError(.timedOut) }
            return (jsonResponse(req.url!), Data([0x09]))
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
        let manager = CacheManager(root: tempRoot(), configuration: mockDownloadConfig())
        MockDownloadProtocol.handler = { req in (jsonResponse(req.url!, status: 404), Data()) }
        await #expect(throws: APIError.badStatus(404)) {
            try await manager.download(id: 1, from: URL(string: "https://srv.test/x")!)
        }
    }

    @Test func cancelThrowsAndReturnsToNotCached() async {
        let root = tempRoot()
        let manager = CacheManager(root: root, configuration: hangingDownloadConfig())

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

    @Test func testDownloadSendsBearerToken() async throws {
        var seenAuth: [String?] = []
        MockDownloadProtocol.handler = { request in
            seenAuth.append(request.value(forHTTPHeaderField: "Authorization"))
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data("video".utf8))
        }
        let root = tempRoot()
        let manager = CacheManager(root: root, configuration: mockDownloadConfig())
        try await manager.download(id: 7,
                                   from: URL(string: "https://example.test/videos/7/stream")!,
                                   preview: URL(string: "https://example.test/videos/7/preview")!,
                                   bearerToken: "secret")
        #expect(seenAuth == ["Bearer secret", "Bearer secret"])
    }

    @Test func showPosterStoreAndLookup() throws {
        let manager = CacheManager(root: tempRoot(), configuration: mockDownloadConfig())
        let key = "/library/shows/bluey/poster.png"
        #expect(manager.cachedShowPosterURL(for: key) == nil)

        manager.storeShowPoster(Data([0x01, 0x02]), for: key)

        let url = try #require(manager.cachedShowPosterURL(for: key))
        #expect(url.pathExtension == "png")
        #expect(try Data(contentsOf: url) == Data([0x01, 0x02]))
        // A different key must not resolve to this poster.
        #expect(manager.cachedShowPosterURL(for: "/other/poster.png") == nil)
    }

    @Test func showPosterKeyIsStableAndExtSanitized() throws {
        let root = tempRoot()
        let manager = CacheManager(root: root, configuration: mockDownloadConfig())
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
        let manager = CacheManager(root: tempRoot(), configuration: mockDownloadConfig())
        MockDownloadProtocol.handler = { req in
            let bytes: [UInt8] = req.url!.host == "img.test" ? [0xCC] : [0x00]
            return (jsonResponse(req.url!), Data(bytes))
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
        let manager = CacheManager(root: tempRoot(), configuration: mockDownloadConfig())
        MockDownloadProtocol.handler = { req in
            if req.url!.host == "img.test" { throw URLError(.timedOut) }
            return (jsonResponse(req.url!), Data([0x09]))
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
        let manager = CacheManager(root: tempRoot(), configuration: mockDownloadConfig())
        manager.storeShowPoster(Data([0x01]), for: "k2")
        var posterRequests = 0
        MockDownloadProtocol.handler = { req in
            if req.url!.host == "img.test" { posterRequests += 1 }
            return (jsonResponse(req.url!), Data([0x00]))
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
