import Foundation

/// What a grid is showing.
///
/// This type is the single place that knows two spellings: the wire spelling
/// (`queryItems`) and the persistence spelling (`storageKey`). Nothing else
/// should build either by hand.
public enum Feed: Codable, Hashable, Sendable {
    case all
    case group(id: Int)

    public var queryItems: [URLQueryItem] {
        switch self {
        case .all: return []
        case .group(let id): return [URLQueryItem(name: "group_id", value: String(id))]
        }
    }

    /// Key for anything persisted per-feed: the cached list file name, the
    /// per-feed autoplay/randomize/cell-size preferences, scroll anchors.
    public var storageKey: String {
        switch self {
        case .all: return "all"
        case .group(let id): return "group:\(id)"
        }
    }

    /// `nil` for anything else, including the `plex:tv` / `plex:movies` keys
    /// older builds persisted; their cached lists are simply never read again.
    public init?(storageKey: String) {
        if storageKey == "all" {
            self = .all
        } else if storageKey.hasPrefix("group:"), let id = Int(storageKey.dropFirst(6)) {
            self = .group(id: id)
        } else {
            return nil
        }
    }
}
