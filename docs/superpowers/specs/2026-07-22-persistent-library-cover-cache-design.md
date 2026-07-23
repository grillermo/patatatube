# Persistent Library Cover Cache Design

## Goal

Store every successfully displayed library movie and TV-show cover on the
device, regardless of whether its video has been downloaded. Returning to a
previously viewed cover must not require another image request or show a loader.

## Design

`AuthedImage` keeps its current lookup order: process-memory cache, supplied
local file, then network. When a network request succeeds, the owning view
persists the returned bytes to `CacheManager`; the memory cache is still filled
for the current session.

`CacheManager` owns a small image-file API separate from MP4 download state:

- Movie covers are stored and looked up by `Video.id` as
  `<id>.preview.<extension>`.
- TV-show covers are stored and looked up by a deterministic key derived from
  the show group. This lets every episode in the same show resolve the same
  cover file.
- Cache files remain when an MP4 cache is deleted, matching the existing
  policy that small images are useful offline.

Movie cells and movie detail views pass their cached cover file to
`AuthedImage`. `ShowsView` does the same for show posters. Each view supplies
an `onNetworkLoad` callback that writes the image only when no corresponding
disk file already exists, so repeated lazy-view tasks cannot rewrite it.

## Error Handling

Disk writes are best-effort. A failed image request leaves the existing loader
and can be retried when SwiftUI recreates the view. A failed cache write does
not prevent the successfully fetched image from being shown in the current
session.

## Tests

Add `CacheManager` tests that verify movie-cover storage and lookup by video ID
and show-cover storage and lookup by stable show key. Add UI-focused tests only
where the existing test harness can observe the callback wiring; production
behavior remains exercised by the shared cache manager tests.
