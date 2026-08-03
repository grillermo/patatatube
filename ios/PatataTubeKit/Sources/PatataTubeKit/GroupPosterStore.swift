import Foundation

/// The art shown on one Videos-group card: the newest video in that group that
/// had a preview, last time the group was loaded.
public struct GroupPoster: Codable, Equatable, Sendable {
    public var videoID: Int
    public var path: String

    public init(videoID: Int, path: String) {
        self.videoID = videoID
        self.path = path
    }
}

/// Remembers one poster per Videos group so the group screen can render art for
/// groups that aren't loaded. Deliberately fed from lists that were fetched
/// anyway — the group screen itself issues no requests.
public struct GroupPosterStore: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public static func key(_ group: String) -> String { "groupPoster:\(group)" }

    public func poster(for group: String) -> GroupPoster? {
        guard let data = defaults.data(forKey: Self.key(group)) else { return nil }
        return try? JSONDecoder().decode(GroupPoster.self, from: data)
    }

    /// Records the first video carrying a preview. The list arrives in the
    /// server's display order, so "first" is the same row the grid shows first.
    /// A group with no usable video keeps whatever it had — an empty fetch (or
    /// an offline one) must not blank a card that already has art.
    public func record(_ videos: [Video], for group: String?) {
        guard let group, MediaTab.videoGroups.contains(group) else { return }
        guard let match = videos.first(where: { $0.previewUrl?.isEmpty == false }),
              let path = match.previewUrl,
              let data = try? JSONEncoder().encode(GroupPoster(videoID: match.id, path: path))
        else { return }
        defaults.set(data, forKey: Self.key(group))
    }
}
