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
        guard let base = credentials.baseURL else { return nil }
        return base.appendingPathComponent(video.streamPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}
