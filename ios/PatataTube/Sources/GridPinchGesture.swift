import SwiftUI
import UIKit
import PatataTubeKit

/// A UIKit pinch for the grids, replacing `MagnificationGesture`, which lost
/// gesture arbitration to the scroll pan (any one-finger drift scrolled
/// instead of pinching). Recognizes simultaneously with the scroll view's pan
/// and, Photos-style, freezes scrolling for as long as the pinch is down.
struct GridPinchGesture: UIGestureRecognizerRepresentable {
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPinchGestureRecognizer {
        let recognizer = UIPinchGestureRecognizer()
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(
        _ recognizer: UIPinchGestureRecognizer, context: Context
    ) {
        switch recognizer.state {
        case .began:
            context.coordinator.lockScrolling(around: recognizer.view)
            DevLog.event(.tap, "grid pinch began")
            onChanged(recognizer.scale)
        case .changed:
            onChanged(recognizer.scale)
        case .ended:
            context.coordinator.unlockScrolling()
            DevLog.event(.tap, "grid pinch ended",
                         ["scale": String(format: "%.2f", recognizer.scale)])
            onEnded(recognizer.scale)
        case .cancelled, .failed:
            context.coordinator.unlockScrolling()
            onEnded(recognizer.scale)
        default:
            break
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// The pan we disabled, kept so unlock re-enables exactly that one.
        private weak var lockedPan: UIPanGestureRecognizer?

        /// Disabling the scroll view's pan cancels an in-flight scroll, which
        /// is what makes two fingers down feel like Photos: the list stops
        /// dead and only the pinch tracks. If no scroll view is found
        /// (SwiftUI hosting changed), the pinch still works — just no lock.
        func lockScrolling(around view: UIView?) {
            var current = view
            while let candidate = current {
                if let scrollView = candidate as? UIScrollView {
                    scrollView.panGestureRecognizer.isEnabled = false
                    lockedPan = scrollView.panGestureRecognizer
                    return
                }
                current = candidate.superview
            }
        }

        func unlockScrolling() {
            lockedPan?.isEnabled = true
            lockedPan = nil
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
