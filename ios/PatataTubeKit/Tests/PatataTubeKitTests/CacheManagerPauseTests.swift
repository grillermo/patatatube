import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Cache manager pause")
struct CacheManagerPauseTests {
    fileprivate func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pause-cache-\(UUID().uuidString)")
    }

    fileprivate func pausedEntry(
        videoID: Int,
        versionID: Int? = nil,
        progress: Double = 0.4
    ) -> PausedDownload {
        PausedDownload(
            videoID: videoID,
            versionID: versionID,
            remoteURL: URL(string: "https://example.com/\(videoID).mp4")!,
            isHLS: false,
            streamCount: 2,
            previewURL: nil,
            showPosterKey: nil,
            showPosterURL: nil,
            progress: progress,
            transferredByteCount: 400,
            totalByteCount: 1_000
        )
    }

    /// Seeds a paused entry on disk, then builds a manager over that root so it
    /// loads the entry at init — the "app was quit while paused" case.
    fileprivate func managerWithPausedEntry(
        _ entry: PausedDownload,
        root: URL
    ) -> CacheManager {
        var store = PausedDownloadStore(root: root)
        store.insert(entry)
        return CacheManager(
            root: root,
            configuration: .ephemeral,
            fileManager: .default
        )
    }

    @Test func pausedEntriesAppearInActiveDownloadsAsPaused() {
        let root = temporaryRoot()
        let manager = managerWithPausedEntry(pausedEntry(videoID: 7, versionID: 2), root: root)

        let activities = manager.activeDownloads()
        #expect(activities.count == 1)
        #expect(activities.first?.videoID == 7)
        #expect(activities.first?.versionID == 2)
        #expect(activities.first?.isPaused == true)
        #expect(activities.first?.progress == 0.4)
    }

    @Test func pausedEntriesDoNotMoveTheByteCounter() {
        let root = temporaryRoot()
        let manager = managerWithPausedEntry(pausedEntry(videoID: 7), root: root)
        #expect(manager.downloadedByteCount() == 0)
    }

    @Test func aPausedKeyStillReadsAsDownloading() {
        let root = temporaryRoot()
        let manager = managerWithPausedEntry(pausedEntry(videoID: 7, progress: 0.4), root: root)
        guard case .downloading(let progress) = manager.state(for: 7) else {
            Issue.record("expected .downloading, got \(manager.state(for: 7))")
            return
        }
        #expect(progress == 0.4)
    }

    @Test func aPausedEntryWhoseFileLandedIsDropped() throws {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = managerWithPausedEntry(pausedEntry(videoID: 7), root: root)
        try Data("mp4".utf8).write(to: manager.localURL(for: 7))

        #expect(manager.activeDownloads().isEmpty)
        #expect(PausedDownloadStore(root: root).contains("7") == false)
    }
}

private final class PauseSpyGate: DownloadConcurrencyGating, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var acquireCount = 0
    private(set) var releaseCount = 0
    private var limit = 3

    func acquire() async { lock.withLock { acquireCount += 1 } }
    func release() { lock.withLock { releaseCount += 1 } }
    func setLimit(_ n: Int) { lock.withLock { limit = max(n, 1) } }
    var currentLimit: Int { lock.withLock { limit } }
}

extension CacheManagerPauseTests {
    @Test func aStoredPausedEntryReservesAPermitAtLaunch() async throws {
        let root = temporaryRoot()
        var store = PausedDownloadStore(root: root)
        store.insert(pausedEntry(videoID: 7))
        let spy = PauseSpyGate()
        let manager = CacheManager(
            root: root,
            configuration: .ephemeral,
            fileManager: .default,
            concurrencyGate: spy
        )
        // The reservation runs in a detached task; wait for it to be granted.
        await manager.awaitPermit(for: "7")

        #expect(spy.acquireCount == 1)
        #expect(spy.releaseCount == 0)
    }

    @Test func releasingAPausedPermitReturnsItToTheGate() async throws {
        let root = temporaryRoot()
        var store = PausedDownloadStore(root: root)
        store.insert(pausedEntry(videoID: 7))
        let spy = PauseSpyGate()
        let manager = CacheManager(
            root: root,
            configuration: .ephemeral,
            fileManager: .default,
            concurrencyGate: spy
        )
        await manager.awaitPermit(for: "7")
        manager.releasePausedPermit(for: "7")

        #expect(spy.releaseCount == 1)
    }
}

