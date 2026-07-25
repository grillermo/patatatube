import Foundation
import AVFoundation

/// Orchestrates watch-to-cache: owns one `RangeFetcher` per playing video and
/// serves an `AVURLAsset` whose loading AVFoundation routes through this object.
///
/// The asset is built on a private `ptcapture://` URL (the real `https://`
/// remote with only its scheme swapped). AVFoundation cannot load a custom
/// scheme itself, so every content-info and data request is handed to the
/// `AVAssetResourceLoaderDelegate` methods below, which adapt them to the
/// matching `RangeFetcher`.
public final class CaptureManager: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    public static let scheme = "ptcapture"

    private let registry: RangeFetcherRegistry
    private let delegateQueue = DispatchQueue(label: "patatatube.capture.loader")
    private let lock = NSLock()
    /// Maps a capturing asset's URL back to the cache key of its fetcher.
    /// Populated in `asset(...)` and read in the delegate — this is how a
    /// loading request finds its fetcher without reverse-matching remote URLs
    /// or re-parsing video/version ids out of the URL.
    private var keysByCaptureURL: [URL: String] = [:]

    init(registry: RangeFetcherRegistry) {
        self.registry = registry
    }

    // MARK: Scheme helpers (unit-tested)

    public static func captureURL(from remote: URL) -> URL? {
        guard var comps = URLComponents(url: remote, resolvingAgainstBaseURL: false) else { return nil }
        comps.scheme = scheme
        return comps.url
    }

    public static func remoteURL(from captureURL: URL) -> URL? {
        guard var comps = URLComponents(url: captureURL, resolvingAgainstBaseURL: false) else { return nil }
        comps.scheme = "https"
        return comps.url
    }

    // MARK: Registry

    func fetcher(forCacheKey key: String) -> RangeFetcher? {
        registry.existing(cacheKey: key)
    }

    /// Builds a capturing asset for a video, registering a `RangeFetcher` keyed
    /// on `videoId[:versionId]`. Re-using the same identity returns a fresh
    /// asset wired to a fresh fetcher (the manifest on disk resumes progress).
    public func asset(
        videoId: Int,
        versionId: Int?,
        remoteURL: URL,
        bearerToken: String?,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) -> AVURLAsset {
        let key = versionId.map { "\(videoId):\($0)" } ?? "\(videoId)"
        let fetcher = registry.fetcher(
            videoId: videoId, versionId: versionId, remoteURL: remoteURL,
            bearerToken: bearerToken, onProgress: onProgress)
        _ = fetcher
        let captureURL = Self.captureURL(from: remoteURL) ?? remoteURL
        lock.withLock { keysByCaptureURL[captureURL] = key }
        let asset = AVURLAsset(url: captureURL)
        asset.resourceLoader.setDelegate(self, queue: delegateQueue)
        return asset
    }

    // MARK: AVAssetResourceLoaderDelegate

    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let url = loadingRequest.request.url,
              let key = lock.withLock({ keysByCaptureURL[url] }),
              let fetcher = fetcher(forCacheKey: key)
        else { return false }

        Task {
            do {
                let info = try await fetcher.loadContentInfo()

                if let infoRequest = loadingRequest.contentInformationRequest {
                    infoRequest.contentType = "public.mpeg-4"
                    infoRequest.contentLength = info.totalByteCount
                    infoRequest.isByteRangeAccessSupported = true
                }

                if let dataRequest = loadingRequest.dataRequest {
                    let start = dataRequest.requestedOffset
                    let end = dataRequest.requestsAllDataToEndOfResource
                        ? info.totalByteCount - 1
                        : min(start + Int64(dataRequest.requestedLength) - 1, info.totalByteCount - 1)
                    // Stream the requested range to the player in ≤1 MiB chunks
                    // rather than buffering the whole (possibly multi-GB) remainder
                    // in RAM: fetch one sub-chunk, respond with it, repeat.
                    // `respond(with:)` may be called repeatedly to deliver partial
                    // data incrementally.
                    let chunk: Int64 = 1_048_576
                    var offset = start
                    while offset <= end {
                        if Task.isCancelled {
                            // AVFoundation already dropped interest — finish quietly.
                            loadingRequest.finishLoading()
                            return
                        }
                        let chunkEnd = min(offset + chunk - 1, end)
                        let data = try await fetcher.data(
                            for: DownloadByteRange(start: offset, end: chunkEnd),
                            origin: .player)
                        dataRequest.respond(with: data)
                        offset = chunkEnd + 1
                    }
                }

                loadingRequest.finishLoading()
            } catch is CancellationError {
                // Request was cancelled — nothing to report.
            } catch {
                loadingRequest.finishLoading(with: error)
            }
        }
        return true
    }

    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        // Best-effort: the async Task ends when its fetch completes or throws.
    }
}
