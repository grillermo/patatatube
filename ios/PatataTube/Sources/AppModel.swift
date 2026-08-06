// ios/PatataTube/Sources/AppModel.swift
import Foundation
import Combine
import SwiftUI
import PatataTubeKit

@MainActor
final class AppModel: ObservableObject {
    let credentials: CredentialStore
    let cache: CacheManager
    let streamCache: StreamCache
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
    let videoListCache: VideoListCache
    let groups = GroupStore()
    private let downloadSettings: DownloadStreamSettings
    private let simultaneousSettings: SimultaneousDownloadSettings

    @Published var baseURLText: String
    @Published var tokenText: String
    @Published var downloadStreamCount: Int
    @Published var downloadConcurrency: Int

    /// Keyed by `Feed.storageKey` ("all" / "group:3" / "plex:tv"), so a
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

    /// Scope key for one TV show's episode list. Prefixed so a show titled
    /// "movies" can never share a bucket with the movies tab.
    static func showScope(_ title: String) -> String { "show:\(title)" }

    func autoplay(for feed: Feed) -> Bool { autoplayByFeed[feed.storageKey] ?? false }

    /// Episode queues keep their existing per-show scope; feeds use the typed
    /// overload above.
    func autoplay(for scope: String?) -> Bool {
        scope.flatMap { autoplayByFeed[$0] } ?? false
    }

    func autoplayBinding(for feed: Feed) -> Binding<Bool> {
        Binding(
            get: { self.autoplay(for: feed) },
            set: { self.autoplayByFeed[feed.storageKey] = $0 }
        )
    }

    func autoplayBinding(for scope: String) -> Binding<Bool> {
        Binding(
            get: { self.autoplayByFeed[scope] ?? false },
            set: { self.autoplayByFeed[scope] = $0 }
        )
    }

    /// Bumped by the "Open Web" quick action. A counter, not a Bool, so a
    /// second shortcut tap re-opens the bridge even if the flag never got
    /// cleared — the grid only reacts to changes.
    @Published var webBridgeRequests: Int = 0

    /// True while a launch through the "Open Web" quick action is holding
    /// restoration back. The point of that shortcut is the web bridge, so
    /// replaying last session's tab/path/player underneath it (and flashing it
    /// on screen first) is exactly wrong — restoration waits until the bridge
    /// is dismissed.
    @Published private(set) var restorationDeferred = false

    /// Bumped when a deferred restoration is released. Views re-run their
    /// restore on a change; the `RestorationGate` still keeps it to one run.
    @Published private(set) var restorationReleases = 0

    /// Called by the views that would otherwise restore at launch. Reads the
    /// router directly because the shortcut can be delivered either before or
    /// after `handle(_:)` gets a chance to run. Returns whether restoration is
    /// currently being held back.
    @discardableResult
    func deferRestorationIfWebLaunch() -> Bool {
        if restorationDeferred { return true }
        guard QuickActionRouter.shared.pending == .openWeb else { return false }
        deferRestoration()
        return restorationDeferred
    }

    /// No-op once restoration has already run — a shortcut tap on an app that
    /// is already up has nothing to defer.
    private func deferRestoration() {
        guard !restorationDeferred, !restorationGate.isClaimed else { return }
        restorationDeferred = true
        DevLog.event(.nav, "restoration deferred", ["reason": "openWeb quick action"])
    }

