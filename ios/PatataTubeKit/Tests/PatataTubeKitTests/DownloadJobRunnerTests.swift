import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Download job runner")
struct DownloadJobRunnerTests {
    private let body = sampleBody(100_000)
    private let identity = MediaIdentity(etag: "\"j\"", totalByteCount: 100_000)

    private func runner(
        _ store: MediaStore, key: String, path: String, streams: Int,
        minPiece: Int64 = 1, commitSize: Int = 10_000, maxAttempts: Int = 4
    ) -> DownloadJobRunner {
        DownloadJobRunner(
            store: store, key: key, streamCount: streams,
            session: URLSession(configuration: ChunkedRangeProtocol.configuration()),
            upstream: UpstreamRequests(url: URL(string: "https://srv.test\(path)")!, credentials: nil),
            tuning: DownloadTuning(minPiece: minPiece, commitSize: commitSize, maxAttempts: maxAttempts),
            onProgress: { _ in }
        )
    }

    private func stub(_ path: String, etag: String = "\"j\"", afterChunk: @escaping (Int) -> Bool = { _ in true }) {
        ChunkedRangeProtocol.stub(path: path, plan: .init(
            fullBody: body, etag: etag, chunkSize: 10_000,
            failureError: URLError(.networkConnectionLost), afterChunk: afterChunk
        ))
    }

    @Test func fourStreamsFillAndPromoteTheFile() async throws {
        let path = "/job/four"
        stub(path)
        defer { ChunkedRangeProtocol.reset(path: path) }
        let store = MediaStore(videosRoot: temporaryVideosRoot())
        try await runner(store, key: "1", path: path, streams: 4).run()
        #expect(try Data(contentsOf: store.finishedURL(key: "1")) == body)
        let ranges = ChunkedRangeProtocol.recordedRanges(path: path)
        #expect(ranges.first == "bytes=0-0")
        #expect(Set(ranges.dropFirst().prefix(4)) == [
            "bytes=0-24999", "bytes=25000-49999", "bytes=50000-74999", "bytes=75000-99999",
        ])
    }

    @Test func fetchesOnlyTheHoles() async throws {
        let path = "/job/holes"
        stub(path)
        defer { ChunkedRangeProtocol.reset(path: path) }
        let store = MediaStore(videosRoot: temporaryVideosRoot())
        let generation = try await store.open(key: "1", identity: identity)
        try await put(store, key: "1", DownloadByteRange(start: 0, end: 49_999), generation: generation, from: body)
        try await runner(store, key: "1", path: path, streams: 1, minPiece: 10_000_000).run()
        #expect(ChunkedRangeProtocol.recordedRanges(path: path) == ["bytes=50000-99999"])
        #expect(try Data(contentsOf: store.finishedURL(key: "1")) == body)
    }

    @Test func takesOverAParkedPlaybackClaim() async throws {
        let path = "/job/idle"
        stub(path)
        defer { ChunkedRangeProtocol.reset(path: path) }
        let store = MediaStore(videosRoot: temporaryVideosRoot())
        _ = try await store.open(key: "1", identity: identity)
        guard case .granted(let parked) = await store.claim(key: "1", from: 0, through: 99_999, owner: .playback, waitWithin: 0)
        else { Issue.record("refused"); return }
        await store.setClaimIdle(key: "1", id: parked.id, idle: true)
        try await runner(store, key: "1", path: path, streams: 1, minPiece: 10_000_000).run()
        #expect(ChunkedRangeProtocol.recordedRanges(path: path) == ["bytes=0-99999"])
        #expect(try Data(contentsOf: store.finishedURL(key: "1")) == body)
    }

    @Test func restartsWhenTheFileChangedOnTheServer() async throws {
        let path = "/job/changed"
        stub(path, etag: "\"new\"")
        defer { ChunkedRangeProtocol.reset(path: path) }
        let store = MediaStore(videosRoot: temporaryVideosRoot())
        _ = try await store.open(key: "1", identity: MediaIdentity(etag: "\"old\"", totalByteCount: 100_000))
        try await runner(store, key: "1", path: path, streams: 1, minPiece: 10_000_000).run()
        #expect(ChunkedRangeProtocol.recordedRanges(path: path) == ["bytes=0-99999", "bytes=0-99999"])
        #expect(try Data(contentsOf: store.finishedURL(key: "1")) == body)
    }

    @Test func failsAfterTheRetriesRunOutAndKeepsTheEntry() async throws {
        let path = "/job/fail"
        stub(path) { _ in false }
        defer { ChunkedRangeProtocol.reset(path: path) }
        let store = MediaStore(videosRoot: temporaryVideosRoot())
        _ = try await store.open(key: "1", identity: identity)
        await #expect(throws: URLError.self) {
            try await runner(store, key: "1", path: path, streams: 1, minPiece: 10_000_000, commitSize: 100_000).run()
        }
        #expect(ChunkedRangeProtocol.recordedRanges(path: path).count == 4)
        #expect(await store.manifest(key: "1") != nil)
        #expect(await store.claims(key: "1").isEmpty)
    }
}