extension CacheManagerPauseTests {
    @Test func pausingRecordsTheEntryAndKeepsThePermit() async throws {
        let root = temporaryRoot()
        let spy = PauseSpyGate()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        // Never responds: the download stays in flight while we pause it.
        let releaseRequest = DispatchSemaphore(value: 0)
        MockURLProtocol.handler = { _ in
            releaseRequest.wait()
            throw URLError(.timedOut)
        }
        defer { MockURLProtocol.handler = nil }

        let manager = CacheManager(
            root: root,
            configuration: config,
            fileManager: .default,
            concurrencyGate: spy
        )
        let remote = URL(string: "https://example.com/7.mp4")!
        let download = Task { try await manager.download(id: 7, from: remote) }
        // Let the probe register the key in `inFlight`.
        try await Task.sleep(for: .milliseconds(200))

        manager.pause(
            id: 7, versionId: nil, remote: remote, isHLS: false, streamCount: 1,
            preview: nil, showPosterKey: nil, showPoster: nil
        )
        _ = try? await download.value

        #expect(PausedDownloadStore(root: root).contains("7"))
        #expect(manager.activeDownloads().first?.isPaused == true)
        // Acquired once for the download; never released, because it is paused.
        #expect(spy.acquireCount == 1)
        #expect(spy.releaseCount == 0)
    }

    @Test func pausingASegmentedDownloadKeepsItsManifest() async throws {
        let root = temporaryRoot()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let total = 4_000
        // Range requests never respond: the segments stay in flight while we pause.
        let releaseRequest = DispatchSemaphore(value: 0)
        MockURLProtocol.handler = { request in
            if request.httpMethod == "HEAD" || request.value(forHTTPHeaderField: "Range") == nil {
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: [
                        "Content-Length": "\(total)",
                        "Accept-Ranges": "bytes",
                        "ETag": "\"abc\"",
                    ]
                )!
                return (response, Data())
            }
            releaseRequest.wait()
            throw URLError(.timedOut)
        }
        defer { MockURLProtocol.handler = nil }

        let manager = CacheManager(root: root, configuration: config, fileManager: .default)
        let remote = URL(string: "https://example.com/7.mp4")!
        let download = Task {
            try await manager.download(id: 7, from: remote, streamCount: 2)
        }
        try await Task.sleep(for: .milliseconds(300))

        manager.pause(
            id: 7, versionId: nil, remote: remote, isHLS: false, streamCount: 2,
            preview: nil, showPosterKey: nil, showPoster: nil
        )
        _ = try? await download.value

        let manifest = SegmentedDownloadStore(root: root, fileManager: .default)
            .manifestURL(cacheKey: "7")
        #expect(FileManager.default.fileExists(atPath: manifest.path))
    }
}

extension CacheManagerPauseTests {
    @Test func resumingClearsTheEntryAndReusesTheHeldPermit() async throws {
        let root = temporaryRoot()
        let spy = PauseSpyGate()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        defer { MockURLProtocol.handler = nil }

        var store = PausedDownloadStore(root: root)
        store.insert(pausedEntry(videoID: 7))
        let manager = CacheManager(
            root: root,
            configuration: config,
            fileManager: .default,
            concurrencyGate: spy
        )
        await manager.awaitPermit(for: "7")
        #expect(spy.acquireCount == 1)

        // The transfer itself fails (offline), but resume must still consume the
        // entry and hand the reserved permit back exactly once.
        try? await manager.resume(id: 7)

        #expect(PausedDownloadStore(root: root).contains("7") == false)
        #expect(manager.activeDownloads().isEmpty)
        #expect(spy.acquireCount == 1)   // no second acquire
        #expect(spy.releaseCount == 1)
    }

    /// The live-handover shape, end to end: no launch-restored entry, no
    /// reservation — the permit is the one the finishing `download` handed to
    /// the paused table. One acquire, one release, across the whole cycle.
    @Test func pausingAndResumingALiveDownloadBalancesTheGate() async throws {
        let root = temporaryRoot()
        let spy = PauseSpyGate()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        // Never responds: the download is genuinely in flight when we pause it.
        let releaseRequest = DispatchSemaphore(value: 0)
        MockURLProtocol.handler = { _ in
            releaseRequest.wait()
            throw URLError(.timedOut)
        }
        defer {
            MockURLProtocol.handler = nil
            releaseRequest.signal()
        }

        let manager = CacheManager(
            root: root,
            configuration: config,
            fileManager: .default,
            concurrencyGate: spy
        )
        let remote = URL(string: "https://example.com/7.mp4")!
        let download = Task { try await manager.download(id: 7, from: remote) }
        try await Task.sleep(for: .milliseconds(200))

        manager.pause(
            id: 7, versionId: nil, remote: remote, isHLS: false, streamCount: 1,
            preview: nil, showPosterKey: nil, showPoster: nil
        )
        _ = try? await download.value
        #expect(spy.acquireCount == 1)
        #expect(spy.releaseCount == 0)   // handed over to the paused entry

        // The resumed transfer fails immediately; what matters is that it
        // reuses the held permit and returns it exactly once.
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        try? await manager.resume(id: 7)

        #expect(PausedDownloadStore(root: root).contains("7") == false)
        #expect(manager.activeDownloads().isEmpty)
        #expect(spy.acquireCount == 1)
        #expect(spy.releaseCount == 1)
    }

