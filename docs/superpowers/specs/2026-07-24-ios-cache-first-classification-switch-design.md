# Cache-first classification switch (iOS)

## Problem

Tapping a classification tab in the iOS grid (`VideoGridView`) does:

```swift
store.filter = value
Task { await store.load() }
```

`VideoStore.load()` sets `isLoading`, hits the API, and only *then* replaces
`videos`. During the network round-trip the grid keeps rendering the **previous**
classification's videos, so switching tabs shows the wrong content until the API
returns, then snaps to the new list. There is no loading UI today.

`bootLoad()` already does the right thing at startup (show cached list instantly,
then refresh), but that path isn't used on tab switch.

## Goal

Tab tap → show the new classification instantly from its per-classification disk
cache → refresh from API → replace. When there is no cache, show **skeleton
placeholder cells** (never an empty grid, never the old classification's videos)
until the API returns.

## Design

### 1. `VideoStore.switchFilter(to:)`

New `@MainActor` method mirroring `bootLoad()`, used by the tabs:

```swift
public func switchFilter(to value: String?) async {
    filter = value
    let cached = await loadCache()   // reads the NEW filter's per-classification cache
    videos = cached ?? []            // instant swap; [] triggers skeletons via isLoading
    await load()                     // API refresh, then replace + persist
}
```

- `loadCache()` already keys off `filter` and decodes off the main actor, so it
  must run *after* `filter` is set (it is).
- Cache hit → correct classification's videos appear immediately, API replaces.
- Cache miss → `videos = []`; because `load()` sets `isLoading = true`, the grid
  renders skeletons until the API returns.
- `load()` is unchanged: still persists the cache and still swallows cancellation.

`VideoListCache` is already per-classification (`fileURL` = `<classification|all>.json`),
so no cache-layer changes are needed.

### 2. Tab wiring (`VideoGridView.tab`)

Replace the two-statement body with a single call:

```swift
Button(title) {
    Task { await store.switchFilter(to: value) }
}
```

### 3. Skeleton grid

No loading UI exists today. Add skeleton placeholder cells rendered when
`store.isLoading && filteredVideos.isEmpty`. This condition guarantees the grid
is **never** empty: it shows either skeletons (loading) or real videos.

Skeleton geometry matches each tab's real cell frame (confirmed against the
on-disk preview cache — Plex posters are 2:3; the default video cell forces 16:9):

| Tab (`store.filter`) | Grid columns | Skeleton cell aspect |
|----------------------|--------------|----------------------|
| `tv` (ShowsView)     | adaptive min 160 | 2:3 poster + 2 short text bars below |
| `movies` (MovieCell) | adaptive min `cellSize` (220) | 2:3 poster |
| default (VideoCell)  | adaptive min `cellSize` (220) | 16:9 |

Each skeleton cell: a `RoundedRectangle` fill with a subtle pulsing/shimmer
(`.redacted(reason: .placeholder)` or an opacity animation), corner radius
matching the real cells. Render ~8 cells (enough to fill the first screen) in the
same `LazyVGrid`/columns as the real content so the layout doesn't jump when real
videos replace them.

Implementation: a small `SkeletonGrid` view parameterized by `aspectRatio`,
`columns`, and whether to draw the two text bars (tv). Insert one branch per tab
that swaps skeleton ↔ real grid on `isLoading && filteredVideos.isEmpty`.

### 4. Test

`PatataTubeKit` test (`VideoStore`):

- Stub `VideoListCaching` returning a known list for a given classification.
- Stub `VideoAPI` whose `videos(classification:)` suspends on a signal.
- Call `switchFilter(to:)`; before releasing the API, assert `store.videos`
  equals the cached list (cache-hit case) or is empty (cache-miss case).
- Release the API; assert `store.videos` equals the API result and the cache was
  saved.

## Non-goals

- No change to `load()`, `bootLoad()`, cache format, or the API.
- No skeleton for search-empty states (search filters an already-loaded list;
  `isLoading` is false there, so real "no results" still shows nothing).
- No change to the SSR web page — iOS only.

## Files

- `ios/PatataTubeKit/Sources/PatataTubeKit/VideoStore.swift` — add `switchFilter`.
- `ios/PatataTube/Sources/VideoGridView.swift` — tab wiring + skeleton branches.
- New `SkeletonGrid` view (in `VideoGridView.swift` or its own file).
- `ios/PatataTubeKit/Tests/...` — `switchFilter` test.
