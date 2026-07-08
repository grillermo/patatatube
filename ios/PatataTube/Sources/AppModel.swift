// ios/PatataTube/Sources/AppModel.swift
import Foundation
import Combine
import PatataTubeKit

@MainActor
final class AppModel: ObservableObject {
    let credentials: CredentialStore
    let cache: CacheManager
    let store: VideoStore
    let api: APIClient

    @Published var baseURLText: String
    @Published var tokenText: String

    init() {
        let credentials = KeychainCredentialStore()
        let api = APIClient(store: credentials)
        self.credentials = credentials
        self.cache = CacheManager()
        self.api = api
        self.store = VideoStore(api: api, cache: VideoListCache())
        self.baseURLText = credentials.baseURL?.absoluteString ?? ""
        self.tokenText = credentials.token ?? ""
    }

    func saveSettings() {
        credentials.baseURL = URL(string: baseURLText.trimmingCharacters(in: .whitespaces))
        credentials.token = tokenText.isEmpty ? nil : tokenText
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
