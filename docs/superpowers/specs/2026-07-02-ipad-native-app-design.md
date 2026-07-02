# PatataTube iPad Native App — Design

**Date:** 2026-07-02
**Status:** Approved (design)

## Goal

Replace the web PWA with a native SwiftUI iPad app that consumes the same
backend, reaches feature parity with the web UI, and caches videos locally for
offline playback.

## Context

The existing backend (`main.py`, FastAPI) serves a **server-rendered HTML** page
for the video list — there is no JSON list endpoint. It exposes:

- `POST /upload` (Bearer token) — add video by URL (already JSON in/out).
- `GET /videos/{id}/stream` — byte-range capable mp4 streaming.
- `POST /videos/{id}/move` — reorder up/down (form-encoded, 303 redirect).
- `POST /videos/{id}/classify` — set classification (form-encoded, 303 redirect).
- `GET /` and `/videos` — HTML grid page.

Video data model (`db.py` `videos` table):
`id, url, platform, source_key, title, filename, status, error_msg,
created_at, preview_url, position, classification`.

Classifications: `children, adults, education, entertainment`.

## Decisions

- **Data source:** Add JSON endpoints to the FastAPI backend. HTML views stay
  untouched (web keeps working).
- **Offline caching:** Full-file mp4 download (not HLS segments) — matches how
  the backend stores whole mp4 files.
- **Repo layout:** Xcode project lives in `ios/` inside this repo (monorepo).

## Backend additions (Python)

New JSON endpoints alongside existing HTML routes:

- `GET /api/videos?classification=<opt>` → JSON array of video objects. Each:
  `{ id, title, platform, source_key, preview_url, classification, position,
  status, stream_path }`. Only `status == "done"` videos are playable; include
  status so the app can show pending state. Ordered by `position DESC,
  created_at DESC` (same as `db.get_all_videos`).
- `POST /api/videos/{id}/move` body `{ "direction": "up" | "down" }` → JSON
  `{ ok: bool }`. Wraps `db.move_video`.
- `POST /api/videos/{id}/classify` body `{ "classification": "<one of
  CLASSIFICATIONS>" }` → JSON `{ ok: bool }`. Wraps
  `db.set_video_classification`.
- `POST /upload` — reuse as-is (already JSON, Bearer token).
- `GET /videos/{id}/stream` — reuse as-is (range requests serve both AVPlayer
  streaming and `URLSession` download).

Auth: move/classify JSON endpoints require the same Bearer token check as
`/upload` (`_check_token`). Read endpoint (`GET /api/videos`) is unauthenticated
like the HTML page.

## App architecture (SwiftUI, MVVM)

Layers, each independently testable:

- **`APIClient`** — async/await `URLSession`. Builds requests, decodes JSON,
  attaches Bearer token for write calls. Depends on: base URL + token from
  `KeychainStore`.
- **`VideoStore`** (`ObservableObject`) — holds `[Video]`, current
  classification filter, loading/error state. Calls `APIClient`. Drives views.
- **`CacheManager`** — downloads mp4 via `URLSession` download task to
  `Caches/videos/{id}.mp4`. Tracks per-video state: `.notCached`,
  `.downloading(progress)`, `.cached`. Exposes local file URL when cached.
- **`KeychainStore`** — persists server base URL + upload Bearer token.
- **Views:**
  - `VideoGridView` — grid of preview thumbnails, classification filter tabs,
    per-video download button + reorder/classify actions.
  - `VideoPlayerView` — `AVPlayer` fullscreen playback; exits on video end.
  - `UploadView` — paste URL → `POST /upload`.
  - `SettingsView` — base URL, token, "cache all" action.

## Data flow

1. Launch → `VideoStore.load()` → `GET /api/videos` → render grid.
2. Tap video → if `CacheManager` reports `.cached`, play local file URL; else
   stream from `/videos/{id}/stream` via `AVPlayer` and optionally kick a
   background download.
3. Classify / reorder → optimistic UI update → POST → on failure, revert and
   refetch.
4. Upload → `POST /upload` → poll/refetch list (backend downloads async).

## Caching detail

- Store at `Caches/videos/{id}.mp4` (system-evictable Caches dir; acceptable
  since source of truth is the server).
- Manual per-video "download" button; "cache all" in Settings.
- Playback prefers local file when present.
- LRU/size-cap eviction: out of scope for v1 (YAGNI). Rely on system Caches
  eviction.

## Feature parity checklist (vs web)

- [ ] Grid with preview thumbnails
- [ ] Classification filter (children/adults/education/entertainment)
- [ ] Fullscreen playback
- [ ] Exit fullscreen when video ends
- [ ] Reorder up/down
- [ ] Set classification
- [ ] Upload by URL (Bearer token)
- [ ] Offline playback of cached videos (new capability beyond web)

## Testing

- Unit: `APIClient` JSON decode (fixtures), `CacheManager` path + state
  transitions, `VideoStore` filter logic. Swift Testing framework.
- Manual: `AVPlayer` fullscreen/exit-on-end, download progress, offline play.

## Stack

SwiftUI, iPadOS 17+, AVKit/AVFoundation, async/await `URLSession`,
Swift Testing. Xcode project in `ios/`.

## Out of scope (v1)

- LRU/size-capped cache eviction.
- Push/live updates of the list (manual refresh only).
- iPhone-specific layout tuning (iPad-first).
