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
        self.store = VideoStore(api: api, cache: VideoListCache())
        self.downloadSettings = downloadSettings
        self.simultaneousSettings = simultaneousSettings
        self.downloadStreamCount = downloadSettings.load()
        self.downloadConcurrency = simultaneousSettings.load()
        self.baseURLText = credentials.baseURL?.absoluteString ?? ""
        self.tokenText = credentials.token ?? ""
        cache.setMaxConcurrentDownloads(self.downloadConcurrency)
        Task { await streamProxy.start() }
    }

    func saveSettings() {
        credentials.baseURL = URL(string: baseURLText.trimmingCharacters(in: .whitespaces))
        credentials.token = tokenText.isEmpty ? nil : tokenText
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
        case .clearVideos: await clearVideos()
        case .clearCovers: await clearCovers()
        case .clearLists: await clearLists()
        case .resetSettings: resetSettings()
        }
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
        tokenText = ""
        baseURLText = ""
        downloadStreamCount = DownloadStreamSettings.defaultCount
        downloadConcurrency = SimultaneousDownloadSettings.defaultCount
        downloadSettings.save(downloadStreamCount)
        simultaneousSettings.save(downloadConcurrency)
        cache.setMaxConcurrentDownloads(downloadConcurrency)
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
