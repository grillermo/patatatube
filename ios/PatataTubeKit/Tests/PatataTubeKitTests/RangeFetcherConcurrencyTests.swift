import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Range fetcher concurrency", .serialized)
struct RangeFetcherConcurrencyTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fetcher-concurrency-\(UUID().uuidString)")
    }
    private let body = Data((0..<100).map { UInt8($0) })
    private let remote = URL(string: "https://srv.test/videos/1/stream")!

    /// Serves 206 range responses over `body`, delaying each GET so the two
    /// concurrent calls genuinely overlap across their `await` points.
    private func installSlowHandler() {
        let body = body
        MockURLProtocol.handler = { request in
            let spec = (request.value(forHTTPHeaderField: "Range") ?? "bytes=0-0")
                .replacingOccurrences(of: "bytes=", with: "")
            let parts = spec.split(separator: "-")
            let start = Int(parts[0])!
            let end = parts.count > 1 && !parts[1].isEmpty ? Int(parts[1])! : body.count - 1
            if !(start == 0 && end == 0) { Thread.sleep(forTimeInterval: 0.05) }
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

    private func makeFetcher(store: CapturedDownloadStore) -> RangeFetcher {
        RangeFetcher(
            cacheKey: "1", remoteURL: remote, bearerToken: "t",
            videoId: 1, versionId: nil,
            store: store, session: mockSession(), onProgress: { _ in })
    }

    @Test func concurrentFetchesRecordEveryRange() async throws {
        installSlowHandler()
        let fetcher = makeFetcher(store: CapturedDownloadStore(root: root()))
        _ = try await fetcher.loadContentInfo()

        async let low: Data = fetcher.data(for: .init(start: 0, end: 9))
        async let high: Data = fetcher.data(for: .init(start: 50, end: 59))
        let (lowData, highData) = try await (low, high)

        #expect(lowData == body.subdata(in: 0..<10))
        #expect(highData == body.subdata(in: 50..<60))
        #expect(await fetcher.manifestSnapshot?.capturedRanges == [
            .init(start: 0, end: 9),
            .init(start: 50, end: 59),
        ])
    }
}
