import Foundation

/// Client-side grouping of library TV episodes into shows.
public struct ShowGroup: Identifiable, Equatable, Hashable, Sendable {
    public let title: String
    /// Sorted by season, then episode.
    public let episodes: [Video]

    public var id: String { title }
    public var posterPath: String? { episodes.first?.showPreviewUrl }

    public static func group(_ videos: [Video]) -> [ShowGroup] {
        let grouped = Dictionary(grouping: videos.filter { $0.showTitle != nil },
                                 by: { $0.showTitle! })
        return grouped
            .map { title, episodes in
                ShowGroup(title: title, episodes: episodes.sorted {
                    ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0)
                })
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    public func seasons() -> [(number: Int, episodes: [Video])] {
        let grouped = Dictionary(grouping: episodes, by: { $0.season ?? 0 })
        return grouped.keys.sorted().map { (number: $0, episodes: grouped[$0]!) }
    }

    // Manual Hashable conformance: hash based on title (the id)
    public func hash(into hasher: inout Hasher) {
        hasher.combine(title)
    }
}
