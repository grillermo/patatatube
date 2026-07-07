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

private func mockDownloadSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockDownloadProtocol.self]
    return URLSession(configuration: config)
}

private func tempRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("cache-\(UUID().uuidString)")
}

@Suite(.serialized)
struct CacheManagerTests {

    @Test func localURLUsesIdAndMp4() {
        let manager = CacheManager(root: tempRoot(), session: mockDownloadSession())
        #expect(manager.localURL(for: 5).lastPathComponent == "5.mp4")
    }

    @Test func stateIsNotCachedThenCachedAfterDownload() async throws {
        let root = tempRoot()
        let manager = CacheManager(root: root, session: mockDownloadSession())
        #expect(manager.state(for: 11) == .notCached)

        MockDownloadProtocol.handler = { req in
            (jsonResponse(req.url!), Data([0x00, 0x01, 0x02, 0x03]))
        }
        try await manager.download(id: 11, from: URL(string: "https://srv.test/videos/11/stream")!)

        #expect(manager.state(for: 11) == .cached)
        let saved = try Data(contentsOf: manager.localURL(for: 11))
        #expect(saved == Data([0x00, 0x01, 0x02, 0x03]))
    }

    @Test func downloadAlsoCachesPreview() async throws {
        let root = tempRoot()
        let manager = CacheManager(root: root, session: mockDownloadSession())
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
        let manager = CacheManager(root: root, session: mockDownloadSession())
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
        let manager = CacheManager(root: tempRoot(), session: mockDownloadSession())
        MockDownloadProtocol.handler = { req in (jsonResponse(req.url!, status: 404), Data()) }
        await #expect(throws: APIError.badStatus(404)) {
            try await manager.download(id: 1, from: URL(string: "https://srv.test/x")!)
        }
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
        let manager = CacheManager(root: root, session: mockDownloadSession())
        try await manager.download(id: 7,
                                   from: URL(string: "https://example.test/videos/7/stream")!,
                                   preview: URL(string: "https://example.test/videos/7/preview")!,
                                   bearerToken: "secret")
        #expect(seenAuth == ["Bearer secret", "Bearer secret"])
    }
}
