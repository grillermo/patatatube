import SwiftUI
import UIKit
import PatataTubeKit

/// A UIKit pinch for the grids, replacing `MagnificationGesture`, which lost
/// gesture arbitration to the scroll pan (any one-finger drift scrolled
/// instead of pinching). Recognizes simultaneously with the scroll view's pan
/// and, Photos-style, freezes scrolling for as long as the pinch is down.
///
/// A pinch that ends via `.cancelled`/`.failed` (e.g. the OS interrupts the
/// touch) still calls `onEnded` with the last live scale, exactly like a
/// normal `.ended` — this is deliberate, matching "the grid keeps whatever
/// size it was tracking toward" rather than silently reverting, and is not
/// an oversight.
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
            // Force scale to exactly 1.0 at the start of every gesture. This
            // is UIKit's own default, but pinning it explicitly here makes
            // the invariant a hard guarantee rather than an assumption:
            // VideoGridView's onChanged closure relies on "scale == 1.0"
            // to detect a fresh gesture and reset its cached base size.
            recognizer.scale = 1
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
            // Still commits the last live scale via onEnded (see the type's
            // doc comment) — log it distinctly so a "began" record in
            // log/ios.jsonl always has a matching terminal record, cancelled
            // or not, rather than reading as a hang.
            context.coordinator.unlockScrolling()
            DevLog.event(.tap, "grid pinch cancelled",
                         ["scale": String(format: "%.2f", recognizer.scale)])
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
            // No UIScrollView found up the chain — scrolling can't be
            // locked, so this pinch is exposed to exactly the arbitration
            // bug this type exists to fix. Make that visible instead of
            // failing silently.
            DevLog.error(
                GridPinchGestureError.noScrollViewFound,
                "grid pinch could not find a UIScrollView to lock"
            )
        }

        func unlockScrolling() {
            lockedPan?.isEnabled = true
            lockedPan = nil
        }

        /// Only the scroll view's own pan needs to run simultaneously with
        /// the pinch (so two fingers landing mid-scroll still recognizes);
        /// every other recognizer in the hierarchy (taps, long-press,
        /// nav-swipe, ...) keeps default exclusive arbitration.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            other is UIPanGestureRecognizer && other.view is UIScrollView
        }
    }
}

/// Marker error for `DevLog.error` when `lockScrolling` can't find a
/// `UIScrollView` to disable — carries no payload, just a stable type name.
private enum GridPinchGestureError: Error {
    case noScrollViewFound
}
