import Foundation
import CryptoKit
import AVFoundation

public enum CacheState: Equatable, Sendable {
    case notCached
    case downloading(Double)
    /// Bytes on disk, nothing transferring. Re-downloading resumes from the gaps.
    case paused(Double)
    case cached
}

private final class RangeDownloadTask: @unchecked Sendable {
    let id = UUID()
    let task: Task<Void, Error>
    var completion: CheckedContinuation<Void, Error>?

    init(task: Task<Void, Error>) {
        self.task = task
    }
}

protocol CacheManagerCancellationFencing: Sendable {
    func beginCancellation(cacheKey: String)
    func endCancellation(cacheKey: String)
    func isCancellationRequested(cacheKey: String) -> Bool
    func performMutation(
        cacheKey: String,
        _ mutation: () throws -> Void
    ) throws
    func performTerminalClaim(
        cacheKey: String,
        _ claim: () -> Bool
    ) -> Bool
}

final class CacheManagerCancellationFence:
    CacheManagerCancellationFencing,
    @unchecked Sendable
{
    private let condition = NSCondition()
    private var cancellationRequestCounts: [String: Int] = [:]
    private var mutationKeys: Set<String> = []

    func beginCancellation(cacheKey: String) {
        condition.lock()
        cancellationRequestCounts[cacheKey, default: 0] += 1
        while mutationKeys.contains(cacheKey) {
            condition.wait()
        }
        condition.unlock()
    }

    func endCancellation(cacheKey: String) {
        condition.withLock {
            let remaining = (cancellationRequestCounts[cacheKey] ?? 1) - 1
            cancellationRequestCounts[cacheKey] = remaining > 0 ? remaining : nil
        }
    }

    func isCancellationRequested(cacheKey: String) -> Bool {
        condition.withLock {
            (cancellationRequestCounts[cacheKey] ?? 0) > 0
        }
    }

    func performMutation(
        cacheKey: String,
        _ mutation: () throws -> Void
    ) throws {
        condition.lock()
        guard (cancellationRequestCounts[cacheKey] ?? 0) == 0 else {
            condition.unlock()
            throw CancellationError()
        }
        mutationKeys.insert(cacheKey)
        condition.unlock()

        let result = Result { try mutation() }

        condition.lock()
        mutationKeys.remove(cacheKey)
        let cancelled = (cancellationRequestCounts[cacheKey] ?? 0) > 0
        condition.broadcast()
        condition.unlock()

        if cancelled {
            throw CancellationError()
        }
        try result.get()
    }

    func performTerminalClaim(
        cacheKey: String,
        _ claim: () -> Bool
    ) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard (cancellationRequestCounts[cacheKey] ?? 0) == 0 else {
            return false
        }
        return claim()
    }
}

public extension CacheManager {
    /// Everything the cache needs to serve or download one video's HLS package.
    struct PlaybackTarget: Sendable {
        public let id: Int
        public let versionId: Int?
        public let master: URL?
        public let bearerToken: String?
        public let title: String
        public let audioLang: String?
        public let hlsStatus: String

        public init(
            id: Int, versionId: Int?, master: URL?, bearerToken: String?,
            title: String, audioLang: String?, hlsStatus: String
        ) {
            self.id = id
            self.versionId = versionId
            self.master = master
            self.bearerToken = bearerToken
            self.title = title
            self.audioLang = audioLang
            self.hlsStatus = hlsStatus
        }
    }

    enum PlaybackAsset: Sendable, Equatable {
        case asset(AVURLAsset)
        case unplayable(reason: String)
    }
}

