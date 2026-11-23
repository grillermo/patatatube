import Combine
import SwiftUI

/// Mirrors AVPlayerViewController's own transport-bar rules so the custom
/// buttons come and go with the system ones: a tap on the video toggles them,
/// they auto-hide after a few seconds while playing, and stay up while paused.
@MainActor
final class OrientationControlVisibility: ObservableObject {
    @Published private(set) var isVisible = false
    private var hideTask: Task<Void, Never>?
    private var isPlaying = true
    private var clock: any Clock<Duration> = ContinuousClock()

    /// A tap on the video itself (not on one of AVKit's controls).
    func toggle() {
        if isVisible { hide() } else { reveal() }
    }

    func reveal() {
        isVisible = true
        rearm()
    }

    func reveal<C: Clock>(using clock: C) where C.Duration == Duration {
        self.clock = clock
        reveal()
    }

    /// Paused keeps the buttons up indefinitely, like AVKit; resuming starts
    /// the countdown again.
    func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        if isVisible { rearm() }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        isVisible = false
    }

    private func rearm() {
        hideTask?.cancel()
        hideTask = nil
        guard isPlaying else { return }
        let clock = self.clock
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
    /// Shuffle for the queue's scope; `nil` hides the button, same as autoplay.
    var isShuffleOn: Bool = false
    var onToggleShuffle: (() -> Void)? = nil

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
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

                        if let onToggleShuffle {
                            Button {
                                onToggleShuffle()
                            } label: {
                                controlIcon("shuffle", active: isShuffleOn)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(isShuffleOn ? "Turn shuffle off" : "Turn shuffle on")
                        }
                    }
                    .padding(.leading, 16)
                    .padding(.top, geometry.size.height * Self.verticalOffsetFraction)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func controlIcon(_ systemName: String, active: Bool) -> some View {
        controlIcon(active: active) {
            Image(systemName: systemName).font(.system(size: 19, weight: .medium))
        }
    }

    /// Matches AVPlayerViewController's own chrome (close, PiP, volume, ⋯):
    /// a 44pt Liquid Glass circle on iOS 26, a dark material disc before it.
    /// A flat black disc vanished over the letterbox bars, leaving bare glyphs.
    private func controlIcon<Content: View>(
        active: Bool, @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .foregroundStyle(active ? Color.accentColor : .white)
            .frame(width: 44, height: 44)
            .modifier(SystemChromeBackground())
            .contentShape(Circle())
    }
}

private struct SystemChromeBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                .environment(\.colorScheme, .dark)
        }
    }
}
