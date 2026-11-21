import Foundation
import Testing
@testable import PatataTubeKit

/// Thread-safe one-shot flag for URL-protocol callbacks.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    /// True the first time only.
    func setOnce() -> Bool { lock.withLock { defer { set = true }; return !set } }
}

@Suite("Range fetcher")
struct RangeFetcherTests {
    private let body = sampleBody(100_000)
    private let identity = MediaIdentity(etag: "\"r\"", totalByteCount: 100_000)
    private let session = URLSession(configuration: ChunkedRangeProtocol.configuration())

    private func fetcher(
        _ store: MediaStore, key: String, path: String, generation: Int,
        identity: MediaIdentity? = nil, commitSize: Int = 10_000, maxAttempts: Int = 4,
        limiter: ReadAheadLimiter? = nil
    ) -> RangeFetcher {
        RangeFetcher(
            store: store, key: key, identity: identity ?? self.identity, generation: generation,
            session: session,
            upstream: UpstreamRequests(url: URL(string: "https://srv.test\(path)")!, credentials: nil, fallbackToken: "tok"),
            commitSize: commitSize, maxAttempts: maxAttempts, limiter: limiter
        )
    }

    private func stub(_ path: String, etag: String = "\"r\"", afterChunk: @escaping (Int) -> Bool = { _ in true }) {
        ChunkedRangeProtocol.stub(path: path, plan: .init(
            fullBody: body, etag: etag, chunkSize: 10_000,
            failureError: URLError(.networkConnectionLost), afterChunk: afterChunk
        ))
    }

    @Test func commitsEachChunkBeforeTheBodyEnds() async throws {
        let path = "/rf/commit"
        let release = DispatchSemaphore(value: 0)
        stub(path) { delivered in
            if delivered == 50_000 { _ = release.wait(timeout: .now() + 5) }
            return true
        }
        defer { ChunkedRangeProtocol.reset(path: path) }
        let store = MediaStore(videosRoot: temporaryVideosRoot())
        let generation = try await store.open(key: "1", identity: identity)
        guard case .granted(let claim) = await store.claim(key: "1", from: 0, through: 99_999, owner: .download, waitWithin: 0)
        else { Issue.record("refused"); return }
        let run = Task { try await fetcher(store, key: "1", path: path, generation: generation).run(claim: claim.id) }
        #expect(await eventually { await store.available(key: "1", from: 0)?.bytes == 50_000 })
        release.signal()
        #expect(try await run.value == .promoted)
        #expect(try Data(contentsOf: store.finishedURL(key: "1")) == body)
        let request = try #require(ChunkedRangeProtocol.recordedRanges(path: path).first)
        #expect(request == "bytes=0-99999")
    }

    @Test func stopsAtBytesAlreadyStored() async throws {
        let path = "/rf/stop"
        stub(path)
        defer { ChunkedRangeProtocol.reset(path: path) }
        let store = MediaStore(videosRoot: temporaryVideosRoot())
        let generation = try await store.open(key: "1", identity: identity)
        try await put(store, key: "1", DownloadByteRange(start: 60_000, end: 99_999), generation: generation, from: body)
        guard case .granted(let claim) = await store.claim(key: "1", from: 0, through: 99_999, owner: .download, waitWithin: 0)
        else { Issue.record("refused"); return }
        #expect(try await fetcher(store, key: "1", path: path, generation: generation).run(claim: claim.id) == .promoted)
        #expect(ChunkedRangeProtocol.recordedRanges(path: path) == ["bytes=0-59999"])
    }

    @Test func parksAtTheReadAheadLeadAndMarksItsClaimIdle() async throws {
        let path = "/rf/lead"
        stub(path)
        defer { ChunkedRangeProtocol.reset(path: path) }
        let store = MediaStore(videosRoot: temporaryVideosRoot())
        let generation = try await store.open(key: "1", identity: identity)
        guard case .granted(let claim) = await store.claim(key: "1", from: 0, through: 99_999, owner: .playback, waitWithin: 0)
        else { Issue.record("refused"); return }
        let limiter = ReadAheadLimiter(lead: 20_000, position: 0)
        let run = Task { try await fetcher(store, key: "1", path: path, generation: generation, limiter: limiter).run(claim: claim.id) }
        #expect(await eventually { await store.claimSnapshot(key: "1", id: claim.id)?.idle == true })
        let parkedAt = await store.available(key: "1", from: 0)?.bytes ?? -1
        #expect(parkedAt >= 20_000 && parkedAt <= 30_000)
        limiter.advance(to: 100_000)
        #expect(try await run.value == .promoted)
    }

    @Test func retriesFromItsLastCommit() async throws {
        let path = "/rf/retry"
        let failed = Flag()
        stub(path) { delivered in !(delivered == 40_000 && failed.setOnce()) }
        defer { ChunkedRangeProtocol.reset(path: path) }
        let store = MediaStore(videosRoot: temporaryVideosRoot())
        let generation = try await store.open(key: "1", identity: identity)
        guard case .granted(let claim) = await store.claim(key: "1", from: 0, through: 99_999, owner: .download, waitWithin: 0)
        else { Issue.record("refused"); return }
        #expect(try await fetcher(store, key: "1", path: path, generation: generation).run(claim: claim.id) == .promoted)
        #expect(ChunkedRangeProtocol.recordedRanges(path: path) == ["bytes=0-99999", "bytes=40000-99999"])
    }

    @Test func reportsAChangedFileWithItsNewIdentity() async throws {
        let path = "/rf/etag"
        stub(path, etag: "\"other\"")
        defer { ChunkedRangeProtocol.reset(path: path) }
        let store = MediaStore(videosRoot: temporaryVideosRoot())
        let generation = try await store.open(key: "1", identity: identity)
        guard case .granted(let claim) = await store.claim(key: "1", from: 0, through: 99_999, owner: .download, waitWithin: 0)
        else { Issue.record("refused"); return }
        await #expect(throws: RangeFetchError.entityChanged(MediaIdentity(etag: "\"other\"", totalByteCount: 100_000))) {
            _ = try await fetcher(store, key: "1", path: path, generation: generation).run(claim: claim.id)
        }
    }

    @Test func requestsFollowTheCurrentBaseURLAndToken() async throws {
        let path = "/rf/headers"
        stub(path)
        defer { ChunkedRangeProtocol.reset(path: path) }
        let request = UpstreamRequests(
            url: URL(string: "https://remote.test\(path)?version_id=2")!,
            credentials: InMemoryCredentialStore(baseURL: URL(string: "http://192.168.1.1:3050"), token: "live"),
            fallbackToken: "stale"
        ).ranged(DownloadByteRange(start: 5, end: 9))
        #expect(request.url?.absoluteString == "http://192.168.1.1:3050\(path)?version_id=2")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer live")
        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=5-9")
    }

    @Test func probeReadsTheIdentity() async throws {
        let path = "/rf/probe"
        stub(path)
        defer { ChunkedRangeProtocol.reset(path: path) }
        let upstream = UpstreamRequests(url: URL(string: "https://srv.test\(path)")!, credentials: nil)
        #expect(try await IdentityProbe.fetch(upstream.probe(), session: session) == identity)
    }
}
