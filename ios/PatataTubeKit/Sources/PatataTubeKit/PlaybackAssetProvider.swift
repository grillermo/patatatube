import Foundation

/// What the player should be handed for a video.
enum PlaybackAssetDecision: Equatable, Sendable {
    /// Play the cached `.movpkg` directly — complete, or partial while offline.
    case localPackage
    /// Start (or attach to) a fill-ahead download and play its asset, so watched
    /// bytes land on disk and already-downloaded bytes are read from disk.
    case fillAhead
    /// Stream the remote playlist without caching (cellular).
    case remoteOnly
    case unplayable(reason: String)
}

/// The single place that decides where playback bytes come from.
enum PlaybackAssetProvider {
    static func decide(
        hlsStatus: String,
        entry: HLSCacheEntry?,
        entryAudioLangMatches: Bool,
        isOnWiFi: Bool,
        hasNetwork: Bool
    ) -> PlaybackAssetDecision {
        if let entry, entryAudioLangMatches {
            // A package built for a different audio language is stale — the user
            // would hear the wrong track — so it is not played and not resumed.
            if entry.isComplete { return .localPackage }
            // Partial: offline, the downloaded region is all there is. Online,
            // the fill-ahead task both serves it and finishes it.
            if !hasNetwork { return .localPackage }
            return isOnWiFi ? .fillAhead : .remoteOnly
        }

        guard hasNetwork else { return .unplayable(reason: "Offline and not downloaded") }
        switch hlsStatus {
        case "done":
            return isOnWiFi ? .fillAhead : .remoteOnly
        case "error":
            return .unplayable(reason: "HLS packaging failed")
        default:
            return .unplayable(reason: "HLS not ready")
        }
    }
}
