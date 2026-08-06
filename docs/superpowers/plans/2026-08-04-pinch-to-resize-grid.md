# Pinch-to-resize grid Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a pinch gesture anywhere over `defaultGrid` or `moviesGrid` live-resize the grid, snapping to the nearest of the existing 4 canonical sizes and persisting it, the same as the ellipsis menu's size buttons.

**Architecture:** A pure snapping function (`GridDisplayMode.nearestCanonicalSize(to:)`) added to PatataTubeKit, driven by a `MagnificationGesture` attached to the two `ScrollView`s that already read `cellSize` in `VideoGridView`. During the gesture, a local `@State` live size overrides `model.cellSize(for:)` for rendering; on release the live size snaps and is persisted through the existing `model.setCellSize(_:for:)`.

**Tech Stack:** Swift, SwiftUI (`MagnificationGesture`, `@GestureState`), XCTest (PatataTubeKit only — no iOS app test target exists).

## Global Constraints

- Canonical grid sizes are exactly `{70 (list), 170, 295, 420}` — from
  `docs/superpowers/specs/2026-08-04-pinch-to-resize-grid-design.md`, matching
  `GridDisplayMode.listCellSize`, `.minCellSize`, `.minCellSize + .step`,
  `.maxCellSize`.
- Live rendering clamps to `[70, 420]`; never renders below list or above the
  max grid size.
- Scope is exactly the two grids that already read `cellSize`:
  `defaultGrid` (group route) and `moviesGrid` (Movies tab). `GroupsView`,
  `ShowsView`, `EpisodesView`, `DownloadsView` are untouched.
- Persistence goes through the existing `AppModel.setCellSize(_:for:)` only —
  no new UserDefaults keys, no new per-feed dictionaries.
- No iOS app test target exists (see `CLAUDE.md`); all automated testing for
  this feature lives in PatataTubeKit and runs via `swift test`. View-level
  gesture behavior is verified manually.

---