public final class CacheManager: NSObject, @unchecked Sendable {
    private let root: URL
    private let capturedStore: CapturedDownloadStore
    private var session: URLSession!
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private let cancellationFence: any CacheManagerCancellationFencing
    private let concurrencyGate: any DownloadConcurrencyGating
    private let waitBeforePublication: @Sendable () async -> Void
    private var inFlight: [String: DownloadActivityAccumulator] = [:]
    /// In-memory mirror of which cache keys have a persisted capture manifest on
    /// disk, mapped to their last-known progress. Read by `state(for:)` under the
    /// lock so a grid render never does per-cell disk I/O. Seeded once at init
    /// from `capturedStore.manifests()`, then kept current incrementally as
    /// capture progress is written and as manifests are removed.
    private var capturedManifestProgress: [String: Double] = [:]
    private var completionHistory: DownloadCompletionHistoryStore
    /// Live range downloads, keyed by cache key. Cancelling one stops its
    /// workers and leaves the partial on disk for a later resume.
    private var downloadTasks: [String: RangeDownloadTask] = [:]

    private let hlsStore: HLSAssetStore
    private var downloader: (any HLSDownloading)!
    /// Live fraction per cache key, mirrored so `state(for:)` never reads disk.
    private var hlsProgress: [String: Double] = [:]
    /// Continuations of explicit `download()` calls awaiting a terminal event.
    private var downloadWaiters: [String: CheckedContinuation<Void, Error>] = [:]
    private var tempCacheCapBytes: Int64 = 10 * 1_073_741_824
    /// The request behind a running download, kept until the store has an entry
    /// for it. AVFoundation's own delegate (`willDownloadTo`) creates that entry
    /// as soon as a real download starts — this is only the bridge for the gap
    /// between "download started" and "location known" (and the seam a fake
    /// downloader in tests never fills in on its own).
    private var pendingRequests: [String: HLSDownloadRequest] = [:]

    public convenience init(
        root: URL? = nil,
        configuration: URLSessionConfiguration = .default
    ) {
        self.init(
            root: root,
            configuration: configuration,
            fileManager: .default,
            cancellationFence: CacheManagerCancellationFence()
        )
    }

    init(
        root: URL?,
        configuration: URLSessionConfiguration,
        fileManager: FileManager,
        now: @escaping @Sendable () -> Date = Date.init,
        cancellationFence: any CacheManagerCancellationFencing =
            CacheManagerCancellationFence(),
        concurrencyGate: any DownloadConcurrencyGating =
            DownloadConcurrencyGate(limit: 3),
        waitBeforePublication: @escaping @Sendable () async -> Void = {},
        downloader: (any HLSDownloading)? = nil
    ) {
        self.fileManager = fileManager
        self.now = now
        self.cancellationFence = cancellationFence
        self.concurrencyGate = concurrencyGate
        self.waitBeforePublication = waitBeforePublication
        self.root = root ?? fileManager
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("videos")
        self.completionHistory = DownloadCompletionHistoryStore(
            root: self.root,
            fileManager: fileManager
        )
        self.capturedStore = CapturedDownloadStore(
            root: self.root,
            fileManager: fileManager
        )
        self.hlsStore = HLSAssetStore(root: self.root, fileManager: fileManager)
        super.init()
        self.session = URLSession(configuration: configuration)
        try? fileManager.createDirectory(at: self.root, withIntermediateDirectories: true)
        // Visible in the Files app (Documents), but keep it out of iCloud/device
        // backups - these MP4s are re-downloadable, not user data.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = self.root
        try? dir.setResourceValues(values)
        // Seed the capture-manifest cache once (an O(n) disk scan at startup, not
        // per render) so `state(for:)` can answer from memory afterward.
        for manifest in capturedStore.manifests() {
            capturedManifestProgress[manifest.cacheKey] = manifest.progress
        }
        self.downloader = downloader ?? HLSDownloadEngine(store: self.hlsStore)
        self.downloader.setEventHandler { [weak self] event in
            self?.handle(event)
        }
    }

    /// Sets the global cap on how many videos download at once.
    public func setMaxConcurrentDownloads(_ n: Int) {
        concurrencyGate.setLimit(n)
    }

    /// Current global simultaneous-download cap.
    public var maxConcurrentDownloads: Int {
        concurrencyGate.currentLimit
    }

