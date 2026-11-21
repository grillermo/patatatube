import Foundation

/// One pushed screen in the grid's navigation stack.
///
/// Routes carry **ids, not values**: never a `Video`. The row
/// is looked up against the loaded list at render time, so a route that no
/// longer resolves (deleted group) can be dropped instead of
/// decoding into a phantom screen. It also keeps the persisted blob small.
public enum Route: Codable, Hashable, Sendable {
    case group(id: Int)  // VideoGroup.id
    case downloads
}

/// Playback that was on screen when the app went away. The queue is not
/// persisted — it is rebuilt at launch from the restored screen — and the
/// position is not either: `ResumePositionStore` already owns that.
public struct PlayerState: Codable, Equatable, Sendable {
    public var videoID: Int
    public var versionID: Int?
    public var sleepMode: Bool

    public init(videoID: Int, versionID: Int?, sleepMode: Bool) {
        self.videoID = videoID
        self.versionID = versionID
        self.sleepMode = sleepMode
    }
}

/// Everything needed to put the user back where they left off.
public struct RestorationState: Codable, Equatable, Sendable {
    /// Recorded for a self-describing blob and to scope scroll anchors. **Not**
    /// applied at boot: `VideoStore` already persists the selected feed itself
    /// under `selectedFeed`.
    public var feed: Feed?
    /// Root-first.
    public var path: [Route]
    /// The committed search text (`activeSearch`), not the in-flight field.
    public var search: String
    /// Screen key -> id of the topmost visible item on that screen.
    public var scrollAnchors: [String: String]
    public var player: PlayerState?

    public static let empty = RestorationState(
        feed: nil, path: [], search: "", scrollAnchors: [:], player: nil
    )

    public init(feed: Feed?, path: [Route], search: String,
                scrollAnchors: [String: String], player: PlayerState?) {
        self.feed = feed
        self.path = path
        self.search = search
        self.scrollAnchors = scrollAnchors
        self.player = player
    }

    /// Scroll-anchor key for the root grid on one feed.
    public static func gridKey(feed: Feed) -> String {
        "grid:\(feed.storageKey)"
    }
}
