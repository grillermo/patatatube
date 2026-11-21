// ios/PatataTube/Sources/AppModel.swift
import Foundation
import Combine
import SwiftUI
import PatataTubeKit

@MainActor
final class AppModel: ObservableObject {
    let credentials: CredentialStore
    /// Points `credentials.baseURL` at the LAN server while it answers, the
    /// remote URL otherwise. Nil when the store isn't routed (tests).
    let serverPicker: ServerPicker?
    let cache: CacheManager
    let streamProxy: StreamProxy
    let store: VideoStore
    let api: APIClient
    /// Local mirror of server resume positions, and the throttled writer that
    /// keeps the server in sync. Shared so the grid can read a position at tap
    /// time and the player can report against the same store.
    let resumeStore: ResumePositionStore
    lazy var positions = PlaybackPositionReporter(api: api, store: resumeStore)
    let restorationStore = RestorationStore()
    /// Restoration is a launch concern, and `VideoGridView`'s restore lives in
    /// a `.task` that SwiftUI restarts whenever the grid re-enters the
    /// hierarchy (every `fullScreenCover` dismissal). The gate lives here, not
    /// in the view, so exactly one run per launch can apply saved state.
    let restorationGate = RestorationGate()
    /// Last time the app was in front of the user or playing something.
    let idle = IdleTracker()
    /// Bumped by `resetAfterIdle`. An open `VideoPlayerView` watches it and
    /// dismisses itself — the grid's and the PiP-restore's covers both.
    @Published private(set) var idleResetToken = 0
    /// Play-and-sleep reached its end: `SleepScreen` covers the whole app until
    /// a long-press clears it. Set by both the full-screen player and the audio
    /// queue, including while backgrounded, so it is waiting on return.
    @Published var sleepScreenShown = false
    /// This process started more than an hour after the last engagement.
    private(set) var launchedAfterIdle = false
    /// Picture in Picture outlives the player cover, so its state lives here.
    let pip = PiPSession()
    /// Audio-only playback for the group-detail list. Lives here, like `pip`,
    /// because it must survive the list view that started it.
    let audio = AudioQueuePlayer()
    let videoListCache: VideoListCache
    let groups = GroupStore()
    private let downloadSettings: DownloadStreamSettings
    private let simultaneousSettings: SimultaneousDownloadSettings

    @Published var baseURLText: String
    @Published var lanURLText: String
    @Published var tokenText: String
    @Published var downloadStreamCount: Int
    @Published var downloadConcurrency: Int

    /// Keyed by `Feed.storageKey` ("all" / "group:3"), so a
    /// preference set on one group leaves the others alone. New key names on
    /// purpose: the old dictionaries were keyed by classification name and
    /// their entries mean nothing now.
    ///
    /// The three dictionaries keep whatever storage mechanism they have today
    /// (read the file — only their names and key strings change here).
    @Published var autoplayByFeed: [String: Bool] = [:]

    @Published var randomizeByFeed: [String: Bool] = [:]

    /// Grid cell size per feed, persisted (unlike the two above — a chosen
    /// cell size is a layout preference, not a playback mode). Seeded from the
    /// old global `gridCellSize` so existing installs keep their size.
    @Published var cellSizeByFeed: [String: Double] = [:]

    static let defaultCellSize: Double = 220
    private static let cellSizeDefaultsKey = "gridCellSizes"
    private static let legacyCellSizeKey = "gridCellSize"

    /// Autoplay is **on until switched off**: nothing is persisted, so every
    /// launch starts every scope at the default, and that default is on.
    func autoplay(for feed: Feed) -> Bool { autoplayByFeed[feed.storageKey] ?? true }

    /// For a scope key already resolved to a string (the player's
    /// `autoplayScope`); feeds use the typed overload above.
    func autoplay(for scope: String?) -> Bool {
        scope.flatMap { autoplayByFeed[$0] } ?? true
    }

