import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Cache manager range download", .serialized)
struct CacheManagerRangeDownloadTests {
    private let body = Data((0..<100).map { UInt8($0) })
    private let remote = URL(string: "https://srv.test/videos/1/stream")!

    private func root() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cm-range-\(UUID().uuidString)")
    }

    private func installHandler() {
        let body = body
        MockURLProtocol.handler = { request in
            let spec = (request.value(forHTTPHeaderField: "Range") ?? "bytes=0-0")
                .replacingOccurrences(of: "bytes=", with: "")
            let parts = spec.split(separator: "-")
            let start = Int(parts[0])!
            let end = parts.count > 1 && !parts[1].isEmpty ? Int(parts[1])! : body.count - 1
            let slice = body.subdata(in: start..<(end + 1))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 206, httpVersion: nil,
                headerFields: [
                    "Accept-Ranges": "bytes",
                    "ETag": "\"v1\"",
                    "Content-Range": "bytes \(start)-\(end)/\(body.count)",
                    "Content-Length": "\(slice.count)",
                ])!
            return (response, slice)
        }
    }

    private func makeManager(root: URL) -> CacheManager {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return CacheManager(root: root, configuration: config)
    }

    @Test func downloadWritesCompleteFileAndReportsCached() async throws {
        installHandler()
        let root = root()
        let manager = makeManager(root: root)

        try await manager.download(id: 1, from: remote, bearerToken: "t", streamCount: 4)

        #expect(manager.state(for: 1) == .cached)
        #expect(try Data(contentsOf: manager.localURL(for: 1)) == body)
        #expect(manager.recentDownloads().contains { $0.videoID == 1 })
    }

    @Test func downloadResumesFromBytesLeftByPlayback() async throws {
        installHandler()
        let root = root()
        let manager = makeManager(root: root)
        // Watch-capture the first half through the public capture path.
        let asset = manager.captureAsset(
            videoId: 1, remoteURL: remote, bearerToken: "t")
        #expect(asset.url.scheme == CaptureManager.scheme)
        let fetcher = try #require(manager.testFetcher(videoId: 1, versionId: nil))
        _ = try await fetcher.data(for: .init(start: 0, end: 49), origin: .player)
        #expect(manager.state(for: 1) == .downloading(0.5))

        try await manager.download(id: 1, from: remote, bearerToken: "t", streamCount: 2)

        #expect(manager.state(for: 1) == .cached)
        #expect(try Data(contentsOf: manager.localURL(for: 1)) == body)
    }
}
