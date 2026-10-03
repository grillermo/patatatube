// ios/PatataTube/Sources/SleepScreen.swift
import SwiftUI

/// Play-and-sleep's end state: a black screen that swallows every touch, so a
/// child can't tap back into the app. Playback is already paused, which
/// releases the idle timer, so the device auto-locks on the system schedule.
/// Parents escape by tapping the four quadrants counter-clockwise from the
/// top-left; each correct tap lights its square, a wrong one blanks them all.
///
/// Drawn by both `RootTabView` and `VideoPlayerView` from the one
/// `AppModel.sleepScreenShown` flag: a `fullScreenCover` sits above anything
/// the root draws, so the player has to draw its own copy.
/// The unlock sequence: quadrants in counter-clockwise order from top-left.
/// A wrong tap resets to the start; the fourth correct tap completes it.
struct QuadrantUnlock: Equatable {
    enum Quadrant: Int, CaseIterable { case topLeft, bottomLeft, bottomRight, topRight }

    private(set) var lit: [Quadrant] = []

    /// Returns true when this tap completes the sequence.
    mutating func tap(_ quadrant: Quadrant) -> Bool {
        guard quadrant.rawValue == lit.count else {
            lit = []
            return false
        }
        lit.append(quadrant)
        return lit.count == Quadrant.allCases.count
    }

    static func quadrant(at point: CGPoint, in size: CGSize) -> Quadrant {
        let left = point.x < size.width / 2
        let top = point.y < size.height / 2
        switch (left, top) {
        case (true, true): return .topLeft
        case (true, false): return .bottomLeft
        case (false, false): return .bottomRight
        case (false, true): return .topRight
        }
    }
}

struct SleepScreen: View {
    let onDismiss: () -> Void

    @State private var unlock = QuadrantUnlock()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                // Lit squares only; unlit ones are indistinguishable from the
                // black background so nothing hints where to tap.
                ForEach(unlock.lit, id: \.self) { quadrant in
                    Color.white
                        .frame(width: geo.size.width / 2, height: geo.size.height / 2)
                        .position(center(of: quadrant, in: geo.size))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture().onEnded { tap in
                    let quadrant = QuadrantUnlock.quadrant(at: tap.location, in: geo.size)
                    if unlock.tap(quadrant) { onDismiss() }
                }
            )
        }
        .ignoresSafeArea()
        .persistentSystemOverlays(.hidden)
    }

    private func center(of quadrant: QuadrantUnlock.Quadrant, in size: CGSize) -> CGPoint {
        let x = size.width / 4, y = size.height / 4
        switch quadrant {
        case .topLeft: return CGPoint(x: x, y: y)
        case .bottomLeft: return CGPoint(x: x, y: y * 3)
        case .bottomRight: return CGPoint(x: x * 3, y: y * 3)
        case .topRight: return CGPoint(x: x * 3, y: y)
        }
    }
}