    /// Web bridge dismissed: let the launch restoration happen now.
    func releaseRestoration() {
        guard restorationDeferred else { return }
        restorationDeferred = false
        restorationReleases += 1
        DevLog.event(.nav, "restoration released", ["reason": "web bridge dismissed"])
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
        cellSizeByFeed[feed.storageKey] = value
        UserDefaults.standard.set(cellSizeByFeed, forKey: Self.cellSizeDefaultsKey)
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
        credentials: CredentialStore = KeychainCredentialStore(),
        cacheRoot: URL? = nil,
        downloadSettings: DownloadStreamSettings = DownloadStreamSettings(),
        simultaneousSettings: SimultaneousDownloadSettings = SimultaneousDownloadSettings()
    ) {
        let api = APIClient(store: credentials)
        let resumeStore = ResumePositionStore(serverURL: credentials.baseURL)
        let streamCache = StreamCache()
        let cache = CacheManager(root: cacheRoot, streamCache: streamCache)
        self.credentials = credentials
        self.streamCache = streamCache
        self.cache = cache
        self.streamProxy = StreamProxy(
            cache: streamCache,
            credentials: credentials,
            offlineRoot: cache.videosRoot
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
        self.baseURLText = credentials.baseURL?.absoluteString ?? ""
        self.tokenText = credentials.token ?? ""
        cache.setMaxConcurrentDownloads(self.downloadConcurrency)
        loadCellSizes()
        // On a real device the backend is DevLog's only sink, so nothing is
        // recorded until it knows where to post. No-op without DEVLOG.
        DevLog.connect(baseURL: credentials.baseURL, token: credentials.token)
        Task { await streamProxy.start() }
    }

    func saveSettings() {
        credentials.baseURL = URL(string: baseURLText.trimmingCharacters(in: .whitespaces))
        credentials.token = tokenText.isEmpty ? nil : tokenText
        resumeStore.useServer(credentials.baseURL)
        DevLog.connect(baseURL: credentials.baseURL, token: credentials.token)
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
        case .openWeb:
            deferRestoration()
            webBridgeRequests += 1
        case .clearVideos: await clearVideos()
        case .clearCovers: await clearCovers()
        case .clearLists: await clearLists()
        case .resetSettings: resetSettings()
        case .clearRestoration: clearRestoration()
        }
    }

    /// Wipes the saved path/player/scroll state. The running session keeps
    /// whatever is on screen — the point is a clean slate for the *next*
    /// launch, so a bad restored state can't be replayed forever.
    func clearRestoration() {
        restorationStore.clear()
        restorationGate.reset()
        DevLog.event(.state, "restoration cleared")
    }

    func clearVideos() async {
        cache.clearAllVideos()
        await store.load()
    }

    func clearCovers() async {
        cache.clearAllCovers()
        await store.load()
    }

    func clearLists() async {
        store.clearListCache()
        await store.load()
    }

    /// Logs out (Keychain token + base URL) and resets download settings to
    /// defaults. Leaves cached files untouched.
    func resetSettings() {
        credentials.token = nil
        credentials.baseURL = nil
        resumeStore.useServer(nil)
        tokenText = ""
        baseURLText = ""
        downloadStreamCount = DownloadStreamSettings.defaultCount
        downloadConcurrency = SimultaneousDownloadSettings.defaultCount
        downloadSettings.save(downloadStreamCount)
        simultaneousSettings.save(downloadConcurrency)
        cache.setMaxConcurrentDownloads(downloadConcurrency)
    }

    func makeCacheStatisticsCollector() -> CacheStatisticsCollector {
        CacheStatisticsCollector(
            videosRoot: cache.videosRoot,
            streamRoot: streamCache.root,
            videoListRoot: videoListCache.root
        )
    }

    /// Absolute stream/download URL for a video's `streamPath`.
    func streamURL(for video: Video) -> URL? {
        return absoluteURL(for: video, path: video.streamPath)
    }

    /// HLS master playlist URL, or nil when the server did not advertise one.
    func hlsURL(for video: Video) -> URL? {
        guard let hlsPath = video.hlsPath, !hlsPath.isEmpty else { return nil }
        return absoluteURL(for: video, path: hlsPath)
    }

    /// Proxied HLS playback URL; nil when no HLS package or proxy is down.
    func proxiedHLSURL(for video: Video) -> URL? {
        guard video.hlsPath?.isEmpty == false else { return nil }
        return streamProxy.hlsURL(videoId: video.id, versionId: video.chosenVersionId)
    }

    /// Proxied MP4 playback URL; nil when proxy is down.
    func proxiedMP4URL(for video: Video) -> URL? {
        streamProxy.mp4URL(videoId: video.id, versionId: video.chosenVersionId)
    }

    /// Offline HLS playback URL for a promoted package; nil when absent/proxy down.
    func offlineHLSURL(for video: Video) -> URL? {
        guard cache.offlineHLSMasterURL(for: video.id, versionId: video.chosenVersionId) != nil
        else { return nil }
        return streamProxy.offlineHLSURL(videoId: video.id, versionId: video.chosenVersionId)
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
