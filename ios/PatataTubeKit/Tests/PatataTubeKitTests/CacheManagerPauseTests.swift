import Foundation
import Testing
@testable import PatataTubeKit

/// Grants at once and counts, so a test can see a permit held or returned.
private final class RecordingGate: DownloadConcurrencyGating, @unchecked Sendable {
    private let lock = NSLock()
    private var acquires = 0
    private var releases = 0
    func acquire() async { lock.withLock { acquires += 1 } }
    func release() { lock.withLock { releases += 1 } }
    func setLimit(_ n: Int) {}
    var currentLimit: Int { 3 }
    var counts: (acquires: Int, releases: Int) { lock.withLock { (acquires, releases) } }
}

@Suite("Cache manager pause, resume and cancel")
struct CacheManagerPauseTests {
    private func manager(root: URL, gate: any DownloadConcurrencyGating = DownloadConcurrencyGate(limit: 3)) -> CacheManager {
        CacheManager(
            root: root, configuration: ChunkedRangeProtocol.configuration(), fileManager: .default,
            concurrencyGate: gate, fetchTuning: DownloadTuning(minPiece: 1_048_576, commitSize: 64)
        )
    }

    private func pinnedManifest(key: String, path: String, paused: Bool,
                                identity: MediaIdentity? = nil, committed: ByteRangeSet = ByteRangeSet()) -> MediaEntryManifest {
        MediaEntryManifest(
            key: key, identity: identity, committed: committed,
            pin: PinState(job: DownloadJobParameters(
                remoteURL: URL(string: "https://srv.test\(path)")!, streamCount: 1,
                previewURL: nil, showPosterKey: nil, showPosterURL: nil
            ), paused: paused),
            lastAccess: Date()
        )
    }

    @Test func pausingKeepsTheBytesAndResumeFetchesOnlyTheRest() async throws {
        let root = temporaryVideosRoot("pause")
        let path = "/videos/81/stream"
        let payload = sampleBody(4096)
        let manager = manager(root: root)
        let paused = Flag()
        ChunkedRangeProtocol.stub(path: path, plan: .init(
            fullBody: payload, etag: "\"p81\"", chunkSize: 64,
            failureError: URLError(.networkConnectionLost),
            afterChunk: { delivered in
                if delivered >= 1024, paused.setOnce() {
                    manager.pause(id: 81, remote: URL(string: "https://srv.test\(path)")!, streamCount: 1)
                }
                return true
            }
        ))
        defer { ChunkedRangeProtocol.reset(path: path) }

        await #expect(throws: DownloadPausedError.self) {
            try await manager.download(id: 81, from: URL(string: "https://srv.test\(path)")!)
        }
        await manager.settleStoreWork()
        let manifest = try #require(await manager.mediaStore.manifest(key: "81"))
        #expect(manifest.pin?.paused == true)
        let kept = manifest.committed.totalBytes
        #expect(kept >= 64 && kept < 4096)
        #expect(manager.activeDownloads().map(\.isPaused) == [true])
        if case .downloading = manager.state(for: 81) {} else {
            Issue.record("a paused download should read as downloading, got \(manager.state(for: 81))")
        }

        try await manager.resume(id: 81)

        #expect(try Data(contentsOf: manager.localURL(for: 81)) == payload)
        let ranges = ChunkedRangeProtocol.recordedRanges(path: path).filter { $0 != "bytes=0-0" }
        #expect(ranges == ["bytes=0-4095", "bytes=\(kept)-4095"])
        #expect(manager.activeDownloads().isEmpty)
    }

    @Test func aPausedDownloadReloadsAsPaused() throws {
        let root = temporaryVideosRoot("pause")
        var committed = ByteRangeSet()
        committed.insert(DownloadByteRange(start: 0, end: 399))
        try MediaStore.writeManifest(
            pinnedManifest(key: "82", path: "/videos/82/stream", paused: true,
                           identity: MediaIdentity(etag: "\"e\"", totalByteCount: 1000), committed: committed),
            storeRoot: MediaStore.storeRoot(videosRoot: root)
        )
        let manager = manager(root: root)
        #expect(manager.activeDownloads() == [DownloadActivity(
            videoID: 82, versionID: nil, progress: 0.4, transferredByteCount: 400,
            totalByteCount: 1000, isPaused: true
        )])
        #expect(manager.state(for: 82) == .downloading(0.4))
    }

    @Test func aStoredPausedDownloadHoldsAPermitUntilCancelled() async throws {
        let root = temporaryVideosRoot("pause")
        try MediaStore.writeManifest(
            pinnedManifest(key: "83", path: "/videos/83/stream", paused: true),
            storeRoot: MediaStore.storeRoot(videosRoot: root)
        )
        let gate = RecordingGate()
        let manager = manager(root: root, gate: gate)
        #expect(await eventually { gate.counts.acquires == 1 })
        #expect(gate.counts.releases == 0)
        manager.cancel(id: 83)
        #expect(await eventually { gate.counts.releases == 1 })
        await manager.settleStoreWork()
        #expect(await manager.mediaStore.manifest(key: "83") == nil)
        #expect(manager.activeDownloads().isEmpty)
    }

    @Test func resumeInterruptedRestartsPinnedUnpausedDownloads() async throws {
        let root = temporaryVideosRoot("pause")
        let path = "/videos/84/stream"
        let payload = sampleBody(512)
        ChunkedRangeProtocol.stub(path: path, plan: .init(
            fullBody: payload, etag: "\"p84\"", chunkSize: 64,
            failureError: URLError(.networkConnectionLost), afterChunk: { _ in true }
        ))
        defer { ChunkedRangeProtocol.reset(path: path) }
        try MediaStore.writeManifest(
            pinnedManifest(key: "84", path: path, paused: false),
            storeRoot: MediaStore.storeRoot(videosRoot: root)
        )
        let manager = manager(root: root)
        #expect(manager.resumeInterrupted() == [84])
        #expect(await eventually { manager.state(for: 84) == .cached })
        #expect(try Data(contentsOf: manager.localURL(for: 84)) == payload)
    }

    @Test func resumeInterruptedLeavesPausedDownloadsAlone() throws {
        let root = temporaryVideosRoot("pause")
        try MediaStore.writeManifest(
            pinnedManifest(key: "86", path: "/videos/86/stream", paused: true),
            storeRoot: MediaStore.storeRoot(videosRoot: root)
        )
        #expect(manager(root: root).resumeInterrupted() == [])
    }

    @Test func cancellingWhileAPlayerReadsDefersTheDelete() async throws {
        let root = temporaryVideosRoot("pause")
        let manager = manager(root: root)
        let store = manager.mediaStore
        _ = try await store.open(key: "85", identity: MediaIdentity(etag: "\"e\"", totalByteCount: 100))
        await store.beginRead(key: "85")
        manager.cancel(id: 85)
        await manager.settleStoreWork()
        #expect(FileManager.default.fileExists(atPath: store.entryDir(key: "85").path))
        await store.endRead(key: "85")
        #expect(!FileManager.default.fileExists(atPath: store.entryDir(key: "85").path))
    }

    @Test func resumingAnUnknownKeyDoesNothing() async throws {
        let manager = manager(root: temporaryVideosRoot("pause"))
        try await manager.resume(id: 999)
        #expect(manager.state(for: 999) == .notCached)
    }
}
