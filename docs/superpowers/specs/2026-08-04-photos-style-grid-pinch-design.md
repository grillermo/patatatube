# Photos-style pinch-to-resize for iOS grids

Date: 2026-08-04
Status: approved

## Problem

The grid-resize pinch (added in c7d642c) is attached as a SwiftUI
`MagnificationGesture` via `.gesture()` on the `ScrollView`
(`VideoGridView.swift:433` and `:632`). SwiftUI's scroll pan wins gesture
arbitration: during a two-finger touch, any slight finger movement starts a
scroll and the pinch never recognizes. In practice the gesture is nearly
impossible to perform.

iOS Photos gets this right at the UIKit level: its pinch recognizer runs
simultaneously with the scroll pan, and the moment two fingers are down and the
pinch begins, scrolling is frozen until the fingers lift.

## Decisions

- **Bump deployment target to iOS 18.0** so the fix can use Apple's
  first-class `UIGestureRecognizerRepresentable` API instead of a
  `UIViewRepresentable` superview-walking shim. (User's device runs iOS 18+.)
- **Keep the current visuals**: continuous live cell resize while pinching,
  rubber-band clamp, snap to the nearest canonical size
  (list / small / medium / large) on release. Only the gesture plumbing
  changes.

## Design

### 1. Deployment target

- `ios/PatataTube/project.yml`: both targets `17.0` → `18.0`.
- `ios/PatataTubeKit/Package.swift`: `.iOS(.v17)` → `.iOS(.v18)`.

### 2. `GridPinchGesture` (new file, app target)

`ios/PatataTube/Sources/GridPinchGesture.swift` — a
`UIGestureRecognizerRepresentable` wrapping `UIPinchGestureRecognizer`.

- **Simultaneous recognition**: the coordinator is the recognizer's
  `UIGestureRecognizerDelegate` and returns `true` from
  `gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:)`, so the pinch can
  begin even while the scroll pan is tracking.
- **Scroll lock** (the Photos behavior): on `.began`, walk up from
  `recognizer.view` superviews to find the enclosing `UIScrollView` and set its
  `panGestureRecognizer.isEnabled = false` — disabling a recognizer cancels it
  mid-flight, so the in-progress scroll stops dead. On
  `.ended` / `.cancelled` / `.failed`, re-enable it.
- **Callbacks**: `onChanged(scale)` and `onEnded(scale)` closures with the same
  semantics as `MagnificationGesture`'s value, so the existing
  `pinchStartSize` / `pinchLiveSize` / snap logic in `VideoGridView` is reused
  unchanged.

### 3. Wire-up in `VideoGridView`

Replace the `pinchGesture` computed property's `MagnificationGesture` body with
the new `GridPinchGesture`, attached at the same two points (root scroll view,
episodes grid). All sizing logic — `GridDisplayMode.clampedCellSize`,
`nearestCanonicalSize`, per-feed persistence via `model.setCellSize` — stays
where it is. No PatataTubeKit logic changes.

### 4. Instrumentation

DevLog `tap`-kind events on pinch begin and end (final snapped size in `meta`),
matching existing call-site style. `@autoclosure` args, cheap meta only.

## Error handling

- **No `UIScrollView` found** (SwiftUI internals change): pinch still works —
  resize happens, just no scroll freeze. Graceful degradation, no crash.
- **Pan never left disabled**: re-enable on every terminal recognizer state and
  defensively in the coordinator's cleanup, so scrolling can never get stuck
  off.

## Testing

- `GridDisplayModeTests` unchanged; `swift test` and `swift test -c release`
  stay green (no package logic touched beyond the platform bump).
- Manual checklist (device/simulator):
  - Two-finger touch on grid freezes scrolling immediately.
  - Pinch out grows cells live; pinch in shrinks through to list.
  - Release snaps to nearest canonical size and persists per feed.
  - One-finger scroll is completely unaffected.
  - Grid-size menu buttons still work.
  - Works on both the movies grid and the episodes grid.
