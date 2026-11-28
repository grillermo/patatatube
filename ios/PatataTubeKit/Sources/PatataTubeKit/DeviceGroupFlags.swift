import Combine
import Foundation

/// A per-group on/off setting kept on this device only: "Download
/// automatically" (`autoDownloadDefaultsKey`) and "Auto play new videos"
/// (`autoPlayDefaultsKey`) are each one of these.
///
/// **Deliberately device-local**, unlike `display_titles` and
/// `remember_position` which live on the group row: a download spends *this*
/// device's storage, and auto play takes over *this* screen, so turning either
/// on for the kids' iPad must not do the same on the phone.
public final class DeviceGroupFlags: ObservableObject, @unchecked Sendable {
    public static let autoDownloadDefaultsKey = "autoDownloadGroups"
    public static let autoPlayDefaultsKey = "autoPlayNewGroups"

    @Published public private(set) var groupIDs: Set<Int>

    private let defaults: UserDefaults
    private let key: String

    public init(key: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = key
        groupIDs = Set(defaults.array(forKey: key) as? [Int] ?? [])
    }

    public func isOn(_ groupID: Int) -> Bool { groupIDs.contains(groupID) }

    public func set(_ groupID: Int, _ on: Bool) {
        guard isOn(groupID) != on else { return }
        if on { groupIDs.insert(groupID) } else { groupIDs.remove(groupID) }
        defaults.set(groupIDs.sorted(), forKey: key)
    }

    /// Drops ids of groups the server no longer lists, so a deleted group's id
    /// can't silently switch the setting on for a group created later.
    public func retain(only existing: Set<Int>) {
        let kept = groupIDs.intersection(existing)
        guard kept != groupIDs else { return }
        groupIDs = kept
        defaults.set(groupIDs.sorted(), forKey: key)
    }
}

public enum AutoDownload {
    /// The videos worth starting a download for: finished on the server, with
    /// something to stream, and not on this device in any form yet. A paused
    /// or running download is not `.notCached`, so a pause made by hand is left
    /// alone.
    public static func targets(in videos: [Video],
                               state: (Video) -> CacheState) -> [Video] {
        videos.filter { $0.status == "done" && !$0.streamPath.isEmpty && state($0) == .notCached }
    }

    /// Bytes an auto-downloaded video needs before "Auto play new videos"
    /// starts it. The stream proxy fills any gap behind the playhead itself,
    /// so this is only a head start against an immediate stall; 4 MB is the
    /// distance the proxy is willing to wait behind a fetcher.
    public static let autoPlayHeadStartBytes: Int64 = 4 * 1024 * 1024

    /// Whether a new video has enough on disk to start playing: complete, or
    /// at least `autoPlayHeadStartBytes` in (or all of a smaller file).
    public static func readyToAutoPlay(state: CacheState,
                                       transferred: Int64,
                                       total: Int64?) -> Bool {
        if state == .cached { return true }
        guard case .downloading = state else { return false }
        if let total, total > 0, transferred >= total { return true }
        return transferred >= autoPlayHeadStartBytes
    }
}
