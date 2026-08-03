import Foundation

/// A Plex media type. Deliberately not a group: these have their own tabs,
/// their own directories on the server, and their own playback rules.
public enum PlexKind: String, Codable, Hashable, Sendable, CaseIterable {
    case tv
    case movies
}

/// What a grid is showing. Replaces the old `VideoStore.filter: String?`, which
/// was sometimes a group name, sometimes "tv", sometimes nil — the last place
/// the classification concept survived on the client.
///
/// This type is the single place that knows two spellings: the wire spelling
/// (`queryItems`) and the persistence spelling (`storageKey`). Nothing else
/// should build either by hand.
public enum Feed: Codable, Hashable, Sendable {
    case all
    case group(id: Int)
    case plex(PlexKind)

    public var queryItems: [URLQueryItem] {
        switch self {
        case .all: return []
        case .group(let id): return [URLQueryItem(name: "group_id", value: String(id))]
        case .plex(let kind): return [URLQueryItem(name: "plex_kind", value: kind.rawValue)]
        }
    }

    /// Key for anything persisted per-feed: the cached list file name, the
    /// per-feed autoplay/randomize/cell-size preferences, scroll anchors.
    public var storageKey: String {
        switch self {
        case .all: return "all"
        case .group(let id): return "group:\(id)"
        case .plex(let kind): return "plex:\(kind.rawValue)"
        }
    }

    public init?(storageKey: String) {
        if storageKey == "all" {
            self = .all
        } else if storageKey.hasPrefix("group:"), let id = Int(storageKey.dropFirst(6)) {
            self = .group(id: id)
        } else if storageKey.hasPrefix("plex:"), let kind = PlexKind(rawValue: String(storageKey.dropFirst(5))) {
            self = .plex(kind)
        } else {
            return nil
        }
    }
}
