import Combine
import SwiftUI

@MainActor
final class OrientationControlVisibility: ObservableObject {
    @Published private(set) var isVisible = false
    private var hideTask: Task<Void, Never>?

    func reveal() {
        reveal(using: ContinuousClock())
    }

    func reveal<C: Clock>(using clock: C) where C.Duration == Duration {
        hideTask?.cancel()
        isVisible = true
        hideTask = Task { @MainActor [weak self] in
            do {
                try await clock.sleep(for: .seconds(4))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.isVisible = false
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        isVisible = false
    }
}

struct HorizontalLockOverlay: View {
    static let verticalOffsetFraction: CGFloat = 0.20

    let isHorizontal: Bool
    let isVisible: Bool
    let isBlocked: Bool
    let onToggle: () -> Void
    let isSleepOn: Bool
    let onToggleSleep: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                if isVisible && !isBlocked {
                    VStack(spacing: 12) {
                        Button {
                            onToggle()
                        } label: {
                            controlIcon(isHorizontal ? "lock.rotation" : "rotate.right",
                                        active: isHorizontal)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isHorizontal ? "Unlock video orientation" : "Lock video orientation")

                        Button {
                            onToggleSleep()
                        } label: {
                            controlIcon("moon.fill", active: isSleepOn)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isSleepOn ? "Cancel sleep after this video" : "Sleep after this video")
                    }
                    .padding(.trailing, 16)
                    .padding(.top, geometry.size.height * Self.verticalOffsetFraction)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    private func controlIcon(_ systemName: String, active: Bool) -> some View {
        Image(systemName: systemName)
            .font(.title3.weight(.semibold))
            .foregroundStyle(active ? Color.accentColor : .white)
            .frame(width: 44, height: 44)
            .background(.black.opacity(0.55), in: Circle())
    }
}
