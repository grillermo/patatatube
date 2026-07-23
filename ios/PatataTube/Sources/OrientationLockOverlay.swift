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

struct OrientationLockOverlay: View {
    let isLocked: Bool
    let isVisible: Bool
    let isBlocked: Bool
    let onToggle: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if isVisible && !isBlocked {
                Button {
                    onToggle()
                } label: {
                    Image(systemName: isLocked ? "lock.rotation" : "rotate.right")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(isLocked ? Color.accentColor : .white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isLocked ? "Unlock video orientation" : "Lock video orientation")
                .padding(16)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}
