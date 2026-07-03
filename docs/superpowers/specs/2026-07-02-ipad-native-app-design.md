# PatataTube iPad Native App — Design

**Date:** 2026-07-02
**Status:** Server side DONE (Plan 1 merged to main). iOS app (Plan 2) NOT STARTED.

## Progress

### Server JSON API — COMPLETE (2026-07-02)

All committed to `main`. New files:
- `views/serializers.py` — `serialize_video(video: dict) -> dict` presenter
- `services.py` — `apply_move(video_id, direction)`, `apply_classification(video_id, classification)`
- `tests/test_serializers.py`, `tests/test_services.py`

SSR form endpoints now call `services.py`. JSON endpoints added to `main.py`:
- `GET /api/classifications` → `{"classifications": [...]}`
- `GET /api/videos?classification=` → list of serialized video dicts
- `POST /api/videos/{id}/move` (Bearer) → `{"ok": bool}`
- `POST /api/videos/{id}/classify` (Bearer) → `{"ok": bool}`

61 tests pass. PWA untouched.

### iOS SwiftUI App — COMPLETE (2026-07-02)

Two-part project: pure-Swift SPM package `PatataTubeKit` (models, APIClient, CredentialStore, CacheManager, VideoStore, Swift Testing) + thin Xcode app `PatataTube` (SwiftUI views, AVKit playback, app wiring).

## Goal

Add a native SwiftUI iPad app **alongside** the existing web PWA (the PWA is
NOT replaced — both remain first-class clients). The app consumes a new JSON
API, reaches feature parity with the web UI, and caches videos locally for
offline playback. The JSON API shares as much server code as possible with the
existing server-rendered (SSR) HTML app.

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

- **PWA stays:** The web SSR app is not replaced. The native app is an
  additional client. Both consume the same underlying data/query layer.
- **Data source:** Add JSON endpoints to the FastAPI backend. HTML views keep
  working; JSON and HTML share server code (see "Shared server code").
- **Offline caching:** Full-file mp4 download (not HLS segments) — matches how
  the backend stores whole mp4 files.
- **Repo layout:** Xcode project lives in `ios/` inside this repo (monorepo).

## Shared server code

The SSR page and the JSON API must share logic, not duplicate it. Both already
read from `db.get_all_videos(classification)`; the shared pieces:

- **`serialize_video(video: dict) -> dict`** — canonical presenter producing the
  JSON shape (`id, url, title, platform, source_key, preview_url,
  classification, position, status, stream_path`). Extract to a shared module
  (e.g. `views/serializers.py`). The JSON endpoint returns
  `[serialize_video(v) for v in videos]`; `build_videos_page` consumes the same
  serialized objects instead of poking raw DB dicts, so both stay consistent.
- **Shared move/classify core** — extract the body of the existing form
  endpoints (`move_video_endpoint`, `classify_video_endpoint`) into plain
  functions that take `(video_id, direction)` / `(video_id, classification)`
  and call `db`. The HTML form endpoints (303 redirect) and the JSON endpoints
  both call these — no duplicated validation.
- **`CLASSIFICATIONS`** — already the single source of truth in `db.py`; reused
  by SSR, JSON, and validation. No change.
- **Stream endpoint** — `GET /videos/{id}/stream` already shared by web `<video>`
  and native `AVPlayer`/download; unchanged.

## Backend additions (Python)

New JSON endpoints alongside existing HTML routes:

- `GET /api/videos?classification=<opt>` → JSON array of `serialize_video(v)`
  objects (see "Shared server code"). Includes `status` so the app can show
  pending state. Ordered by `position DESC, created_at DESC` (same as
  `db.get_all_videos`). Also returns available `CLASSIFICATIONS` (either as a
  sibling `GET /api/classifications` or an envelope) so the app's filter tabs
  stay in sync with the server.
- `POST /api/videos/{id}/move` body `{ "direction": "up" | "down" }` → JSON
  `{ ok: bool }`. Calls the shared move core.
- `POST /api/videos/{id}/classify` body `{ "classification": "<one of
  CLASSIFICATIONS>" }` → JSON `{ ok: bool }`. Calls the shared classify core.
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

## Server test additions

- `serialize_video` output shape (fixture-based).
- SSR page still renders unchanged after refactor (existing template test /
  smoke test of `build_videos_page`).
- JSON endpoints: `GET /api/videos` shape + classification filter; move/classify
  JSON endpoints require token and mutate via shared core.

## Feature parity checklist (vs web)

- [x] Grid with preview thumbnails
- [x] Classification filter (children/adults/education/entertainment)
- [x] Fullscreen playback
- [x] Exit fullscreen when video ends
- [x] Reorder up/down
- [x] Set classification
- [x] Upload by URL (Bearer token)
- [x] Offline playback of cached videos (new capability beyond web)

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
