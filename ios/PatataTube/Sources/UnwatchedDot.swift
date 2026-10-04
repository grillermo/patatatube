import SwiftUI

/// The red dot on a video nobody has played yet. Per-video counterpart of the
/// group card's `UnreadBadge`; the server decides which videos carry it.
struct UnwatchedDot: View {
    var size: CGFloat = 12

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.4), radius: 1, x: 0, y: 1)
            .allowsHitTesting(false)
            .accessibilityLabel("Unwatched")
    }
}
