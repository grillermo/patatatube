import Foundation
import CryptoKit

public enum CacheState: Equatable, Sendable {
    case notCached
    case downloading(Double)
    case cached
}

private struct SegmentTaskContext {
    let attemptID: UUID
    let cacheKey: String
    let segmentIndex: Int
    let resumed: Bool
}

private final class FreshProbeAttempt: @unchecked Sendable {
    let id = UUID()
    let cacheKey: String
    var task: URLSessionDataTask?
    var continuation: CheckedContinuation<DownloadProbe, Error>?

    init(cacheKey: String) {
        self.cacheKey = cacheKey
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

private final class SegmentedAttempt: @unchecked Sendable {
    // A single segment may hit a transient transport error several times on a
    // long transfer; retry it in place this many times before failing the whole
    // attempt, so one flaky connection can't discard the other segments' work.
    static let maxSegmentRetries = 3

    let id = UUID()
    let cacheKey: String
    let bearerToken: String?
    var manifest: SegmentedDownloadManifest
    var continuation: CheckedContinuation<URL, Error>?
    var taskIDs: Set<Int> = []
    var activeByteCounts: [Int: Int64] = [:]
    var completedResults: [Int: Result<URL, Error>] = [:]
    var segmentRetryCounts: [Int: Int] = [:]
    var terminalError: Error?
    var preservingResumeData = false
    var resumeDataPendingTaskIDs: Set<Int> = []
    var explicitlyCancelled = false
    var terminalClaimed = false

    init(
        cacheKey: String,
        bearerToken: String?,
        manifest: SegmentedDownloadManifest,
        continuation: CheckedContinuation<URL, Error>?
    ) {
        self.cacheKey = cacheKey
        self.bearerToken = bearerToken
        self.manifest = manifest
        self.continuation = continuation
    }
}

public final class CacheManager: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let root: URL
    private let segmentedStore: SegmentedDownloadStore
    private var session: URLSession!
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private let cancellationFence: any CacheManagerCancellationFencing
    private let concurrencyGate: any DownloadConcurrencyGating
    private var inFlight: [String: DownloadActivityAccumulator] = [:]
    private var completionHistory: DownloadCompletionHistoryStore
    private var continuations: [Int: CheckedContinuation<URL, Error>] = [:]
    private var idByTask: [Int: String] = [:]
    private var tasksByKey: [String: URLSessionDownloadTask] = [:]
    private var completedResults: [Int: Result<URL, Error>] = [:]
    private var segmentedAttempts: [String: SegmentedAttempt] = [:]
    private var probeAttempts: [String: FreshProbeAttempt] = [:]
    private var segmentContextByTask: [Int: SegmentTaskContext] = [:]
    private var tasksByIdentifier: [Int: URLSessionDownloadTask] = [:]
    private var legacyResumeBaselineTaskIDs: Set<Int> = []

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
            DownloadConcurrencyGate(limit: 3)
    ) {
        self.fileManager = fileManager
        self.now = now
        self.cancellationFence = cancellationFence
        self.concurrencyGate = concurrencyGate
        self.root = root ?? fileManager
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("videos")
        self.completionHistory = DownloadCompletionHistoryStore(
            root: self.root,
            fileManager: fileManager
        )
        self.segmentedStore = SegmentedDownloadStore(
            root: self.root,
            fileManager: fileManager
        )
        super.init()
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        try? fileManager.createDirectory(at: self.root, withIntermediateDirectories: true)
        // Visible in the Files app (Documents), but keep it out of iCloud/device
        // backups - these MP4s are re-downloadable, not user data.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = self.root
        try? dir.setResourceValues(values)
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
            inFlight[key].map { .downloading($0.activity.progress) } ?? .notCached
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
        _ = try await downloadVideo(
            id: id,
            versionId: versionId,
            from: remote,
            bearerToken: bearerToken,
            streamCount: min(max(streamCount, 1), 4)
        )
        // Best-effort: a missing preview must not fail the cached video.
        if let preview { try? await cachePreview(id: id, from: preview, bearerToken: bearerToken) }
        // Show poster is shared across episodes: fetch once, skip when cached.
        if let showPosterKey, let showPoster, cachedShowPosterURL(for: showPosterKey) == nil {
            try? await cacheShowPoster(key: showPosterKey, from: showPoster, bearerToken: bearerToken)
        }
    }

