import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Media store core")
struct MediaStoreTests {
    private let identity = MediaIdentity(etag: "\"e1\"", totalByteCount: 1000)
    private let body = sampleBody(1000)

    private func makeStore(tuning: MediaStore.Tuning = .init()) -> (MediaStore, URL) {
        let root = temporaryVideosRoot()
        return (MediaStore(videosRoot: root, tuning: tuning), root)
    }

    @Test func openCreatesAnEntryForTheIdentity() async throws {
        let (store, _) = makeStore()
        _ = try await store.open(key: "1", identity: identity)
        let manifest = try #require(await store.manifest(key: "1"))
        #expect(manifest.identity == identity)
        #expect(manifest.committed.runs.isEmpty)
        #expect(manifest.pin == nil)
        #expect(FileManager.default.fileExists(atPath: store.dataURL(key: "1").path))
        #expect(await store.verifiedIdentity(key: "1")?.identity == identity)
    }

    @Test func availabilityIsTheContiguousCommittedRun() async throws {
        let (store, _) = makeStore()
        let generation = try await store.open(key: "1", identity: identity)
        try await put(store, key: "1", DownloadByteRange(start: 0, end: 99), generation: generation, from: body)
        try await put(store, key: "1", DownloadByteRange(start: 200, end: 299), generation: generation, from: body)
        #expect(await store.available(key: "1", from: 0)?.bytes == 100)
        #expect(await store.available(key: "1", from: 50)?.bytes == 50)
        #expect(await store.available(key: "1", from: 100)?.bytes == 0)
        #expect(await store.available(key: "1", from: 250)?.bytes == 50)
        #expect(await store.available(key: "missing", from: 0) == nil)
    }

    @Test func aLaterClaimShortensTheOneItLandsIn() async throws {
        let (store, _) = makeStore()
        _ = try await store.open(key: "1", identity: identity)
        guard case .granted(let first) = await store.claim(
            key: "1", from: 0, through: 999, owner: .download, waitWithin: 0
        ) else { Issue.record("first claim refused"); return }
        #expect(first.end == 999)
        guard case .granted(let second) = await store.claim(
            key: "1", from: 500, through: 999, owner: .playback, waitWithin: 0
        ) else { Issue.record("second claim refused"); return }
        #expect(second.end == 999)
        let claims = await store.claims(key: "1")
        #expect(claims.map(\.cursor) == [0, 500])
        #expect(claims.map(\.end) == [499, 999])
    }

