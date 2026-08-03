import Foundation

/// The three top-level media types in the tab bar. `filter` maps a tab onto the
/// `VideoStore.filter` value it loads; the Videos tab has none of its own —
/// its filter is whichever group the user opened.
public enum MediaTab: String, CaseIterable, Codable, Hashable, Sendable {
    case videos
    case tv
    case movies

    /// The Videos tab's groups, in display order. These are classification
    /// values, so they must stay in sync with `CLASSIFICATIONS` in `db.py`.
    public static let videoGroups = ["children", "adults", "anabel", "asmr"]

    public var filter: String? {
        switch self {
        case .videos: return nil
        case .tv: return "tv"
        case .movies: return "movies"
        }
    }

    public static func label(forGroup group: String) -> String {
        group == "asmr" ? "ASMR" : group.capitalized
    }
}
