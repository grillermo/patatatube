import Foundation

/// A user-chosen emoji cover for one Videos group. Takes precedence over the
/// `GroupPosterStore` art on the group card, so a group whose newest preview is
/// a bad frame can still be recognised at a glance.
///
/// **The server owns these** (`GET/POST /api/group-covers`) so a choice made on
/// one device shows up on the others. UserDefaults is only a mirror, kept so
/// the group screen — which is offline-first by design and issues no requests
/// for its art — still renders the right covers before (or without) a fetch.
public struct GroupCoverStore: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public static func key(_ group: String) -> String { "groupCover:\(group)" }

    public func cover(for group: String) -> String? {
        defaults.string(forKey: Self.key(group))
    }

    public func covers() -> [String: String] {
        var result: [String: String] = [:]
        for group in MediaTab.videoGroups {
            result[group] = cover(for: group)
        }
        return result
    }

    /// Stores the first emoji found in `text`. The field is free text, so a
    /// paste of "🐸 frogs" is taken as 🐸 rather than rejected; text with no
    /// emoji at all clears the cover instead of storing a letter.
    ///
    /// Local only — callers that want the choice to travel must also send it
    /// with `VideoAPI.setGroupCover`.
    @discardableResult
    public func setCover(_ text: String?, for group: String) -> String? {
        guard MediaTab.videoGroups.contains(group) else { return nil }
        guard let emoji = Self.firstEmoji(in: text ?? "") else {
            defaults.removeObject(forKey: Self.key(group))
            return nil
        }
        defaults.set(emoji, forKey: Self.key(group))
        return emoji
    }

    /// Replaces the mirror with what the server has. A group the server doesn't
    /// list has no cover *there*, so it loses its local one too — that is how a
    /// clear made on another device propagates.
    @discardableResult
    public func apply(_ remote: [String: String]) -> [String: String] {
        for group in MediaTab.videoGroups {
            setCover(remote[group], for: group)
        }
        return covers()
    }

    /// One grapheme cluster, so flags, skin-tone modifiers and ZWJ families
    /// (👩‍👩‍👧) each count as a single emoji rather than their parts.
    public static func firstEmoji(in text: String) -> String? {
        text.first(where: { char in
            char.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0x238C }
        }).map(String.init)
    }
}
