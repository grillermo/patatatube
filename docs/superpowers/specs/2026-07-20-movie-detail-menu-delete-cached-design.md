# Movie Detail: Three-Dot Menu with Delete Cached

**Date:** 2026-07-20
**Status:** Approved

## Goal

Add a three-dot menu to the top-right of the movie detail page (`MovieDetailView`)
with a single "Delete cached" action that removes every cached MP4 for the movie.
The existing download button (arrow / progress ring / checkmark in the content
HStack) is untouched.

## Scope

- **In:** toolbar menu on `MovieDetailView`, "Delete cached" item, new
  `CacheManager` helpers.
- **Out:** moving the download button (explicitly dropped), confirmation
  dialogs, grid-cell changes, any backend change.

## Design

### 1. CacheManager (PatataTubeKit)

Two new public methods:

- `hasAnyCached(id: Int) -> Bool`
  Scans the cache root for video files belonging to `id`: a file named
  `"\(id).mp4"` or one matching `"\(id).v<n>.mp4"` (prefix `"\(id).v"` +
  suffix `".mp4"`). This pattern cannot match `"\(id).preview.<ext>"`.
- `removeAllCached(id: Int)`
  Deletes all files matched by the rule above, plus resume-data files for the
  video: `"\(id).resume"` and any `"\(id):<n>.resume"` (prefix `"\(id):"`,
  suffix `".resume"`). Preview images and show posters are kept — they are
  small and still useful for offline grid display.

Both are directory scans with `FileManager`, best-effort (`try?`) like the
existing `removeCached`.

### 2. MovieDetailView (iOS app)

- Add `.toolbar { ToolbarItem(placement: .topBarTrailing) { Menu { … } } }`
  with label `Image(systemName: "ellipsis.circle")`.
- Menu contains one item:
  - `Button(role: .destructive)` labeled "Delete cached" with `trash` icon.
  - `.disabled(!model.cache.hasAnyCached(id: currentVideo.id))` — always
    visible, grayed out when nothing is cached.
- Tap action:
  1. `model.cache.removeAllCached(id: currentVideo.id)`
  2. Reset local download-button state so the UI flips immediately instead of
     waiting for the 500 ms cache poll:
     `activeDownloadID = nil; downloadPhase = .idle;
     observedCacheState = .notCached; progress = 0`

### Edge cases

- **Old version cached while a new version downloads:** item is enabled (a
  cached file exists). Delete removes on-disk files only; the in-flight
  `URLSession` download is not cancelled and writes its file when it
  finishes. Accepted behavior.
- **Nothing cached:** item disabled; deleting is impossible, no empty-menu
  state to handle.
- **No confirmation dialog:** cached files are re-downloadable; the
  destructive (red) role is sufficient signal.

## Testing

- `cd ios/PatataTubeKit && swift build` must pass (compile check for the new
  CacheManager methods; no iOS test target exists).
- Manual verification per `ios/README.md` checklist: menu appears, item
  disabled when nothing cached, enabled after download, delete flips the
  download button back to the arrow, movie re-downloads fine afterward.
