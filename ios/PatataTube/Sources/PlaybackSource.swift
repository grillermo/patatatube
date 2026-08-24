// ios/PatataTube/Sources/PlaybackSource.swift
import AVFoundation
import PatataTubeKit

/// Which URL a video actually plays from, and an `AVPlayerItem` over it.
///
/// Extracted from `VideoPlayerView` so the full-screen player and
/// `AudioQueuePlayer` share one chain. Playback failures that only happen
/// sometimes are usually a wrong branch — a `cached` state over a file that is
/// missing or half written, say — so the branch and the on-disk facts behind it
/// are recorded together, before AVFoundation ever sees the URL.
///
/// Most callers only ask *whether* a video is playable, sweeping a queue for
/// the next candidate. Those probes pass `log: false` — one source line per
/// candidate would bury the one that actually got played.
@MainActor
enum PlaybackSource {
    /// As `playerItem(for:)`, but reports which of the five source branches was
    /// taken. Playback failures that only happen sometimes are usually a wrong
    /// branch — a `cached` state over a file that is missing or half written,
    /// say — so the branch and the on-disk facts behind it are recorded
    /// together, before AVFoundation ever sees the URL.
    static func item(for video: Video, model: AppModel, log: Bool = true)
        -> (item: AVPlayerItem, source: String)? {
        let cacheState = model.cache.state(for: video.id, versionId: video.chosenVersionId)
        let local = model.cache.localURL(for: video.id, versionId: video.chosenVersionId)
        let localExists = FileManager.default.fileExists(atPath: local.path)

        func chose(_ source: String, _ item: AVPlayerItem, _ extra: [String: String] = [:]) -> (AVPlayerItem, String) {
            guard log else { return (item, source) }
            var meta = [
                "video_id": "\(video.id)",
                "version_id": video.chosenVersionId.map(String.init) ?? "-",
                "source": source,
                "cache": DevLog.describe(cacheState),
                "local_exists": "\(localExists)",
                "local_bytes": Self.fileSize(at: local),
                "status": video.status ?? "-",
                "is_library": "\(video.isLibrary)",
                "has_hls": "\(!(video.hlsPath ?? "").isEmpty)",
                // Discriminates the two ways a downloaded video ends up streaming.
                // Proxy down (port nil) kills the offline HLS route as well as the
                // network ones, because both go through the same URL builder.
                "proxy_port": model.streamProxy.port.map(String.init) ?? "nil",
                // True when *some* version of this video is on disk. `cache` is
                // keyed by chosenVersionId, so `cache=notCached` together with
                // `any_version_cached=true` is version-key drift: the file is
                // there under a different key and playback went to the network.
                "any_version_cached": "\(model.cache.hasAnyCached(id: video.id))",
                "local_path": local.lastPathComponent,
            ]
            meta.merge(extra) { current, _ in current }
            DevLog.event(.play, "source -> \(source)", meta)
            return (item, source)
        }

        if cacheState == .cached {
            // Offline wins: local MP4 file, else promoted HLS via the proxy.
            if localExists {
                return chose("local_mp4", AVPlayerItem(url: local))
            }
            if let offline = model.offlineHLSURL(for: video) {
                return chose("offline_hls", AVPlayerItem(url: offline))
            }
            // Reported cached, yet neither offline source resolved — the cache
            // and the filesystem disagree. Falls through to streaming below.
            if log {
                DevLog.event(.cache, "cached but no local source", [
                    "video_id": "\(video.id)",
                    "local": local.path,
                ])
            }
        }
        // Library rows that haven't been converted server-side have no streamable file yet.
        if video.isLibrary && video.status != "done" {
            if log {
                DevLog.event(.play, "source -> none (library not converted)", [
                    "video_id": "\(video.id)", "status": video.status ?? "-",
                ])
            }
            return nil
        }
        if let proxied = model.proxiedHLSURL(for: video) {
            // Proxied HLS: read-through cache, native subtitle tracks, no headers needed.
            return chose("proxy_hls", AVPlayerItem(url: proxied))
        }
        if let hlsURL = model.hlsURL(for: video) {
            // Proxy down: direct remote HLS with authed headers (old behavior).
            return chose("direct_hls", AVPlayerItem(asset: authedAsset(url: hlsURL, model: model)), ["proxy": "down"])
        }
        if video.hlsPath == nil || video.hlsPath?.isEmpty == true,
           let proxied = model.proxiedMP4URL(for: video), model.streamURL(for: video) != nil {
            // Proxied direct MP4 for rows without an HLS package.
            return chose("proxy_mp4", AVPlayerItem(url: proxied))
        }
        if let url = model.streamURL(for: video) {
            // Proxy down: direct MP4 fallback.
            return chose("direct_mp4", AVPlayerItem(asset: authedAsset(url: url, model: model)), ["proxy": "down"])
        }
        if log {
            DevLog.event(.play, "source -> none", [
                "video_id": "\(video.id)", "cache": DevLog.describe(cacheState),
            ])
        }
        return nil
    }

    /// One asset carrying the bearer header, so AVFoundation authenticates the
    /// HLS playlist, segment, and subtitle sub-requests on the same asset.
    static func authedAsset(url: URL, model: AppModel) -> AVURLAsset {
        var options: [String: Any] = [:]
        if let token = model.credentials.token {
            options["AVURLAssetHTTPHeaderFieldsKey"] = ["Authorization": "Bearer \(token)"]
        }
        return AVURLAsset(url: url, options: options)
    }

    /// Playability probe for `QueueNavigator`: a video has a source or it doesn't.
    static func isPlayable(_ video: Video, model: AppModel) -> Bool {
        item(for: video, model: model, log: false) != nil
    }

    private static func fileSize(at url: URL) -> String {
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int64 else { return "-" }
        return "\(size)"
    }
}
