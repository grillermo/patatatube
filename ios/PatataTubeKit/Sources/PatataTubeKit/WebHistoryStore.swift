import Foundation

/// One visited page in the web bridge's address history.
public struct WebHistoryEntry: Codable, Equatable, Sendable {
    public let url: String
    public let lastVisited: Date

    public init(url: String, lastVisited: Date) {
        self.url = url
        self.lastVisited = lastVisited
    }
}

/// Address history for the in-app web view, backed by `UserDefaults`.
///
/// Every committed navigation is recorded — link taps included — deduped by
/// absolute URL string, newest first, capped at `limit`. Nothing here throws:
/// unreadable storage is treated as an empty history and overwritten on the
/// next `record`, because a broken history must never block browsing.
public final class WebHistoryStore: @unchecked Sendable {
    public static let storageKey = "webBridgeHistory"

    private let defaults: UserDefaults
    private let limit: Int
    private let lock = NSLock()
    private var cache: [WebHistoryEntry]

    public init(defaults: UserDefaults = .standard, limit: Int = 200) {
        self.defaults = defaults
        self.limit = max(1, limit)
        let data = defaults.data(forKey: Self.storageKey)
        self.cache = data.flatMap { try? JSONDecoder().decode([WebHistoryEntry].self, from: $0) } ?? []
    }

    /// Newest first.
    public var entries: [WebHistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        return cache
    }

    /// The page the web view should open on, or `nil` when nothing was visited yet.
    public var lastURL: URL? {
        entries.first.flatMap { URL(string: $0.url) }
    }

    public func record(_ url: URL) {
        let key = url.absoluteString
        lock.lock(); defer { lock.unlock() }
        cache.removeAll { $0.url == key }
        cache.insert(WebHistoryEntry(url: key, lastVisited: Date()), at: 0)
        if cache.count > limit { cache.removeLast(cache.count - limit) }
        let snapshot = cache

        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// Fuzzy-matches history by treating whitespace in `query` as wildcards:
    /// every token must occur, in order, somewhere in the URL string. So
    /// `"awh live"` finds `https://awh.chiq.me/live` but `"live awh"` does not.
    /// A blank query returns the whole history. Results stay newest first.
    public func search(_ query: String) -> [WebHistoryEntry] {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return entries }

        return entries.filter { entry in
            var remainder = Substring(entry.url.lowercased())
            for token in tokens {
                guard let hit = remainder.range(of: token) else { return false }
                remainder = remainder[hit.upperBound...]
            }
            return true
        }
    }
}
