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
    /// As `playerItem(for:)`, but reports which of the four source branches (`local_mp4`, `airplay_mp4`, `proxy_mp4`, `direct_mp4`) was
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
                // Discriminates the two ways a downloaded video ends up streaming.
                // Proxy down (port nil) kills the proxied MP4 route, so a non-cached
                // video falls to `direct_mp4`.
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
        if external,
           let url = model.airPlayStreamURL(for: video) {
            return chose("airplay_mp4", AVPlayerItem(url: url))
        }
        if let proxied = model.proxiedMP4URL(for: video), model.streamURL(for: video) != nil {
            // Proxied MP4: read-through cache, no headers needed.
            return chose("proxy_mp4", AVPlayerItem(url: proxied))
        }
        if let url = model.streamURL(for: video) {
            // Proxy down: direct MP4 with authed headers.
            return chose("direct_mp4", AVPlayerItem(asset: authedAsset(url: url, model: model)), ["proxy": "down"])
        }
        if log {
            DevLog.event(.play, "source -> none", [
                "video_id": "\(video.id)", "cache": DevLog.describe(cacheState),
            ])
        }
        return nil
    }

    /// One asset carrying the bearer header, so AVFoundation authenticates every
    /// range request on the same asset.
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
