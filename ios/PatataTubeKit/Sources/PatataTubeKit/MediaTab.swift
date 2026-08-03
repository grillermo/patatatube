import Foundation

/// The three top-level media types in the tab bar.
public enum MediaTab: String, CaseIterable, Codable, Hashable, Sendable {
    case videos
    case tv
    case movies

    /// The feed a tab loads. The Videos tab has none of its own — its feed is
    /// whichever group the user opened.
    public var feed: Feed? {
        switch self {
        case .videos: return nil
        case .tv: return .plex(.tv)
        case .movies: return .plex(.movies)
        }
    }
}
