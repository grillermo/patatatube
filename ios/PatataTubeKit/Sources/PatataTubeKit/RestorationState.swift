import Foundation

/// One pushed screen in the grid's navigation stack.
///
/// Routes carry **ids, not values**: never a `Video` or a `ShowGroup`. The row
/// is looked up against the loaded list at render time, so a route that no
/// longer resolves (deleted video, renamed show) can be dropped instead of
/// decoding into a phantom screen. It also keeps the persisted blob small.
public enum Route: Codable, Hashable, Sendable {
    case show(title: String)   // ShowGroup.id
    case movie(id: Int)        // Video.id
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
    /// applied at boot: `VideoStore` already persists the selected
    /// classification itself under `selectedClassification`.
    public var filter: String?
    /// Root-first.
    public var path: [Route]
    /// The committed search text (`activeSearch`), not the in-flight field.
    public var search: String
    /// Screen key -> id of the topmost visible item on that screen.
    public var scrollAnchors: [String: String]
    public var player: PlayerState?

    public static let empty = RestorationState(
        filter: nil, path: [], search: "", scrollAnchors: [:], player: nil
    )

    public init(filter: String?, path: [Route], search: String,
                scrollAnchors: [String: String], player: PlayerState?) {
        self.filter = filter
        self.path = path
        self.search = search
        self.scrollAnchors = scrollAnchors
        self.player = player
    }

    /// Scroll-anchor key for the root grid on one classification tab.
    public static func gridKey(filter: String?) -> String {
        "grid:\(filter ?? "")"
    }

    /// Scroll-anchor key for one show's episode list.
    public static func showKey(title: String) -> String {
        "show:\(title)"
    }
}
