// ios/PatataTube/Sources/AppModel.swift
import Foundation
import Combine
import SwiftUI
import Network
import PatataTubeKit

@MainActor
final class AppModel: ObservableObject {
    let credentials: CredentialStore
    let cache: CacheManager
    let store: VideoStore
    let api: APIClient
    private let downloadSettings: DownloadStreamSettings
    private let simultaneousSettings: SimultaneousDownloadSettings
    private let hlsCacheSettings = HLSCacheSizeSettings()

    @Published var baseURLText: String
    @Published var tokenText: String
    @Published var downloadStreamCount: Int
    @Published var downloadConcurrency: Int
    @Published var hlsCacheCapGigabytes: Int = HLSCacheSizeSettings.defaultGigabytes

    @Published private(set) var isOnWiFi = true
    @Published private(set) var hasNetwork = true
    private let pathMonitor = NWPathMonitor()

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
        cache: CacheManager = CacheManager(),
        downloadSettings: DownloadStreamSettings = DownloadStreamSettings(),
        simultaneousSettings: SimultaneousDownloadSettings = SimultaneousDownloadSettings()
    ) {
        let api = APIClient(store: credentials)
        self.credentials = credentials
        self.cache = cache
        self.api = api
        self.store = VideoStore(api: api, cache: VideoListCache())
        self.downloadSettings = downloadSettings
        self.simultaneousSettings = simultaneousSettings
        self.downloadStreamCount = downloadSettings.load()
        self.downloadConcurrency = simultaneousSettings.load()
        self.baseURLText = credentials.baseURL?.absoluteString ?? ""
        self.tokenText = credentials.token ?? ""
        cache.setMaxConcurrentDownloads(self.downloadConcurrency)
        let capBytes = hlsCacheSettings.load()
        self.hlsCacheCapGigabytes = Int(capBytes / HLSCacheSizeSettings.bytesPerGigabyte)
        cache.setTempCacheCap(bytes: capBytes)
        startNetworkMonitor()
    }

    /// Fill-ahead is Wi-Fi-only, so playback needs the current interface type.
    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.hasNetwork = path.status == .satisfied
                self?.isOnWiFi = path.status == .satisfied
                    && !path.usesInterfaceType(.cellular)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "patatatube.network.monitor"))
    }

    /// Everything the cache needs to serve one video.
    func playbackTarget(for video: Video) -> CacheManager.PlaybackTarget {
        CacheManager.PlaybackTarget(
            id: video.id,
            versionId: video.chosenVersionId,
            master: hlsURL(for: video),
            bearerToken: credentials.token,
            title: video.title ?? video.sourceFilename ?? "PatataTube",
            audioLang: video.audioLang,
            hlsStatus: video.hlsStatus)
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
        hlsCacheCapGigabytes = min(
            max(hlsCacheCapGigabytes, HLSCacheSizeSettings.allowedGigabytes.lowerBound),
            HLSCacheSizeSettings.allowedGigabytes.upperBound
        )
        let capBytes = Int64(hlsCacheCapGigabytes) * HLSCacheSizeSettings.bytesPerGigabyte
        hlsCacheSettings.save(capBytes)
        cache.setTempCacheCap(bytes: capBytes)
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

    /// HLS master playlist URL, or nil when the server did not advertise one.
    func hlsURL(for video: Video) -> URL? {
        guard let hlsPath = video.hlsPath, !hlsPath.isEmpty else { return nil }
        return absoluteURL(for: video, path: hlsPath)
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