    /// A pause that raced a completion: the file lands while the entry is
    /// paused. Dropping the stale entry must also return the permit the
    /// finishing download handed over, or the gate slot is gone for good.
    @Test func droppingAStalePausedEntryReleasesItsPermit() async throws {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        let spy = PauseSpyGate()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let releaseRequest = DispatchSemaphore(value: 0)
        MockURLProtocol.handler = { _ in
            releaseRequest.wait()
            throw URLError(.timedOut)
        }
        defer {
            MockURLProtocol.handler = nil
            releaseRequest.signal()
        }

        let manager = CacheManager(
            root: root,
            configuration: config,
            fileManager: .default,
            concurrencyGate: spy
        )
        let remote = URL(string: "https://example.com/7.mp4")!
        let download = Task { try await manager.download(id: 7, from: remote) }
        try await Task.sleep(for: .milliseconds(200))

        manager.pause(
            id: 7, versionId: nil, remote: remote, isHLS: false, streamCount: 1,
            preview: nil, showPosterKey: nil, showPoster: nil
        )
        _ = try? await download.value
        #expect(spy.releaseCount == 0)

        // The file landed anyway — the paused row is now stale.
        try Data("mp4".utf8).write(to: manager.localURL(for: 7))

        #expect(manager.activeDownloads().isEmpty)
        #expect(PausedDownloadStore(root: root).contains("7") == false)
        #expect(spy.releaseCount == 1)
    }

    @Test func resumingAnUnknownKeyDoesNothing() async throws {
        let manager = CacheManager(
            root: temporaryRoot(),
            configuration: .ephemeral,
            fileManager: .default
        )
        try await manager.resume(id: 999)
        #expect(manager.activeDownloads().isEmpty)
    }
}

extension CacheManagerPauseTests {
    @Test func resumeInterruptedSkipsPausedKeys() async throws {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // A paused plain download leaves exactly this artifact behind.
        try Data("resume-bytes".utf8).write(to: root.appendingPathComponent("7.resume"))
        var store = PausedDownloadStore(root: root)
        store.insert(pausedEntry(videoID: 7))

        let manager = CacheManager(
            root: root, configuration: .ephemeral, fileManager: .default
        )
        #expect(manager.resumeInterrupted().isEmpty)
        #expect(manager.activeDownloads().first?.isPaused == true)
    }

    @Test func cancellingAPausedEntryClearsItAndItsPermit() async throws {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("resume-bytes".utf8).write(to: root.appendingPathComponent("7.resume"))
        var store = PausedDownloadStore(root: root)
        store.insert(pausedEntry(videoID: 7))
        let spy = PauseSpyGate()
        let manager = CacheManager(
            root: root, configuration: .ephemeral, fileManager: .default,
            concurrencyGate: spy
        )
        await manager.awaitPermit(for: "7")

        manager.cancel(id: 7)

        #expect(PausedDownloadStore(root: root).contains("7") == false)
        #expect(manager.activeDownloads().isEmpty)
        #expect(spy.releaseCount == 1)
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("7.resume").path
            ) == false
        )
    }

    @Test func clearingAllVideosDropsPausedEntries() async throws {
        let root = temporaryRoot()
        var store = PausedDownloadStore(root: root)
        store.insert(pausedEntry(videoID: 7))
        let spy = PauseSpyGate()
        let manager = CacheManager(
            root: root, configuration: .ephemeral, fileManager: .default,
            concurrencyGate: spy
        )
        await manager.awaitPermit(for: "7")

        manager.clearAllVideos()

        #expect(PausedDownloadStore(root: root).entries.isEmpty)
        #expect(manager.activeDownloads().isEmpty)
        #expect(spy.releaseCount == 1)
    }

    @Test func aPausedDownloadIsTreatedAsACancellation() async {
        #expect(await VideoStore.isCancellation(DownloadPausedError()))
    }
}
