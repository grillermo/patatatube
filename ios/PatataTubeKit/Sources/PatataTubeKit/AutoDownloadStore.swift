import Combine
import Foundation

/// The groups whose videos this device downloads on its own, every time the
/// app becomes active.
///
/// **Deliberately device-local**, unlike `display_titles` and
/// `remember_position` which live on the group row: a download spends *this*
/// device's storage, so turning it on for the kids' iPad must not make the
/// phone fill up with the same group.
public final class AutoDownloadStore: ObservableObject, @unchecked Sendable {
    public static let defaultsKey = "autoDownloadGroups"

    @Published public private(set) var groupIDs: Set<Int>

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        groupIDs = Set(defaults.array(forKey: Self.defaultsKey) as? [Int] ?? [])
    }

    public func isOn(_ groupID: Int) -> Bool { groupIDs.contains(groupID) }

    public func set(_ groupID: Int, _ on: Bool) {
        guard isOn(groupID) != on else { return }
        if on { groupIDs.insert(groupID) } else { groupIDs.remove(groupID) }
        defaults.set(groupIDs.sorted(), forKey: Self.defaultsKey)
    }

    /// Drops ids of groups the server no longer lists, so a deleted group's id
    /// can't silently switch auto-download on for a group created later.
    public func retain(only existing: Set<Int>) {
        let kept = groupIDs.intersection(existing)
        guard kept != groupIDs else { return }
        groupIDs = kept
        defaults.set(groupIDs.sorted(), forKey: Self.defaultsKey)
    }

    /// The videos worth starting a download for: finished on the server, with
    /// something to stream, and not on this device in any form yet. A paused
    /// or running download is not `.notCached`, so a pause made by hand is left
    /// alone.
    public static func targets(in videos: [Video],
                               state: (Video) -> CacheState) -> [Video] {
        videos.filter { $0.status == "done" && !$0.streamPath.isEmpty && state($0) == .notCached }
    }
}