    /// Restarts downloads interrupted by app suspension. Call when the app
    /// returns to the foreground (and on launch): a suspended `.default` session
    /// cancels its tasks and the OS hands back resume data, which we persisted
    /// as `{key}.resume`. This picks those files up and continues from the last
    /// byte. Fire-and-forget — no caller awaits the result; the delegate methods
    /// move the finished file into place. Returns the video ids it resumed.
    @discardableResult
    public func resumeInterrupted(bearerToken: String? = nil) -> [Int] {
        var resumed: [Int] = []
        var resumedIDs: Set<Int> = []

        func recordResumedID(_ id: Int) {
            if resumedIDs.insert(id).inserted {
                resumed.append(id)
            }
        }

        let manifests = lock.withLock {
            segmentedStore.manifests()
        }
        for manifest in manifests {
            let key = manifest.cacheKey
            let destination = localURL(
                for: manifest.videoId,
                versionId: manifest.versionId
            )
            if fileManager.fileExists(atPath: destination.path) {
                segmentedStore.remove(cacheKey: key)
                continue
            }
            let attempt = SegmentedAttempt(
                cacheKey: key,
                bearerToken: bearerToken,
                manifest: manifest,
                continuation: nil
            )
            let registered = lock.withLock {
                guard segmentedAttempts[key] == nil,
                      tasksByKey[key] == nil,
                      probeAttempts[key] == nil
                else { return false }
                segmentedAttempts[key] = attempt
                inFlight[key] = activityAccumulator(
                    manifest: manifest,
                    activeByteCounts: [:]
                )
                return true
            }
            guard registered else { continue }
            startIncompleteSegments(attempt: attempt, bearerToken: bearerToken)
            recordResumedID(manifest.videoId)
        }

        let contents = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        let keys = contents
            .filter { $0.hasSuffix(".resume") }
            .map { String($0.dropLast(".resume".count)) }
        for key in keys {
            let id = videoId(from: key)
            let vid = versionId(from: key)
            // Finished while we were away — drop the stale resume file.
            if fileManager.fileExists(atPath: localURL(for: id, versionId: vid).path) {
                try? fileManager.removeItem(at: resumeURL(for: key))
                continue
            }
            // A live task already owns this key (e.g. the user re-tapped download).
            if lock.withLock({
                tasksByKey[key] != nil
                    || segmentedAttempts[key] != nil
                    || probeAttempts[key] != nil
            }) {
                continue
            }
            guard let data = try? Data(contentsOf: resumeURL(for: key)), !data.isEmpty else { continue }
            let task = session.downloadTask(withResumeData: data)
            lock.withLock {
                inFlight[key] = DownloadActivityAccumulator(
                    videoID: id,
                    versionID: vid,
                    totalByteCount: nil,
                    now: now()
                )
                idByTask[task.taskIdentifier] = key
                tasksByKey[key] = task
                legacyResumeBaselineTaskIDs.insert(task.taskIdentifier)
            }
            task.resume()
            recordResumedID(id)
        }
        return resumed
    }

    /// Cancels an in-flight download for this id/version. The awaiting
    /// `download` call throws; `state(for:)` returns to `.notCached`.
    /// Explicit cancel restarts from scratch - it does not persist resume data.
    public func cancel(id: Int, versionId: Int? = nil) {
        let key = cacheKey(videoId: id, versionId: versionId)
        cancellationFence.beginCancellation(cacheKey: key)
        defer {
            cancellationFence.endCancellation(cacheKey: key)
        }
        let (probeTask, probeContinuation, segmentedAttempt) = lock.withLock {
            let probe = probeAttempts.removeValue(forKey: key)
            if probe != nil, segmentedAttempts[key] == nil {
                inFlight[key] = nil
            }
            let task = probe?.task
            let continuation = probe?.continuation
            probe?.task = nil
            probe?.continuation = nil
            return (task, continuation, segmentedAttempts[key])
        }
        probeTask?.cancel()
        probeContinuation?.resume(throwing: CancellationError())
        if let attempt = segmentedAttempt {
            let claim = lock.withLock { () -> (
                continuation: CheckedContinuation<URL, Error>?,
                tasks: [URLSessionDownloadTask],
                error: Error?
            )? in
                attempt.explicitlyCancelled = true
                return claimSegmentedAttemptLocked(
                    attempt,
                    error: CancellationError()
                )
            }
            if let claim {
                segmentedStore.remove(cacheKey: key)
                completeSegmentedClaim(
                    attempt,
                    continuation: claim.continuation,
                    result: .failure(CancellationError())
                )
                claim.tasks.forEach { $0.cancel() }
            }
        }
        lock.withLock({ tasksByKey[key] })?.cancel()
    }

    /// Deletes a cached MP4. Used when the server re-converts a file with a
    /// different audio track set, making the cached copy stale.
    public func removeCached(id: Int, versionId: Int? = nil) {
        try? fileManager.removeItem(at: localURL(for: id, versionId: versionId))
    }

    /// True when any cached MP4 (any version) exists for this video.
    public func hasAnyCached(id: Int) -> Bool {
        !cachedVideoFilenames(id: id).isEmpty
    }

    /// Deletes every cached MP4 and resume file for this video, all versions.
    /// Preview images and show posters are kept — small, still useful offline.
    public func removeAllCached(id: Int) {
        let contents = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        let resumes = contents.filter {
            $0 == "\(id).resume" || ($0.hasPrefix("\(id):") && $0.hasSuffix(".resume"))
        }
        for name in cachedVideoFilenames(id: id) + resumes {
            try? fileManager.removeItem(at: root.appendingPathComponent(name))
        }
        for manifest in segmentedStore.manifests() where manifest.videoId == id {
            segmentedStore.remove(cacheKey: manifest.cacheKey)
        }
    }

    /// Clears every downloaded video: cancels in-flight downloads, removes all
    /// MP4s + resume files + segment manifests + completion history. Preview
    /// images and show posters are kept (see `clearAllCovers()`).
    public func clearAllVideos() {
        for activity in activeDownloads() {
            cancel(id: activity.videoID, versionId: activity.versionID)
        }
        let contents = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        for name in contents where name.hasSuffix(".mp4") || name.hasSuffix(".resume") {
            try? fileManager.removeItem(at: root.appendingPathComponent(name))
        }
        for manifest in segmentedStore.manifests() {
            segmentedStore.remove(cacheKey: manifest.cacheKey)
        }
        lock.withLock { completionHistory.clear() }
    }