    @Test func aClaimStopsAtCommittedAndClaimedBytes() async throws {
        let (store, _) = makeStore()
        let generation = try await store.open(key: "1", identity: identity)
        try await put(store, key: "1", DownloadByteRange(start: 600, end: 699), generation: generation, from: body)
        guard case .granted(let head) = await store.claim(
            key: "1", from: 0, through: 999, owner: .download, waitWithin: 0
        ) else { Issue.record("refused"); return }
        #expect(head.end == 599)
        #expect(await store.claim(key: "1", from: 650, through: 999, owner: .download, waitWithin: 0)
                == .alreadyCommitted)
        guard case .granted(let tail) = await store.claim(
            key: "1", from: 700, through: 999, owner: .download, waitWithin: 0
        ) else { Issue.record("refused"); return }
        #expect(tail.end == 999)
    }

    @Test func aFetcherCloseBehindCoversTheByte() async throws {
        let (store, _) = makeStore()
        _ = try await store.open(key: "1", identity: identity)
        _ = await store.claim(key: "1", from: 0, through: 999, owner: .download, waitWithin: 0)
        guard case .covered(let holder, _) = await store.claim(
            key: "1", from: 50, through: 999, owner: .playback, waitWithin: 100
        ) else { Issue.record("expected covered"); return }
        #expect(holder.cursor == 0)
        #expect(await store.claims(key: "1").count == 1)
    }

    @Test func anIdleClaimIsTakenOverAtItsCursor() async throws {
        let (store, _) = makeStore()
        _ = try await store.open(key: "1", identity: identity)
        guard case .granted(let parked) = await store.claim(
            key: "1", from: 0, through: 999, owner: .playback, waitWithin: 0
        ) else { Issue.record("refused"); return }
        await store.setClaimIdle(key: "1", id: parked.id, idle: true)
        guard case .granted(let taken) = await store.claim(
            key: "1", from: 0, through: 999, owner: .download, waitWithin: 0
        ) else { Issue.record("idle claim was not taken over"); return }
        #expect(taken.cursor == 0 && taken.end == 999)
        #expect(await store.claimSnapshot(key: "1", id: parked.id) == nil)
    }

    @Test func aWaiterIsWokenByACommit() async throws {
        let (store, _) = makeStore()
        let generation = try await store.open(key: "1", identity: identity)
        let seen = await store.version(key: "1")
        let woke = Task { await store.waitForChange(key: "1", after: seen); return true }
        try await Task.sleep(for: .milliseconds(20))
        try await put(store, key: "1", DownloadByteRange(start: 0, end: 9), generation: generation, from: body)
        #expect(await woke.value)
    }

    @Test func aCancelledWaiterReturns() async throws {
        let (store, _) = makeStore()
        _ = try await store.open(key: "1", identity: identity)
        let seen = await store.version(key: "1")
        let waiter = Task { await store.waitForChange(key: "1", after: seen) }
        try await Task.sleep(for: .milliseconds(20))
        waiter.cancel()
        await waiter.value
    }

    @Test func aCommitFromAnOldGenerationIsStale() async throws {
        let (store, _) = makeStore()
        let generation = try await store.open(key: "1", identity: identity)
        guard case .granted(let claim) = await store.claim(
            key: "1", from: 0, through: 99, owner: .download, waitWithin: 0
        ) else { Issue.record("refused"); return }
        #expect(try await store.commit(key: "1", claim: claim.id, generation: generation + 1, through: 9) == .stale)
        #expect(try await store.commit(key: "1", claim: claim.id, generation: generation, through: 9)
                == .continueThrough(99))
        await #expect(throws: MediaStoreError.commitOutsideClaim) {
            _ = try await store.commit(key: "1", claim: claim.id, generation: generation, through: 5)
        }
    }

    @Test func aDifferentIdentityResetsTheEntry() async throws {
        let (store, _) = makeStore()
        let generation = try await store.open(key: "1", identity: identity)
        try await put(store, key: "1", DownloadByteRange(start: 0, end: 99), generation: generation, from: body)
        let changed = MediaIdentity(etag: "\"e2\"", totalByteCount: 2000)
        let next = try await store.open(key: "1", identity: changed)
        #expect(next != generation)
        #expect(await store.available(key: "1", from: 0)?.bytes == 0)
        #expect(await store.manifest(key: "1")?.identity == changed)
    }

    @Test func closingTheLastHolePromotesTheFile() async throws {
        let (store, _) = makeStore()
        let generation = try await store.open(key: "7:2", identity: identity)
        try await put(store, key: "7:2", DownloadByteRange(start: 0, end: 499), generation: generation, from: body)
        guard case .granted(let last) = await store.claim(
            key: "7:2", from: 500, through: 999, owner: .download, waitWithin: 0
        ) else { Issue.record("refused"); return }
        let handle = try FileHandle(forWritingTo: store.dataURL(key: "7:2"))
        try handle.seek(toOffset: 500)
        try handle.write(contentsOf: body.subdata(in: 500..<1000))
        try handle.close()
        #expect(try await store.commit(key: "7:2", claim: last.id, generation: generation, through: 999) == .promoted)
        let finished = store.finishedURL(key: "7:2")
        #expect(finished.lastPathComponent == "7.v2.mp4")
        #expect(try Data(contentsOf: finished) == body)
        #expect(!FileManager.default.fileExists(atPath: store.entryDir(key: "7:2").path))
        #expect(await store.manifest(key: "7:2") == nil)
    }

    @Test func committedRangesSurviveANewStore() async throws {
        var tuning = MediaStore.Tuning()
        tuning.manifestFlushBytes = 1
        let (store, root) = makeStore(tuning: tuning)
        let generation = try await store.open(key: "1", identity: identity)
        try await put(store, key: "1", DownloadByteRange(start: 0, end: 99), generation: generation, from: body)
        let reopened = MediaStore(videosRoot: root)
        let manifest = try #require(await reopened.manifest(key: "1"))
        #expect(manifest.committed.totalBytes == 100)
        #expect(await reopened.verifiedIdentity(key: "1") == nil, "a new process probes again")
    }

    @Test func claimForDownloadSplitsAnEmptyFileIntoFour() async throws {
        let (store, _) = makeStore()
        _ = try await store.open(key: "1", identity: MediaIdentity(etag: "\"e\"", totalByteCount: 23))
        let claims = await store.claimForDownload(key: "1", slots: 4, minPiece: 1)
        #expect(claims.map { "\($0.cursor)-\($0.end)" }.sorted() == ["0-4", "11-16", "17-22", "5-10"])
    }

    @Test func aCommitPastAShortenedClaimIsClamped() async throws {
        let (store, _) = makeStore()
        let generation = try await store.open(key: "1", identity: identity)
        guard case .granted(let first) = await store.claim(
            key: "1", from: 0, through: 999, owner: .download, waitWithin: 0
        ) else { Issue.record("refused"); return }
        _ = await store.claim(key: "1", from: 500, through: 999, owner: .playback, waitWithin: 0)
        let handle = try FileHandle(forWritingTo: store.dataURL(key: "1"))
        try handle.write(contentsOf: body.subdata(in: 0..<800))
        try handle.close()
        #expect(try await store.commit(key: "1", claim: first.id, generation: generation, through: 799) == .finished)
        #expect(await store.available(key: "1", from: 0)?.bytes == 500)
        // The claim is gone now; a late commit is just finished.
        #expect(try await store.commit(key: "1", claim: first.id, generation: generation, through: 799) == .finished)
    }

    @Test func aFailedPromotionWakesWaitersAndIsRetried() async throws {
        let (store, root) = makeStore()
        let generation = try await store.open(key: "1", identity: identity)
        guard case .granted(let claim) = await store.claim(
            key: "1", from: 0, through: 999, owner: .download, waitWithin: 0
        ) else { Issue.record("refused"); return }
        let handle = try FileHandle(forWritingTo: store.dataURL(key: "1"))
        try handle.write(contentsOf: body)
        try handle.close()
        let seen = await store.version(key: "1")
        let woke = Task { await store.waitForChange(key: "1", after: seen); return true }
        try await Task.sleep(for: .milliseconds(20))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        await #expect(throws: MediaStoreError.promotionFailed) {
            _ = try await store.commit(key: "1", claim: claim.id, generation: generation, through: 999)
        }
        #expect(await woke.value)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        _ = try await store.open(key: "1", identity: identity)
        #expect(try Data(contentsOf: store.finishedURL(key: "1")) == body)
        #expect(!FileManager.default.fileExists(atPath: store.entryDir(key: "1").path))
    }

    @Test func aFinishedFileOfTheWrongSizeIsDropped() async throws {
        let (store, _) = makeStore()
        try body.prefix(10).write(to: store.finishedURL(key: "1"))
        _ = try await store.open(key: "1", identity: identity)
        #expect(!FileManager.default.fileExists(atPath: store.finishedURL(key: "1").path))
        #expect(await store.available(key: "1", from: 0)?.bytes == 0)
        #expect(await store.manifest(key: "1")?.identity == identity)
    }

    @Test func aFinishedFileOfTheRightSizeIsServed() async throws {
        let (store, _) = makeStore()
        try body.write(to: store.finishedURL(key: "1"))
        _ = try await store.open(key: "1", identity: identity)
        #expect(await store.available(key: "1", from: 0)?.bytes == 1000)
    }
}
