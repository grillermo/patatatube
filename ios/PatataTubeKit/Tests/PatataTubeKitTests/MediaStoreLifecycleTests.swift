import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Media store lifecycle")
struct MediaStoreLifecycleTests {
    private let identity = MediaIdentity(etag: "\"e1\"", totalByteCount: 1000)
    private let body = sampleBody(1000)
    private let job = DownloadJobParameters(
        remoteURL: URL(string: "https://srv.test/videos/1/stream")!,
        streamCount: 1, previewURL: nil, showPosterKey: nil, showPosterURL: nil
    )

    @Test func discardWaitsForTheLastReader() async throws {
        let store = MediaStore(videosRoot: temporaryVideosRoot())
        _ = try await store.open(key: "1", identity: identity)
        await store.beginRead(key: "1")
        await store.discard(key: "1")
        #expect(FileManager.default.fileExists(atPath: store.entryDir(key: "1").path))
        await store.endRead(key: "1")
        #expect(!FileManager.default.fileExists(atPath: store.entryDir(key: "1").path))
        #expect(await store.manifest(key: "1") == nil)
    }

    @Test func pinningAgainCancelsADeferredDelete() async throws {
        let store = MediaStore(videosRoot: temporaryVideosRoot())
        _ = try await store.open(key: "1", identity: identity)
        await store.beginRead(key: "1")
        await store.discard(key: "1")
        await store.setPin(key: "1", pin: PinState(job: job, paused: false))
        await store.endRead(key: "1")
        #expect(await store.manifest(key: "1")?.pin?.paused == false)
    }

    @Test func pinnedAndReadEntriesAreNeverEvicted() async throws {
        let clock = TestNow()
        let store = MediaStore(videosRoot: temporaryVideosRoot(), budgetBytes: 150, now: { clock.date })
        for key in ["pinned", "read", "old", "new"] {
            let generation = try await store.open(key: key, identity: identity)
            try await put(store, key: key, DownloadByteRange(start: 0, end: 99), generation: generation, from: body)
            clock.advance(10)
        }
        await store.setPin(key: "pinned", pin: PinState(job: job, paused: true))
        await store.beginRead(key: "read")
        await store.enforceBudget()
        // Unpinned total 300 > 150: "read" is busy, so the oldest idle one goes first.
        #expect(await store.manifest(key: "pinned") != nil)
        #expect(await store.manifest(key: "read") != nil)
        #expect(await store.manifest(key: "old") == nil)
        #expect(await store.manifest(key: "new") == nil)
    }

    @Test func storageFailureEvictsTheOldestOtherUnpinnedEntry() async throws {
        let clock = TestNow()
        let store = MediaStore(videosRoot: temporaryVideosRoot(), now: { clock.date })
        for key in ["a", "b", "c"] {
            _ = try await store.open(key: key, identity: identity)
            clock.advance(10)
        }
        await store.setPin(key: "a", pin: PinState(job: job, paused: false))
        #expect(await store.evictForStorageFailure(excluding: "c"))
        #expect(await store.manifest(key: "a") != nil)
        #expect(await store.manifest(key: "b") == nil)
        #expect(await store.manifest(key: "c") != nil)
        #expect(await store.evictForStorageFailure(excluding: "c") == false)
    }

    @Test func pinningBeforeTheProbeCreatesAnEntryOpenAdopts() async throws {
        let store = MediaStore(videosRoot: temporaryVideosRoot())
        await store.setPin(key: "1", pin: PinState(job: job, paused: false))
        let pinned = try #require(await store.manifest(key: "1"))
        #expect(pinned.identity == nil)
        #expect(!FileManager.default.fileExists(atPath: store.dataURL(key: "1").path))
        _ = try await store.open(key: "1", identity: identity)
        #expect(await store.manifest(key: "1")?.identity == identity)
        #expect(await store.manifest(key: "1")?.pin == pinned.pin)
        #expect(FileManager.default.fileExists(atPath: store.dataURL(key: "1").path))
    }

    @Test func openOverAFinishedFileReportsEverythingAvailable() async throws {
        let root = temporaryVideosRoot()
        let store = MediaStore(videosRoot: root)
        try body.write(to: store.finishedURL(key: "1"))
        let generation = try await store.open(key: "1", identity: identity)
        #expect(await store.available(key: "1", from: 400) == Availability(generation: generation, bytes: 600))
        #expect(await store.claim(key: "1", from: 0, through: 999, owner: .playback, waitWithin: 0)
                == .alreadyCommitted)
        let handle = try #require(await store.openReadHandle(key: "1"))
        try handle.seek(toOffset: 10)
        #expect(try handle.read(upToCount: 5) == body.subdata(in: 10..<15))
    }

    @Test func promoteIfCompleteSeesAFinishedFile() async throws {
        let store = MediaStore(videosRoot: temporaryVideosRoot())
        let generation = try await store.open(key: "1", identity: identity)
        try await put(store, key: "1", DownloadByteRange(start: 0, end: 99), generation: generation, from: body)
        #expect(try await store.promoteIfComplete(key: "1") == false)
        try body.write(to: store.finishedURL(key: "2"))
        #expect(try await store.promoteIfComplete(key: "2"))
    }

    @Test func discardAllForAVideoKeepsOtherVideos() async throws {
        let store = MediaStore(videosRoot: temporaryVideosRoot())
        for key in ["23", "23:4", "24:1"] { _ = try await store.open(key: key, identity: identity) }
        await store.discardAll(videoId: 23)
        #expect(await store.manifest(key: "23") == nil)
        #expect(await store.manifest(key: "23:4") == nil)
        #expect(await store.manifest(key: "24:1") != nil)
    }
}
