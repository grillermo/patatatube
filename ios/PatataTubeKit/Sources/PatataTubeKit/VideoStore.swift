import Foundation
import Combine

@MainActor
public final class VideoStore: ObservableObject {
    @Published public private(set) var videos: [Video] = []
    @Published public var filter: String?
    @Published public private(set) var isLoading = false
    @Published public var errorText: String?

    private let api: VideoAPI
    private let cache: VideoListCaching?

    public init(api: VideoAPI, cache: VideoListCaching? = nil) {
        self.api = api
        self.cache = cache
    }

    /// Boot path: show cached videos instantly if present, then refresh from network.
    /// With no cache, falls back to a plain network load.
    public func bootLoad() async {
        if let cached = cache?.load(classification: filter), !cached.isEmpty {
            videos = cached
        }
        await load()
    }

    public func load() async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            let fetched = try await api.videos(classification: filter)
            videos = fetched
            cache?.save(fetched, classification: filter)
        } catch {
            if let cached = cache?.load(classification: filter) {
                videos = cached
            } else {
                errorText = String(describing: error)
            }
        }
    }

    public func classify(id: Int, to classification: String) async {
        guard let index = videos.firstIndex(where: { $0.id == id }) else { return }
        let previous = videos
        videos[index] = videos[index].withClassification(classification)
        do {
            let ok = try await api.classify(id: id, classification: classification)
            if !ok { videos = previous }
        } catch {
            videos = previous
            errorText = String(describing: error)
        }
    }

    public func move(id: Int, direction: String) async {
        do {
            let ok = try await api.move(id: id, direction: direction)
            if ok { await load() }
        } catch {
            errorText = String(describing: error)
        }
    }

    public func upload(url: String) async {
        do {
            _ = try await api.upload(url: url)
            await load()
        } catch {
            errorText = String(describing: error)
        }
    }
}
