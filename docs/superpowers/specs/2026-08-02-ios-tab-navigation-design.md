# iOS tab navigation + video groups — design

Date: 2026-08-02

## Problem

Every classification lives on one toolbar segmented `Picker`
(`VideoGridView.filterTabs`): children / adults / education / tv / movies. The
control is cramped, its hardcoded default is already stale (`education` no
longer exists server-side, `anabel` is missing), and it flattens two different
kinds of thing — top-level media types (TV, Movies) and video buckets — into one
row.

## Goal

Three top-level media types in a `TabView` (Videos, TV, Movies). Inside Videos,
four groups (children, adults, anabel, asmr) presented with the same poster-card
UI that `ShowsView` uses for TV shows. Tapping a group shows exactly the grid
that shows today.

## Design

### 1. Navigation shell

Root becomes a `TabView`; each tab owns its own `NavigationStack`.

| Tab    | SF Symbol                      | Root content              |
| ------ | ------------------------------ | ------------------------- |
| Videos | `play.rectangle.on.rectangle`  | `GroupsView` (4 cards)    |
| TV     | `tv`                           | `ShowsView` (unchanged)   |
| Movies | `film`                         | `moviesGrid` (unchanged)  |

`VideoStore.filter` remains the single source of truth for what is loaded.
Selecting the TV or Movies tab calls `switchFilter(to: "tv" | "movies")`,
exactly as the picker did. The Videos tab root does **not** fetch anything; the
fetch happens on group tap.

The toolbar segmented `Picker` (`filterTabs`) is deleted.

### 2. Videos group screen

New `GroupsView`, laid out like `ShowsView`: adaptive `LazyVGrid`, 2:3 poster,
title, caption. Cards, in order: Children, Adults, Anabel, ASMR.

Tap → `switchFilter(to: group)` and push `Route.group(name:)`, whose destination
is the existing `defaultGrid`. The grid itself is unchanged.

**Card art.** No extra requests. When a group's list loads, persist that group's
newest `preview_url` in `UserDefaults` under `groupPoster:<name>`; the card
renders it through the existing `AuthedImage` + preview disk cache. A group never
visited on this device shows a plain placeholder tile. No episode counts —
counts would require either an extra endpoint or four full list fetches, both
rejected.

**Search.** `.searchable` stays attached to the grid only; the group screen (four
cards) has no search field. The options menu (upload / autoplay / randomize /
downloads / settings) is identical on every tab, as today.

### 3. Server: new `asmr` classification

`db.py`:

```python
CLASSIFICATIONS = ["children", "adults", "anabel", "asmr", "tv", "movies"]
```

Purely additive. The constant is imported everywhere classification is
validated, so the JSON API, the SSR classify form and the iOS classify menu all
accept `asmr` with no further change. No migration: the column is free-text with
validation at the edges, and no existing row changes.

iOS `VideoGridView.classifications`' hardcoded default is corrected to match
(drops `education`, adds `anabel` and `asmr`). `api.classifications()` still
overwrites it at runtime; the default only matters before the first response.

`adults` keeps its plural spelling. No rename.

### 4. Session restoration (full depth)

Restoration today replays `filter`, the navigation `path`, and the grid scroll
anchor. Additions:

- `Route` gains `case group(name: String)`.
- The persisted session gains the selected tab.
- Restoring the Videos tab replays `[.group(name)]` first, then any deeper route
  (`.show`, `.downloads`) on top, so a restored show screen still has a group
  screen beneath it.

Grid scroll anchors keep their `"grid:<filter>"` key unchanged — `filter` still
identifies the group.

### 5. Tests

- PatataTubeKit: group-poster cache write-on-load / read-on-render.
- PatataTubeKit: restoration round-trip including tab selection and `.group`.
- Backend: `asmr` accepted by the classify endpoints; an unknown value is still
  rejected.
- Manual checklist (`ios/README.md`): tab switching, group tap → grid, cold
  launch restore into a group and into a show under a group.

## Out of scope

- Group counts, a `/api/groups` endpoint, or prefetching all four lists.
- Any change to the grid, player, download, or promote paths.
- Cross-group search.
