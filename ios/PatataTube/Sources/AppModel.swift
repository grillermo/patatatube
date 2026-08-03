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
    let groupPosters = GroupPosterStore()
    private let downloadSettings: DownloadStreamSettings
    private let simultaneousSettings: SimultaneousDownloadSettings

    @Published var baseURLText: String
    @Published var tokenText: String
    @Published var downloadStreamCount: Int
    @Published var downloadConcurrency: Int

    /// When on, a finished video rolls into the next one in the queue. Session-only
    /// by design — it resets to off on relaunch, so a long queue can never keep
    /// playing across launches unnoticed.
    @Published var autoplay: Bool = false

    /// Keyed by classification (`store.filter`, `"all"` for the unfiltered
    /// tab). Session-only, same lifetime as `autoplay` — not persisted
    /// across relaunch.
    @Published var randomizeByClassification: [String: Bool] = [:]

    /// Bumped by the "Open Web" quick action. A counter, not a Bool, so a
    /// second shortcut tap re-opens the bridge even if the flag never got
    /// cleared — the grid only reacts to changes.
    @Published var webBridgeRequests: Int = 0

    func randomize(for classification: String?) -> Bool {
        randomizeByClassification[classification ?? "all"] ?? false
    }

    func randomizeBinding(for classification: String?) -> Binding<Bool> {
        Binding(
            get: { self.randomize(for: classification) },
            set: { self.randomizeByClassification[classification ?? "all"] = $0 }
        )
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
            positionStore: resumeStore,
            groupPosters: groupPosters
        )
        self.downloadSettings = downloadSettings
        self.simultaneousSettings = simultaneousSettings
        self.downloadStreamCount = downloadSettings.load()
        self.downloadConcurrency = simultaneousSettings.load()
        self.baseURLText = credentials.baseURL?.absoluteString ?? ""
        self.tokenText = credentials.token ?? ""
        cache.setMaxConcurrentDownloads(self.downloadConcurrency)
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
        case .openWeb: webBridgeRequests += 1
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
