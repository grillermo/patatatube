// ios/PatataTube/Sources/SleepScreen.swift
import SwiftUI

/// Play-and-sleep's end state: a black screen that swallows every touch, so a
/// child can't tap back into the app. Playback is already paused, which
/// releases the idle timer, so the device auto-locks on the system schedule.
/// Parents escape with a two-second long-press.
///
/// Drawn by both `RootTabView` and `VideoPlayerView` from the one
/// `AppModel.sleepScreenShown` flag: a `fullScreenCover` sits above anything
/// the root draws, so the player has to draw its own copy.
struct SleepScreen: View {
    let onDismiss: () -> Void

    var body: some View {
        Color.black.ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture {}
            .onLongPressGesture(minimumDuration: 2) { onDismiss() }
            .persistentSystemOverlays(.hidden)
    }
}
