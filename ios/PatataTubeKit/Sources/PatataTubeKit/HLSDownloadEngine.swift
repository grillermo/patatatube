import AVFoundation
import Foundation

struct HLSDownloadRequest: Sendable {
    let cacheKey: String
    let videoId: Int
    let versionId: Int?
    let master: URL
    let bearerToken: String?
    let title: String
    let audioLang: String?
    /// Fill-ahead started by playback (Wi-Fi only) vs an explicit Download tap.
    let isFillAhead: Bool
}

enum HLSDownloadEvent: Sendable {
    case progress(cacheKey: String, fraction: Double, transferredBytes: Int64)
    case finished(cacheKey: String)
    case failed(cacheKey: String, error: Error)
    case cancelled(cacheKey: String)
}

enum HLSDownloadError: Error, Equatable {
    /// The session refused to create a task (bad asset, or no HLS at that URL).
    case taskCreationFailed
}

protocol HLSDownloading: AnyObject, Sendable {
    /// Starts (or resumes) the download for `request` and returns the asset the
    /// player should use. Returning the *task's* asset is what makes playback
    /// read through the download's own store.
    func start(_ request: HLSDownloadRequest) -> AVURLAsset?
    func cancel(cacheKey: String)
    func isRunning(cacheKey: String) -> Bool
    func runningKeys() -> Set<String>
    /// Reattaches to tasks that survived app suspension/termination.
    func restoreTasks() async
    func setEventHandler(_ handler: @escaping @Sendable (HLSDownloadEvent) -> Void)
}

/// Owns the app's two `AVAssetDownloadURLSession`s: one Wi-Fi-only session for
/// watch-driven fill-ahead, one unrestricted session for explicit downloads.
/// A session is one-per-identifier and must never be invalidated, so both live
/// for the app's lifetime.
final class HLSDownloadEngine: NSObject, HLSDownloading, AVAssetDownloadDelegate, @unchecked Sendable {
    private let store: HLSAssetStore
    private let lock = NSLock()
    private var handler: (@Sendable (HLSDownloadEvent) -> Void)?
    private var tasksByKey: [String: AVAggregateAssetDownloadTask] = [:]
    private var keysByTask: [Int: String] = [:]
    private var requestsByKey: [String: HLSDownloadRequest] = [:]

    private var fillAheadSession: AVAssetDownloadURLSession!
    private var manualSession: AVAssetDownloadURLSession!

    init(store: HLSAssetStore) {
        self.store = store
        super.init()
        let fillAhead = URLSessionConfiguration.background(
            withIdentifier: "patatatube.hls.fillahead")
        // Watching must never spend cellular data in the background; an explicit
        // Download tap goes through `manualSession` instead.
        fillAhead.allowsCellularAccess = false
        fillAheadSession = AVAssetDownloadURLSession(
            configuration: fillAhead, assetDownloadDelegate: self, delegateQueue: .main)

        let manual = URLSessionConfiguration.background(withIdentifier: "patatatube.hls.manual")
        manual.allowsCellularAccess = true
        manualSession = AVAssetDownloadURLSession(
            configuration: manual, assetDownloadDelegate: self, delegateQueue: .main)
    }

    func setEventHandler(_ handler: @escaping @Sendable (HLSDownloadEvent) -> Void) {
        lock.withLock { self.handler = handler }
    }

    func isRunning(cacheKey: String) -> Bool {
        lock.withLock { tasksByKey[cacheKey] != nil }
    }

    func runningKeys() -> Set<String> {
        lock.withLock { Set(tasksByKey.keys) }
    }

    func start(_ request: HLSDownloadRequest) -> AVURLAsset? {
        if let existing = lock.withLock({ tasksByKey[request.cacheKey] }) {
            return existing.urlAsset
        }
        let asset = makeAsset(for: request)
        let session = request.isFillAhead ? fillAheadSession! : manualSession!
        guard let task = session.aggregateAssetDownloadTask(
            with: asset,
            mediaSelections: asset.allMediaSelections,
            assetTitle: request.title,
            assetArtworkData: nil,
            options: nil
        ) else {
            emit(.failed(cacheKey: request.cacheKey, error: HLSDownloadError.taskCreationFailed))
            return nil
        }
        lock.withLock {
            tasksByKey[request.cacheKey] = task
            keysByTask[task.taskIdentifier] = request.cacheKey
            requestsByKey[request.cacheKey] = request
        }
        task.resume()
        return task.urlAsset
    }

