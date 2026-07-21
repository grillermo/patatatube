import Foundation

/// What the player does when the current item plays to the end.
public enum PlaybackEndAction: Equatable, Sendable {
    /// Play the next playable video in the queue.
    case advance
    /// Close the player.
    case dismiss
    /// Pause and leave the player mounted (nothing dismisses while backgrounded).
    case stop
    /// Pause and show the black sleep overlay so the device can auto-lock.
    case sleep
}

/// Sleep mode overrides everything: the whole point is that playback ends there.
/// Otherwise the autoplay flag governs both foreground and background: with
/// autoplay on a finished video always rolls into the next one; with it off
/// playback ends where it is — dismissing when the user is looking, pausing
/// when they are not.
public func playbackEndAction(autoplay: Bool, isForeground: Bool, sleepMode: Bool = false) -> PlaybackEndAction {
    if sleepMode { return .sleep }
    if autoplay { return .advance }
    return isForeground ? .dismiss : .stop
}
