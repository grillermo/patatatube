// ios/PatataTube/Sources/SleepScreen.swift
import SwiftUI

/// Play-and-sleep's end state: a black screen that swallows every touch, so a
/// child can't tap back into the app. Playback is already paused, which
/// releases the idle timer, so the device auto-locks on the system schedule.
/// Parents escape with a three-second long-press, shown as a ring that fills while held.
///
/// Drawn by both `RootTabView` and `VideoPlayerView` from the one
/// `AppModel.sleepScreenShown` flag: a `fullScreenCover` sits above anything
/// the root draws, so the player has to draw its own copy.
struct SleepScreen: View {
    let onDismiss: () -> Void

    private static let holdDuration = 3.0

    @State private var isHolding = false

    var body: some View {
        ZStack {
            Color.black
            // An empty ring appears under the finger's press and fills over the
            // hold, so a parent can see the hold is registering.
            if isHolding {
                Circle().stroke(.white.opacity(0.25), lineWidth: 6)
                    .frame(width: 120, height: 120)
                    .overlay(FillingRing(duration: Self.holdDuration))
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture {}
        // Generous `maximumDistance` (default 10pt): a slightly drifting
        // finger must not cancel the hold.
        .onLongPressGesture(minimumDuration: Self.holdDuration, maximumDistance: 150) {
            onDismiss()
        } onPressingChanged: { pressing in
            withAnimation(.easeOut(duration: 0.15)) { isHolding = pressing }
        }
        .persistentSystemOverlays(.hidden)
    }
}

/// Trims from empty to full once on appear; removed from the tree on release,
/// so each press starts again from empty.
private struct FillingRing: View {
    let duration: Double
    @State private var progress = 0.0

    var body: some View {
        Circle().trim(from: 0, to: progress)
            .stroke(.white, style: StrokeStyle(lineWidth: 6, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .onAppear { withAnimation(.linear(duration: duration)) { progress = 1 } }
    }
}
