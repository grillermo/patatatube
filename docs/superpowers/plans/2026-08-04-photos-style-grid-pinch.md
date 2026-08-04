# Photos-Style Grid Pinch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the grid-resize pinch actually recognizable: two fingers down freezes scrolling (like iOS Photos) and the pinch live-resizes the grid, instead of losing gesture arbitration to the scroll pan.

**Architecture:** Replace the SwiftUI `MagnificationGesture` in `VideoGridView` with a `UIGestureRecognizerRepresentable` (iOS 18 API) wrapping a `UIPinchGestureRecognizer`. Its coordinator is the recognizer's delegate, returns `true` for simultaneous recognition so the pinch can begin while the scroll pan tracks, and on `.began` disables the enclosing `UIScrollView`'s pan recognizer (which cancels an in-flight scroll) until the pinch ends. All sizing logic (`GridDisplayMode`, per-feed persistence) is untouched.

**Tech Stack:** SwiftUI, UIKit (`UIPinchGestureRecognizer`, `UIGestureRecognizerRepresentable`), XcodeGen, SwiftPM.

**Spec:** `docs/superpowers/specs/2026-08-04-photos-style-grid-pinch-design.md`

## Global Constraints

- Deployment target becomes **iOS 18.0** everywhere: both XcodeGen targets in `ios/PatataTube/project.yml` and `.iOS(.v18)` in `ios/PatataTubeKit/Package.swift` (keep `.macOS(.v14)`).
- No PatataTubeKit logic changes beyond the platform line. `GridDisplayMode` and its tests stay as-is.
- DevLog rules (project CLAUDE.md): use `DevLog.event`, never `print`; cheap `meta` values only; no tokens/bodies.
- `docs/` is gitignored; plan/spec commits need `git add -f`.
- App-target code has no automated test target — verification for Tasks 2–3 is compile + manual checklist; PatataTubeKit still must pass `swift test` in both configs after the platform bump.

---

### Task 1: Bump deployment target to iOS 18

**Files:**
- Modify: `ios/PatataTube/project.yml` (lines ~4-5, ~38-39, ~105-106 — one `deploymentTarget` under `options`, one per target)
- Modify: `ios/PatataTubeKit/Package.swift` (platforms line: `[.iOS(.v17), .macOS(.v14)]`)

**Interfaces:**
- Consumes: nothing.
- Produces: build environment where iOS-18-only `UIGestureRecognizerRepresentable` compiles (Task 2 requires this).

- [ ] **Step 1: Edit project.yml**

Change every `iOS: "17.0"` / `deploymentTarget: "17.0"` to `"18.0"`. There are three spots: the top-level `options.deploymentTarget.iOS`, and one `deploymentTarget:` per target (app target ~line 39, second target ~line 106). Verify none remain:

```bash
grep -n '17\.0' ios/PatataTube/project.yml
```

Expected: no matches.

- [ ] **Step 2: Edit Package.swift**

```swift
platforms: [.iOS(.v18), .macOS(.v14)],
```

- [ ] **Step 3: Verify package still builds and tests pass (both configs)**

```bash
cd ios/PatataTubeKit && swift build && swift test && swift test -c release
```

Expected: build ok, tests pass. (Full parallel `swift test` has known pre-existing flakes — see CLAUDE.md; re-run filtered before concluding a regression.)

- [ ] **Step 4: Regenerate the Xcode project and build the app**