    /// Resume source. Per the Task 0 spike: a previously started package resumes
    /// when the task is recreated from the *local* `.movpkg` asset; the remote
    /// master is used only for a first-time download. If the spike found the
    /// remote asset also resumes, this still works — the local asset is the
    /// stronger guarantee and needs no network for the playlist.
    private func makeAsset(for request: HLSDownloadRequest) -> AVURLAsset {
        if let entry = store.entry(cacheKey: request.cacheKey),
           !entry.isComplete,
           let local = store.resolve(entry) {
            return AVURLAsset(url: local)
        }
        var options: [String: Any] = [:]
        if let token = request.bearerToken {
            options["AVURLAssetHTTPHeaderFieldsKey"] = ["Authorization": "Bearer \(token)"]
        }
        return AVURLAsset(url: request.master, options: options)
    }

    func cancel(cacheKey: String) {
        let task = lock.withLock { () -> AVAggregateAssetDownloadTask? in
            guard let task = tasksByKey.removeValue(forKey: cacheKey) else { return nil }
            keysByTask[task.taskIdentifier] = nil
            requestsByKey[cacheKey] = nil
            return task
        }
        guard let task else { return }
        // Cancelling keeps the partial package: the whole point is resuming it.
        task.cancel()
        emit(.cancelled(cacheKey: cacheKey))
    }

    /// Background sessions outlive the process. Reattach so a download that
    /// continued while the app was away keeps reporting progress.
    func restoreTasks() async {
        for session in [fillAheadSession!, manualSession!] {
            let tasks = await session.allTasks
            for task in tasks.compactMap({ $0 as? AVAggregateAssetDownloadTask }) {
                guard let key = cacheKey(matching: task) else {
                    task.cancel()
                    continue
                }
                lock.withLock {
                    tasksByKey[key] = task
                    keysByTask[task.taskIdentifier] = key
                }
            }
        }
    }

    /// Maps a restored task back to a cache key via the index: the only durable
    /// link is the package location AVFoundation reported in `willDownloadTo`.
    private func cacheKey(matching task: AVAggregateAssetDownloadTask) -> String? {
        let url = task.urlAsset.url
        for entry in store.entries() where store.resolve(entry) == url {
            return entry.cacheKey
        }
        return nil
    }

    private func emit(_ event: HLSDownloadEvent) {
        let handler = lock.withLock { self.handler }
        handler?(event)
    }

    // MARK: AVAssetDownloadDelegate

    func urlSession(
        _ session: URLSession,
        aggregateAssetDownloadTask task: AVAggregateAssetDownloadTask,
        willDownloadTo location: URL
    ) {
        guard let key = lock.withLock({ keysByTask[task.taskIdentifier] }),
              let request = lock.withLock({ requestsByKey[key] }),
              let bookmark = HLSAssetStore.makeBookmark(for: location)
        else { return }
        // First sighting of the package's location — record it before any byte
        // lands so a kill mid-download still leaves a resumable, evictable row.
        let existing = store.entry(cacheKey: key)
        store.upsert(HLSCacheEntry(
            cacheKey: key,
            videoId: request.videoId,
            versionId: request.versionId,
            bookmark: bookmark,
            kind: request.isFillAhead ? (existing?.kind ?? .temp) : .permanent,
            isComplete: false,
            fractionComplete: existing?.fractionComplete ?? 0,
            byteCount: existing?.byteCount ?? 0,
            lastPlayedAt: existing?.lastPlayedAt ?? Date(),
            audioLang: request.audioLang))
    }

    func urlSession(
        _ session: URLSession,
        aggregateAssetDownloadTask task: AVAggregateAssetDownloadTask,
        didLoad timeRange: CMTimeRange,
        totalTimeRangesLoaded loadedTimeRanges: [NSValue],
        timeRangeExpectedToLoad: CMTimeRange,
        for mediaSelection: AVMediaSelection
    ) {
        guard let key = lock.withLock({ keysByTask[task.taskIdentifier] }) else { return }
        let loaded = loadedTimeRanges.reduce(0.0) { $0 + $1.timeRangeValue.duration.seconds }
        let expected = timeRangeExpectedToLoad.duration.seconds
        let fraction = expected > 0 ? min(max(loaded / expected, 0), 1) : 0
        emit(.progress(
            cacheKey: key, fraction: fraction, transferredBytes: task.countOfBytesReceived))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let key = lock.withLock({ () -> String? in
            guard let key = keysByTask.removeValue(forKey: task.taskIdentifier) else { return nil }
            tasksByKey[key] = nil
            requestsByKey[key] = nil
            return key
        }) else { return }

        if let error {
            let urlError = error as? URLError
            if urlError?.code == .cancelled {
                emit(.cancelled(cacheKey: key))
            } else {
                emit(.failed(cacheKey: key, error: error))
            }
            return
        }
        emit(.finished(cacheKey: key))
    }
}