    func autoplayBinding(for feed: Feed) -> Binding<Bool> {
        Binding(
            get: { self.autoplay(for: feed) },
            set: { self.autoplayByFeed[feed.storageKey] = $0 }
        )
    }

    func autoplayBinding(for scope: String) -> Binding<Bool> {
        Binding(
            get: { self.autoplay(for: scope) },
            set: { self.autoplayByFeed[scope] = $0 }
        )
    }

    func randomize(for feed: Feed) -> Bool { randomizeByFeed[feed.storageKey] ?? false }

    func randomize(for scope: String?) -> Bool {
        scope.flatMap { randomizeByFeed[$0] } ?? false
    }

    func randomizeBinding(for feed: Feed) -> Binding<Bool> {
        Binding(
            get: { self.randomize(for: feed) },
            set: { self.randomizeByFeed[feed.storageKey] = $0 }
        )
    }

    func randomizeBinding(for scope: String) -> Binding<Bool> {
        Binding(
            get: { self.randomizeByFeed[scope] ?? false },
            set: { self.randomizeByFeed[scope] = $0 }
        )
    }

    func cellSize(for feed: Feed) -> Double { cellSizeByFeed[feed.storageKey] ?? legacyCellSize }

    func setCellSize(_ value: Double, for feed: Feed) {
        let wasGrid = GridDisplayMode.forCellSize(cellSize(for: feed)) != .list
        cellSizeByFeed[feed.storageKey] = value
        UserDefaults.standard.set(cellSizeByFeed, forKey: Self.cellSizeDefaultsKey)
        if wasGrid, GridDisplayMode.forCellSize(value) == .list {
            autoplayByFeed[feed.storageKey] = true
        }
    }

    private var legacyCellSize: Double {
        let stored = UserDefaults.standard.double(forKey: Self.legacyCellSizeKey)
        return stored > 0 ? stored : Self.defaultCellSize
    }

    private func loadCellSizes() {
        cellSizeByFeed = UserDefaults.standard
            .dictionary(forKey: Self.cellSizeDefaultsKey) as? [String: Double] ?? [:]
    }

    init(
        credentials: CredentialStore = RoutedCredentialStore(inner: KeychainCredentialStore()),
        cacheRoot: URL? = nil,
        downloadSettings: DownloadStreamSettings = DownloadStreamSettings(),
        simultaneousSettings: SimultaneousDownloadSettings = SimultaneousDownloadSettings()
    ) {
        let api = APIClient(store: credentials)
        let resumeStore = ResumePositionStore(serverURL: credentials.identityURL)
        let cache = CacheManager(root: cacheRoot, credentials: credentials)
        self.credentials = credentials
        let routed = credentials as? RoutedCredentialStore
        self.serverPicker = routed.map(ServerPicker.init(store:))
        self.cache = cache
        self.streamProxy = StreamProxy(
            store: cache.mediaStore,
            credentials: credentials
        )
        self.api = api
        self.resumeStore = resumeStore
        let videoListCache = VideoListCache()
        self.videoListCache = videoListCache
        self.store = VideoStore(
            api: api,
            cache: videoListCache,
            mediaCache: cache,
            positionStore: resumeStore
        )
        self.downloadSettings = downloadSettings
        self.simultaneousSettings = simultaneousSettings
        self.downloadStreamCount = downloadSettings.load()
        self.downloadConcurrency = simultaneousSettings.load()
        self.baseURLText = credentials.identityURL?.absoluteString ?? ""
        self.lanURLText = routed?.lanURLText ?? ""
        self.tokenText = credentials.token ?? ""
        cache.setMaxConcurrentDownloads(self.downloadConcurrency)
        loadCellSizes()
        // On a real device the backend is DevLog's only sink, so nothing is
        // recorded until it knows where to post. No-op without DEVLOG.
        DevLog.connect(baseURL: credentials.identityURL, token: credentials.token)
        Task { await streamProxy.start() }
        // Cold launch: nothing is on screen yet. `VideoGridView.initialLoad`
        // reads this to skip re-presenting the saved player, and resets its
        // position once the row (and so whether it remembers) is known.
        launchedAfterIdle = idle.isStale()
        idle.markEngaged()
    }

