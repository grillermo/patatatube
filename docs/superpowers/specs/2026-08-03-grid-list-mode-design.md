# List mode at the smallest grid size — design

Date: 2026-08-03
Status: approved, ready for implementation planning

## Problem

`VideoGridView`'s cell size is adjustable per feed (`AppModel.cellSize(for:)`,
120–420pt, 50pt steps, driven by "Smaller cells"/"Bigger cells" in the ellipsis
menu). At the 120pt floor the cards are tiny squares: the poster is too small to
recognise and the title is cramped, so the densest setting is also the least
usable one. A list of rows is the right shape at that density.

## Goal

At one step below the current floor, both `cellSize`-driven grids render a
single-column list of rows instead of a grid of cards.

## Scope

In scope — the two grids that already read `cellSize`:

- `defaultGrid` (`VideoCell`) — the grid you get when you tap a group card, and
  every other feed root that renders it.
- `moviesGrid` (`MovieCell`) — the Movies tab.

Out of scope, unchanged: `GroupsView`, `ShowsView`, `EpisodesView`,
`DownloadsView`. None of them read `cellSize` today.

## Mode and persistence

`cellSize` stays the single per-feed persisted number. A sentinel value of `70`
— one 50pt step below the 120pt floor — means list mode. Nothing about
`AppModel`, its UserDefaults dictionary (`gridCellSizes`), or `Feed.storageKey`
changes. An older build reading `70` would draw 70pt cells; harmless.

A new pure type in PatataTubeKit owns the whole state machine:

- `GridDisplayMode.forCellSize(_:)` → `.list` when `< 120`, else `.grid(size)`
- the target of the smaller/bigger buttons, their labels, and their disabled
  state

Labels:

| current size | "smaller" button | "bigger" button |
|---|---|---|
| > 120 | "Smaller cells" | "Bigger cells" |
| 120 | **"List view"** → 70 | "Bigger cells" |
| 70 (list) | disabled | **"Grid view"** → 120 |

## Rendering

`columns` becomes mode-driven:

- list → `[GridItem(.flexible(), spacing: 0)]`
- grid → today's `[GridItem(.adaptive(minimum: cellSize), spacing: 16)]`

`LazyVGrid` spacing drops to 0 in list mode; the grid's `.padding()` stays.

Both `defaultGrid` and `moviesGrid` branch on the mode: list renders
`VideoRow` / `MovieRow`, grid renders today's `VideoCell` / `MovieCell`. The
per-item `.id(String(video.id))` and the `onAppear` / `onDisappear` hooks stay
*outside* that branch.

This is deliberate: the enclosing `ScrollView`, `ScrollViewReader`,
scroll-anchor restore (`restoredGroupAnchor`, `gridItemAppeared`), the search
filter, and `.refreshable` are all untouched, so pull-to-refresh keeps behaving
exactly as it does now. A real SwiftUI `List` was rejected for exactly this
reason — it would have replaced the scroll container and put all of that
behaviour back in play.

Both grids are already split out of `body` because inlining them blew the type
checker's time budget. The new branch goes inside each split-out property and
the rows are separate files, so nothing is added to that expression.

`SkeletonGrid` gains the same mode: in list it draws grey 78×44 thumbs with two
bars per row, same item count, same `columns` binding.

## `VideoRow`

Layout: 78×44 thumbnail (16:9, `AuthedImage`, black fallback with no overlaid
title text, `onPreviewLoaded` passed through) — one-line title with
`.truncationMode(.tail)` — spacer — 44×44 ellipsis button. A `Divider()`
separates rows. Flat: no card background, no corner radius.

Everything left of the ellipsis is the play tap target, carrying the same
`.logTap("play", ["video_id":…, "status":…])` the cell has today.

No download button and no download-state glyph in the row. All of it lives in
the menu, which is a single flat list:

- download action, labelled from `CacheState`: "Download" / "Downloading 42%"
  plus "Cancel download" / "Delete download"
- "Play and sleep" — only when the video is in the `children` group and `done`
- "Info" — the existing `VideoInfoView` sheet
- groups and the "Move to Plex" section — only when `!video.isPlexItem`
- a "Version" section when `versions.count > 1`, checkmark on the chosen one
- a disabled status line when `status != "done"` (e.g. "Status: queued")
- "Delete video", destructive, through the existing confirmation dialog

`VideoRow` takes the same closure set as `VideoCell`, so `defaultGrid` passes
identical arguments to either.

**Known tradeoff:** a download in flight is invisible until the menu is opened,
and the percentage in the label is a snapshot from when the menu opened — menus
don't live-update. Accepted: the row stays clean at its densest setting.

## `MovieRow`

`NavigationLink(value: Route.movie(id:))` over a 78×44 thumbnail — the 2:3
poster letterboxed (`fit`) inside the 78pt-wide box so titles line up with video
rows — plus a one-line title and a `Divider()`. No ellipsis and no menu, because
`MovieCell` has none: the poster is a link and `MovieDetailView` owns playback
and download. The same `storePreview` side effect on network image load is kept.

## Testing

No iOS app test target exists, so all testable logic lives in PatataTubeKit and
is covered by `swift test`. New `GridDisplayModeTests`:

- `forCellSize`: 70 → list, 119 → list, 120 → grid(120), 420 → grid(420)
- smaller from 120 → 70; smaller from 170 → 120; smaller at 70 → disabled
- bigger from 70 → 120; bigger from 120 → 170; bigger at 420 → disabled
- labels: at 120 smaller reads "List view"; at 70 bigger reads "Grid view"; at
  170 both read "Smaller cells"/"Bigger cells"

The views themselves are verified manually against `ios/README.md`'s checklist.

## Files

New:

- `ios/PatataTubeKit/Sources/PatataTubeKit/GridDisplayMode.swift`
- `ios/PatataTubeKit/Tests/PatataTubeKitTests/GridDisplayModeTests.swift`
- `ios/PatataTube/Sources/VideoRow.swift`
- `ios/PatataTube/Sources/MovieRow.swift`

Edited:

- `ios/PatataTube/Sources/VideoGridView.swift` — mode-driven `columns`, the two
  grid branches, the two menu buttons
- `ios/PatataTube/Sources/SkeletonGrid.swift` — list variant

Untouched: `AppModel`, the backend, `Video`, `project.yml` (XcodeGen globs the
app sources).

## Verification

```bash
cd ios/PatataTubeKit && swift build && swift test
cd ios/PatataTube && xcodegen generate     # then build/run in Xcode
```

Manual: shrink a group's grid to 120, confirm "List view" appears, tap it, check
rows render, play on tap, menu contents, pull-to-refresh, search filtering,
scroll position restored after backgrounding, and that the Movies tab reaches
its own list independently.
