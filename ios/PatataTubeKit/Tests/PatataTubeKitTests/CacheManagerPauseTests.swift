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
        // Releasing matters beyond this test: a handler left blocked holds a
        // CFNetwork loader thread for the rest of the process, and the pool is
        // shared, so it stalls unrelated tests' sessions too.
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
        // Range requests never respond: the segments stay in flight while we
        // pause.
        //
        // Known pre-existing gap, left as-is deliberately: the probe is
        // `bytes=0-0`, so it *does* carry a Range header and hangs here too,
        // which means no manifest is ever written and this expectation fails
        // when the suite is run filtered. It fails identically on the commit
        // before this work. Answering the probe fixes it but destabilises
        // `pausingRecordsTheEntryAndKeepsThePermit`,
        // `pausingAndResumingALiveDownloadBalancesTheGate` and
        // `droppingAStalePausedEntryReleasesItsPermit`, because
        // `MockURLProtocol.handler` is one global that every parallel test
        // overwrites. Untangling that shared stub is its own change.
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
        // See the note in `pausingRecordsTheEntryAndKeepsThePermit`: a handler
        // left blocked holds a shared loader thread for the whole test process.
        defer {
            MockURLProtocol.handler = nil
            releaseRequest.signal()
        }

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

/// One-shot latch so a chunk callback fires its side effect exactly once.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}

/// Size of a segment's part file, or 0 when it does not exist yet.
private func partByteCount(root: URL, cacheKey: String, index: Int = 0) -> Int64 {
    let url = SegmentedDownloadStore(root: root, fileManager: .default)
        .partURL(cacheKey: cacheKey, index: index)
    return ((try? FileManager.default.attributesOfItem(
        atPath: url.path
    )[.size]) as? NSNumber)?.int64Value ?? 0
}

/// Waits until a segment's part file has at least `byteCount` bytes on disk.
///
/// Tests drive the cut *from observed durable state* rather than from a
/// sleep: the stub stalls mid-body until this returns, so the assertion that
/// bytes survived never races the delegate queue, however loaded the machine.
private func awaitPartByteCount(
    root: URL,
    cacheKey: String,
    atLeast byteCount: Int64,
    timeout: Duration = .seconds(20)
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if partByteCount(root: root, cacheKey: cacheKey) >= byteCount {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

extension CacheManagerPauseTests {
    /// The whole point of the part-file transport: a paused segment resumes
    /// from the bytes already on disk instead of re-requesting from zero.
    /// URLSession hands back no resume data for a deliberate cancel, so before
    /// this the second request was always `bytes=0-…` and the transfer
    /// restarted.
    @Test func resumeContinuesFromPersistedBytesNotZero() async throws {
        let root = temporaryRoot()
        let path = "/91.mp4"
        defer { ChunkedRangeProtocol.reset(path: path) }

        let total = 1_048_576
        let body = Data((0..<total).map { UInt8($0 % 251) })
        let manager = CacheManager(
            root: root,
            configuration: ChunkedRangeProtocol.configuration(),
            fileManager: .default
        )
        let remote = URL(string: "https://example.com\(path)")!
        let stallOnce = OnceFlag()
        // The stub holds the connection open at a quarter of the body until the
        // test has seen those bytes land, then cuts it.
        let cut = DispatchSemaphore(value: 0)
        ChunkedRangeProtocol.stub(path: path, plan: .init(
            fullBody: body,
            etag: "\"continuation\"",
            chunkSize: 32_768,
            failureError: URLError(.cancelled),
            afterChunk: { delivered in
                guard delivered >= 262_144, stallOnce.claim() else { return true }
                cut.wait()
                return false
            }
        ))
        defer { cut.signal() }

        let download = Task { try await manager.download(id: 91, from: remote, streamCount: 1) }
        #expect(await awaitPartByteCount(root: root, cacheKey: "91", atLeast: 262_144))
        manager.pause(
            id: 91, versionId: nil, remote: remote, isHLS: false,
            streamCount: 1, preview: nil, showPosterKey: nil, showPoster: nil
        )
        cut.signal()
        _ = try? await download.value

        let store = SegmentedDownloadStore(root: root, fileManager: .default)
        let partSize = partByteCount(root: root, cacheKey: "91")
        #expect(partSize > 0)
        #expect(partSize < Int64(total))
        let paused = try store.load(cacheKey: "91")
        #expect(paused.segments[0].persistedByteCount == partSize)
        #expect(paused.segments[0].isComplete == false)

        try await manager.resume(id: 91)

        // The resumed request asked for the tail, not the whole file.
        let ranges = ChunkedRangeProtocol.recordedRanges(path: path)
        #expect(ranges.last == "bytes=\(partSize)-\(total - 1)")
        #expect(ranges.contains("bytes=0-0"))   // the probe, once
        #expect(try Data(contentsOf: manager.localURL(for: 91)) == body)
        #expect(manager.state(for: 91) == .cached)
        #expect(PausedDownloadStore(root: root).contains("91") == false)
    }

    /// The same continuation rule on the in-attempt retry path: a transient
    /// transport blip re-requests only the bytes the part file does not
    /// already hold, instead of discarding the segment's progress.
    @Test func aRetriedSegmentContinuesFromItsPartFile() async throws {
        let root = temporaryRoot()
        let path = "/92.mp4"
        defer { ChunkedRangeProtocol.reset(path: path) }

        let total = 1_048_576
        let body = Data((0..<total).map { UInt8($0 % 251) })
        let manager = CacheManager(
            root: root,
            configuration: ChunkedRangeProtocol.configuration(),
            fileManager: .default
        )
        let remote = URL(string: "https://example.com\(path)")!
        let blipOnce = OnceFlag()
        let cut = DispatchSemaphore(value: 0)
        ChunkedRangeProtocol.stub(path: path, plan: .init(
            fullBody: body,
            etag: "\"retry\"",
            chunkSize: 32_768,
            failureError: URLError(.networkConnectionLost),
            afterChunk: { delivered in
                guard delivered >= 262_144, blipOnce.claim() else { return true }
                cut.wait()
                return false
            }
        ))
        defer { cut.signal() }

        let download = Task { try await manager.download(id: 92, from: remote, streamCount: 1) }
        #expect(await awaitPartByteCount(root: root, cacheKey: "92", atLeast: 262_144))
        cut.signal()
        try await download.value

        let ranges = ChunkedRangeProtocol.recordedRanges(path: path)
        // probe, first attempt, retry — and the retry starts mid-file.
        #expect(ranges.count == 3)
        #expect(ranges.first == "bytes=0-0")
        #expect(ranges[1] == "bytes=0-\(total - 1)")
        let retryStart = ranges[2]
            .dropFirst("bytes=".count)
            .prefix { $0 != "-" }
        #expect(Int(retryStart) ?? 0 > 0)
        #expect(ranges[2] == "bytes=\(retryStart)-\(total - 1)")
        #expect(try Data(contentsOf: manager.localURL(for: 92)) == body)
        #expect(manager.state(for: 92) == .cached)
    }
}
