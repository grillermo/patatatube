import Foundation

/// What the player does when the current item plays to the end.
public enum PlaybackEndAction: Equatable, Sendable {
    /// Play the next playable video in the queue.
    case advance
    /// Close the player.
    case dismiss
    /// Pause and leave the player mounted (nothing dismisses while backgrounded).
    case stop
}

/// The autoplay flag governs both foreground and background: with autoplay on a
/// finished video always rolls into the next one; with it off playback ends where
/// it is — dismissing when the user is looking, pausing when they are not.
public func playbackEndAction(autoplay: Bool, isForeground: Bool) -> PlaybackEndAction {
    if autoplay { return .advance }
    return isForeground ? .dismiss : .stop
}
