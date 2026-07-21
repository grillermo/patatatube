# iOS Toolbar Menu Consolidation

**Date:** 2026-07-21
**Component:** `ios/PatataTube/Sources/VideoGridView.swift`

## Problem

The video-grid toolbar spreads its controls across the navigation bar and
branches on `horizontalSizeClass`:

- **Leading:** Settings (gear).
- **Trailing (regular/iPad):** Download-all, Smaller cells, Bigger cells,
  Autoplay switch, Refresh, New-video (+) — all as separate bar buttons.
- **Trailing (compact/narrow):** an `ellipsis.circle` Menu holding only
  Download-all + cell size −/+, plus separate Autoplay, Refresh, New-video
  buttons.

Two divergent layouts to maintain, and the iPad bar is crowded.

## Goal

Collapse everything into a single `ellipsis.circle` (`⋯`) Menu, identical in
both size classes. Toolbar becomes just the search bar + the `⋯` button.

## Design

Replace the entire `.toolbar { … }` body with one trailing `ToolbarItem`
containing a `Menu` labeled `Image(systemName: "ellipsis.circle")`.

Menu contents, grouped with `Divider()`:

```
⋯
├─ New video          plus                    → showUpload = true
├─ Refresh            arrow.clockwise         → Task { await store.refreshLibrary() }   [.disabled(store.isLoading)]
├─ Autoplay [toggle]  (checkmark row)         → Toggle(isOn: $model.autoplay)
├──────────  Divider
├─ Download all       arrow.down.circle       → Task { await downloadAll() }            [.disabled(downloadingAll)]
├─ Smaller cells      minus.magnifyingglass   → cellSize -= step   [.disabled(cellSize <= minCellSize)]
├─ Bigger cells       plus.magnifyingglass    → cellSize += step   [.disabled(cellSize >= maxCellSize)]
├──────────  Divider
└─ Settings           gear                    → showSettings = true
```

### Removed / changed

- **Delete** the leading gear `ToolbarItem`.
- **Delete** the `if horizontalSizeClass == .compact { … } else { … }`
  branching entirely — one code path now.
- **Delete** the separate Autoplay / Refresh / New-video trailing
  `ToolbarItem`s.
- **Delete** the `@Environment(\.horizontalSizeClass) private var
  horizontalSizeClass` line (no longer referenced).

### Autoplay inside the menu

Use an inline `Toggle(isOn: $model.autoplay) { Label("Autoplay", systemImage:
"play.circle") }`. SwiftUI menus render a bound `Toggle` as a checkmark row (the
`.switch` style does not apply inside a menu), which is the correct affordance.

The `AutoplayToggle` component is **left untouched** — it is still used by
`EpisodesView.swift:57`.

### Behavior notes (accepted trade-offs)

- **Refresh** and **Download-all** lose their inline `ProgressView` spinner —
  menus cannot host a live spinner. In-progress state is still conveyed via the
  `.disabled(...)` modifier. Pull-to-refresh (`.refreshable`) remains for live
  refresh feedback.
- Sheets (`showSettings`, `showUpload`), `downloadAll()`, and the `cellSize`
  state/steps are unchanged — only the trigger site moves into the menu.

### Untouched

- `.searchable(text:)` search bar — stays a separate toolbar affordance.
- `.refreshable { await store.load() }` pull-to-refresh.
- All grid rendering, playback, download, and error-banner logic.

## Testing

No automated iOS test target exists. Manual verification (`xcodegen generate`,
build, run):

1. iPad (regular width): toolbar shows search bar + a single `⋯`; no other bar
   buttons. Menu opens with all 8 rows in the grouped order above.
2. Narrow width (Split View / iPhone): identical `⋯` menu, same contents.
3. Each row works: New video and Settings open their sheets; Refresh reloads;
   Autoplay row toggles and shows a checkmark reflecting `model.autoplay`;
   Download-all downloads uncached videos; Smaller/Bigger cells resize the grid
   and disable at the min/max bounds.
4. Refresh row is disabled while `store.isLoading`; Download-all disabled while
   `downloadingAll`.