### Task 1: `GridDisplayMode.nearestCanonicalSize(to:)`

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/GridDisplayMode.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/GridDisplayModeTests.swift`

**Interfaces:**
- Consumes: existing `GridDisplayMode.listCellSize` (`70`), `.minCellSize`
  (`170`), `.step` (`125`), `.maxCellSize` (`420`) — all already defined in
  this file.
- Produces:
  - `public static let GridDisplayMode.canonicalSizes: [Double]` — `[70, 170,
    295, 420]`, ascending.
  - `public static func GridDisplayMode.clampedCellSize(_ raw: Double) ->
    Double` — clamps `raw` into `[listCellSize, maxCellSize]`.
  - `public static func GridDisplayMode.nearestCanonicalSize(to raw: Double)
    -> Double` — returns whichever of `canonicalSizes` is closest to `raw`;
    on an exact tie between two neighbors, returns the smaller one (ties
    resolve down — this is a direct consequence of scanning
    `canonicalSizes` ascending with strict `<` comparison, not a separate
    rule to implement).

Task 2 calls `clampedCellSize` on every gesture update and
`nearestCanonicalSize(to:)` once in `onEnded`.

- [ ] **Step 1: Write the failing tests**

Append to `ios/PatataTubeKit/Tests/PatataTubeKitTests/GridDisplayModeTests.swift`
(inside the existing `GridDisplayModeTests` class, after the last test):

```swift
    func testCanonicalSizesAreListAndTheThreeGridStops() {
        XCTAssertEqual(GridDisplayMode.canonicalSizes, [70, 170, 295, 420])
    }

    func testClampedCellSizeClampsBelowList() {
        XCTAssertEqual(GridDisplayMode.clampedCellSize(10), 70)
    }

    func testClampedCellSizeClampsAboveCeiling() {
        XCTAssertEqual(GridDisplayMode.clampedCellSize(999), 420)
    }

    func testClampedCellSizePassesThroughMidRange() {
        XCTAssertEqual(GridDisplayMode.clampedCellSize(250), 250)
    }

    func testNearestCanonicalSizeSnapsToExactStops() {
        XCTAssertEqual(GridDisplayMode.nearestCanonicalSize(to: 70), 70)
        XCTAssertEqual(GridDisplayMode.nearestCanonicalSize(to: 170), 170)
        XCTAssertEqual(GridDisplayMode.nearestCanonicalSize(to: 295), 295)
        XCTAssertEqual(GridDisplayMode.nearestCanonicalSize(to: 420), 420)
    }

    func testNearestCanonicalSizeRoundsToCloserNeighbor() {
        XCTAssertEqual(GridDisplayMode.nearestCanonicalSize(to: 100), 70)
        XCTAssertEqual(GridDisplayMode.nearestCanonicalSize(to: 150), 170)
        XCTAssertEqual(GridDisplayMode.nearestCanonicalSize(to: 250), 295)
        XCTAssertEqual(GridDisplayMode.nearestCanonicalSize(to: 400), 420)
    }

    func testNearestCanonicalSizeTiesRoundDown() {
        XCTAssertEqual(GridDisplayMode.nearestCanonicalSize(to: 120), 70)
        XCTAssertEqual(GridDisplayMode.nearestCanonicalSize(to: 232.5), 170)
        XCTAssertEqual(GridDisplayMode.nearestCanonicalSize(to: 357.5), 295)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios/PatataTubeKit && swift test --filter GridDisplayModeTests`
Expected: FAIL to build — `canonicalSizes`, `clampedCellSize`,
`nearestCanonicalSize` do not exist yet.

- [ ] **Step 3: Implement the three additions**

In `ios/PatataTubeKit/Sources/PatataTubeKit/GridDisplayMode.swift`, add after
the existing `listCellSize` declaration (still inside `enum GridDisplayMode`,
before `forCellSize`):

```swift
    /// The 4 sizes a pinch gesture (or repeated menu taps) can land on:
    /// list, then the 3 grid stops `minCellSize`, `minCellSize + step`,
    /// `maxCellSize`. Ascending — `nearestCanonicalSize` relies on the order.
    public static let canonicalSizes: [Double] = [
        listCellSize, minCellSize, minCellSize + step, maxCellSize,
    ]

    /// Constrains a raw size (e.g. `baseSize * pinchScale`) to the range
    /// live rendering is allowed to show — never below list, never above the
    /// biggest grid stop.
    public static func clampedCellSize(_ raw: Double) -> Double {
        min(max(raw, listCellSize), maxCellSize)
    }

    /// Whichever `canonicalSizes` entry is closest to `raw`. Ties resolve to
    /// the smaller neighbor (scans ascending, keeps the first value that
    /// isn't strictly beaten).
    public static func nearestCanonicalSize(to raw: Double) -> Double {
        canonicalSizes.min(by: { abs($0 - raw) < abs($1 - raw) }) ?? raw
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios/PatataTubeKit && swift test --filter GridDisplayModeTests`
Expected: PASS, all tests including the 7 new ones.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/GridDisplayMode.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/GridDisplayModeTests.swift
git commit -m "feat(ios): add canonical-size snapping to GridDisplayMode"
```

---

### Task 2: Pinch gesture on the two grids

**Files:**
- Modify: `ios/PatataTube/Sources/VideoGridView.swift`

**Interfaces:**
- Consumes: `GridDisplayMode.clampedCellSize(_:)`,
  `GridDisplayMode.nearestCanonicalSize(to:)` (Task 1). Existing
  `model.cellSize(for: store.feed)`, `model.setCellSize(_:for:)`,
  `store.feed`.
- Produces: nothing new consumed elsewhere — this is the leaf of the feature.

No automated test (no iOS app test target). Verified manually at the end of
this task.

- [ ] **Step 1: Add gesture state and a live-cell-size override**

In `ios/PatataTube/Sources/VideoGridView.swift`, the view currently computes
`cellSize` and `displayMode` like this (around line 206):

```swift
    private var cellSize: Double { model.cellSize(for: store.feed) }
    /// List or grid, derived from the one persisted per-feed size.
    private var displayMode: GridDisplayMode { GridDisplayMode.forCellSize(cellSize) }
```

Replace that pair with (same location):

```swift
    /// Set only while a pinch is tracking; overrides the persisted size for
    /// rendering so the grid reflows live. `nil` the rest of the time.
    @State private var pinchLiveSize: Double?
    /// The size a pinch gesture started from — captured on first touch so
    /// `pinchLiveSize` scales from the persisted value, not from whatever
    /// `pinchLiveSize` last was.
    @State private var pinchStartSize: Double?

    private var cellSize: Double {
        pinchLiveSize ?? model.cellSize(for: store.feed)
    }
    /// List or grid, derived from the live-or-persisted size.
    private var displayMode: GridDisplayMode { GridDisplayMode.forCellSize(cellSize) }

    /// Pinch-to-resize: live-tracks scale against the size the gesture
    /// started from, then snaps to the nearest canonical stop and persists
    /// it exactly like the ellipsis menu's size buttons do.
    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                let base = pinchStartSize ?? model.cellSize(for: store.feed)
                if pinchStartSize == nil { pinchStartSize = base }
                pinchLiveSize = GridDisplayMode.clampedCellSize(base * scale)
            }
            .onEnded { scale in
                let base = pinchStartSize ?? model.cellSize(for: store.feed)
                let raw = GridDisplayMode.clampedCellSize(base * scale)
                model.setCellSize(GridDisplayMode.nearestCanonicalSize(to: raw), for: store.feed)
                pinchStartSize = nil
                pinchLiveSize = nil
            }
    }
```

- [ ] **Step 2: Attach the gesture to the Movies tab's scroll view**

`rootScrollView` (around line 379) currently reads:

```swift
    private var rootScrollView: some View {
        ScrollView {
            if store.isLoading && filteredVideos.isEmpty && tab != .videos {
                SkeletonGrid(columns: columns, aspectRatio: 2.0/3.0,
                             showsTextBars: tab == .tv,
                             isList: displayMode == .list)
            } else {
                switch tab {
                case .videos:
                    GroupsView(groups: groups)
                case .tv:
                    ShowsView(
                        videos: filteredVideos,
                        onPlay: { video, queue in
                            play(video, queueSnapshot: queue, caller: "shows")
                        },
                        onDownload: { await download($0) },
                        onItemAppear: { gridItemAppeared($0) },
                        onItemDisappear: { gridItemDisappeared($0) }
                    )
                case .movies:
                    moviesGrid
                }
            }
        }
    }
```

Only the `.movies` branch reads `cellSize` — `GroupsView`/`ShowsView` use
their own fixed columns, so a pinch on the Videos/TV tab root writes a
`cellSize` those tabs never render, same as the ellipsis menu's existing
"Smaller cells"/"Bigger cells" buttons already do unconditionally on every
tab today. No tab gate needed — attach the gesture unconditionally so the
code stays as simple as the precedent it's matching. Change the closing brace
of the `ScrollView` body:

```swift
        }
        .gesture(pinchGesture)
    }
```

- [ ] **Step 3: Attach the gesture to the group route's scroll view**

The group destination (around line 592, inside `destination(for:)`) currently
reads:

```swift
        case .group:
            ScrollViewReader { proxy in
                ScrollView {
                    if store.isLoading && filteredVideos.isEmpty {
                        SkeletonGrid(columns: columns, aspectRatio: 16.0/9.0,
                                     isList: displayMode == .list)
                    } else {
                        defaultGrid
                    }
                }
                .task(id: restoredGroupAnchor) {
                    guard let anchor = restoredGroupAnchor else { return }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(anchor, anchor: .top)
                    restoredGroupAnchor = nil
                }
            }
            .searchable(text: $searchText, prompt: "Search videos")
            .refreshable { await store.refreshLibrary() }
            .toolbar { optionsToolbar }
```

This `ScrollView` always renders `defaultGrid` (or its skeleton) when reached
— no tab gate needed here, unlike Step 2. Add the gesture directly to the
inner `ScrollView`:

```swift
                ScrollView {
                    if store.isLoading && filteredVideos.isEmpty {
                        SkeletonGrid(columns: columns, aspectRatio: 16.0/9.0,
                                     isList: displayMode == .list)
                    } else {
                        defaultGrid
                    }
                }
                .gesture(pinchGesture)
                .task(id: restoredGroupAnchor) {
```

- [ ] **Step 4: Build**

Run: `cd ios/PatataTube && xcodegen generate`
Then build the `PatataTube` scheme in Xcode (⌘B) for a simulator destination.
Expected: builds cleanly, no new warnings on `VideoGridView.swift`.

- [ ] **Step 5: Manual verification**

Run the app in the iOS Simulator (pinch gestures work with two-finger trackpad
gestures in Simulator, or via Simulator's "Multi-Touch" is on by default for
trackpad pinch):

1. Open a group (defaultGrid). Pinch out slowly: cards should grow smoothly,
   reflowing column count as they cross size thresholds, matching what
   "Bigger cells" would do at each stop.
2. Continue pinching out to the largest size, then past it: grid should clamp
   at the 420pt stop, not keep growing.
3. Release mid-pinch at a size between two stops: grid should snap to
   whichever canonical stop it was closer to.
4. Pinch in past the smallest grid stop (170): grid should live-reflow into
   list rows (matches list-mode behavior from
   `2026-08-03-grid-list-mode-design.md`) before you even release.
5. Release while in list: persisted size should be the list sentinel — leave
   the group and come back, confirm it's still list mode.
6. Repeat 1–5 on the Movies tab (`moviesGrid`).
7. On the Videos tab root and TV tab (GroupsView/ShowsView), pinch: confirm
   no crash and no visible effect (out of scope, matches the ellipsis menu's
   existing behavior there).
8. With a grid loaded, do an ordinary one-finger scroll before, during, and
   after a pinch: confirm scrolling is unaffected by the added gesture.
9. Pinch-resize a group, navigate to a different group, confirm the second
   group's size is independent (per-feed persistence, unchanged from
   existing menu behavior).

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTube/Sources/VideoGridView.swift
git commit -m "feat(ios): pinch-to-resize the video and movies grids"
```
