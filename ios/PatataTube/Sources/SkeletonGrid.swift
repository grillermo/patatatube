import SwiftUI

/// Placeholder cells shown while a feed's videos load and none are
/// yet on screen. Keeps the grid from ever appearing empty or lingering on the
/// previous feed's content. Every cell uses a 16:9 frame, like the real ones.
struct SkeletonGrid: View {
    let columns: [GridItem]
    let aspectRatio: CGFloat
    var count: Int = 8
    /// Rows instead of cards, matching `VideoRow`'s geometry, so the
    /// placeholder does not change shape the moment real content lands.
    var isList: Bool = false

    @State private var pulse = false

    var body: some View {
        LazyVGrid(columns: columns, spacing: isList ? 0 : 16) {
            ForEach(0..<count, id: \.self) { _ in
                if isList {
                    listRow
                } else {
                    card
                }
            }
        }
        .padding()
        .opacity(pulse ? 0.55 : 1.0)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
        .accessibilityHidden(true)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.2))
                .aspectRatio(aspectRatio, contentMode: .fit)
        }
    }

    private var listRow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: VideoRow.thumbWidth, height: VideoRow.thumbHeight)
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 80, height: 10)
                }
                Spacer(minLength: 44)
            }
            .padding(.vertical, 6)
            Divider()
        }
    }
}
