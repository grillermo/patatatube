import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Range fetcher fetchAll", .serialized)
struct RangeFetcherFetchAllTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fetchall-\(UUID().uuidString)")
    }
    private let body = Data((0..<100).map { UInt8($0) })
    private let remote = URL(string: "https://srv.test/videos/1/stream")!

    /// Serves 206 responses and records every GET range (the 0-0 probe excluded).
    private func installHandler(recorder: RangeRecorder) {
        let body = body
        MockURLProtocol.handler = { request in
            let spec = (request.value(forHTTPHeaderField: "Range") ?? "bytes=0-0")
                .replacingOccurrences(of: "bytes=", with: "")
            let parts = spec.split(separator: "-")
            let start = Int(parts[0])!
            let end = parts.count > 1 && !parts[1].isEmpty ? Int(parts[1])! : body.count - 1
            if !(start == 0 && end == 0) { recorder.record(start: start, end: end) }
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
            store: store, session: mockSession(), onProgress: { _, _ in })
    }

    @Test func downloadAllPublishesCompleteFile() async throws {
        let recorder = RangeRecorder()
        installHandler(recorder: recorder)
        let root = root()
        let fetcher = makeFetcher(store: CapturedDownloadStore(root: root))
        let destination = root.appendingPathComponent("1.mp4")

        try await fetcher.downloadAll(concurrency: 4, destination: destination)

        #expect(try Data(contentsOf: destination) == body)
        #expect(recorder.covered() == [0...99])
    }

    @Test func fetchAllRequestsOnlyTheGaps() async throws {
        let recorder = RangeRecorder()
        installHandler(recorder: recorder)
        let root = root()
        let fetcher = makeFetcher(store: CapturedDownloadStore(root: root))
        // Simulate a half-watched video: capture the first half through the
        // same path playback uses.
        _ = try await fetcher.loadContentInfo()
        _ = try await fetcher.data(for: .init(start: 0, end: 49))
        recorder.reset()

        try await fetcher.fetchAll(concurrency: 2)

        #expect(recorder.covered() == [50...99])
        #expect(await fetcher.manifestSnapshot?.isComplete == true)
    }

    @Test func fetchAllFillsHolesLeftBySeeking() async throws {
        let recorder = RangeRecorder()
        installHandler(recorder: recorder)
        let fetcher = makeFetcher(store: CapturedDownloadStore(root: root()))
        _ = try await fetcher.loadContentInfo()
        _ = try await fetcher.data(for: .init(start: 20, end: 29))
        _ = try await fetcher.data(for: .init(start: 60, end: 69))
        recorder.reset()

        try await fetcher.fetchAll(concurrency: 1)

        #expect(recorder.covered() == [0...19, 30...59, 70...99])
    }

    @Test func capturedRangesAreServedFromDiskWithoutNetwork() async throws {
        let recorder = RangeRecorder()
        installHandler(recorder: recorder)
        let fetcher = makeFetcher(store: CapturedDownloadStore(root: root()))
        try await fetcher.fetchAll(concurrency: 2)
        recorder.reset()

        let data = try await fetcher.data(for: .init(start: 30, end: 39))

        #expect(data == body.subdata(in: 30..<40))
        #expect(recorder.covered().isEmpty)
    }
}

/// Collects requested ranges and merges them into minimal closed ranges so a
/// test can assert on coverage without depending on chunk boundaries.
final class RangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var ranges: [ClosedRange<Int>] = []

    func record(start: Int, end: Int) {
        lock.withLock { ranges.append(start...end) }
    }
    func reset() { lock.withLock { ranges = [] } }
    func covered() -> [ClosedRange<Int>] {
        let sorted = lock.withLock { ranges }.sorted { $0.lowerBound < $1.lowerBound }
        guard var current = sorted.first else { return [] }
        var merged: [ClosedRange<Int>] = []
        for next in sorted.dropFirst() {
            if next.lowerBound <= current.upperBound + 1 {
                current = current.lowerBound...max(current.upperBound, next.upperBound)
            } else {
                merged.append(current)
                current = next
            }
        }
        merged.append(current)
        return merged
    }
}
