import CryptoKit
import Foundation

public enum CacheState: Equatable, Sendable {
    case notCached
    case downloading(Double)
    case cached
}

/// Offline videos: downloads and their pause/resume/cancel, deletion, and the
/// state the UI shows for each video.
///
/// Since 2.9 a download is a **pinned entry** in the `MediaStore` that the
/// stream proxy also reads and writes. `DownloadJobRunner` fills its holes,
/// and whatever closes the last one (a download or watching) renames it to
/// `localURL`. This class keeps only what the UI must read synchronously —
/// running jobs, a mirror of pinned entries, progress — under `lock`, and
/// sends every store write through one serial queue so they land in call
/// order: a cancel followed at once by a new download can never reach the
/// store reversed.
public final class CacheManager: @unchecked Sendable {
    private enum StopReason {
        case paused
        case cancelled
    }

    /// One running download. `stopReason` and `task` are touched only under
    /// `CacheManager.lock`.
    private final class RunningJob: @unchecked Sendable {
        let params: DownloadJobParameters
        var stopReason: StopReason?
        var task: Task<Void, Error>?

        init(params: DownloadJobParameters) {
            self.params = params
        }
    }

    /// The UI's synchronous view of a pinned store entry.
    private struct PinnedRecord {
        var params: DownloadJobParameters
        var paused: Bool
        var progress: Double
        var transferredByteCount: Int64
        var totalByteCount: Int64?
    }

    private let root: URL
    private let store: MediaStore
    private let session: URLSession
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let credentials: CredentialStore?
    private let tuning: DownloadTuning
    private let lock = NSLock()
    let concurrencyGate: any DownloadConcurrencyGating
    private var inFlight = InFlightActivities()
    private var completionHistory: DownloadCompletionHistoryStore
    private var jobs: [String: RunningJob] = [:]
    private var pinned: [String: PinnedRecord] = [:]
    /// Keys whose `download` is waiting at the gate, so `resumeInterrupted`
    /// on a quick background/foreground does not queue them twice.
    private var queuedKeys: Set<String> = []
    /// A pause or cancel that arrived while the key's `download` was still
    /// queued at the gate. `download` takes it right after `acquire`, returns
    /// the permit it was just given and does not start the job.
    private var queuedStops: [String: StopReason] = [:]
    private var storeChain: Task<Void, Never>?
    /// Paused keys. A paused download keeps its gate permit (as in 2.8).
    private var pausedKeys: Set<String> = []
    /// Paused keys currently holding a gate permit.
    private var pausedPermitKeys: Set<String> = []
    /// Keys a pause claimed permit ownership of; survives the moment `resume`
    /// clears `pausedKeys`, so a slow unwind's `releasePermit` hands the
    /// permit to the resumed transfer rather than to the gate.
    private var permitOwnerKeys: Set<String> = []
    /// Launch-time permit reservations for entries paused in a past process.
    private var pausedReservations: [String: Task<Void, Never>] = [:]

