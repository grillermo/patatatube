# Movie Portrait Grid — Design

Date: 2026-07-19
Status: Approved (pending spec review)

## Goal

Display movies in the iOS video grid the same way TV shows are displayed: portrait 2:3 poster cards. Tapping a movie opens a detail page (Netflix/Plex style) instead of playing immediately.

## Scope

- Applies **only when the "movies" filter tab is active** in `VideoGridView`. The "all" tab keeps the existing 16:9 `VideoCell` for every video, including movies (which stay letterboxed there via the existing `isPoster` logic).
- iOS app only. No backend or web (SSR) changes.

## Components

### `MovieCell.swift` (new, `ios/PatataTube/Sources/`)

A fork of `VideoCell` (per explicit decision: fork, do not parametrize `VideoCell`). Differences from the parent:

- Artwork aspect ratio is **2:3 portrait, `scaledToFill`** (Plex movie posters are natively 2:3, so no letterboxing needed), instead of 16:9.
- The poster area is a **`NavigationLink(value: video)`** (navigates to the detail page) instead of a play button. The controls row sits outside the link, so its buttons keep their own tap targets.
- Everything else is retained from `VideoCell`: the controls row under the poster (download button with idle → downloading-progress-ring → done checkmark states, including the `downloadPhase`/`observedCacheState` polling machinery), version picker when `versions.count > 1`, the ellipsis menu (Info, Move up/down, classify, Delete), the delete confirmation dialog, and the `VideoInfoView` sheet.

`VideoCell` itself is untouched.

### `MovieDetailView.swift` (new, `ios/PatataTube/Sources/`)

Pushed detail page for a single movie:

- Large poster (`AuthedImage`, 2:3), title, summary.
- **Play** button — invokes the same play path `VideoGridView` uses (`ensureReady` for library videos that aren't `done`, then fullscreen player). The existing "Preparing…" overlay is attached to the `NavigationStack`, so it already covers pushed views.
- **Download** button with progress — same visual states as the cell's download button, driven by the same closures/cache-state polling.
- **Version picker** when the movie has more than one version.

Receives its closures (`onPlay`, `onDownload`, `onCancel`, `onChooseVersion`) from `VideoGridView`, same wiring pattern as `VideoCell`.

### `VideoGridView.swift` (modified)

- When `store.filter == "movies"`, render the `LazyVGrid` with `MovieCell` instead of `VideoCell`. Same adaptive columns / `cellSize` sizing initially; tune later if portrait cells look off.
- Add `.navigationDestination(for: Video.self) { MovieDetailView(...) }`.

### `Video` (PatataTubeKit, modified)

`Video` is `Codable, Equatable, Sendable, Identifiable` but **not `Hashable`**, which `NavigationLink(value:)` requires. Add `Hashable` conformance to `Video` and its nested value types (`VideoVersion`, `SubtitleTrack`) — synthesized, no custom implementation.

## Data flow

No new data. Movies already carry `previewUrl` (tall Plex poster), `summary`, `versions`. Search filtering (`filteredVideos`) applies unchanged before the grid branch.

## Error handling

Unchanged paths: play errors surface through `store.errorText` banner; download failures set `store.errorText` and reset the button to idle (existing `onDownload() -> Bool` contract).

## Testing

No automated iOS test target exists. Manual checklist additions (ios/README.md):

- Movies tab shows portrait 2:3 cards; posters fill without letterbox bars.
- Tap movie card → detail page with poster, title, summary.
- Play from detail works for unconverted library movie (Preparing… overlay shows on pushed view).
- Download from detail and from the cell both show progress ring and end in checkmark.
- "all" tab still shows movies as 16:9 letterboxed cells.
- `cd ios/PatataTubeKit && swift build` passes (Hashable change).