    private static let legacyHLSPendingKey = "legacyHLSRedownloads"
    private var legacyHLSMigrationRunning = false

    /// 2.8 -> 2.9: offline HLS packages and paused HLS downloads are gone;
    /// download those videos again as mp4. Runs on every activation until the
    /// pending list is empty. A video the server no longer has (404) leaves
    /// the list rather than being retried forever; a pause or cancellation
    /// keeps it for the next activation.
    func migrateLegacyHLSDownloads() {
        let defaults = UserDefaults.standard
        var pending = Set(defaults.array(forKey: Self.legacyHLSPendingKey) as? [Int] ?? [])
        pending.formUnion(cache.removeLegacyHLSPackages())
        defaults.set(pending.sorted(), forKey: Self.legacyHLSPendingKey)
        guard !pending.isEmpty, !legacyHLSMigrationRunning,
              let base = credentials.baseURL else { return }
        legacyHLSMigrationRunning = true
        let token = credentials.token
        let streams = downloadStreamCount
        let cache = self.cache
        Task { @MainActor in
            await withBoundedTaskGroup(limit: cache.maxConcurrentDownloads, over: pending.sorted()) { id in
                let url = base.appendingPathComponent("videos/\(id)/stream")
                do {
                    try await cache.download(id: id, from: url, bearerToken: token, streamCount: streams)
                } catch is CancellationError {
                    return
                } catch is DownloadPausedError {
                    return
                } catch {
                    DevLog.error(error, "legacy HLS re-download failed", ["video_id": "\(id)"])
                }
                var left = Set(UserDefaults.standard.array(forKey: Self.legacyHLSPendingKey) as? [Int] ?? [])
                left.remove(id)
                UserDefaults.standard.set(left.sorted(), forKey: Self.legacyHLSPendingKey)
            }
            self.legacyHLSMigrationRunning = false
        }
    }

    /// Called whenever the scene becomes active. After more than an hour away
    /// (and nothing playing), the previous session is over: nothing keeps
    /// playing, no player stays full screen, and positions that aren't
    /// remembered go back to 0 so the next tap starts from the top.
    func appDidBecomeActive() {
        // Audio only marks on start/stop, so a queue still going is engaged now.
        if audio.isPlaying { idle.markEngaged() }
        if idle.isStale() { resetAfterIdle() }
        idle.markEngaged()
    }

    private func resetAfterIdle() {
        DevLog.event(.lifecycle, "idle reset", [
            "last_engaged": idle.lastEngagedAt.map { "\(Int($0.timeIntervalSince1970))" } ?? "nil",
        ])
        audio.stop()
        if let floating = pip.floatingVideo {
            pip.stopFloating()
            resetPositionIfForgotten(floating)
        }
        // Open players dismiss themselves and write their own reset position
        // on the way out, after the teardown's own position write.
        idleResetToken += 1
        restorationStore.mutate { $0.player = nil }
    }

    /// One play of `video` — any player (full-screen or the audio queue) calls
    /// this each time an item starts, and every call is counted, so replays
    /// keep climbing `videos.play_count`. Deliberately not deduplicated per
    /// run: a count that ignores replays is not a play count. What is not a new
    /// play is a *handover* of an already-playing item between the mini player
    /// and the full-screen player, and those call sites skip this instead.
    ///
    /// Only the play that empties the badge answers `changed`, and only then is
    /// the group list refetched — rather than edited locally, so the badge is
    /// always exactly what the server counts.
    func markPlayed(_ video: Video) {
        let id = video.id
        store.markWatched(id: id)
        Task {
            if let changed = try? await api.markPlayed(id: id), changed,
               let remote = try? await api.groups() {
                groups.apply(remote)
            }
        }
    }