    /// Location of the cached package. When nothing is cached this is where one
    /// would live, so callers can build a path without a nil check — check
    /// `state(for:)` before playing it.
    public func localURL(for id: Int, versionId: Int? = nil) -> URL {
        let key = cacheKey(videoId: id, versionId: versionId)
        if let entry = hlsStore.entry(cacheKey: key), let url = hlsStore.resolve(entry) {
            return url
        }
        return root.appendingPathComponent("hls-cache", isDirectory: true)
            .appendingPathComponent("\(key.replacingOccurrences(of: ":", with: ".")).movpkg")
    }

    /// Local file URL of a cached preview image, or nil if none is cached.
    ///
    /// Version-aware: the filename embeds a hash of the preview URL, which carries
    /// Plex's thumb version (`?v=`). A poster changed on Plex gets a new URL → new
    /// hash → this returns nil → the caller refetches the current poster. Passing
    /// `path: nil` falls back to a plain id match (no URL to key on).
    public func cachedPreviewURL(for id: Int, path: String?) -> URL? {
        let contents = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        let prefix = path.map { "\(id).preview.\(posterHash($0))." } ?? "\(id).preview."
        guard let name = contents.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return root.appendingPathComponent(name)
    }

    /// Writes preview bytes for a movie. Best-effort: failures leave the preview uncached.
    /// Any prior poster version for this movie is dropped so only the current one remains.
    public func storePreview(_ data: Data, for id: Int, path: String) {
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let prefix = "\(id).preview."
        for name in (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? [] where name.hasPrefix(prefix) {
            try? fileManager.removeItem(at: root.appendingPathComponent(name))
        }
        let destination = root.appendingPathComponent("\(id).preview.\(posterHash(path)).\(safeExt(from: path))")
        try? data.write(to: destination)
    }

    /// Local file URL of a cached show poster, or nil if none is cached.
    /// Keyed by the raw showPreviewUrl string so store and lookup always agree.
    public func cachedShowPosterURL(for key: String) -> URL? {
        let prefix = "poster.\(posterHash(key))."
        let contents = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        guard let name = contents.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return root.appendingPathComponent(name)
    }

    /// Writes poster bytes for a show. Best-effort: failures leave the poster uncached.
    public func storeShowPoster(_ data: Data, for key: String) {
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("poster.\(posterHash(key)).\(safeExt(from: key))")
        try? fileManager.removeItem(at: destination)
        try? data.write(to: destination)
    }

    /// Metadata-only: never touches disk, so a grid render never does per-cell
    /// disk I/O (same reasoning as `capturedManifestProgress` above). Whether the
    /// package is still physically present is checked only when it is actually
    /// about to be played, in `playbackAsset(for:isOnWiFi:hasNetwork:)`.
    public func state(for id: Int, versionId: Int? = nil) -> CacheState {
        let key = cacheKey(videoId: id, versionId: versionId)
        guard let entry = hlsStore.entry(cacheKey: key) else { return .notCached }
        if entry.kind == .permanent, entry.isComplete { return .cached }
        if downloader.isRunning(cacheKey: key) {
            return .downloading(lock.withLock { hlsProgress[key] ?? entry.fractionComplete })
        }
        return .paused(lock.withLock { hlsProgress[key] ?? entry.fractionComplete })
    }

    // MARK: Playback

    /// The asset the player should use, and the read-through cache's front door.
    /// On Wi-Fi this starts (or attaches to) a fill-ahead download and hands back
    /// *its* asset, so already-downloaded segments are read from disk and only
    /// the missing ones hit the network.
    public func playbackAsset(
        for target: PlaybackTarget, isOnWiFi: Bool, hasNetwork: Bool
    ) -> PlaybackAsset {
        let key = cacheKey(videoId: target.id, versionId: target.versionId)
        let entry = hlsStore.entry(cacheKey: key)
        let langMatches = entry.map { $0.audioLang == target.audioLang } ?? false

        switch PlaybackAssetProvider.decide(
            hlsStatus: target.hlsStatus, entry: entry,
            entryAudioLangMatches: langMatches,
            isOnWiFi: isOnWiFi, hasNetwork: hasNetwork
        ) {
        case .localPackage:
            guard let entry, let url = hlsStore.resolve(entry) else {
                return .unplayable(reason: "Cached package is gone")
            }
            touch(cacheKey: key)
            return .asset(AVURLAsset(url: url))

        case .fillAhead:
            // A stale-language package cannot be resumed — its segments carry the
            // wrong audio. Drop it and start clean.
            if entry != nil, !langMatches { hlsStore.remove(cacheKey: key) }
            guard let master = target.master else {
                return .unplayable(reason: "No server URL configured")
            }
            let request = HLSDownloadRequest(
                cacheKey: key, videoId: target.id, versionId: target.versionId,
                master: master, bearerToken: target.bearerToken, title: target.title,
                audioLang: target.audioLang, isFillAhead: true)
            guard let asset = downloader.start(request) else {
                return authedRemoteAsset(target: target)
            }
            lock.withLock {
                pendingRequests[key] = request
                if inFlight[key] == nil {
                    inFlight[key] = DownloadActivityAccumulator(
                        videoID: target.id, versionID: target.versionId,
                        totalByteCount: nil, now: now())
                }
            }
            touch(cacheKey: key)
            return .asset(asset)

        case .remoteOnly:
            return authedRemoteAsset(target: target)

        case .unplayable(let reason):
            return .unplayable(reason: reason)
        }
    }

    private func authedRemoteAsset(target: PlaybackTarget) -> PlaybackAsset {
        guard let master = target.master else {
            return .unplayable(reason: "No server URL configured")
        }
        var options: [String: Any] = [:]
        if let token = target.bearerToken {
            options["AVURLAssetHTTPHeaderFieldsKey"] = ["Authorization": "Bearer \(token)"]
        }
        return .asset(AVURLAsset(url: master, options: options))
    }

    /// Playback of this video stopped. A finished fill-ahead has already been
    /// promoted; anything short of complete is cancelled and kept as an
    /// LRU-evictable partial, because the user skipped and only an explicit
    /// Download should spend data on the rest.
    public func notePlaybackEnded(videoId: Int, versionId: Int? = nil) {
        let key = cacheKey(videoId: videoId, versionId: versionId)
        if let entry = hlsStore.entry(cacheKey: key), !entry.isComplete,
           lock.withLock({ downloadWaiters[key] == nil })
        {
            downloader.cancel(cacheKey: key)
        }
        touch(cacheKey: key)
        evictIfNeeded()
    }

    public func setTempCacheCap(bytes: Int64) {
        lock.withLock { tempCacheCapBytes = max(bytes, 0) }
        evictIfNeeded()
    }

    private func touch(cacheKey key: String) {
        guard var entry = hlsStore.entry(cacheKey: key) else { return }
        entry.lastPlayedAt = now()
        if let url = hlsStore.resolve(entry) {
            entry.byteCount = hlsStore.directorySize(of: url)
        }
        hlsStore.upsert(entry)
    }

    private func evictIfNeeded() {
        let cap = lock.withLock { tempCacheCapBytes }
        for key in CacheEvictor.keysToEvict(
            entries: hlsStore.entries(), capBytes: cap,
            protectedKeys: downloader.runningKeys()
        ) {
            hlsStore.remove(cacheKey: key)
            lock.withLock { hlsProgress[key] = nil }
        }
    }

    // MARK: Engine events

    /// Entry for `key`, synthesized from `pendingRequests` if none exists yet.
    /// In production `willDownloadTo` (`HLSDownloadEngine`) usually wins this
    /// race — AVFoundation reports the package location before the first byte
    /// of progress. This is the fallback for the gap before that, and the seam
    /// a fake downloader in tests relies on entirely.
    private func entryOrSynthesize(key: String, fraction: Double) -> HLSCacheEntry? {
        if let entry = hlsStore.entry(cacheKey: key) { return entry }
        guard let request = lock.withLock({ pendingRequests[key] }) else { return nil }
        return HLSCacheEntry(
            cacheKey: key, videoId: request.videoId, versionId: request.versionId,
            bookmark: Data(), kind: request.isFillAhead ? .temp : .permanent,
            isComplete: false, fractionComplete: fraction, byteCount: 0,
            lastPlayedAt: now(), audioLang: request.audioLang)
    }

    private func handle(_ event: HLSDownloadEvent) {
        switch event {
        case .progress(let key, let fraction, let bytes):
            guard var entry = entryOrSynthesize(key: key, fraction: fraction) else { return }
            entry.fractionComplete = fraction
            entry.byteCount = bytes
            hlsStore.upsert(entry)
            lock.withLock {
                hlsProgress[key] = fraction
                if inFlight[key] == nil {
                    inFlight[key] = DownloadActivityAccumulator(
                        videoID: entry.videoId, versionID: entry.versionId,
                        totalByteCount: nil, now: now())
                }
                inFlight[key]?.record(
                    transferredByteCount: bytes, progress: fraction,
                    totalByteCount: nil, now: now())
            }

        case .finished(let key):
            if var entry = entryOrSynthesize(key: key, fraction: 1) {
                entry.isComplete = true
                entry.fractionComplete = 1
                // Completion is the auto-download rule: a watch that fetched the
                // whole asset becomes a permanent download.
                entry.kind = .permanent
                if let url = hlsStore.resolve(entry) {
                    entry.byteCount = hlsStore.directorySize(of: url)
                }
                hlsStore.upsert(entry)
                lock.withLock {
                    hlsProgress[key] = 1
                    inFlight[key] = nil
                    pendingRequests[key] = nil
                    completionHistory.record(DownloadCompletion(
                        videoID: entry.videoId, versionID: entry.versionId,
                        completedAt: now()))
                }
            }
            resumeWaiter(key: key, result: .success(()))

        case .failed(let key, let error):
            // Segments can vanish under us (the server repackages on an audio
            // change), and a partial from a previous package is not resumable —
            // drop it rather than resume garbage.
            hlsStore.remove(cacheKey: key)
            lock.withLock {
                hlsProgress[key] = nil
                inFlight[key] = nil
                pendingRequests[key] = nil
            }
            resumeWaiter(key: key, result: .failure(error))

        case .cancelled(let key):
            lock.withLock {
                inFlight[key] = nil
                pendingRequests[key] = nil
            }
            resumeWaiter(key: key, result: .failure(CancellationError()))
        }
    }

    private func resumeWaiter(key: String, result: Result<Void, Error>) {
        let waiter = lock.withLock { downloadWaiters.removeValue(forKey: key) }
        switch result {
        case .success: waiter?.resume()
        case .failure(let error): waiter?.resume(throwing: error)
        }
    }

    // MARK: Watch-to-cache capture

    /// A capturing `AVURLAsset` served through an in-process `CaptureManager`.
    /// Loaded so a fresh manager is created only once `session` is wired up.
    private lazy var fetcherRegistry = RangeFetcherRegistry(
        store: capturedStore, session: session,
        waitBeforePublication: waitBeforePublication)
    private lazy var captureManager = CaptureManager(registry: fetcherRegistry)

    /// Builds an `AVURLAsset` that plays the remote video while capturing every
    /// fetched byte to a partial on disk. Capture progress is surfaced through
    /// `inFlight`/`state(for:)` — but only when no manual download owns the key.
    /// `isEligibleForCapture` must be false for any video whose watch can never
    /// be finalized into a cached MP4 — library rows and HLS-packaged videos.
    /// Capturing those would accumulate a partial on disk that the finalize hook
    /// deliberately skips, orphaning a `.downloading` state forever. The gate
    /// lives here (not only at the call site) so no future caller can bypass it:
    /// when ineligible we hand back a plain authed asset that captures nothing.
    public func captureAsset(
        videoId: Int, versionId: Int? = nil, remoteURL: URL, bearerToken: String?,
        isEligibleForCapture: Bool = true
    ) -> AVURLAsset {
        guard isEligibleForCapture else {
            var options: [String: Any] = [:]
            if let bearerToken {
                options["AVURLAssetHTTPHeaderFieldsKey"] = ["Authorization": "Bearer \(bearerToken)"]
            }
            return AVURLAsset(url: remoteURL, options: options)
        }
        let key = cacheKey(videoId: videoId, versionId: versionId)
        return captureManager.asset(
            videoId: videoId, versionId: versionId, remoteURL: remoteURL, bearerToken: bearerToken,
            onProgress: { [weak self] captured, total in
                self?.registerCaptureProgress(
                    key: key, videoId: videoId, versionId: versionId,
                    capturedBytes: captured, totalByteCount: total)
            })
    }

    /// Fetches every uncaptured byte and publishes the completed MP4 into the
    /// cache. Best-effort; leaves the partial intact on failure.
    public func finalizeCapture(videoId: Int, versionId: Int? = nil) async {
        let key = cacheKey(videoId: videoId, versionId: versionId)
        guard let fetcher = captureManager.fetcher(forCacheKey: key) else { return }
        let destination = localURL(for: videoId, versionId: versionId)
        let finalized = (try? await fetcher.finalize(destination: destination)) != nil
        lock.withLock {
            inFlight[key] = nil
            // Publishing removes the on-disk manifest; drop the mirror so a
            // completed capture stops reporting as `.downloading`.
            if finalized { capturedManifestProgress[key] = nil }
        }
    }

    /// Publishes capture progress into `inFlight` so the grid shows a capturing
    /// video as `.downloading`. This is also the `onProgress` callback for an
    /// explicit `download()`/`resumeInterrupted()` fetch: the registry hands out
    /// one `RangeFetcher` per cache key, so any progress report for a key that
    /// has a `downloadTasks` entry is necessarily that same download's own
    /// progress, not an unrelated capture racing it — always update `inFlight`.
    private func registerCaptureProgress(
        key: String, videoId: Int, versionId: Int?,
        capturedBytes: Int64, totalByteCount: Int64
    ) {
        let progress = totalByteCount > 0
            ? min(max(Double(capturedBytes) / Double(totalByteCount), 0), 1)
            : 0
        lock.withLock {
            // A capture-progress callback means the manifest was just written to
            // disk — mirror it so `state(for:)` never has to read it back.
            capturedManifestProgress[key] = progress
            if inFlight[key] == nil {
                inFlight[key] = DownloadActivityAccumulator(
                    videoID: videoId, versionID: versionId,
                    totalByteCount: totalByteCount, now: now())
            }
            inFlight[key]?.record(
                transferredByteCount: capturedBytes,
                progress: progress,
                totalByteCount: totalByteCount,
                now: now())
        }
    }

    public func activeDownloads() -> [DownloadActivity] {
        lock.withLock { inFlight.values.map(\.activity).sorted { $0.id < $1.id } }
    }

    public func recentDownloads() -> [DownloadCompletion] {
        lock.withLock {
            completionHistory.prune { completion in
                hlsStore.entry(cacheKey: cacheKey(
                    videoId: completion.videoID, versionId: completion.versionID)) != nil
            }
        }
    }

    /// Downloads a video's HLS package for offline playback, resuming whatever a
    /// previous watch already captured. `streamCount` is ignored: AVFoundation
    /// manages segment concurrency inside its own session.
    public func download(id: Int, versionId: Int? = nil, from remote: URL, preview: URL? = nil,
                         showPosterKey: String? = nil, showPoster: URL? = nil,
                         bearerToken: String? = nil, streamCount: Int = 1) async throws {
        await concurrencyGate.acquire()
        defer { concurrencyGate.release() }
        let key = cacheKey(videoId: id, versionId: versionId)

        if state(for: id, versionId: versionId) != .cached {
            let request = HLSDownloadRequest(
                cacheKey: key, videoId: id, versionId: versionId, master: remote,
                bearerToken: bearerToken, title: "\(id)",
                audioLang: hlsStore.entry(cacheKey: key)?.audioLang,
                isFillAhead: false)
            guard downloader.start(request) != nil else {
                throw HLSDownloadError.taskCreationFailed
            }
            lock.withLock {
                pendingRequests[key] = request
                if inFlight[key] == nil {
                    inFlight[key] = DownloadActivityAccumulator(
                        videoID: id, versionID: versionId, totalByteCount: nil, now: now())
                }
            }
            try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    lock.withLock { downloadWaiters[key] = continuation }
                }
            }, onCancel: {
                self.cancel(id: id, versionId: versionId)
            })
        }
        // Best-effort: a missing preview must not fail the cached video.
        if let preview { try? await cachePreview(id: id, from: preview, bearerToken: bearerToken) }
        // Show poster is shared across episodes: fetch once, skip when cached.
        if let showPosterKey, let showPoster, cachedShowPosterURL(for: showPosterKey) == nil {
            try? await cacheShowPoster(key: showPosterKey, from: showPoster, bearerToken: bearerToken)
        }
    }

    /// Test seam: the live fetcher for a key, so a test can drive playback-side
    /// captures without an `AVPlayer`.
    func testFetcher(videoId: Int, versionId: Int?) -> RangeFetcher? {
        fetcherRegistry.existing(cacheKey: cacheKey(videoId: videoId, versionId: versionId))
    }

    /// Test seam: whether `downloadTasks` still tracks a live download for this
    /// key, so a test can confirm a `resumeInterrupted`-spawned task cleaned up
    /// after itself instead of leaking the bookkeeping forever.
    func hasDownloadTask(videoId: Int, versionId: Int?) -> Bool {
        lock.withLock { downloadTasks[cacheKey(videoId: videoId, versionId: versionId)] != nil }
    }

    private func clearRangeDownloadAttempt(key: String, taskID: UUID) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard downloadTasks[key]?.id == taskID else { return nil }
            let continuation = downloadTasks[key]?.completion
            downloadTasks[key] = nil
            inFlight[key] = nil
            return continuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    private func completeRangeDownloadAttempt(
        key: String, taskID: UUID, videoID: Int, versionID: Int?
    ) -> Bool {
        lock.withLock {
            guard downloadTasks[key]?.id == taskID else { return false }
            downloadTasks[key] = nil
            inFlight[key] = nil
            // Publishing removed the manifest; drop the mirror so the video
            // stops reporting as in-progress.
            capturedManifestProgress[key] = nil
            completionHistory.record(DownloadCompletion(
                videoID: videoID, versionID: versionID, completedAt: now()))
            return true
        }
    }

    private func waitForRangeDownloadAttempt(
        key: String, trackedTask: RangeDownloadTask
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let registered = lock.withLock { () -> Bool in
                guard downloadTasks[key]?.id == trackedTask.id else { return false }
                downloadTasks[key]?.completion = continuation
                return true
            }
            guard registered else {
                continuation.resume(throwing: CancellationError())
                return
            }
            Task { [weak self] in
                do {
                    try await trackedTask.task.value
                    self?.resumeRangeDownloadWaiter(
                        key: key, taskID: trackedTask.id, result: .success(()))
                } catch {
                    self?.resumeRangeDownloadWaiter(
                        key: key, taskID: trackedTask.id, result: .failure(error))
                }
            }
        }
    }

    private func resumeRangeDownloadWaiter(
        key: String, taskID: UUID, result: Result<Void, Error>
    ) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard downloadTasks[key]?.id == taskID else { return nil }
            let continuation = downloadTasks[key]?.completion
            downloadTasks[key]?.completion = nil
            return continuation
        }
        switch result {
        case .success:
            continuation?.resume()
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }

    /// Reattaches to background tasks that outlived a suspension or a kill.
    /// Fire-and-forget; returns the video ids with a live or resumable package.
    @discardableResult
    public func resumeInterrupted(bearerToken: String? = nil) -> [Int] {
        Task { await downloader.restoreTasks() }
        evictIfNeeded()
        return hlsStore.entries().filter { !$0.isComplete }.map(\.videoId)
    }

    /// Stops an in-flight download. The partial package stays on disk, so
    /// `state(for:)` reports `.paused(progress)` and a later download resumes it.
    public func cancel(id: Int, versionId: Int? = nil) {
        downloader.cancel(cacheKey: cacheKey(videoId: id, versionId: versionId))
    }

    /// Deletes a partial package, reclaiming the disk.
    public func removePartial(id: Int, versionId: Int? = nil) {
        let key = cacheKey(videoId: id, versionId: versionId)
        cancel(id: id, versionId: versionId)
        guard let entry = hlsStore.entry(cacheKey: key), !entry.isComplete else { return }
        hlsStore.remove(cacheKey: key)
        lock.withLock {
            hlsProgress[key] = nil
            inFlight[key] = nil
        }
    }

    /// Deletes a cached package, complete or not.
    public func removeCached(id: Int, versionId: Int? = nil) {
        let key = cacheKey(videoId: id, versionId: versionId)
        cancel(id: id, versionId: versionId)
        hlsStore.remove(cacheKey: key)
        lock.withLock {
            hlsProgress[key] = nil
            inFlight[key] = nil
        }
    }

    /// True when any complete package (any version) exists for this video.
    public func hasAnyCached(id: Int) -> Bool {
        hlsStore.entries().contains { $0.videoId == id && $0.isComplete }
    }

    /// Deletes every package for this video, all versions. Preview images and
    /// show posters are kept — small, still useful offline.
    public func removeAllCached(id: Int) {
        for entry in hlsStore.entries() where entry.videoId == id {
            removeCached(id: entry.videoId, versionId: entry.versionId)
        }
    }

    /// Clears every downloaded video: cancels in-flight downloads, removes all
    /// packages and completion history. Cover images are kept.
    public func clearAllVideos() {
        for entry in hlsStore.entries() {
            cancel(id: entry.videoId, versionId: entry.versionId)
        }
        hlsStore.removeAll()
        lock.withLock {
            hlsProgress.removeAll()
            inFlight.removeAll()
            completionHistory.clear()
        }
    }

    /// Clears every cached preview image and show poster. Videos, manifests,
    /// and history are kept (see `clearAllVideos()`).
    public func clearAllCovers() {
        let contents = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        for name in contents where name.contains(".preview.") || name.hasPrefix("poster.") {
            try? fileManager.removeItem(at: root.appendingPathComponent(name))
        }
    }

    private func cachedVideoFilenames(id: Int) -> [String] {
        let contents = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        return contents.filter {
            $0 == "\(id).mp4" || ($0.hasPrefix("\(id).v") && $0.hasSuffix(".mp4"))
        }
    }

    private func filename(videoId: Int, versionId: Int?) -> String {
        if let versionId {
            return "\(videoId).v\(versionId).mp4"
        }
        return "\(videoId).mp4"
    }

    private func cacheKey(videoId: Int, versionId: Int?) -> String {
        if let versionId {
            return "\(videoId):\(versionId)"
        }
        return "\(videoId)"
    }
    private func cachePreview(id: Int, from remote: URL, bearerToken: String? = nil) async throws {
        var request = URLRequest(url: remote)
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.badStatus(http.statusCode)
        }
        storePreview(data, for: id, path: remote.absoluteString)
    }

    private func cacheShowPoster(key: String, from remote: URL, bearerToken: String? = nil) async throws {
        var request = URLRequest(url: remote)
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.badStatus(http.statusCode)
        }
        storeShowPoster(data, for: key)
    }

    private func posterHash(_ key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    private func safeExt(from urlString: String) -> String {
        let ext = (URL(string: urlString)?.pathExtension ?? "").lowercased()
        return (1...4).contains(ext.count) && ext.allSatisfy(\.isLetter) ? ext : "jpg"
    }
}
