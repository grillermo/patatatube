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
    ///
    /// `external` asks for a source an AirPlay receiver can load on its own —
    /// see `airPlayRouteActive`. Only the full-screen player passes it; the
    /// audio queue stays on the device and sends AirPlay just its sound.
    static func item(for video: Video, model: AppModel, log: Bool = true, external: Bool = false)
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

        // Offline wins: a local MP4 file, which AirPlay can also take.
        if cacheState == .cached, localExists {
            return chose("local_mp4", AVPlayerItem(url: local))
        }
        // Everything below is the proxy or needs a header, neither of which an
        // Apple TV can use, so an AirPlay route streams the MP4 from the server.
        if external, !(video.isLibrary && video.status != "done"),
           let url = model.airPlayStreamURL(for: video) {
            return chose("airplay_mp4", AVPlayerItem(url: url))
        }
        if cacheState == .cached {
            // Else promoted HLS via the proxy.
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

    /// Whether audio is going to an AirPlay receiver — the case while screen
    /// mirroring to an Apple TV, and after picking one in a route picker.
    static var airPlayRouteActive: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
    }

    /// Lets `player` hand `item` to an AirPlay receiver only when the receiver
    /// can load it. External playback sends the receiver the item's *URL*, and
    /// the proxy's `http://127.0.0.1:…` is the Apple TV itself, and AirPlay
    /// doesn't forward a bearer header — the TV shows a crossed-out icon and
    /// nothing plays. A local file AVFoundation serves to the receiver itself;
    /// `airplay_mp4` carries its token in the query. For the rest, playback
    /// stays on the device and screen mirroring shows it.
    /// Per item, so call it again after every `replaceCurrentItem`.
    static func configureExternalPlayback(_ player: AVPlayer, for item: AVPlayerItem) {
        let reachable = isReachableByAirPlay(item)
        player.allowsExternalPlayback = reachable
        player.usesExternalPlaybackWhileExternalScreenIsActive = reachable
    }

    /// A local file, or `airplay_mp4` — the two sources a receiver can load.
    static func isReachableByAirPlay(_ item: AVPlayerItem) -> Bool {
        let url = (item.asset as? AVURLAsset)?.url
        return url?.isFileURL == true || url?.query?.contains("token=") == true
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
