// ios/PatataTube/Sources/UnreadBadge.swift
import SwiftUI

/// White number on a red circle: how many videos in a group are new and unplayed.
/// Renders nothing at 0, so a caught-up group looks exactly as before.
struct UnreadBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .frame(minWidth: 24, minHeight: 24)
                .background(.red, in: Capsule())
                .accessibilityLabel("\(count) unplayed")
        }
    }
}
