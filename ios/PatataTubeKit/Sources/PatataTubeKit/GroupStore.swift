import Combine
import Foundation

/// The Videos tab's group list, mirrored into UserDefaults.
///
/// **The server owns these** (`GET /api/groups`) so a group added on one device
/// shows up on the others. UserDefaults is only a mirror, kept because the
/// group screen is offline-first by design: it renders from this before (or
/// entirely without) a fetch. Replaces `GroupCoverStore` — the emoji is a field
/// on the group now, not a parallel table keyed by name.
public final class GroupStore: ObservableObject, @unchecked Sendable {
    public static let defaultsKey = "videoGroups"

    @Published public private(set) var groups: [VideoGroup] = []

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([VideoGroup].self, from: data) {
            groups = decoded.sorted { $0.position < $1.position }
        }
    }

    /// Replaces the mirror with what the server has. A group the server no
    /// longer lists disappears here too — that is how a deletion made
    /// elsewhere propagates.
    public func apply(_ remote: [VideoGroup]) {
        groups = remote.sorted { $0.position < $1.position }
        persist()
    }

    /// Optimistic local flip of one group's "display titles". The server is
    /// still the owner — the caller PATCHes and calls this again to revert if
    /// that fails — but the grid redraws without waiting for the round trip.
    public func setDisplayTitles(id: Int, _ on: Bool) {
        guard let index = groups.firstIndex(where: { $0.id == id }),
              groups[index].displayTitles != on else { return }
        groups[index] = groups[index].withDisplayTitles(on)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(groups) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    public func group(id: Int) -> VideoGroup? { groups.first { $0.id == id } }

    public func group(named name: String) -> VideoGroup? { groups.first { $0.name == name } }
}