    func resetPositionIfForgotten(_ video: Video) {
        guard !groups.remembersPosition(video) else { return }
        let id = video.id
        Task { await positions.record(id: id, secs: 0, duration: nil, force: true) }
    }


    func saveSettings() {
        credentials.baseURL = URL(string: baseURLText.trimmingCharacters(in: .whitespaces))
        credentials.token = tokenText.isEmpty ? nil : tokenText
        if let routed = credentials as? RoutedCredentialStore {
            routed.lanURLText = lanURLText
            lanURLText = routed.lanURLText
        }
        serverPicker?.settingsChanged()
        resumeStore.useServer(credentials.identityURL)
        DevLog.connect(baseURL: credentials.identityURL, token: credentials.token)
        downloadStreamCount = min(
            max(downloadStreamCount, DownloadStreamSettings.allowedCounts.lowerBound),
            DownloadStreamSettings.allowedCounts.upperBound
        )
        downloadSettings.save(downloadStreamCount)
        downloadConcurrency = min(
            max(downloadConcurrency, SimultaneousDownloadSettings.allowedCounts.lowerBound),
            SimultaneousDownloadSettings.allowedCounts.upperBound
        )
        simultaneousSettings.save(downloadConcurrency)
        cache.setMaxConcurrentDownloads(downloadConcurrency)
    }

    func handle(_ action: QuickAction) async {
        switch action {
        case .clearAll: clearAll()
        // Opened as a link by SceneDelegate; never routed here.
        case .installLatest: break
        }
    }

    /// Leaves the app as if freshly installed: downloads cancelled, every file
    /// the app wrote deleted, UserDefaults and the Keychain token wiped. Then
    /// the process exits — the stores in memory still hold the old state, and
    /// several of them write it back to UserDefaults as they go, so only a
    /// fresh launch actually starts from nothing.
    func clearAll() {
        DevLog.event(.state, "clear all")
        DevLog.flush()
        audio.stop()
        cache.clearAllVideos()
        let fm = FileManager.default
        let roots = [
            fm.urls(for: .documentDirectory, in: .userDomainMask)[0],
            fm.urls(for: .cachesDirectory, in: .userDomainMask)[0],
            fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
            fm.temporaryDirectory,
        ]
        for root in roots {
            for item in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.removeItem(at: item)
            }
        }
        credentials.token = nil
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            UserDefaults.standard.synchronize()
        }
        exit(0)
    }

    func makeCacheStatisticsCollector() -> CacheStatisticsCollector {
        CacheStatisticsCollector(
            videosRoot: cache.videosRoot,
            streamRoot: cache.mediaStore.storeRoot,
            videoListRoot: videoListCache.root
        )
    }

    /// Absolute stream/download URL for a video's `streamPath`.
    func streamURL(for video: Video) -> URL? {
        return absoluteURL(for: video, path: video.streamPath)
    }

    /// `streamURL` with the token in its query, for an AirPlay receiver: the
    /// Apple TV fetches the URL itself, so it can't use the stream proxy
    /// (loopback) or a bearer header.
    func airPlayStreamURL(for video: Video) -> URL? {
        guard !video.streamPath.isEmpty, let token = credentials.token,
              let url = streamURL(for: video),
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "token", value: token)]
        return comps.url
    }

    /// Proxied MP4 playback URL; nil when proxy is down.
    func proxiedMP4URL(for video: Video) -> URL? {
        streamProxy.mp4URL(videoId: video.id, versionId: video.chosenVersionId)
    }

    private func absoluteURL(for video: Video, path rawPath: String) -> URL? {
        guard let base = credentials.baseURL else { return nil }
        let path = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url = base.appendingPathComponent(path)
        guard let versionId = video.chosenVersionId,
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "version_id", value: "\(versionId)")]
        return comps.url
    }
}
