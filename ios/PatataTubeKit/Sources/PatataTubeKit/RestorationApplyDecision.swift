import Foundation

/// Whether a restored snapshot may be written over what is on screen right
/// now. Restoration is a *launch* concern: it seeds empty state, it never
/// takes state away from a running session.
///
/// Second layer behind `RestorationGate`. The gate stops restoration from
/// running twice; this stops a restore that does run from undoing live
/// navigation or playback.
public enum RestorationApplyDecision {
    /// Restored paths seed an empty stack only. A restore that resolved to
    /// nothing must never pop the screen the user is on.
    public static func shouldApplyPath(restoredIsEmpty: Bool, liveIsEmpty: Bool) -> Bool {
        !restoredIsEmpty && liveIsEmpty
    }

    /// A restored player is presented only when nothing is presented. Anything
    /// else is either a duplicate presentation or a resurrection of a player
    /// the user just dismissed.
    public static func shouldApplyPlayer(hasRestoredPlayer: Bool, hasLivePlayer: Bool) -> Bool {
        hasRestoredPlayer && !hasLivePlayer
    }
}
