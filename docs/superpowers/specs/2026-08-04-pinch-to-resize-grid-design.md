# Pinch-to-resize the video grid — design

Date: 2026-08-04
Status: approved, ready for implementation planning

## Problem

Grid cell size (list / 170 / 295 / 420, `GridDisplayMode`) is only adjustable
through the ellipsis menu's "Smaller cells" / "Bigger cells" buttons. There is
no direct-manipulation way to resize, the way Photos resizes its grid with a
pinch gesture.

## Goal

A pinch gesture anywhere over `defaultGrid` or `moviesGrid` live-resizes the
grid as the fingers move, then snaps to the nearest canonical size and
persists it — functionally equivalent to pressing the menu button that many
times, but continuous and direct.

## Scope

Same two grids `GridDisplayMode` already governs (per
`2026-08-03-grid-list-mode-design.md`):

- `defaultGrid` (group route)
- `moviesGrid` (Movies tab)

Out of scope, unchanged: `GroupsView`, `ShowsView`, `EpisodesView`,
`DownloadsView` — none read `cellSize` today, so a pinch there would have
nothing to act on.

## Gesture behavior

A `MagnificationGesture` is attached to the `ScrollView` wrapping each grid
(not the `LazyVGrid` itself, so it fires over padding/empty space too — "the
whole screen" the way Photos' pinch does).

**Live tracking.** `@GestureState` holds the current scale. While the gesture
is active, the grid renders off `liveCellSize = clamp(baseSize * scale, 70,
420)` instead of `model.cellSize(for:)`, where `baseSize` is whatever
`model.cellSize(for:)` was when the gesture began. No new threshold logic is
needed: `GridDisplayMode.forCellSize` already treats anything `< 170` as
`.list`, so crossing that boundary mid-pinch already reflows into rows live,
the same as it does today when a value is set via the menu.

**Snap on release.** `onEnded` maps the final live size to the nearest of the
four canonical values `{70 (list), 170, 295, 420}` and calls
`model.setCellSize(_:for: store.feed)` once — the same call the menu buttons
already make. A pinch can never leave a feed parked on a size the menu
couldn't also reach.

**Clamping, not rubber-banding.** Scale is clamped during tracking, not
allowed to overshoot and spring back — simpler, and with only 4 stops the
overshoot affordance Photos uses for many stops isn't needed here.

## Interaction with scrolling

`MagnificationGesture` is a distinct (multi-touch) recognizer from
`ScrollView`'s single-finger pan, so both compose without a custom
`UIGestureRecognizerDelegate` — standard SwiftUI behavior, no special handling
required.

## State

No new persisted state. Reuses `AppModel.cellSizeByFeed` / `setCellSize(_:for:)`
exactly as the menu buttons do. One new small view-level helper (a computed
"nearest canonical size" function) alongside `GridDisplayMode` in
PatataTubeKit, unit-tested the same way `smaller`/`bigger` are.

## Files

New: nothing (helper lives in `GridDisplayMode.swift`).

Edited:

- `ios/PatataTubeKit/Sources/PatataTubeKit/GridDisplayMode.swift` — add
  `nearestCanonicalSize(to:)` (or similarly named) pure function: `Double ->
  Double`, snapping to `{70, 170, 295, 420}`.
- `ios/PatataTubeKit/Tests/PatataTubeKitTests/GridDisplayModeTests.swift` —
  cover the snap boundaries (midpoints round to nearer neighbor).
- `ios/PatataTube/Sources/VideoGridView.swift` — the two `ScrollView`s wrapping
  `defaultGrid`/`moviesGrid` gain the magnification gesture, `@GestureState`,
  and a live-vs-persisted `cellSize` read.

Untouched: `AppModel`'s storage, the backend, `Video`, `project.yml`.

## Testing

PatataTubeKit: `nearestCanonicalSize` boundary cases (exact stops, midpoints,
below 70, above 420).

No iOS app test target exists — gesture behavior is verified manually:
pinch in/out over both grids, confirm live reflow, confirm release snaps and
persists (survives navigating away and back), confirm crossing into/out of
list mid-pinch, confirm ordinary one-finger scrolling still works during and
after a pinch.

## Verification

```bash
cd ios/PatataTubeKit && swift build && swift test
cd ios/PatataTube && xcodegen generate     # then build/run in Xcode
```
