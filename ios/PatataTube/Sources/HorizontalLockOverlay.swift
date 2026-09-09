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
    /// Autoplay for the queue's scope. `onToggleAutoplay == nil` means this
    /// presentation has no scope to key the setting under (a PiP restore with
    /// no `restoreScope`), and the button is left out rather than shown inert.
    var isAutoplayOn: Bool = false
    var onToggleAutoplay: (() -> Void)? = nil

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                if isVisible && !isBlocked {
                    VStack(spacing: 12) {
                        Button {
                            onToggle()
                        } label: {
                            controlIcon(isHorizontal ? "lock.rotation" : "rectangle.landscape.rotate",
                                        active: isHorizontal)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isHorizontal ? "Stop forcing horizontal video" : "Force horizontal video")

                        Button {
                            onToggleSleep()
                        } label: {
                            controlIcon("moon.fill", active: isSleepOn)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isSleepOn ? "Cancel sleep after this video" : "Sleep after this video")

                        if let onToggleAutoplay {
                            Button {
                                onToggleAutoplay()
                            } label: {
                                controlIcon(active: isAutoplayOn) {
                                    // Not an SF Symbol, so it needs an explicit
                                    // size — `.font` does not scale a bitmap.
                                    Image("Autoplay")
                                        .renderingMode(.template)
                                        .resizable()
                                        .frame(width: 22, height: 22)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(isAutoplayOn ? "Turn autoplay off" : "Turn autoplay on")
                        }
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
        controlIcon(active: active) {
            Image(systemName: systemName).font(.title3.weight(.semibold))
        }
    }

    private func controlIcon<Content: View>(
        active: Bool, @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .foregroundStyle(active ? Color.accentColor : .white)
            .frame(width: 44, height: 44)
            .background(.black.opacity(0.55), in: Circle())
    }
}
