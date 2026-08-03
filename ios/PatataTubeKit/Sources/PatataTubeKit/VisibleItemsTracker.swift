import Foundation

/// Tracks which cells are on screen and reports the topmost one, for scroll
/// restoration.
///
/// Callbacks arrive out of order — SwiftUI routinely delivers the outgoing
/// cell's `onDisappear` after the incoming cell's `onAppear` — so nothing here
/// depends on call order. Visibility is a set; "topmost" is derived from the
/// list's current ordering, which is also what makes the answer survive
/// insertions, deletions and cell-size changes.
@MainActor
public final class VisibleItemsTracker {
    private var order: [String] = []
    private var indexByID: [String: Int] = [:]
    private var visible: Set<String> = []

    public init() {}

    /// The list's current ordering. Ids no longer present stop counting as
    /// visible, so a deleted row cannot pin the anchor forever.
    public func setOrder(_ ids: [String]) {
        order = ids
        indexByID = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        visible = visible.filter { indexByID[$0] != nil }
    }

    public func appeared(_ id: String) {
        guard indexByID[id] != nil else { return }
        visible.insert(id)
    }

    public func disappeared(_ id: String) {
        visible.remove(id)
    }

    /// The visible id earliest in the current ordering, or nil when nothing is
    /// on screen.
    public var topmost: String? {
        visible.min { (indexByID[$0] ?? .max) < (indexByID[$1] ?? .max) }
    }
}
