import Foundation

/// One row of the server's `groups` table. The Videos tab's cards are these,
/// in `position` order — the list is server data now, not a compiled-in array.
public struct VideoGroup: Codable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let label: String
    public let emoji: String?
    public let position: Int
    /// Overlay each video's title on its poster in this group's grid.
    /// Server-owned (`groups.display_titles`), so it follows the group across
    /// devices instead of living in one device's UserDefaults.
    public let displayTitles: Bool
    /// What the group is *for*, in the owner's words. The server's classifier
    /// reads it to file new uploads (`groups.description`); nothing in the app
    /// renders it outside the editor. Nil when unset.
    public let description: String?
    /// Videos added to this group and not yet played, derived by the server
    /// from `videos.play_count` (announced, never played). The wire name stays
    /// `unread_count`. The card hides its badge at 0.
    public let unreadCount: Int

    public init(id: Int, name: String, label: String, emoji: String?, position: Int,
                displayTitles: Bool = false, description: String? = nil,
                unreadCount: Int = 0) {
        self.id = id
        self.name = name
        self.label = label
        self.emoji = emoji
        self.position = position
        self.displayTitles = displayTitles
        self.description = description
        self.unreadCount = unreadCount
    }

    /// Hand-rolled so a payload without `displayTitles` (or `description`, or `unreadCount`)
    /// decodes as off/nil rather than throwing: `GroupStore`'s UserDefaults
    /// mirror holds blobs written by builds that predate the fields, and dropping the whole mirror on upgrade
    /// would empty the offline-first group screen.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        label = try c.decode(String.self, forKey: .label)
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji)
        position = try c.decode(Int.self, forKey: .position)
        displayTitles = try c.decodeIfPresent(Bool.self, forKey: .displayTitles) ?? false
        description = try c.decodeIfPresent(String.self, forKey: .description)
        unreadCount = try c.decodeIfPresent(Int.self, forKey: .unreadCount) ?? 0
    }

    public func withDisplayTitles(_ on: Bool) -> VideoGroup {
        VideoGroup(id: id, name: name, label: label, emoji: emoji, position: position,
                   displayTitles: on, description: description, unreadCount: unreadCount)
    }

    public func withDescription(_ text: String?) -> VideoGroup {
        VideoGroup(id: id, name: name, label: label, emoji: emoji, position: position,
                   displayTitles: displayTitles, description: text, unreadCount: unreadCount)
    }

    public var feed: Feed { .group(id: id) }
}