```bash
cd ios/PatataTube && xcodegen generate
xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`. (Adjust scheme name if `xcodebuild -list` shows a different one.)

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTube/project.yml ios/PatataTubeKit/Package.swift
git commit -m "build(ios): raise deployment target to iOS 18"
```

---

### Task 2: `GridPinchGesture` — UIKit pinch with scroll lock

**Files:**
- Create: `ios/PatataTube/Sources/GridPinchGesture.swift`

**Interfaces:**
- Consumes: nothing from other tasks (pure UIKit/SwiftUI).
- Produces: `struct GridPinchGesture: UIGestureRecognizerRepresentable` with initializer
  `init(onChanged: @escaping (CGFloat) -> Void, onEnded: @escaping (CGFloat) -> Void)`.
  `scale` semantics identical to `MagnificationGesture`'s value: multiplicative factor since gesture start. Task 3 attaches it via `.gesture(GridPinchGesture(onChanged:onEnded:))`.

- [ ] **Step 1: Write the file**

```swift
import SwiftUI
import UIKit

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

        deinit {
            // MainActor-isolated deinit is fine here; keep scroll from ever
            // staying dead if the recognizer is torn down mid-pinch.
            lockedPan?.isEnabled = true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
```

Note on `deinit`: if the compiler rejects touching `lockedPan` from a
nonisolated deinit under strict concurrency, drop the `deinit` entirely —
`unlockScrolling()` on every terminal state already covers real teardown, and
a deallocated recognizer's view is gone anyway.

- [ ] **Step 2: Build to verify it compiles**

```bash
cd ios/PatataTube && xcodegen generate
xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add ios/PatataTube/Sources/GridPinchGesture.swift
git commit -m "feat(ios): UIKit pinch recognizer with Photos-style scroll lock"
```

---

### Task 3: Rewire `VideoGridView` to the new gesture

**Files:**
- Modify: `ios/PatataTube/Sources/VideoGridView.swift:220-237` (the `pinchGesture` property) and its two attach points (`:433` root scroll view, `:632` group destination scroll view)

**Interfaces:**
- Consumes: `GridPinchGesture(onChanged:onEnded:)` from Task 2.
- Produces: user-visible behavior; nothing downstream.

- [ ] **Step 1: Replace the `pinchGesture` property**

Old (lines 220-237): `private var pinchGesture: some Gesture { MagnificationGesture()... }`.

New — same state machine, `UIGestureRecognizerRepresentable` conforms to `Gesture`, so the attach points don't change shape:

```swift
    /// Pinch-to-resize: live-tracks scale against the size the gesture
    /// started from, then snaps to the nearest canonical stop and persists
    /// it exactly like the ellipsis menu's size buttons do. UIKit-backed
    /// (`GridPinchGesture`) so two fingers freeze scrolling instead of the
    /// scroll pan swallowing the pinch.
    private var pinchGesture: some Gesture {
        GridPinchGesture(
            onChanged: { scale in
                let base = pinchStartSize ?? model.cellSize(for: store.feed)
                if pinchStartSize == nil { pinchStartSize = base }
                pinchLiveSize = GridDisplayMode.clampedCellSize(base * scale)
            },
            onEnded: { scale in
                let base = pinchStartSize ?? model.cellSize(for: store.feed)
                let raw = GridDisplayMode.clampedCellSize(base * scale)
                model.setCellSize(GridDisplayMode.nearestCanonicalSize(to: raw), for: store.feed)
                pinchStartSize = nil
                pinchLiveSize = nil
            }
        )
    }
```

The two `.gesture(pinchGesture)` attach points (`rootScrollView` and the
`.group` destination) stay exactly as they are.

If `some Gesture` opaque-type inference complains (representable's `Body` is
`Never`-adjacent on some SDKs), change the property's type to
`GridPinchGesture` — call sites are unaffected.

- [ ] **Step 2: Build**

```bash
cd ios/PatataTube && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Manual verification in Simulator (or device)**

Run the app (Simulator pinch: hold Option, drag). On the movies grid and on a
group grid:

1. Two-finger touch while list is mid-scroll → scrolling stops dead.
2. Pinch out → cells grow live; pinch in → shrink through to list rows.
3. Release → snaps to nearest canonical size; kill + relaunch app → size kept.
4. One-finger scroll → completely normal, no regression.
5. Ellipsis menu Smaller/Bigger/List/Grid buttons still work.
6. `log/ios.jsonl` shows `grid pinch began` / `grid pinch ended` records
   (Debug builds have DEVLOG on automatically).

- [ ] **Step 4: Run package tests once more (unchanged, belt-and-braces)**

```bash
cd ios/PatataTubeKit && swift test && swift test -c release
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTube/Sources/VideoGridView.swift
git commit -m "fix(ios): make grid pinch win over scroll, Photos-style"
```