    /// Session config for downloads. `waitsForConnectivity` parks a retry
    /// during an outage instead of failing at once. (Playback uses
    /// `StreamProxy.defaultSession`, which never waits.)
    public static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        return configuration
    }

    public convenience init(
        root: URL? = nil,
        configuration: URLSessionConfiguration = CacheManager.defaultConfiguration(),
        credentials: CredentialStore? = nil
    ) {
        self.init(
            root: root,
            configuration: configuration,
            fileManager: .default,
            credentials: credentials,
            // Only the real app root owns the real 2.8 stream cache.
            legacyStreamRoot: root == nil
                ? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("stream", isDirectory: true)
                : nil
        )
    }

    init(
        root: URL?,
        configuration: URLSessionConfiguration,
        fileManager: FileManager,
        now: @escaping @Sendable () -> Date = Date.init,
        concurrencyGate: any DownloadConcurrencyGating = DownloadConcurrencyGate(limit: 3),
        credentials: CredentialStore? = nil,
        legacyStreamRoot: URL? = nil,
        storeTuning: MediaStore.Tuning = MediaStore.Tuning(),
        budgetBytes: Int64 = MediaStore.defaultBudgetBytes,
        fetchTuning: DownloadTuning = DownloadTuning()
    ) {
        let resolvedRoot = root ?? fileManager
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("videos")
        try? fileManager.createDirectory(at: resolvedRoot, withIntermediateDirectories: true)
        // Visible in the Files app (Documents), but out of iCloud/device
        // backups — these MP4s are re-downloadable, not user data.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directory = resolvedRoot
        try? directory.setResourceValues(values)
        LegacyCacheMigration.run(videosRoot: resolvedRoot, legacyStreamRoot: legacyStreamRoot, now: now())

        self.root = resolvedRoot
        self.fileManager = fileManager
        self.now = now
        self.concurrencyGate = concurrencyGate
        self.credentials = credentials
        self.tuning = fetchTuning
        self.store = MediaStore(videosRoot: resolvedRoot, budgetBytes: budgetBytes, tuning: storeTuning, now: now)
        self.session = URLSession(configuration: configuration)
        self.completionHistory = DownloadCompletionHistoryStore(root: resolvedRoot, fileManager: fileManager)

        for manifest in MediaStore.loadManifests(storeRoot: MediaStore.storeRoot(videosRoot: resolvedRoot)) {
            guard let pin = manifest.pin else { continue }
            pinned[manifest.key] = PinnedRecord(
                params: pin.job,
                paused: pin.paused,
                progress: manifest.progress,
                transferredByteCount: manifest.committed.totalBytes,
                totalByteCount: manifest.identity?.totalByteCount
            )
            if pin.paused { pausedKeys.insert(manifest.key) }
        }
        for key in pausedKeys { reservePermit(for: key) }
    }

    /// The store `StreamProxy` reads and writes — the same one downloads fill.
    public var mediaStore: MediaStore { store }

    /// Sets the global cap on how many videos download at once.
    public func setMaxConcurrentDownloads(_ n: Int) {
        concurrencyGate.setLimit(n)
    }

    public var maxConcurrentDownloads: Int {
        concurrencyGate.currentLimit
    }

    /// Directory holding the cached videos, for free-space checks.
    public var cacheRootURL: URL { root }

    public func localURL(for id: Int, versionId: Int? = nil) -> URL {
        root.appendingPathComponent(MediaKey.finishedFilename(cacheKey(videoId: id, versionId: versionId)))
    }

    public var videosRoot: URL { root }

    var urlSession: URLSession { session }

    // MARK: - Previews and posters (unchanged from 2.8)

    /// Local file URL of a cached preview image, or nil if none is cached.
    /// Version-aware: the filename embeds a hash of the preview URL.
    public func cachedPreviewURL(for id: Int, path: String?) -> URL? {
        let contents = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        let prefix = path.map { "\(id).preview.\(posterHash($0))." } ?? "\(id).preview."
        guard let name = contents.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return root.appendingPathComponent(name)
    }

    public func storePreview(_ data: Data, for id: Int, path: String) {
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let prefix = "\(id).preview."
        for name in (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? [] where name.hasPrefix(prefix) {
            try? fileManager.removeItem(at: root.appendingPathComponent(name))
        }
        let destination = root.appendingPathComponent("\(id).preview.\(posterHash(path)).\(safeExt(from: path))")
        try? data.write(to: destination)
    }

    public func cachedShowPosterURL(for key: String) -> URL? {
        let prefix = "poster.\(posterHash(key))."
        let contents = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        guard let name = contents.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return root.appendingPathComponent(name)
    }

    public func storeShowPoster(_ data: Data, for key: String) {
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("poster.\(posterHash(key)).\(safeExt(from: key))")
        try? fileManager.removeItem(at: destination)
        try? data.write(to: destination)
    }

    // MARK: - State

    /// `.cached` once the finished mp4 exists, however it got there.
    /// `.downloading` for a running or paused download. A partly watched
    /// video, or a pinned download whose last attempt failed, is
    /// `.notCached`: the download button shows, and tapping it continues
    /// from the committed bytes.
    public func state(for id: Int, versionId: Int? = nil) -> CacheState {
        let key = cacheKey(videoId: id, versionId: versionId)
        if fileManager.fileExists(atPath: localURL(for: id, versionId: versionId).path) { return .cached }
        return lock.withLock {
            if jobs[key] != nil { return .downloading(inFlight[key]?.activity.progress ?? 0) }
            if let record = pinned[key], record.paused { return .downloading(record.progress) }
            return .notCached
        }
    }

    /// Live transfers plus paused downloads, sorted by key. A paused entry
    /// whose file has landed anyway (a pause that raced a completion) is
    /// dropped here, and its permit returned.
    public func activeDownloads() -> [DownloadActivity] {
        let (live, paused) = lock.withLock {
            (inFlight.values.map(\.activity), pinned.filter { $0.value.paused && jobs[$0.key] == nil })
        }
        let liveKeys = Set(live.map(\.id))
        var stale: [String] = []
        var rows: [DownloadActivity] = []
        for (key, record) in paused where !liveKeys.contains(key) {
            let id = MediaKey.videoId(of: key)
            let version = MediaKey.versionId(of: key)
            if fileManager.fileExists(atPath: localURL(for: id, versionId: version).path) {
                stale.append(key)
                continue
            }
            rows.append(DownloadActivity(
                videoID: id,
                versionID: version,
                progress: record.progress,
                transferredByteCount: record.transferredByteCount,
                totalByteCount: record.totalByteCount,
                isPaused: true
            ))
        }
        stale.forEach(forgetPin)
        return (live + rows).sorted { $0.id < $1.id }
    }

    /// Total bytes committed by downloads since launch. Monotonic by
    /// construction; feed it to `DownloadSpeedMeter`.
    public func downloadedByteCount() -> Int64 {
        lock.withLock {
            DevLog.event(.download, "byte counter read", inFlight.counterMeta)
            return inFlight.cumulativeByteCount
        }
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

    // MARK: - Downloading

    public func download(id: Int, versionId: Int? = nil, from remote: URL, preview: URL? = nil,
                         showPosterKey: String? = nil, showPoster: URL? = nil,
                         bearerToken: String? = nil, streamCount: Int = 1) async throws {
        DevLog.event(.download, "download requested", [
            "video_id": "\(id)",
            "version_id": versionId.map(String.init) ?? "-",
            "streams": "\(streamCount)",
            "state": DevLog.describe(state(for: id, versionId: versionId)),
        ])
        let key = cacheKey(videoId: id, versionId: versionId)
        let params = DownloadJobParameters(
            remoteURL: remote,
            streamCount: min(max(streamCount, 1), 4),
            previewURL: preview,
            showPosterKey: showPosterKey,
            showPosterURL: showPoster
        )
        lock.withLock { _ = queuedKeys.insert(key) }
        await concurrencyGate.acquire()
        var stop: StopReason?
        lock.withLock {
            queuedKeys.remove(key)
            stop = queuedStops.removeValue(forKey: key)
        }
        if let stop {
            // Stopped while waiting: the permit is the only thing this call
            // holds (a pause that never started holds none for later).
            DevLog.event(.download, "queued download stopped at gate", [
                "video_id": "\(id)", "reason": stop == .paused ? "paused" : "cancelled",
            ])
            concurrencyGate.release()
            switch stop {
            case .paused: throw DownloadPausedError()
            case .cancelled: throw CancellationError()
            }
        }
        DevLog.event(.download, "download passed gate", ["video_id": "\(id)"])
        defer {
            DevLog.event(.download, "download releasing gate", ["video_id": "\(id)"])
            releasePermit(for: key)
        }
        try await performDownload(key: key, params: params, bearerToken: bearerToken)
    }

    /// The transfer, with no gate interaction: `download` wraps it in an
    /// acquire/release; `resume` reuses the permit the paused entry holds.
    private func performDownload(key: String, params: DownloadJobParameters, bearerToken: String?) async throws {
        let id = MediaKey.videoId(of: key)
        if !fileManager.fileExists(atPath: store.finishedURL(key: key).path) {
            try await runJob(key: key, params: params, bearerToken: bearerToken)
        }
        // Best-effort: a missing preview must not fail the cached video.
        if let preview = params.previewURL {
            try? await cachePreview(id: id, from: preview, bearerToken: bearerToken)
        }
        if let posterKey = params.showPosterKey, let poster = params.showPosterURL,
           cachedShowPosterURL(for: posterKey) == nil {
            try? await cacheShowPoster(key: posterKey, from: poster, bearerToken: bearerToken)
        }
    }

    /// Starts the job for `key`, or joins the one already running.
    private func runJob(key: String, params: DownloadJobParameters, bearerToken: String?) async throws {
        let runner = DownloadJobRunner(
            store: store,
            key: key,
            streamCount: params.streamCount,
            session: session,
            upstream: UpstreamRequests(url: params.remoteURL, credentials: credentials, fallbackToken: bearerToken),
            tuning: tuning,
            onProgress: { [weak self] manifest in self?.recordProgress(key: key, manifest: manifest) }
        )
        // Results leave the lock through captured variables rather than a
        // returned (RunningJob, Task, Bool) tuple: the tuple form is
        // miscompiled by the Swift 6.2 optimizer (-c release only), which
        // over-releases `job` and crashes the unwind on a failed download.
        var job = RunningJob(params: params)
        var task: Task<Void, Error>?
        var created = false
        lock.withLock {
            if let existing = jobs[key], let existingTask = existing.task {
                job = existing
                task = existingTask
                return
            }
            created = true
            jobs[key] = job
            let previous = pinned[key]
            pinned[key] = PinnedRecord(
                params: params,
                paused: false,
                progress: previous?.progress ?? 0,
                transferredByteCount: previous?.transferredByteCount ?? 0,
                totalByteCount: previous?.totalByteCount
            )
            inFlight[key] = DownloadActivityAccumulator(
                videoID: MediaKey.videoId(of: key),
                versionID: MediaKey.versionId(of: key),
                totalByteCount: previous?.totalByteCount
            )
            let pinWritten = enqueueStoreWorkLocked { await $0.setPin(key: key, pin: PinState(job: params, paused: false)) }
            let newTask = Task {
                await pinWritten.value
                try await runner.run()
            }
            job.task = newTask
            task = newTask
        }
        let joinedTask = task!  // set on both branches above
        do {
            try await joinedTask.value
            if created { finishJob(key: key, job: job, error: nil) }
        } catch {
            if created { finishJob(key: key, job: job, error: error) }
            let reason = lock.withLock { job.stopReason }
            switch reason {
            case .paused: throw DownloadPausedError()
            case .cancelled: throw CancellationError()
            case nil: throw error
            }
        }
    }

    private func recordProgress(key: String, manifest: MediaEntryManifest) {
        lock.withLock {
            guard jobs[key] != nil else { return }
            inFlight[key]?.record(
                transferredByteCount: manifest.committed.totalBytes,
                progress: manifest.progress,
                totalByteCount: manifest.identity?.totalByteCount
            )
            pinned[key]?.progress = manifest.progress
            pinned[key]?.transferredByteCount = manifest.committed.totalBytes
            pinned[key]?.totalByteCount = manifest.identity?.totalByteCount
        }
    }

    /// Only the job's creator finishes it, and only while it is still the
    /// current job: a pause or cancel already moved the table on.
    private func finishJob(key: String, job: RunningJob, error: Error?) {
        let unpin: Bool = lock.withLock {
            guard jobs[key] === job else { return false }
            jobs[key] = nil
            inFlight[key] = nil
            guard let error else {
                pinned[key] = nil
                completionHistory.record(DownloadCompletion(
                    videoID: MediaKey.videoId(of: key),
                    versionID: MediaKey.versionId(of: key),
                    completedAt: now()
                ))
                return false // promotion already removed the entry
            }
            if case .badStatus(let status)? = error as? APIError, (400..<500).contains(status) {
                pinned[key] = nil
                return true // the server will not have it on a retry either
            }
            return false // stays pinned with its bytes; the next tap or resumeInterrupted continues
        }
        if unpin { enqueueStoreWork { await $0.discard(key: key) } }
        DevLog.event(.download, error == nil ? "download finished" : "download failed", [
            "key": key, "err": error.map { "\($0)" } ?? "-",
        ])
    }

    /// Suspends a download, keeping its committed bytes **and** its gate
    /// permit. The parameters are stored because a resume may come in a
    /// later process.
    public func pause(
        id: Int,
        versionId: Int? = nil,
        remote: URL,
        streamCount: Int,
        preview: URL? = nil,
        showPosterKey: String? = nil,
        showPoster: URL? = nil
    ) {
        let key = cacheKey(videoId: id, versionId: versionId)
        // Results leave the lock through captured variables, not a returned
        // tuple (see runJob: tuples of class instances crash -c release).
        var applied = false
        var jobTask: Task<Void, Error>?
        var progress = 0.0
        lock.withLock {
            guard !pausedKeys.contains(key) else { return }
            applied = true
            let job = jobs[key]
            let params = job?.params ?? pinned[key]?.params ?? DownloadJobParameters(
                remoteURL: remote,
                streamCount: min(max(streamCount, 1), 4),
                previewURL: preview,
                showPosterKey: showPosterKey,
                showPosterURL: showPoster
            )
            let activity = inFlight[key]?.activity
            let previous = pinned[key]
            let record = PinnedRecord(
                params: params,
                paused: true,
                progress: activity?.progress ?? previous?.progress ?? 0,
                transferredByteCount: activity?.transferredByteCount ?? previous?.transferredByteCount ?? 0,
                totalByteCount: activity?.totalByteCount ?? previous?.totalByteCount
            )
            pinned[key] = record
            pausedKeys.insert(key)
            if job == nil, queuedKeys.contains(key) {
                // Still waiting at the gate: no permit is held yet, so claim
                // none; `download` stops itself when it reaches the front.
                queuedStops[key] = .paused
            } else {
                permitOwnerKeys.insert(key)
            }
            job?.stopReason = .paused
            jobs[key] = nil
            inFlight[key] = nil
            _ = enqueueStoreWorkLocked { await $0.setPin(key: key, pin: PinState(job: params, paused: true)) }
            jobTask = job?.task
            progress = record.progress
        }
        guard applied else { return }
        DevLog.event(.download, "pause", [
            "video_id": "\(id)",
            "version_id": versionId.map(String.init) ?? "-",
            "progress": String(format: "%.3f", progress),
        ])
        jobTask?.cancel()
    }

    /// Restarts a paused download on the permit it has been holding. Only
    /// the Resume menu item calls this.
    public func resume(id: Int, versionId: Int? = nil, bearerToken: String? = nil) async throws {
        let key = cacheKey(videoId: id, versionId: versionId)
        guard lock.withLock({ pinned[key]?.paused == true }) else { return }
        // Can block while more entries are paused than the gate allows, so
        // nothing is claimed before it returns.
        await awaitPermit(for: key)
        // A download paused while still queued never got a permit: take one
        // now, so its resumed transfer counts against the gate like any other.
        let needsPermit = lock.withLock {
            !pausedPermitKeys.contains(key) && !permitOwnerKeys.contains(key) && pausedReservations[key] == nil
        }
        if needsPermit {
            await concurrencyGate.acquire()
            let adopted = lock.withLock { () -> Bool in
                guard pinned[key]?.paused == true, !pausedPermitKeys.contains(key) else { return false }
                pausedPermitKeys.insert(key)
                return true
            }
            if !adopted { concurrencyGate.release(); return }
        }
        guard let params = lock.withLock({ () -> DownloadJobParameters? in
            guard let record = pinned[key], record.paused else { return nil }
            pinned[key]?.paused = false
            pausedKeys.remove(key)
            return record.params
        }) else { return }
        DevLog.event(.download, "resume", [
            "video_id": "\(id)", "version_id": versionId.map(String.init) ?? "-",
        ])
        defer { releasePausedPermit(for: key) }
        try await performDownload(key: key, params: params, bearerToken: bearerToken)
    }

    /// Restarts pinned, unpaused downloads that are not running: those the
    /// app was suspended or killed during, and those whose last attempt
    /// failed. Each goes through the gate like any download. Call on launch
    /// and on every activation. Returns the video ids restarted.
    @discardableResult
    public func resumeInterrupted(bearerToken: String? = nil) -> [Int] {
        let pending = lock.withLock {
            pinned.filter { !$0.value.paused && jobs[$0.key] == nil && !queuedKeys.contains($0.key) }
        }
        for (key, record) in pending {
            let params = record.params
            Task { [weak self] in
                try? await self?.download(
                    id: MediaKey.videoId(of: key),
                    versionId: MediaKey.versionId(of: key),
                    from: params.remoteURL,
                    preview: params.previewURL,
                    showPosterKey: params.showPosterKey,
                    showPoster: params.showPosterURL,
                    bearerToken: bearerToken,
                    streamCount: params.streamCount
                )
            }
        }
        let ids = Array(Set(pending.keys.map(MediaKey.videoId(of:)))).sorted()
        DevLog.event(.download, "resumeInterrupted", [
            "resumed": "\(ids.count)",
            "ids": ids.prefix(20).map(String.init).joined(separator: ","),
            "free_bytes": DevLog.freeDiskBytes(),
        ])
        return ids
    }

    // MARK: - Cancel and delete

    /// Stops a download and unpins it. Its bytes go once no player response
    /// reads them. The awaiting `download` throws `CancellationError`.
    public func cancel(id: Int, versionId: Int? = nil) {
        DevLog.event(.cache, "cancel", [
            "video_id": "\(id)",
            "version_id": versionId.map(String.init) ?? "-",
            "state": DevLog.describe(state(for: id, versionId: versionId)),
        ])
        discardDownload(key: cacheKey(videoId: id, versionId: versionId))
    }

    private func discardDownload(key: String) {
        var task: Task<Void, Error>?
        var wasPaused = false
        lock.withLock {
            // A paused-while-queued key holds no permit yet; its `download`
            // stops itself, so there is none to release here.
            let hadQueuedStop = queuedStops[key] != nil
            wasPaused = pausedKeys.remove(key) != nil && !hadQueuedStop
            let job = jobs.removeValue(forKey: key)
            job?.stopReason = .cancelled
            if job == nil, queuedKeys.contains(key) { queuedStops[key] = .cancelled }
            inFlight[key] = nil
            pinned[key] = nil
            _ = enqueueStoreWorkLocked { await $0.discard(key: key) }
            task = job?.task
        }
        if wasPaused { releasePausedPermit(for: key) }
        task?.cancel()
    }

    /// Drops a pin whose file landed anyway: the mirror, the permit, the flag.
    private func forgetPin(_ key: String) {
        lock.withLock {
            pinned[key] = nil
            _ = pausedKeys.remove(key)
        }
        releasePausedPermit(for: key)
        enqueueStoreWork { await $0.setPin(key: key, pin: nil) }
    }

    /// Deletes a downloaded video (and any store entry for it).
    public func removeCached(id: Int, versionId: Int? = nil) {
        DevLog.event(.cache, "removeCached", [
            "video_id": "\(id)", "version_id": versionId.map(String.init) ?? "-",
        ])
        discardDownload(key: cacheKey(videoId: id, versionId: versionId))
        try? fileManager.removeItem(at: localURL(for: id, versionId: versionId))
    }

    /// True when any cached MP4 exists for this video.
    public func hasAnyCached(id: Int) -> Bool {
        !cachedVideoFilenames(id: id).isEmpty
    }

    /// Deletes every cached MP4 and store entry for this video. Previews and
    /// posters are kept — small, still useful offline.
    public func removeAllCached(id: Int) {
        DevLog.event(.cache, "removeAllCached", ["video_id": "\(id)"])
        let keys = lock.withLock {
            Set(jobs.keys).union(pinned.keys).union(queuedKeys).filter { MediaKey.videoId(of: $0) == id }
        }
        keys.forEach(discardDownload)
        for name in cachedVideoFilenames(id: id) {
            try? fileManager.removeItem(at: root.appendingPathComponent(name))
        }
        enqueueStoreWork { await $0.discardAll(videoId: id) }
    }

    /// One-time cleanup of the HLS era (<= 2.8): deletes every offline HLS
    /// package and the `.hls-tmp` staging dir, and returns the ids to
    /// download again as mp4. Idempotent.
    public func removeLegacyHLSPackages() -> [Int] {
        let contents = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        var ids = Set(PausedDownloadStore.droppedHLSVideoIDs(root: root))
        for name in contents where name.hasPrefix("hls-") {
            let digits = name.dropFirst("hls-".count).prefix { $0.isNumber }
            if let id = Int(digits) { ids.insert(id) }
            try? fileManager.removeItem(at: root.appendingPathComponent(name))
        }
        let staging = root.appendingPathComponent(".hls-tmp", isDirectory: true)
        if let staged = try? fileManager.contentsOfDirectory(atPath: staging.path) {
            for key in staged { ids.insert(MediaKey.videoId(of: key)) }
        }
        try? fileManager.removeItem(at: staging)
        PausedDownloadStore.clearDroppedHLS(root: root)
        let pending = ids.filter { !hasAnyCached(id: $0) }.sorted()
        if !pending.isEmpty {
            DevLog.event(.cache, "legacy HLS removed", [
                "ids": pending.map(String.init).joined(separator: ","),
            ])
        }
        return pending
    }

    /// Cancels every download and deletes every MP4, store entry and the
    /// completion history. Previews and posters stay (see `clearAllCovers`).
    public func clearAllVideos() {
        let keys = lock.withLock { Set(jobs.keys).union(pinned.keys).union(queuedKeys) }
        DevLog.event(.cache, "clearAllVideos", ["downloads": "\(keys.count)"])
        keys.forEach(discardDownload)
        let contents = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        for name in contents where name.hasSuffix(".mp4") || name.hasPrefix("hls-") {
            try? fileManager.removeItem(at: root.appendingPathComponent(name))
        }
        enqueueStoreWork { await $0.discardAll() }
        lock.withLock { completionHistory.clear() }
    }

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

    // MARK: - Store work queue

    @discardableResult
    private func enqueueStoreWork(_ work: @escaping @Sendable (MediaStore) async -> Void) -> Task<Void, Never> {
        lock.withLock { enqueueStoreWorkLocked(work) }
    }

    /// Store writes run one at a time in call order. Caller holds `lock`.
    private func enqueueStoreWorkLocked(_ work: @escaping @Sendable (MediaStore) async -> Void) -> Task<Void, Never> {
        let previous = storeChain
        let store = self.store
        let task = Task {
            await previous?.value
            await work(store)
        }
        storeChain = task
        return task
    }

    /// Waits for every store write queued so far.
    public func settleStoreWork() async {
        let last = lock.withLock { storeChain }
        await last?.value
    }

    // MARK: - Gate permits for paused downloads (unchanged from 2.8)

    /// Returns a finished download's permit — unless the key was paused, in
    /// which case ownership moves to the paused-permit table and the slot
    /// stays occupied.
    func releasePermit(for key: String) {
        let handedOver = lock.withLock { () -> Bool in
            guard pausedKeys.contains(key) || permitOwnerKeys.contains(key),
                  !pausedPermitKeys.contains(key)
            else { return false }
            pausedPermitKeys.insert(key)
            return true
        }
        DevLog.event(.download, handedOver ? "permit held for pause" : "permit released", ["key": key])
        if !handedOver { concurrencyGate.release() }
    }

    /// Re-acquires a permit for an entry paused in a previous process.
    private func reservePermit(for key: String) {
        let task = Task.detached { [weak self] in
            guard let self else { return }
            await self.concurrencyGate.acquire()
            let stillPaused = self.lock.withLock { () -> Bool in
                guard self.pausedKeys.contains(key) else { return false }
                self.pausedPermitKeys.insert(key)
                return true
            }
            if !stillPaused { self.concurrencyGate.release() }
        }
        lock.withLock { pausedReservations[key] = task }
    }

    func awaitPermit(for key: String) async {
        guard let task = lock.withLock({ pausedReservations[key] }) else { return }
        await task.value
    }

    func releasePausedPermit(for key: String) {
        let held = lock.withLock { () -> Bool in
            permitOwnerKeys.remove(key)
            return pausedPermitKeys.remove(key) != nil
        }
        lock.withLock { pausedReservations[key] = nil }
        if held { concurrencyGate.release() }
    }

    // MARK: - Helpers

    func cacheKey(videoId: Int, versionId: Int?) -> String {
        Self.cacheKey(videoId: videoId, versionId: versionId)
    }

    static func cacheKey(videoId: Int, versionId: Int?) -> String {
        MediaKey.key(videoId: videoId, versionId: versionId)
    }

    func cachePreview(id: Int, from remote: URL, bearerToken: String? = nil) async throws {
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

    func cacheShowPoster(key: String, from remote: URL, bearerToken: String? = nil) async throws {
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

extension CacheManager: MediaCaching {}
