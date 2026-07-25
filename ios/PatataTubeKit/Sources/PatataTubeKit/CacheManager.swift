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
        waitBeforePublication: @escaping @Sendable () async -> Void = {}
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
    }

    /// Sets the global cap on how many videos download at once.
    public func setMaxConcurrentDownloads(_ n: Int) {
        concurrencyGate.setLimit(n)
    }

    /// Current global simultaneous-download cap.
    public var maxConcurrentDownloads: Int {
        concurrencyGate.currentLimit
    }

    public func localURL(for id: Int, versionId: Int? = nil) -> URL {
        root.appendingPathComponent(filename(videoId: id, versionId: versionId))
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

    public func state(for id: Int, versionId: Int? = nil) -> CacheState {
        let key = cacheKey(videoId: id, versionId: versionId)
        if fileManager.fileExists(atPath: localURL(for: id, versionId: versionId).path) { return .cached }
        return lock.withLock {
            // An `inFlight` entry means something is transferring right now —
            // a download task or a live capture.
            if let accumulator = inFlight[key] { return .downloading(accumulator.activity.progress) }
            if let progress = capturedManifestProgress[key] { return .paused(progress) }
            return .notCached
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
                fileManager.fileExists(atPath: localURL(
                    for: completion.videoID,
                    versionId: completion.versionID
                ).path)
            }
        }
    }

    public func download(id: Int, versionId: Int? = nil, from remote: URL, preview: URL? = nil,
                         showPosterKey: String? = nil, showPoster: URL? = nil,
                         bearerToken: String? = nil, streamCount: Int = 1) async throws {
        await concurrencyGate.acquire()
        defer { concurrencyGate.release() }
        let key = cacheKey(videoId: id, versionId: versionId)
        let destination = localURL(for: id, versionId: versionId)

        if !fileManager.fileExists(atPath: destination.path) {
            let fetcher = fetcherRegistry.fetcher(
                videoId: id, versionId: versionId, remoteURL: remote, bearerToken: bearerToken,
                onProgress: { [weak self] captured, total in
                    self?.registerCaptureProgress(
                        key: key, videoId: id, versionId: versionId,
                        capturedBytes: captured, totalByteCount: total)
                })
            let workers = min(max(streamCount, 1), 4)
            let task = Task { try await fetcher.downloadAll(
                concurrency: workers, destination: destination) }
            let trackedTask = RangeDownloadTask(task: task)
            lock.withLock {
                downloadTasks[key] = trackedTask
                if inFlight[key] == nil {
                    inFlight[key] = DownloadActivityAccumulator(
                        videoID: id, versionID: versionId, totalByteCount: nil, now: now())
                }
            }
            do {
                try await withTaskCancellationHandler(operation: {
                    try await waitForRangeDownloadAttempt(
                        key: key, trackedTask: trackedTask)
                }, onCancel: {
                    self.cancel(id: id, versionId: versionId)
                })
            } catch {
                clearRangeDownloadAttempt(key: key, taskID: trackedTask.id)
                throw error
            }
            guard completeRangeDownloadAttempt(
                key: key, taskID: trackedTask.id, videoID: id, versionID: versionId
            ) else { throw CancellationError() }
            fetcherRegistry.remove(cacheKey: key)
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

    /// Restarts downloads interrupted by app suspension. Call when the app
    /// returns to the foreground (and on launch): every partial on disk carries
    /// a manifest of exactly which bytes it holds, so a restart re-requests only
    /// the gaps. Fire-and-forget — no caller awaits the result. Returns the
    /// video ids it resumed.
    @discardableResult
    public func resumeInterrupted(bearerToken: String? = nil) -> [Int] {
        var resumed: [Int] = []
        for manifest in capturedStore.manifests() {
            let key = manifest.cacheKey
            let destination = localURL(for: manifest.videoId, versionId: manifest.versionId)
            if fileManager.fileExists(atPath: destination.path) {
                capturedStore.remove(cacheKey: key)
                lock.withLock { capturedManifestProgress[key] = nil }
                continue
            }
            guard lock.withLock({ downloadTasks[key] == nil }) else { continue }
            let videoId = manifest.videoId
            let versionId = manifest.versionId
            let fetcher = fetcherRegistry.fetcher(
                videoId: videoId, versionId: versionId, remoteURL: manifest.remoteURL,
                bearerToken: bearerToken,
                onProgress: { [weak self] captured, total in
                    self?.registerCaptureProgress(
                        key: key, videoId: videoId, versionId: versionId,
                        capturedBytes: captured, totalByteCount: total)
                })
            let task = Task { try await fetcher.downloadAll(
                concurrency: 1, destination: destination) }
            let trackedTask = RangeDownloadTask(task: task)
            lock.withLock {
                downloadTasks[key] = trackedTask
                if inFlight[key] == nil {
                    inFlight[key] = DownloadActivityAccumulator(
                        videoID: videoId, versionID: versionId,
                        totalByteCount: manifest.totalByteCount, now: now())
                }
            }
            // `task` above is otherwise fire-and-forget: nothing else awaits it, so
            // without this the bookkeeping `download()` normally clears on both
            // success and failure (`downloadTasks`/`inFlight`, completion history)
            // would leak forever for a resumed download. Each video gets its own
            // local completion task so one failure can't propagate out of
            // `resumeInterrupted` and abort the scan of the rest of the list.
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await task.value
                    if self.completeRangeDownloadAttempt(
                        key: key, taskID: trackedTask.id,
                        videoID: videoId, versionID: versionId
                    ) {
                        self.fetcherRegistry.remove(cacheKey: key)
                    }
                } catch {
                    self.clearRangeDownloadAttempt(key: key, taskID: trackedTask.id)
                }
            }
            resumed.append(videoId)
        }
        return resumed
    }

    /// Stops an in-flight download for this id/version. The awaiting `download`
    /// call throws. The partial and its manifest stay on disk: `state(for:)`
    /// reports `.paused(progress)` and a later download resumes from the gaps.
    /// Use `removePartial` to reclaim the disk.
    public func cancel(id: Int, versionId: Int? = nil) {
        let key = cacheKey(videoId: id, versionId: versionId)
        let rangeTask = lock.withLock {
            () -> (task: RangeDownloadTask, continuation: CheckedContinuation<Void, Error>?)? in
            guard let task = downloadTasks.removeValue(forKey: key) else { return nil }
            inFlight[key] = nil
            let continuation = task.completion
            task.completion = nil
            return (task, continuation)
        }
        if let rangeTask {
            fetcherRegistry.cancelPublication(cacheKey: key)
            rangeTask.continuation?.resume(throwing: CancellationError())
            rangeTask.task.task.cancel()
        }
    }

    /// Deletes a partial download and its manifest, reclaiming the disk. Leaves
    /// any fully cached MP4 alone (see `removeCached`).
    public func removePartial(id: Int, versionId: Int? = nil) {
        let key = cacheKey(videoId: id, versionId: versionId)
        cancel(id: id, versionId: versionId)
        fetcherRegistry.remove(cacheKey: key)
        capturedStore.remove(cacheKey: key)
        lock.withLock {
            inFlight[key] = nil
            capturedManifestProgress[key] = nil
        }
    }

    /// Deletes a cached MP4. Used when the server re-converts a file with a
    /// different audio track set, making the cached copy stale.
    public func removeCached(id: Int, versionId: Int? = nil) {
        removePartial(id: id, versionId: versionId)
        try? fileManager.removeItem(at: localURL(for: id, versionId: versionId))
    }

    /// True when any cached MP4 (any version) exists for this video.
    public func hasAnyCached(id: Int) -> Bool {
        !cachedVideoFilenames(id: id).isEmpty
    }

    /// Deletes every cached MP4 for this video, all versions.
    /// Preview images and show posters are kept — small, still useful offline.
    public func removeAllCached(id: Int) {
        for activity in activeDownloads() where activity.videoID == id {
            removePartial(id: activity.videoID, versionId: activity.versionID)
        }
        for name in cachedVideoFilenames(id: id) {
            try? fileManager.removeItem(at: root.appendingPathComponent(name))
        }
        for manifest in capturedStore.manifests() where manifest.videoId == id {
            removePartial(id: manifest.videoId, versionId: manifest.versionId)
        }
    }

    /// Clears every downloaded video: cancels in-flight downloads, removes all
    /// MP4s, range manifests, and completion history. Preview
    /// images and show posters are kept (see `clearAllCovers()`).
    public func clearAllVideos() {
        for activity in activeDownloads() {
            removePartial(id: activity.videoID, versionId: activity.versionID)
        }
        let contents = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        for name in contents where name.hasSuffix(".mp4") {
            try? fileManager.removeItem(at: root.appendingPathComponent(name))
        }
        for manifest in capturedStore.manifests() {
            removePartial(id: manifest.videoId, versionId: manifest.versionId)
        }
        lock.withLock {
            capturedManifestProgress.removeAll()
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
