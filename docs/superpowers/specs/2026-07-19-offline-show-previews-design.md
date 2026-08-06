# Offline previews for ShowsView and EpisodesView

**Date:** 2026-07-19
**Status:** Approved

## Problem

The TV tab renders show posters (`ShowsView`) and episode thumbnails (`EpisodesView`)
through `AuthedImage(path:)` with no `localFileURL`, so both hit the network every
time and show nothing offline. Meanwhile `CacheManager` already stores episode
preview images at download time (`{id}.preview.{ext}`, surfaced via
`cachedPreviewURL(for:)`) — the grid (`VideoCell`) uses them, the TV views don't.

Show posters have a second gap: the poster is `show.posterPath`
(= `episodes.first?.showPreviewUrl`), a show-level 2:3 image distinct from the
episode 16:9 `previewUrl`. Nothing caches it today.

## Design

### 1. CacheManager (PatataTubeKit): show poster cache

Posters are keyed by the **raw `showPreviewUrl` string** — the exact string
`ShowsView` reads via `show.posterPath`. Keying by the raw server value (not the
resolved absolute URL) guarantees lookup and store use the same key.

File naming: `poster.{hash}.{safeExt}` in the existing cache `root`, where
`hash` = first 16 hex chars of SHA-256 of the key (CryptoKit) and `safeExt`
reuses `cachePreview`'s sanitization (1–4 alphabetic chars, else `jpg`).

New public API:

- `cachedShowPosterURL(for key: String) -> URL?` — directory scan on the
  `poster.{hash}.` prefix, mirroring `cachedPreviewURL(for:)`.
- `storeShowPoster(_ data: Data, for key: String)` — writes the poster file;
  used by the lazy backfill path. Ext derived from key's URL path when sane,
  else `jpg`.
- `download(id:versionId:from:preview:showPosterKey:showPoster:bearerToken:)` —
  two new optional parameters. After the video lands, best-effort fetch of the
  poster (same `try?` pattern as the preview). A missing/failed poster never
  fails the download.

### 2. ShowsView: cached poster + lazy backfill

- Add `@EnvironmentObject var model: AppModel`.
- Poster render:
  `AuthedImage(path: show.posterPath, localFileURL: model.cache.cachedShowPosterURL(for: show.posterPath ?? ""))`.
- **Lazy backfill** for episodes downloaded before this feature: `AuthedImage`
  gains an optional `onNetworkLoad: ((Data) -> Void)?` callback, fired only when
  the image was fetched from the network (never for local-file loads). ShowsView
  passes a closure that calls `storeShowPoster` iff at least one episode of the
  show is `.cached` and no poster is cached yet. Old shows self-heal on first
  online view; shows with zero downloaded episodes are not cached (no point —
  their videos aren't offline either).

### 3. EpisodesView: cached episode thumbs

Row thumbnail becomes
`AuthedImage(path: episode.previewUrl, localFileURL: model.cache.cachedPreviewURL(for: episode.id))`.
Episode previews are already stored at download time; this is a lookup-only change.

### 4. VideoGridView.download(): pass poster to the cache

Resolve `target.showPreviewUrl` to an absolute URL using the same logic already
used for `previewUrl` (absolute if `http`-prefixed, else appended to
`credentials.baseURL`), and pass `showPosterKey: target.showPreviewUrl` +
`showPoster: resolvedURL` into `cache.download`.

## Error handling

- Poster fetch at download time: best-effort (`try?`), identical to preview.
- Backfill store: best-effort; failure leaves behavior as today (network-only).
- `AuthedImage` local-file read already falls through to network on failure.

## Testing (PatataTubeKit, `swift test`)

Follow existing `CacheManagerTests` patterns:

- `storeShowPoster` + `cachedShowPosterURL` roundtrip; lookup returns nil when absent.
- Same key always maps to same file (hash stability); differing keys don't collide.
- Extension sanitization: query-string/garbage ext → `jpg`.
- `download` with an unreachable poster URL still caches the video successfully.

No automated UI test target exists; ShowsView/EpisodesView changes verified via
the manual checklist (TV tab offline shows posters + thumbs for downloaded shows).

## Out of scope

- Generic disk cache for all `AuthedImage` loads (considered, rejected: new
  cache layer + eviction policy for marginal gain).
- Poster eviction/cleanup on episode deletion (posters are tiny; deletion flow
  untouched).
- Bulk poster backfill on launch (lazy backfill chosen instead).