    /// Clears every cached preview image and show poster. Videos, resume data,
    /// manifests, and history are kept (see `clearAllVideos()`).
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

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64,
                           totalBytesExpectedToWrite: Int64) {
        if let context = lock.withLock({
            segmentContextByTask[downloadTask.taskIdentifier]
        }) {
            updateSegmentProgress(context: context, bytesWritten: bytesWritten)
            return
        }
        guard let key = lock.withLock({ idByTask[downloadTask.taskIdentifier] }) else { return }
        let progress: Double
        if totalBytesExpectedToWrite > 0 {
            progress = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
        } else {
            progress = 0
        }
        lock.withLock {
            guard tasksByKey[key]?.taskIdentifier == downloadTask.taskIdentifier else { return }
            if legacyResumeBaselineTaskIDs.remove(downloadTask.taskIdentifier) != nil {
                inFlight[key]?.establishResumeSamplingBaseline(
                    totalBytesWritten: totalBytesWritten,
                    bytesWritten: bytesWritten
                )
            }
            inFlight[key]?.record(
                transferredByteCount: totalBytesWritten,
                progress: progress,
                totalByteCount: totalBytesExpectedToWrite > 0
                    ? totalBytesExpectedToWrite
                    : nil,
                now: now()
            )
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {
        let taskIdentifier = downloadTask.taskIdentifier
        if let context = lock.withLock({ segmentContextByTask[taskIdentifier] }) {
            let result = recordSegmentFile(
                context: context,
                task: downloadTask,
                location: location
            )
            lock.withLock {
                guard let attempt = segmentedAttempts[context.cacheKey],
                      attempt.id == context.attemptID
                else { return }
                attempt.completedResults[context.segmentIndex] = result
            }
            return
        }
        guard let key = lock.withLock({ idByTask[taskIdentifier] }) else { return }

        let result: Result<URL, Error>
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            result = .failure(APIError.badStatus(http.statusCode))
        } else {
            do {
                try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
                let destination = localURL(for: videoId(from: key), versionId: versionId(from: key))
                try? fileManager.removeItem(at: destination)
                try fileManager.moveItem(at: location, to: destination)
                try? fileManager.removeItem(at: resumeURL(for: key))
                result = .success(destination)
            } catch {
                result = .failure(error)
            }
        }

        lock.withLock { completedResults[taskIdentifier] = result }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           didCompleteWithError error: Error?) {
        let taskIdentifier = task.taskIdentifier
        if let context = lock.withLock({ segmentContextByTask[taskIdentifier] }) {
            completeSegmentTask(
                context: context,
                taskIdentifier: taskIdentifier,
                error: error
            )
            return
        }
        guard let key = lock.withLock({ idByTask[taskIdentifier] }) else { return }

        if let error {
            persistResumeData(from: error, for: key)
            finish(key: key, taskIdentifier: taskIdentifier, result: .failure(error))
            return
        }

        let result = lock.withLock {
            completedResults[taskIdentifier] ?? .failure(URLError(.unknown))
        }
        finish(key: key, taskIdentifier: taskIdentifier, result: result)
    }

    private func downloadVideo(
        id: Int,
        versionId: Int?,
        from remote: URL,
        bearerToken: String?,
        streamCount: Int
    ) async throws -> URL {
        let key = cacheKey(videoId: id, versionId: versionId)
        if let data = try? Data(contentsOf: resumeURL(for: key)), !data.isEmpty {
            return try await downloadLegacy(key: key, resumeData: data)
        }
        let manifestURL = segmentedStore.manifestURL(cacheKey: key)
        if fileManager.fileExists(atPath: manifestURL.path) {
            let manifest: SegmentedDownloadManifest
            do {
                manifest = try segmentedStore.load(cacheKey: key)
            } catch {
                segmentedStore.remove(cacheKey: key)
                lock.withLock { inFlight[key] = nil }
                throw error
            }
            return try await startSegmentedAttempt(
                manifest: manifest,
                bearerToken: bearerToken
            )
        }

        let probeAttempt = FreshProbeAttempt(cacheKey: key)
        let canProbe = lock.withLock {
            guard segmentedAttempts[key] == nil,
                  probeAttempts[key] == nil
            else { return false }
            probeAttempts[key] = probeAttempt
            inFlight[key] = DownloadActivityAccumulator(
                videoID: id,
                versionID: versionId,
                totalByteCount: nil,
                now: now()
            )
            return true
        }
        guard canProbe else { throw CancellationError() }

        do {
            let probe = try await probe(
                remote: remote,
                bearerToken: bearerToken,
                attempt: probeAttempt
            )
            let manifest = try SegmentedDownloadManifest.make(
                videoId: id,
                versionId: versionId,
                remoteURL: remote,
                requestedStreamCount: streamCount,
                totalByteCount: probe.totalByteCount,
                etag: probe.etag
            )
            return try await startSegmentedAttempt(
                manifest: manifest,
                bearerToken: bearerToken,
                probeAttempt: probeAttempt
            )
        } catch {
            lock.withLock {
                guard probeAttempts[key]?.id == probeAttempt.id else { return }
                probeAttempts[key] = nil
                inFlight[key] = nil
            }
            throw error
        }
    }

    private func probe(
        remote: URL,
        bearerToken: String?,
        attempt: FreshProbeAttempt
    ) async throws -> DownloadProbe {
        var request = URLRequest(url: remote)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request) {
                    [weak self, weak attempt] data, response, error in
                        guard let self, let attempt else { return }
                        let result: Result<DownloadProbe, Error>
                        do {
                            if let error {
                                throw error
                            }
                            guard let http = response as? HTTPURLResponse else {
                                throw SegmentedDownloadError.invalidProbe
                            }
                            if (400..<600).contains(http.statusCode) {
                                throw APIError.badStatus(http.statusCode)
                            }
                            result = .success(try SegmentedDownloadStore.validateProbe(
                                http,
                                bodyCount: data?.count ?? 0
                            ))
                        } catch {
                            result = .failure(error)
                        }
                        self.completeProbe(attempt, result: result)
                }
                let shouldResume = lock.withLock {
                    guard probeAttempts[attempt.cacheKey]?.id == attempt.id else {
                        return false
                    }
                    attempt.task = task
                    attempt.continuation = continuation
                    return true
                }
                guard shouldResume else {
                    task.cancel()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                task.resume()
            }
        } onCancel: { [weak self, weak attempt] in
            guard let self, let attempt else { return }
            self.cancelProbeAttempt(attempt)
        }
    }

    private func cancelProbeAttempt(_ attempt: FreshProbeAttempt) {
        let claim: (
            task: URLSessionDataTask?,
            continuation: CheckedContinuation<DownloadProbe, Error>?
        ) = lock.withLock {
            guard probeAttempts[attempt.cacheKey]?.id == attempt.id else {
                return (nil, nil)
            }
            probeAttempts[attempt.cacheKey] = nil
            inFlight[attempt.cacheKey] = nil
            let task = attempt.task
            let continuation = attempt.continuation
            attempt.task = nil
            attempt.continuation = nil
            return (task, continuation)
        }
        claim.task?.cancel()
        claim.continuation?.resume(throwing: CancellationError())
    }

    private func completeProbe(
        _ attempt: FreshProbeAttempt,
        result: Result<DownloadProbe, Error>
    ) {
        let continuation: CheckedContinuation<DownloadProbe, Error>? = lock.withLock {
            guard probeAttempts[attempt.cacheKey]?.id == attempt.id else {
                return nil
            }
            attempt.task = nil
            let continuation = attempt.continuation
            attempt.continuation = nil
            return continuation
        }
        switch result {
        case .success(let probe):
            continuation?.resume(returning: probe)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }

    private func startSegmentedAttempt(
        manifest: SegmentedDownloadManifest,
        bearerToken: String?
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let attempt = SegmentedAttempt(
                cacheKey: manifest.cacheKey,
                bearerToken: bearerToken,
                manifest: manifest,
                continuation: continuation
            )
            let registered = lock.withLock {
                guard segmentedAttempts[manifest.cacheKey] == nil,
                      probeAttempts[manifest.cacheKey] == nil
                else { return false }
                segmentedAttempts[manifest.cacheKey] = attempt
                inFlight[manifest.cacheKey] = activityAccumulator(
                    manifest: manifest,
                    activeByteCounts: [:]
                )
                return true
            }
            guard registered else {
                continuation.resume(throwing: CancellationError())
                return
            }
            startIncompleteSegments(attempt: attempt, bearerToken: bearerToken)
        }
    }

    private func startSegmentedAttempt(
        manifest: SegmentedDownloadManifest,
        bearerToken: String?,
        probeAttempt: FreshProbeAttempt
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let attempt = SegmentedAttempt(
                cacheKey: manifest.cacheKey,
                bearerToken: bearerToken,
                manifest: manifest,
                continuation: continuation
            )
            let registration = lock.withLock { () -> Result<Void, Error> in
                guard probeAttempts[manifest.cacheKey]?.id == probeAttempt.id,
                      segmentedAttempts[manifest.cacheKey] == nil
                else { return .failure(CancellationError()) }
                do {
                    try cancellationFence.performMutation(
                        cacheKey: manifest.cacheKey
                    ) {
                        try segmentedStore.write(manifest)
                    }
                } catch {
                    segmentedStore.remove(cacheKey: manifest.cacheKey)
                    probeAttempts[manifest.cacheKey] = nil
                    inFlight[manifest.cacheKey] = nil
                    return .failure(error)
                }
                probeAttempts[manifest.cacheKey] = nil
                segmentedAttempts[manifest.cacheKey] = attempt
                inFlight[manifest.cacheKey] = activityAccumulator(
                    manifest: manifest,
                    activeByteCounts: [:]
                )
                return .success(())
            }
            guard case .success = registration else {
                if case .failure(let error) = registration {
                    continuation.resume(throwing: error)
                }
                return
            }
            startIncompleteSegments(attempt: attempt, bearerToken: bearerToken)
        }
    }

    private func startIncompleteSegments(
        attempt: SegmentedAttempt,
        bearerToken: String?
    ) {
        let incompleteSegments = attempt.manifest.segments.filter {
            !$0.isComplete
        }
        guard !incompleteSegments.isEmpty else {
            finishCompletedSegmentedAttemptIfReady(attempt)
            return
        }

        let starts = incompleteSegments.map { segment in
            let resumeURL = segmentedStore.resumeURL(
                cacheKey: attempt.cacheKey,
                index: segment.index
            )
            let resumeData = try? Data(contentsOf: resumeURL)
            return (
                segment: segment,
                resumeData: resumeData?.isEmpty == false ? resumeData : nil
            )
        }
        let freshSegmentIndexes = starts.compactMap {
            $0.resumeData == nil ? $0.segment.index : nil
        }
        let resetManifest: SegmentedDownloadManifest? = lock.withLock { () -> SegmentedDownloadManifest? in
            guard let current = segmentedAttempts[attempt.cacheKey],
                  current.id == attempt.id
            else { return nil }
            var didReset = false
            for index in freshSegmentIndexes
            where current.manifest.segments[index].persistedByteCount != 0 {
                current.manifest.segments[index].persistedByteCount = 0
                current.activeByteCounts[index] = nil
                didReset = true
            }
            guard didReset else { return nil }
            inFlight[attempt.cacheKey] = activityAccumulator(
                manifest: current.manifest,
                activeByteCounts: current.activeByteCounts
            )
            return current.manifest
        }
        if let resetManifest {
            do {
                try cancellationFence.performMutation(cacheKey: attempt.cacheKey) {
                    try segmentedStore.write(resetManifest)
                }
            } catch {
                let ownsFailure = lock.withLock {
                    guard let current = segmentedAttempts[attempt.cacheKey],
                          current.id == attempt.id,
                          !current.terminalClaimed
                    else { return false }
                    current.terminalError = error
                    current.preservingResumeData = false
                    return true
                }
                if ownsFailure {
                    finishFailedSegmentedAttemptIfReady(attempt)
                }
                return
            }
        }

        var tasksToStart: [URLSessionDownloadTask] = []
        for start in starts {
            let segment = start.segment
            let task: URLSessionDownloadTask
            let resumed: Bool
            if let resumeData = start.resumeData {
                task = session.downloadTask(withResumeData: resumeData)
                resumed = true
            } else {
                var request = URLRequest(url: attempt.manifest.remoteURL)
                request.setValue(segment.range.headerValue, forHTTPHeaderField: "Range")
                request.setValue(attempt.manifest.etag, forHTTPHeaderField: "If-Range")
                if let bearerToken {
                    request.setValue(
                        "Bearer \(bearerToken)",
                        forHTTPHeaderField: "Authorization"
                    )
                }
                task = session.downloadTask(with: request)
                resumed = false
            }
            let context = SegmentTaskContext(
                attemptID: attempt.id,
                cacheKey: attempt.cacheKey,
                segmentIndex: segment.index,
                resumed: resumed
            )
            let shouldResume = lock.withLock {
                guard let current = segmentedAttempts[attempt.cacheKey],
                      current.id == attempt.id
                else { return false }
                attempt.taskIDs.insert(task.taskIdentifier)
                segmentContextByTask[task.taskIdentifier] = context
                tasksByIdentifier[task.taskIdentifier] = task
                return true
            }
            guard shouldResume else {
                task.cancel()
                tasksToStart.forEach { $0.cancel() }
                return
            }
            tasksToStart.append(task)
        }
        tasksToStart.forEach { $0.resume() }
    }

    /// Re-requests a single segment's byte range from scratch after a transient
    /// transport failure, leaving the attempt's other segment tasks untouched.
    private func relaunchSegment(attempt: SegmentedAttempt, segmentIndex: Int) {
        let segment = attempt.manifest.segments[segmentIndex]
        var request = URLRequest(url: attempt.manifest.remoteURL)
        request.setValue(segment.range.headerValue, forHTTPHeaderField: "Range")
        request.setValue(attempt.manifest.etag, forHTTPHeaderField: "If-Range")
        if let bearerToken = attempt.bearerToken {
            request.setValue(
                "Bearer \(bearerToken)",
                forHTTPHeaderField: "Authorization"
            )
        }
        let task = session.downloadTask(with: request)
        let context = SegmentTaskContext(
            attemptID: attempt.id,
            cacheKey: attempt.cacheKey,
            segmentIndex: segmentIndex,
            resumed: false
        )
        let shouldResume = lock.withLock {
            guard let current = segmentedAttempts[attempt.cacheKey],
                  current.id == attempt.id,
                  !current.terminalClaimed
            else { return false }
            attempt.taskIDs.insert(task.taskIdentifier)
            segmentContextByTask[task.taskIdentifier] = context
            tasksByIdentifier[task.taskIdentifier] = task
            return true
        }
        if shouldResume {
            task.resume()
        } else {
            task.cancel()
        }
    }

    private func downloadLegacy(key: String, resumeData: Data) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.downloadTask(withResumeData: resumeData)
            lock.withLock {
                inFlight[key] = DownloadActivityAccumulator(
                    videoID: videoId(from: key),
                    versionID: versionId(from: key),
                    totalByteCount: nil,
                    now: now()
                )
                continuations[task.taskIdentifier] = continuation
                idByTask[task.taskIdentifier] = key
                tasksByKey[key] = task
                legacyResumeBaselineTaskIDs.insert(task.taskIdentifier)
            }
            task.resume()
        }
    }

    private func updateSegmentProgress(
        context: SegmentTaskContext,
        bytesWritten: Int64
    ) {
        lock.withLock {
            guard let attempt = segmentedAttempts[context.cacheKey],
                  attempt.id == context.attemptID,
                  !attempt.terminalClaimed
            else { return }
            attempt.activeByteCounts[context.segmentIndex, default: 0]
                += max(bytesWritten, 0)
            inFlight[context.cacheKey]?.record(
                transferredByteCount: transferredByteCount(
                    manifest: attempt.manifest,
                    activeByteCounts: attempt.activeByteCounts
                ),
                progress: SegmentedDownloadStore.progress(
                    manifest: attempt.manifest,
                    activeByteCounts: attempt.activeByteCounts
                ),
                now: now()
            )
        }
    }

    private func activityAccumulator(
        manifest: SegmentedDownloadManifest,
        activeByteCounts: [Int: Int64]
    ) -> DownloadActivityAccumulator {
        let progress = SegmentedDownloadStore.progress(
            manifest: manifest,
            activeByteCounts: activeByteCounts
        )
        let now = now()
        var accumulator = DownloadActivityAccumulator(
            videoID: manifest.videoId,
            versionID: manifest.versionId,
            totalByteCount: manifest.totalByteCount,
            now: now
        )
        accumulator.record(
            transferredByteCount: transferredByteCount(
                manifest: manifest,
                activeByteCounts: activeByteCounts
            ),
            progress: progress,
            now: now
        )
        return accumulator
    }

    private func transferredByteCount(
        manifest: SegmentedDownloadManifest,
        activeByteCounts: [Int: Int64]
    ) -> Int64 {
        manifest.segments.reduce(0) { $0 + $1.persistedByteCount }
            + activeByteCounts.values.reduce(0, +)
    }

    private func recordSegmentFile(
        context: SegmentTaskContext,
        task: URLSessionDownloadTask,
        location: URL
    ) -> Result<URL, Error> {
        lock.withLock {
            guard let attempt = segmentedAttempts[context.cacheKey],
                  attempt.id == context.attemptID,
                  !attempt.terminalClaimed
            else {
                return .failure(CancellationError())
            }

            do {
                guard let response = task.response as? HTTPURLResponse else {
                    throw SegmentedDownloadError.invalidSegmentResponse(
                        index: context.segmentIndex
                    )
                }
                let record = attempt.manifest.segments[context.segmentIndex]
                let size = ((try fileManager.attributesOfItem(
                    atPath: location.path
                )[.size]) as? NSNumber)?.int64Value ?? -1
                try SegmentedDownloadStore.validateSegment(
                    response,
                    planned: record,
                    etag: attempt.manifest.etag,
                    totalByteCount: attempt.manifest.totalByteCount,
                    fileSize: size,
                    resumed: context.resumed
                )
                let part = segmentedStore.partURL(
                    cacheKey: context.cacheKey,
                    index: context.segmentIndex
                )
                try cancellationFence.performMutation(cacheKey: context.cacheKey) {
                    try? fileManager.removeItem(at: part)
                    try fileManager.moveItem(at: location, to: part)
                }
                return .success(part)
            } catch {
                return .failure(error)
            }
        }
    }

    private func completeSegmentTask(
        context: SegmentTaskContext,
        taskIdentifier: Int,
        error: Error?
    ) {
        var owningAttempt: SegmentedAttempt?
        var completionError = error
        var unsafeCompletionError: Error?
        var segmentToRetry: Int?
        var directResumeData: Data?
        var directResumeDataNeedsPendingRemoval = false
        var tasksToPreserve: [(
            task: URLSessionDownloadTask,
            taskIdentifier: Int,
            segmentIndex: Int
        )] = []
        var tasksToCancel: [URLSessionDownloadTask] = []

        lock.withLock {
            tasksByIdentifier[taskIdentifier] = nil
            segmentContextByTask[taskIdentifier] = nil

            guard let attempt = segmentedAttempts[context.cacheKey],
                  attempt.id == context.attemptID,
                  !attempt.terminalClaimed
            else { return }
            owningAttempt = attempt
            attempt.taskIDs.remove(taskIdentifier)

            if cancellationFence.isCancellationRequested(cacheKey: context.cacheKey) {
                completionError = CancellationError()
            }
            let recordedResult = attempt.completedResults.removeValue(
                forKey: context.segmentIndex
            )
            if case .failure(let segmentError)? = recordedResult {
                completionError = segmentError
                unsafeCompletionError = segmentError
            }
            if completionError == nil {
                switch recordedResult ?? .failure(URLError(.unknown)) {
                case .success:
                    attempt.manifest.segments[context.segmentIndex].isComplete = true
                    attempt.manifest.segments[context.segmentIndex].persistedByteCount =
                        attempt.manifest.segments[context.segmentIndex].range.length
                    attempt.activeByteCounts[context.segmentIndex] = nil
                    inFlight[context.cacheKey]?.record(
                        transferredByteCount: transferredByteCount(
                            manifest: attempt.manifest,
                            activeByteCounts: attempt.activeByteCounts
                        ),
                        progress: SegmentedDownloadStore.progress(
                            manifest: attempt.manifest,
                            activeByteCounts: attempt.activeByteCounts
                        ),
                        now: now()
                    )
                case .failure(let segmentError):
                    completionError = segmentError
                    unsafeCompletionError = segmentError
                }
            }
            if completionError == nil {
                do {
                    try cancellationFence.performMutation(
                        cacheKey: context.cacheKey
                    ) {
                        try? fileManager.removeItem(at: segmentedStore.resumeURL(
                            cacheKey: context.cacheKey,
                            index: context.segmentIndex
                        ))
                        try segmentedStore.write(attempt.manifest)
                    }
                } catch let persistenceError {
                    completionError = persistenceError
                    unsafeCompletionError = persistenceError
                }
            }
            if let completionError {
                let cancelling = attempt.explicitlyCancelled
                    || cancellationFence.isCancellationRequested(cacheKey: context.cacheKey)
                let retriesUsed = attempt.segmentRetryCounts[context.segmentIndex] ?? 0
                let retryable = unsafeCompletionError == nil
                    && attempt.terminalError == nil
                    && !cancelling
                    && retriesUsed < SegmentedAttempt.maxSegmentRetries
                    && (error.map {
                        isResumableTransportError($0, preservingResumeData: false)
                    } ?? false)
                if retryable {
                    // A transient blip on one segment must not discard the whole
                    // multiplexed download: re-request just this segment's range
                    // from scratch and leave the sibling tasks running.
                    attempt.segmentRetryCounts[context.segmentIndex] = retriesUsed + 1
                    attempt.manifest.segments[context.segmentIndex].isComplete = false
                    attempt.manifest.segments[context.segmentIndex].persistedByteCount = 0
                    attempt.activeByteCounts[context.segmentIndex] = nil
                    inFlight[context.cacheKey]?.record(
                        transferredByteCount: transferredByteCount(
                            manifest: attempt.manifest,
                            activeByteCounts: attempt.activeByteCounts
                        ),
                        progress: SegmentedDownloadStore.progress(
                            manifest: attempt.manifest,
                            activeByteCounts: attempt.activeByteCounts
                        ),
                        now: now()
                    )
                    segmentToRetry = context.segmentIndex
                } else if let unsafeCompletionError {
                    if attempt.terminalError == nil || attempt.preservingResumeData {
                        attempt.terminalError = unsafeCompletionError
                    }
                    attempt.preservingResumeData = false
                    tasksToCancel = attempt.taskIDs.compactMap {
                        tasksByIdentifier[$0]
                    }
                } else if attempt.terminalError == nil {
                    attempt.terminalError = completionError
                    if let transportError = error,
                       isResumableTransportError(
                        transportError,
                        preservingResumeData: false
                       ) {
                        attempt.preservingResumeData = true
                        updatePersistedByteCountLocked(
                            attempt: attempt,
                            segmentIndex: context.segmentIndex
                        )
                        directResumeData = resumeData(from: transportError)
                        if directResumeData != nil {
                            attempt.resumeDataPendingTaskIDs.insert(taskIdentifier)
                            directResumeDataNeedsPendingRemoval = true
                        }
                        tasksToPreserve = attempt.taskIDs.compactMap { siblingID in
                            guard let task = tasksByIdentifier[siblingID],
                                  let siblingContext = segmentContextByTask[siblingID],
                                  siblingContext.attemptID == attempt.id
                            else { return nil }
                            attempt.resumeDataPendingTaskIDs.insert(siblingID)
                            return (
                                task,
                                siblingID,
                                siblingContext.segmentIndex
                            )
                        }
                    } else {
                        tasksToCancel = attempt.taskIDs.compactMap {
                            tasksByIdentifier[$0]
                        }
                    }
                } else if attempt.preservingResumeData,
                          let transportError = error,
                          isResumableTransportError(
                            transportError,
                            preservingResumeData: true
                          ) {
                    updatePersistedByteCountLocked(
                        attempt: attempt,
                        segmentIndex: context.segmentIndex
                    )
                    directResumeData = resumeData(from: transportError)
                }
            }
        }

        guard let attempt = owningAttempt else { return }
        if let segmentToRetry {
            relaunchSegment(attempt: attempt, segmentIndex: segmentToRetry)
            return
        }
        if directResumeData != nil || directResumeDataNeedsPendingRemoval {
            preserveSegmentResumeData(
                directResumeData,
                attempt: attempt,
                segmentIndex: context.segmentIndex,
                pendingTaskIdentifier: directResumeDataNeedsPendingRemoval
                    ? taskIdentifier
                    : nil
            )
        }
        for sibling in tasksToPreserve {
            sibling.task.cancel(byProducingResumeData: {
                [weak self, weak attempt] data in
                guard let self, let attempt else { return }
                self.preserveSegmentResumeData(
                    data,
                    attempt: attempt,
                    segmentIndex: sibling.segmentIndex,
                    pendingTaskIdentifier: sibling.taskIdentifier
                )
            })
        }
        tasksToCancel.forEach { $0.cancel() }

        finishFailedSegmentedAttemptIfReady(attempt)
        finishCompletedSegmentedAttemptIfReady(attempt)
    }

    private func finishCompletedSegmentedAttemptIfReady(
        _ attempt: SegmentedAttempt
    ) {
        var claim: (
            continuation: CheckedContinuation<URL, Error>?,
            tasks: [URLSessionDownloadTask],
            error: Error?
        )?
        _ = cancellationFence.performTerminalClaim(cacheKey: attempt.cacheKey) {
            lock.withLock {
                guard let current = segmentedAttempts[attempt.cacheKey],
                      current.id == attempt.id,
                      current.terminalError == nil,
                      current.taskIDs.isEmpty,
                      current.resumeDataPendingTaskIDs.isEmpty,
                      current.manifest.segments.allSatisfy(\.isComplete),
                      let currentClaim = claimSegmentedAttemptLocked(current)
                else { return false }
                claim = currentClaim
                return true
            }
        }
        guard let claim else { return }
        let destination = localURL(
            for: attempt.manifest.videoId,
            versionId: attempt.manifest.versionId
        )
        do {
            try segmentedStore.assemble(
                manifest: attempt.manifest,
                destination: destination
            )
            completeSegmentedClaim(
                attempt,
                continuation: claim.continuation,
                result: .success(destination)
            )
        } catch {
            segmentedStore.remove(cacheKey: attempt.cacheKey)
            completeSegmentedClaim(
                attempt,
                continuation: claim.continuation,
                result: .failure(error)
            )
        }
    }

    private func finishFailedSegmentedAttemptIfReady(
        _ attempt: SegmentedAttempt
    ) {
        let ready: (
            manifest: SegmentedDownloadManifest,
            preservingResumeData: Bool
        )? = lock.withLock {
            guard let current = segmentedAttempts[attempt.cacheKey],
                  current.id == attempt.id,
                  !current.terminalClaimed,
                  current.terminalError != nil,
                  current.taskIDs.isEmpty,
                  current.resumeDataPendingTaskIDs.isEmpty
            else { return nil }
            return (current.manifest, current.preservingResumeData)
        }
        guard var ready else { return }

        if ready.preservingResumeData {
            do {
                try cancellationFence.performMutation(
                    cacheKey: attempt.cacheKey
                ) {
                    try segmentedStore.write(ready.manifest)
                }
            } catch {
                lock.withLock {
                    guard let current = segmentedAttempts[attempt.cacheKey],
                          current.id == attempt.id
                    else { return }
                    current.preservingResumeData = false
                }
                ready.preservingResumeData = false
            }
        }

        var claim: (
            continuation: CheckedContinuation<URL, Error>?,
            tasks: [URLSessionDownloadTask],
            error: Error?
        )?
        var preservesScratch = false
        _ = cancellationFence.performTerminalClaim(cacheKey: attempt.cacheKey) {
            lock.withLock {
                guard let current = segmentedAttempts[attempt.cacheKey],
                      current.id == attempt.id,
                      current.terminalError != nil,
                      current.taskIDs.isEmpty,
                      current.resumeDataPendingTaskIDs.isEmpty,
                      let currentClaim = claimSegmentedAttemptLocked(current)
                else { return false }
                current.activeByteCounts.removeAll()
                preservesScratch = current.preservingResumeData
                claim = currentClaim
                return true
            }
        }
        guard let claim, let terminalError = claim.error else { return }
        if !preservesScratch {
            segmentedStore.remove(cacheKey: attempt.cacheKey)
        }
        completeSegmentedClaim(
            attempt,
            continuation: claim.continuation,
            result: .failure(terminalError)
        )
    }

    private func isResumableTransportError(
        _ error: Error,
        preservingResumeData: Bool
    ) -> Bool {
        if resumeData(from: error) != nil {
            return true
        }
        if let urlError = error as? URLError {
            return preservingResumeData || urlError.code != .cancelled
        }
        return preservingResumeData && error is CancellationError
    }

    private func resumeData(from error: Error) -> Data? {
        let data = (error as NSError)
            .userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        return data?.isEmpty == false ? data : nil
    }

    private func updatePersistedByteCountLocked(
        attempt: SegmentedAttempt,
        segmentIndex: Int
    ) {
        let active = max(attempt.activeByteCounts[segmentIndex] ?? 0, 0)
        let segment = attempt.manifest.segments[segmentIndex]
        attempt.manifest.segments[segmentIndex].persistedByteCount = min(
            segment.range.length,
            max(segment.persistedByteCount, active)
        )
    }

    private func preserveSegmentResumeData(
        _ data: Data?,
        attempt: SegmentedAttempt,
        segmentIndex: Int,
        pendingTaskIdentifier: Int?
    ) {
        let shouldPersist = lock.withLock {
            guard let current = segmentedAttempts[attempt.cacheKey],
                  current.id == attempt.id,
                  current.preservingResumeData,
                  !current.manifest.segments[segmentIndex].isComplete
            else { return false }
            updatePersistedByteCountLocked(
                attempt: current,
                segmentIndex: segmentIndex
            )
            return data?.isEmpty == false
        }

        var persistenceFailed = false
        if shouldPersist, let data {
            do {
                try cancellationFence.performMutation(
                    cacheKey: attempt.cacheKey
                ) {
                    try data.write(
                        to: segmentedStore.resumeURL(
                            cacheKey: attempt.cacheKey,
                            index: segmentIndex
                        ),
                        options: .atomic
                    )
                }
            } catch {
                persistenceFailed = true
            }
        }

        lock.withLock {
            guard let current = segmentedAttempts[attempt.cacheKey],
                  current.id == attempt.id
            else { return }
            if persistenceFailed {
                current.preservingResumeData = false
            }
            if let pendingTaskIdentifier {
                current.resumeDataPendingTaskIDs.remove(pendingTaskIdentifier)
            }
        }
        finishFailedSegmentedAttemptIfReady(attempt)
    }

    private func claimSegmentedAttemptLocked(
        _ attempt: SegmentedAttempt,
        error: Error? = nil
    ) -> (
        continuation: CheckedContinuation<URL, Error>?,
        tasks: [URLSessionDownloadTask],
        error: Error?
    )? {
        guard let current = segmentedAttempts[attempt.cacheKey],
              current.id == attempt.id,
              !current.terminalClaimed
        else { return nil }
        current.terminalClaimed = true
        if current.terminalError == nil {
            current.terminalError = error
        }
        let continuation = current.continuation
        current.continuation = nil
        return (
            continuation,
            current.taskIDs.compactMap { tasksByIdentifier[$0] },
            current.terminalError
        )
    }

    private func completeSegmentedClaim(
        _ attempt: SegmentedAttempt,
        continuation: CheckedContinuation<URL, Error>?,
        result: Result<URL, Error>
    ) {
        lock.withLock {
            guard let current = segmentedAttempts[attempt.cacheKey],
                  current.id == attempt.id,
                  current.terminalClaimed
            else { return }
            if case .success = result {
                completionHistory.record(DownloadCompletion(
                    videoID: attempt.manifest.videoId,
                    versionID: attempt.manifest.versionId,
                    completedAt: now()
                ))
            }
            segmentedAttempts[attempt.cacheKey] = nil
            inFlight[attempt.cacheKey] = nil
        }
        switch result {
        case .success(let url):
            continuation?.resume(returning: url)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }

    private func finish(key: String, taskIdentifier: Int, result: Result<URL, Error>) {
        let continuation = lock.withLock {
            idByTask[taskIdentifier] = nil
            completedResults[taskIdentifier] = nil
            legacyResumeBaselineTaskIDs.remove(taskIdentifier)
            if tasksByKey[key]?.taskIdentifier == taskIdentifier {
                if case .success = result {
                    completionHistory.record(DownloadCompletion(
                        videoID: videoId(from: key),
                        versionID: versionId(from: key),
                        completedAt: now()
                    ))
                }
                inFlight[key] = nil
                tasksByKey[key] = nil
            }
            return continuations.removeValue(forKey: taskIdentifier)
        }

        switch result {
        case .success(let url):
            continuation?.resume(returning: url)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }

    private func persistResumeData(from error: Error, for key: String) {
        let userInfo = (error as NSError).userInfo
        guard let data = userInfo[NSURLSessionDownloadTaskResumeData] as? Data, !data.isEmpty else {
            return
        }
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: resumeURL(for: key), options: .atomic)
    }

    private func resumeURL(for key: String) -> URL {
        root.appendingPathComponent("\(key).resume")
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

    private func videoId(from key: String) -> Int {
        Int(key.split(separator: ":").first ?? "") ?? 0
    }

    private func versionId(from key: String) -> Int? {
        let parts = key.split(separator: ":")
        guard parts.count == 2 else { return nil }
        return Int(parts[1])
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
