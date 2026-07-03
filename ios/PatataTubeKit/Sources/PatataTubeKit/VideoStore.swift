import Foundation
import Combine

@MainActor
public final class VideoStore: ObservableObject {
    @Published public private(set) var videos: [Video] = []
    @Published public var filter: String?
    @Published public private(set) var isLoading = false
    @Published public var errorText: String?

    private let api: VideoAPI

    public init(api: VideoAPI) { self.api = api }

    public func load() async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            videos = try await api.videos(classification: filter)
        } catch {
            errorText = String(describing: error)
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
