# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

PatataTube — a self-hosted "watch later" for videos. A FastAPI backend downloads Twitter/X and YouTube videos, re-encodes them to iOS-compatible MP4, and serves them via both a server-rendered HTML page (a PWA) and a JSON API. A native SwiftUI iPad app (`ios/`) consumes the JSON API.

## Commands

### Backend (Python, repo root)

```bash
./serve                              # run dev server on :3050 with reload (uses python_env/ venv)
python -m pytest tests/              # run all tests
python -m pytest tests/test_api.py   # one file
python -m pytest tests/test_api.py::test_upload_success   # one test
```

- No `pytest.ini`/`pyproject.toml`. Async tests are marked individually with `@pytest.mark.asyncio` (no global asyncio mode), so new async tests must carry that marker.
- The venv is `python_env/` (gitignored, not checked in). `./serve` hardcodes `python3.13 python_env/bin/uvicorn`. Create it and `pip install -r requirements.txt` before first run.
- `.env` holds `UPLOAD_TOKEN` (see `.env.example`). Loaded via `python-dotenv`.

### iOS (`ios/`)

```bash
cd ios/PatataTube && xcodegen generate && open PatataTube.xcodeproj   # project.pbxproj is generated from project.yml
cd ios/PatataTubeKit && swift build                                   # build the logic package standalone
```

See `ios/README.md` for the full manual test checklist (no automated iOS test target exists yet).

## Architecture

### Request → download → serve flow

1. `POST /upload` (or `/api/videos` paths) — `main.py` classifies the URL (`_classify_url`) into `twitter` or `youtube`, inserts a `queued` row via `db.add_video`, and schedules `downloader.download_video` as a FastAPI `BackgroundTask`.
2. `downloader.py` runs the download off the event loop: **pybalt** for Twitter/X, **yt-dlp** (`--cookies-from-browser`) for YouTube. Every file is passed through `_normalize_media_for_ios` — an ffmpeg step that guarantees H.264/AAC + `+faststart` so iOS can stream it. Output lands at `videos/{id}.mp4`.
3. Status transitions queued → downloading → done. **Failures don't get an `error` status** — `db.update_video(status="error")` and the download exception handler both *delete the row* instead. Don't rely on error rows existing.
4. `GET /videos/{id}/stream` serves the MP4 with HTTP Range support (206 partial content), hand-rolled in `_parse_byte_range` / `_iter_file_range`, gated by an asyncio semaphore (`VIDEO_STREAM_LIMIT`).

### Layering — the SSR page and the JSON API share logic, don't duplicate it

- `db.py` — the only SQLite layer. Single `videos` table. `init_db()` is an **idempotent migration runner**: it does `CREATE TABLE IF NOT EXISTS`, then additive `ALTER TABLE` guards for each newer column, then backfills (`_backfill_positions`, `_backfill_youtube_preview_urls`) and cleanup. Schema changes go here as new idempotent guards, not a migrations framework.
- `services.py` — mutation logic (`apply_move`, `apply_classification`) called by **both** the HTML form endpoints and the JSON API endpoints in `main.py`. Put shared write logic here.
- `views/serializers.py` — `serialize_video` is the canonical video-to-dict presenter for the JSON API. Keep the API shape here.
- `views/render.py` + `views/templates/*.html` — the server-rendered HTML page + PWA splash images.

`CLASSIFICATIONS` (in `db.py`: children/adults/education/entertainment) is the source of truth for video categories, imported everywhere that validates a classification.

### Auth

Write endpoints call `_check_token`: `Authorization: Bearer <UPLOAD_TOKEN>` compared with `secrets.compare_digest`. If `UPLOAD_TOKEN` is unset the server returns 503 (upload disabled). The SSR form endpoints (`/videos/{id}/move`, `/videos/{id}/classify`) are **not** token-gated; the `/api/*` equivalents are.

### iOS

- `ios/PatataTubeKit/` — a local SwiftPM package holding all logic (`APIClient`, `CacheManager`, `VideoStore`, `Video`, `CredentialStore`). This is the testable core; build/isolate bugs here with `swift build`.
- `ios/PatataTube/` — the SwiftUI app shell (`Sources/*.swift`), an XcodeGen target. `Video` decodes the server's snake_case JSON; `CacheManager` downloads MP4s for offline playback; `VideoStore` does optimistic classify/move/upload against `APIClient`.

### Plex library (library rows)

- `plex.py` fetches metadata from the local Plex server (`PLEX_URL`/`PLEX_TOKEN`); its JSON contains raw control characters, so it parses with `json.loads(text, strict=False)`.
- `library.py` owns scanning (`scan_library`) and on-demand ffmpeg conversion (`convert_library_video`): passthrough / remux / transcode per the iPad codec policy (`plan_conversion`), converted file written as a sibling `{name}.mp4`.
- Library rows live in the same `videos` table with `source='library'`, statuses `unconverted → converting → done`; failures set `error_msg` and revert to `unconverted` (never row-delete). Deletes tombstone via `deleted_at` and never touch `source_path`.
- Stream endpoint is token-gated (Bearer or `?token=`); library previews proxy Plex thumbs at `/videos/{id}/preview` with a disk cache in `data/previews/`.

## Conventions

- ffmpeg/ffprobe/yt-dlp binaries and behavior are all env-overridable (`FFMPEG_BIN`, `FFPROBE_BIN`, `YTDLP_BIN`, `YTDLP_BROWSER`, `YTDLP_FORMAT`). Downloader code should keep reading these rather than hardcoding paths.
- `ALLOWED_HOSTS` env drives `TrustedHostMiddleware`; the default includes the production hosts plus `testserver` (FastAPI TestClient's host).
- Tests reload `db` then `main` after setting `DB_PATH`/`UPLOAD_TOKEN` env vars (see the `client` fixture in `tests/test_api.py`) — because both modules read env at import time. Follow that pattern for new integration tests.
