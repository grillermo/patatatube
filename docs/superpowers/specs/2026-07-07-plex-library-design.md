# Plex Library Integration — Design

**Date:** 2026-07-07
**Scope:** Serve the local media library at `/Volumes/Media/media` (movies + TV) through PatataTube, iOS app first. PWA UI for the library is explicitly out of scope for this project.

## Goal

The iOS app gets a refresh button. Pressing it makes the server scan the media library (via the local Plex server's metadata), and the app shows movies as a grid and TV shows grouped show → season → episodes. Files are converted to iOS-compatible MP4 **only on first play or download**, never in bulk.

## Context

- Library: `/Volumes/Media/media/movies` (103 folders) and `/Volumes/Media/media/tv` (83 show folders); 1142 video files: 578 mkv, 560 mp4, 4 avi/m4v. 594 GB; the Media volume has ~877 GB free.
- A Plex Media Server runs on the same machine (`http://localhost:32400`) with sections pointing at exactly these two directories. Its API provides, per item: title, show/season/episode numbers, summary, thumbnail, duration, codecs, and the absolute file path — which joins directly to files on disk.
- Most mkv files are already H.264/HEVC + AAC/EAC3, which iOS plays fine **in an mp4 container** — so most conversions are container remuxes (`-c copy`, seconds), not re-encodes.
- PatataTube today: `videos` table in SQLite, downloads re-encoded to `videos/{id}.mp4`, JSON API consumed by the SwiftUI iPad app, HTTP-Range streaming endpoint.

## Approach (decided)

Extend the existing `videos` table rather than adding parallel library tables or proxying Plex live. Library files become ordinary video rows with a few extra columns. This reuses the stream endpoint, serializer, status flow, auth, and delete path. (Alternatives considered: separate `/api/library/*` tables — duplicates stream/status/serializer logic; live Plex proxy without a DB — converted-state and tombstones need persistence anyway.)

## Server design

### Schema (new idempotent guards in `db.init_db`, existing pattern)

| Column | Type | Meaning |
|---|---|---|
| `source` | TEXT default `'download'` | `'library'` for scanned rows |
| `source_path` | TEXT | Absolute path of the original file; unique upsert key for library rows |
| `converted_path` | TEXT | Sibling MP4 produced by conversion, NULL until converted |
| `show_title` | TEXT | TV only |
| `season` | INTEGER | TV only (Plex `parentIndex`) |
| `episode` | INTEGER | TV only (Plex `index`) |
| `summary` | TEXT | Plex synopsis (movies and episodes) |
| `plex_rating_key` | TEXT | Plex id of the item, for thumb proxying |
| `show_rating_key` | TEXT | Plex id of the show, for show-poster proxying (TV only) |
| `deleted_at` | TEXT | Tombstone timestamp, NULL = alive |

`CLASSIFICATIONS` becomes `["children", "adults", "education", "tv", "movies"]` — `entertainment` removed (no existing rows use it). Scanned rows get classification `movies` or `tv` from their Plex section.

### Statuses

Library rows: `unconverted` → `converting` → `done`. On conversion failure the row returns to `unconverted` with `error_msg` set. The existing delete-row-on-error rule applies **only** to `source='download'` rows.

### Endpoints

- **`POST /api/library/scan`** (token-gated) — Fetches Plex sections (movies, TV) via `PLEX_URL` (default `http://localhost:32400`) + `PLEX_TOKEN` (env, required for scan). Upserts rows keyed on `source_path`; verifies each file exists on disk; skips tombstoned paths; skips any file path matching an existing row's `converted_path` (self-exclusion so our own outputs are never indexed). Metadata only — no ffmpeg. Synchronous, returns `{"added": n, "updated": n, "skipped": n}` in seconds. The client then re-fetches `/api/videos`.
- **`POST /api/videos/{id}/prepare`** (token-gated, idempotent) — If `done`, returns 200. Otherwise ffprobe the source and follow the conversion pipeline below: passthrough → mark `done` with no copy (most of the 560 mp4s play instantly); else set `converting`, run the remux/transcode as a BackgroundTask and return 202. Concurrent prepares for the same row are a no-op while `converting`.
- **`GET /api/videos/{id}`** (token-gated) — single-video JSON, used by the app to poll during conversion.
- **`GET /videos/{id}/preview`** (token-gated) — proxies the Plex thumbnail for the row's `plex_rating_key`, caching the image on disk; `?kind=show` proxies the show poster via `show_rating_key`. The Plex token never reaches the client. Library previews come **only** from Plex — no ffmpeg thumbnailing.

- **Stream endpoint** (`GET /videos/{id}/stream`) — now token-gated (previously open). Resolves the file per row: download rows → `videos/{id}.mp4` as today; library rows → `converted_path` if set, else `source_path` (compatible-mp4 passthrough). Library row not `done` → 409.

All new endpoints, plus the stream endpoint, require `Authorization: Bearer <UPLOAD_TOKEN>` via the existing `_check_token` helper (same env token as uploads; no new auth mechanism). Because HTML `<video>` tags cannot send request headers, the stream endpoint also accepts the token as a `?token=` query parameter so the existing PWA page keeps playing videos (the SSR template appends it).

### Conversion pipeline (ffmpeg)

Conversion reuses the downloader's ffmpeg machinery (`_probe_media`, `_normalize_media_for_ios`), generalized for the library case. Binaries stay env-overridable (`FFMPEG_BIN`, `FFPROBE_BIN`).

**Probe first.** `ffprobe -show_streams -show_format -print_format json` on the source decides one of three outcomes:

1. **Passthrough (no ffmpeg run):** container is mp4/mov **and** video is h264, or hevc tagged `hvc1`, **and** width ≤ 2266 px, **and** audio is aac/ac3/eac3 (or absent) → mark `done`, stream the original directly. No copy written.
2. **Remux (`-c copy`, seconds, no quality loss):** codecs are iOS-playable but the container is not (mkv/avi/m4v), or an incompatible stream needs swapping. Expected for most of the 578 mkv files.
3. **Transcode:** only streams that fail the codec policy below are re-encoded; compliant streams are still copied.

**Command shape** (as in the downloader today):

```
ffmpeg -hide_banner -loglevel error -y -i <source>
  -map 0:v:0 -map 0:a:0? -sn -dn
  <video args> <audio args>
  -movflags +faststart <sibling>.mp4
```

**Video policy** — extends the downloader's current h264-only copy rule. Target device is the iPad mini (6th gen): 2266×1488 Liquid Retina, A15. Resolution above the panel's long edge is wasted bits, so output is capped at **2266 px wide**:
- width ≤ 2266 and `h264` → `-c:v copy -tag:v avc1`
- width ≤ 2266 and `hevc` (incl. 10-bit `yuv420p10le`) → `-c:v copy -tag:v hvc1` — **new**; the A15 plays HEVC Main10 natively, so no re-encode
- width > 2266 (4K/2160p sources) or any other codec → `-c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -profile:v high -tag:v avc1 -vf "scale='min(2266,iw)':-2"` (downscale to fit the panel, never upscale; `-2` keeps even height)

1080p content (the bulk of the library) is untouched by the cap — it copies bit-exact.

**Audio policy** — extends the downloader's current aac-stereo-only copy rule:
- `aac`, `ac3`, `eac3` → `-c:a copy` (iOS plays AC3/EAC3 multichannel natively) — **new**
- anything else (dts, opus, vorbis, flac, …) → `-c:a aac -b:a 128k -ac 2`
- no audio stream → `-an`

Subtitle and data streams are dropped (`-sn -dn`), as today. Only the first video and first audio stream are mapped. ffmpeg writes to a temp file first and the result is moved to the sibling `.mp4` path only on success, so a killed/failed conversion never leaves a half-written file the scanner or Plex could pick up.

The downloader path keeps its existing (stricter) policy for now; the codec policy tables above apply to library conversions. Implementation should factor `_video_codec_args` / `_audio_codec_args` to take a policy rather than duplicating the ffmpeg invocation.

### Conversion output naming

Converted files are written **next to the original, same name, `.mp4` extension** — no new directories (e.g. `…/The.Bear.S01E01.…-CAKES.mkv` → `…/The.Bear.S01E01.…-CAKES.mp4`). Edge case: if the source is itself an incompatible `.mp4` (target name would collide), use `{stem}.ios.mp4`. Known consequence: Plex will index the sibling as a second "version" of the item — harmless, accepted.

### Delete semantics

Deleting a library video sets `deleted_at`, removes `converted_path` if present, and **never touches `source_path`** (the Plex library stays intact). Tombstoned rows are excluded from listings and never re-added by scans. Download rows keep their current delete behavior.

### Configuration

`PLEX_URL` (default `http://localhost:32400`), `PLEX_TOKEN` (required for scan; scan returns 503 without it, mirroring the `UPLOAD_TOKEN` pattern). Existing ffmpeg env overrides apply unchanged.

## iOS design

- **Model** — `Video` gains optional `source`, `showTitle`, `season`, `episode`, `summary`, `showPreviewUrl` (snake_case decode; all optional so old server responses still decode).
- **Refresh button** — toolbar button on the main view: `POST /api/library/scan`, spinner while running, then the existing list reload.
- **Movies** — reuse the existing grid (`VideoGridView` / `VideoCell`) under the `movies` classification. No new UI.
- **TV** — new `ShowsView`: grid of shows built client-side by grouping videos on `showTitle`; poster from `show_preview_url`. Tap → `EpisodesView`: one section per season, rows showing `E{n} — title`, thumbnail, one-line summary.
- **Preview loading** — preview endpoints are token-gated, so thumbnails cannot be loaded with plain `AsyncImage(url:)`; image requests must attach the `Authorization: Bearer` header (fetch via `URLSession` in `APIClient`, as other authenticated calls do).
- **Playback auth** — the stream endpoint is now token-gated: `AVURLAsset` must be created with the `AVURLAssetHTTPHeaderFieldsKey` option carrying the `Authorization: Bearer` header, and `CacheManager` downloads must attach the same header.
- **Play / download flow** — `status == done` → play/cache exactly as today. Otherwise call `prepare`, poll `GET /api/videos/{id}` every 2 s with a "Preparing…" overlay, then play or hand off to `CacheManager`. The same gate applies before offline download.
- **Errors** — `error_msg` present → alert with a retry action (retry = call `prepare` again).

## Error handling

- Plex unreachable / no token → scan returns 502/503 with a message; app shows an alert.
- Source file missing at prepare time → `error_msg` set, row stays `unconverted`.
- Conversion failure → row back to `unconverted` + `error_msg` (row never deleted).

## Testing

- **pytest** (existing `client` fixture pattern — reload `db` then `main` after env setup):
  - scan: upsert, tombstone skipping, converted-file self-exclusion, missing-file handling (Plex fetcher monkeypatched).
  - prepare: state machine incl. compatible-mp4 passthrough (ffprobe mocked), idempotency, failure → `unconverted` + `error_msg`.
  - codec policy: probe result → expected ffmpeg args (h264 copy/avc1, hevc copy/hvc1, other → libx264; aac/ac3/eac3 copy, other → aac stereo; >2266 px wide → downscale re-encode; passthrough vs remux vs transcode decision).
  - stream: path resolution for download vs library rows; 409 for non-`done` library rows; 401 without token, accepted via Bearer header and via `?token=` query parameter.
  - delete: tombstone semantics, original never removed.
- **iOS**: `swift build` on PatataTubeKit; manual test checklist additions in `ios/README.md` (refresh, shows→episodes navigation, preparing overlay, offline caching of a library episode).
