import Foundation
import Combine

public enum PrepareError: Error, Equatable {
    case conversionFailed(String)
}

@MainActor
public final class VideoStore: ObservableObject {
    @Published public private(set) var videos: [Video] = []
    @Published public var filter: String? {
        didSet { defaults.set(filter, forKey: Self.filterKey) }
    }
    @Published public private(set) var isLoading = false
    @Published public var errorText: String?

    private let api: VideoAPI
    private let cache: VideoListCaching?
    private let defaults: UserDefaults
    private static let filterKey = "selectedClassification"

    public init(api: VideoAPI, cache: VideoListCaching? = nil, defaults: UserDefaults = .standard) {
        self.api = api
        self.cache = cache
        self.defaults = defaults
        self.filter = defaults.string(forKey: Self.filterKey)
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
            // A cancelled fetch is routine SwiftUI lifecycle (.task and .refreshable
            // cancel their work on view updates, and a newer load supersedes an older
            // one). It says nothing about the server, so leave the list and errorText
            // untouched rather than banner it or fall back to stale cache.
            if Self.isCancellation(error) { return }
            if let cached = cache?.load(classification: filter) {
                videos = cached
            }
            report(error)
        }
    }

    /// True for routine task cancellation -- SwiftUI cancelling a `.task`/`.refreshable`,
    /// or a newer request superseding an older one. Never a server-side failure.
    public static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    /// Surfaces a failure to the user, swallowing cancellations.
    private func report(_ error: Error) {
        if Self.isCancellation(error) { return }
        errorText = String(describing: error)
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
            report(error)
        }
    }

    public func chooseVersion(id: Int, versionId: Int) async {
        guard let index = videos.firstIndex(where: { $0.id == id }) else { return }
        let previous = videos[index]
        videos[index] = videos[index].withChosenVersion(versionId)
        do {
            let ok = try await api.chooseVersion(id: id, versionId: versionId)
            if !ok { videos[index] = previous }
        } catch {
            videos[index] = previous
            report(error)
        }
    }

    /// Optimistically records the chosen audio language, then reloads so a
    /// server-triggered re-conversion ("converting" status) shows up.
    public func chooseAudio(id: Int, lang: String) async {
        guard let index = videos.firstIndex(where: { $0.id == id }) else { return }
        let previous = videos[index]
        videos[index] = videos[index].withAudioLang(lang)
        do {
            let ok = try await api.chooseAudio(id: id, lang: lang)
            if ok {
                await load()
            } else {
                videos[index] = previous
            }
        } catch {
            videos[index] = previous
            report(error)
        }
    }

    /// Deletes on the server, then refreshes the list (and cache) from the API.
    public func delete(id: Int) async {
        do {
            _ = try await api.delete(id: id)
            await load()
        } catch {
            report(error)
        }
    }

    public func upload(url: String) async {
        do {
            _ = try await api.upload(url: url)
            await load()
        } catch {
            report(error)
        }
    }

    /// Scan the server-side Plex library, then reload the list.
    /// A failed scan surfaces in errorText but still refreshes the list.
    public func refreshLibrary() async {
        var scanErrorText: String?
        do {
            _ = try await api.scanLibrary()
        } catch {
            if !Self.isCancellation(error) { scanErrorText = String(describing: error) }
        }
        await load()
        // If the scan failed but load() itself succeeded (errorText is nil),
        // restore the scan failure so it still surfaces to the user. If load()
        // failed too, its error is more relevant and takes precedence.
        if let scanErrorText, errorText == nil {
            errorText = scanErrorText
        }
    }

    /// Kicks off server-side conversion (if needed) and polls until the video
    /// is streamable. Throws PrepareError when the server reports a failed conversion.
    public func ensureReady(id: Int, pollIntervalSeconds: Double = 2.0) async throws -> Video {
        let status = try await api.prepare(id: id)
        if status == "done" {
            return try await api.video(id: id)
        }
        while true {
            let video = try await api.video(id: id)
            if video.status == "done" { return video }
            if let message = video.errorMsg, !message.isEmpty {
                throw PrepareError.conversionFailed(message)
            }
            try await Task.sleep(nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000))
        }
    }
}
