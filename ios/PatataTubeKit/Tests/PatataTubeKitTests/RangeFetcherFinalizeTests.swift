import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Range fetcher finalize", .serialized)
struct RangeFetcherFinalizeTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("finalize-\(UUID().uuidString)")
    }
    private let body = Data((0..<100).map { UInt8($0) })
    private let remote = URL(string: "https://srv.test/videos/1/stream")!

    private func installHandler(etag: String = "\"v1\"") {
        let body = body
        MockURLProtocol.handler = { request in
            let spec = (request.value(forHTTPHeaderField: "Range") ?? "bytes=0-0")
                .replacingOccurrences(of: "bytes=", with: "")
            let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
            let start = Int(parts[0])!
            let end = parts.count > 1 && !parts[1].isEmpty ? Int(parts[1])! : body.count - 1
            let slice = body.subdata(in: start..<(end + 1))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 206, httpVersion: nil,
                headerFields: [
                    "Accept-Ranges": "bytes", "ETag": etag,
                    "Content-Range": "bytes \(start)-\(end)/\(body.count)",
                    "Content-Length": "\(slice.count)",
                ])!
            return (response, slice)
        }
    }

    @Test func finalizeFillsGapsAndPublishesCompleteFile() async throws {
        installHandler()
        let base = root()
        let store = CapturedDownloadStore(root: base)
        let fetcher = RangeFetcher(
            cacheKey: "1", remoteURL: remote, bearerToken: "t",
            videoId: 1, versionId: nil,
            store: store, session: mockSession(), onProgress: { _ in })
        _ = try await fetcher.loadContentInfo()
        _ = try await fetcher.data(for: .init(start: 0, end: 9))   // watch the head only
        let dest = base.appendingPathComponent("1.mp4")
        try await fetcher.finalize(destination: dest)
        #expect(FileManager.default.fileExists(atPath: dest.path))
        #expect(try Data(contentsOf: dest) == body)
        #expect(store.manifests().isEmpty)   // manifest removed on publish
    }
}
