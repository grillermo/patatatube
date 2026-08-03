import SwiftUI

/// Placeholder cells shown while a feed's videos load and none are
/// yet on screen. Keeps the grid from ever appearing empty or lingering on the
/// previous tab's content. Aspect ratios match the real cells: tv/movies use
/// 2:3 Plex posters, everything else uses a 16:9 frame.
struct SkeletonGrid: View {
    let columns: [GridItem]
    let aspectRatio: CGFloat
    /// tv cells carry a title + episode-count line under the poster; draw stubs.
    var showsTextBars: Bool = false
    var count: Int = 8

    @State private var pulse = false

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(0..<count, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.2))
                        .aspectRatio(aspectRatio, contentMode: .fit)
                    if showsTextBars {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.2))
                            .frame(height: 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.2))
                            .frame(width: 60, height: 10)
                    }
                }
            }
        }
        .padding()
        .opacity(pulse ? 0.55 : 1.0)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
        .accessibilityHidden(true)
    }
}
