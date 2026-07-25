import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Range fetcher", .serialized)
struct RangeFetcherTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fetcher-\(UUID().uuidString)")
    }
    private let body = Data((0..<100).map { UInt8($0) })  // 100 bytes 0x00..0x63
    private let remote = URL(string: "https://srv.test/videos/1/stream")!

    /// Serves 206 range responses over `body` with a fixed strong ETag.
    private func installHandler(etag: String = "\"v1\"", failGET: Bool = false) {
        let body = body
        MockURLProtocol.handler = { request in
            let rangeHeader = request.value(forHTTPHeaderField: "Range") ?? "bytes=0-0"
            let spec = rangeHeader.replacingOccurrences(of: "bytes=", with: "")
            let parts = spec.split(separator: "-")
            let start = Int(parts[0])!
            let end = parts.count > 1 && !parts[1].isEmpty ? Int(parts[1])! : body.count - 1
            if failGET && !(start == 0 && end == 0) { throw URLError(.networkConnectionLost) }
            let slice = body.subdata(in: start..<(end + 1))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 206, httpVersion: nil,
                headerFields: [
                    "Accept-Ranges": "bytes",
                    "ETag": etag,
                    "Content-Range": "bytes \(start)-\(end)/\(body.count)",
                    "Content-Length": "\(slice.count)",
                ])!
            return (response, slice)
        }
    }

    @Test func loadContentInfoParsesTotalAndEtag() async throws {
        installHandler()
        let fetcher = RangeFetcher(
            cacheKey: "1", remoteURL: remote, bearerToken: "t",
            videoId: 1, versionId: nil,
            store: CapturedDownloadStore(root: root()), session: mockSession(),
            onProgress: { _ in })
        let info = try await fetcher.loadContentInfo()
        #expect(info == ContentInfo(totalByteCount: 100, etag: "\"v1\""))
    }

    @Test func dataFetchesWritesAndServesFromDisk() async throws {
        installHandler()
        let store = CapturedDownloadStore(root: root())
        let fetcher = RangeFetcher(
            cacheKey: "1", remoteURL: remote, bearerToken: "t",
            videoId: 1, versionId: nil,
            store: store, session: mockSession(), onProgress: { _ in })
        _ = try await fetcher.loadContentInfo()
        let first = try await fetcher.data(for: .init(start: 10, end: 19))
        #expect(first == body.subdata(in: 10..<20))
        // Now captured on disk; a second read of a subrange returns identical bytes.
        let again = try await fetcher.data(for: .init(start: 12, end: 15))
        #expect(again == body.subdata(in: 12..<16))
        #expect(await fetcher.manifestSnapshot?.capturedRanges == [.init(start: 10, end: 19)])
    }

    @Test func changedEtagOnFetchThrows() async throws {
        installHandler()
        let store = CapturedDownloadStore(root: root())
        let fetcher = RangeFetcher(
            cacheKey: "1", remoteURL: remote, bearerToken: "t",
            videoId: 1, versionId: nil,
            store: store, session: mockSession(), onProgress: { _ in })
        _ = try await fetcher.loadContentInfo()
        installHandler(etag: "\"v2\"")   // server re-encoded
        await #expect(throws: RangeFetcherError.changedEntity) {
            _ = try await fetcher.data(for: .init(start: 0, end: 9))
        }
    }
}
