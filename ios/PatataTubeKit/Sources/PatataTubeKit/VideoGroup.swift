import Foundation

/// One row of the server's `groups` table. The Videos tab's cards are these,
/// in `position` order — the list is server data now, not a compiled-in array.
public struct VideoGroup: Codable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let label: String
    public let emoji: String?
    public let position: Int

    public init(id: Int, name: String, label: String, emoji: String?, position: Int) {
        self.id = id
        self.name = name
        self.label = label
        self.emoji = emoji
        self.position = position
    }

    public var feed: Feed { .group(id: id) }
}
