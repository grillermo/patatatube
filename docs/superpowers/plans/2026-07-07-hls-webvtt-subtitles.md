# HLS WebVTT Subtitles Implementation Plan

> **For:** PatataTube iOS subtitle support without video re-encoding  
> **Goal:** Serve HLS VOD playlists with WebVTT sidecar subtitles and have the iOS app prefer native AVPlayer subtitle playback when available.  
> **Stack:** FastAPI, SQLite, ffmpeg/ffprobe, HLS, WebVTT, SwiftUI, AVPlayer/AVKit  
> **Current behavior:** The backend serves direct MP4 files from `/videos/{id}/stream`; the iOS app plays `Video.streamPath` with `AVPlayer` in `VideoPlayerView`; cached playback stores raw MP4 files as `{id}.mp4`.

## Scope & Terminology (read first)

The `videos` table holds two row kinds with different source resolution and different status semantics. HLS subtitles apply almost entirely to **library** rows; wire both, but do not conflate them.

- **Download rows** (`source` in `twitter`/`youtube`): file at `VIDEOS_DIR / video["filename"]` (e.g. `videos/7.mp4`), readiness is top-level `video["status"] == "done"`. **No subtitle sidecars ever exist** — nothing writes `.srt`/`.vtt`/`.sub` siblings. `discover_subtitles` returns `[]` for these. HLS is still generatable (video-only, no `SUBTITLES` group) but yields no subtitle benefit; treat HLS as optional for download rows.
- **Library rows** (`source == "library"`): source resolved through a **version**, exactly as `/videos/{id}/stream` does (`main.py:372-389`): pick the version via `db.get_video_version(video_id, version_id)`, require `version["status"] == "done"`, use `version["converted_path"] or version["source_path"]`. Sidecar subtitles live next to `source_path`. Readiness is the **version** status, not top-level `video["status"]`.

There is **no `"completed"` status in this codebase.** Statuses are `queued → downloading → done` (downloads) and `unconverted → converting → done` (library/versions). Everywhere below, "ready" means the resolved source's status is `"done"`.

## Design Decisions

1. Keep `/videos/{id}/stream` unchanged as the direct MP4 fallback.
2. Add a parallel HLS path under `/videos/{id}/hls/...`.
3. Prefer video/audio **stream copy** into fMP4 segments. But the source is not guaranteed H.264/AAC: download rows are normalized by `_normalize_media_for_ios` (safe to copy), while library sources may be HEVC/AC3/etc. Reuse `library.plan_conversion`'s codec policy to decide passthrough/remux/transcode per stream, so copy is used only when the codecs are already iPad/HLS-compatible and we transcode otherwise. "No re-encode in the normal path" holds for already-compatible sources only.
4. Convert text subtitle sidecars to WebVTT. Supported inputs for the first pass are `.vtt`, `.srt`, and text `.sub`.
5. Reject image-based VobSub inputs because those are not text subtitles.
6. Generate a multivariant playlist with `EXT-X-MEDIA:TYPE=SUBTITLES` entries and video variants that reference the subtitle group. Omit the `SUBTITLES` group entirely when no text subtitles were discovered.
7. **HLS preparation is asynchronous, never inline in a GET.** Segmenting a full movie can take minutes and must run off the event loop (mirror the existing `/api/videos/{id}/prepare` + `converting`/`409` pattern in `main.py:589`). A playlist GET that finds no package triggers preparation and returns `409` until `master.m3u8` exists; it never blocks on ffmpeg.
8. Prefer remote HLS playback on iOS when `hls_path` is present. Preserve existing MP4 cache playback as the fallback.
9. Add offline HLS caching as its own implementation phase using `AVAssetDownloadURLSession`, because the current cache manager only downloads single MP4 files.

Apple HLS references used for this plan:

- Alternate media playlist tags: https://developer.apple.com/documentation/http-live-streaming/adding-alternate-media-to-a-playlist
- Apple HLS authoring requirements, including WebVTT subtitles: https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices

## File Structure

Create:

- `subtitles.py`  
  Discover subtitle sidecars, parse text subtitle formats, and write normalized WebVTT files.

- `hls.py`  
  Build and validate HLS output paths, call ffmpeg/ffprobe, generate media playlists, generate the multivariant playlist, and report HLS readiness.

- `tests/test_subtitles.py`  
  Unit tests for subtitle discovery, format detection, conversion, and error handling.

- `tests/test_hls.py`  
  Unit tests for HLS playlist generation, endpoint behavior, and no-reencode ffmpeg command construction.

Modify:

- `main.py`  
  Add HLS routes, HLS preparation wiring, and static HLS asset serving with auth.

- `views/serializers.py`  
  Add optional `hls_path` and `subtitle_tracks` fields to video JSON responses.

- `db.py`  
  Add an idempotent `ALTER TABLE videos ADD COLUMN hls_status` guard (values `none`/`converting`/`done`, following the existing migration-guard pattern in `init_db()`). Persist HLS readiness here rather than stat-ing the filesystem inside `serialize_video`: `serialize_video` runs once per row in the list endpoint (`main.py:526`), so per-row disk probes are a latency storm. Subtitle-track discovery for the serializer should likewise read cached results, not walk the filesystem on every response.

- `ios/PatataTubeKit/Sources/PatataTubeKit/Video.swift`  
  Decode optional HLS and subtitle metadata while preserving compatibility with existing API responses.

- `ios/PatataTubeKit/Sources/PatataTubeKit/APIClient.swift`  
  Add client coverage for optional HLS fields if helper methods are needed.

- `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift`  
  Leave MP4 caching unchanged in Phase 1. Add HLS offline support only in Phase 3.

- `ios/PatataTube/Sources/AppModel.swift`  
  Add an `hlsURL(for:)` helper parallel to `streamURL(for:)`.

- `ios/PatataTube/Sources/VideoPlayerView.swift`  
  Prefer remote HLS URLs with auth headers; fall back to cached MP4 or direct MP4.

- `ios/PatataTubeKit/Tests/PatataTubeKitTests/*`  
  Add model decoding tests for `hls_path` and subtitle metadata.

## Backend Plan

### Task 1: Add Subtitle Discovery Tests

1. In `tests/test_subtitles.py`, create temporary files:
   - `movie.mp4`
   - `movie.en.srt`
   - `movie.es.sub`
   - `movie.vtt`
2. Assert `discover_subtitles(movie_path)` returns deterministic tracks ordered by language/name.
3. Assert unsupported subtitle extensions are ignored.
4. Assert `.idx` plus `.sub` VobSub-style inputs are rejected with a clear unsupported-format result.
5. Run:

```bash
rtk pytest tests/test_subtitles.py
```

Expected result: tests fail because `subtitles.py` does not exist.

### Task 2: Implement Subtitle Discovery

1. Create `subtitles.py`.
2. Add a `SubtitleTrack` dataclass with:
   - `source_path: Path`
   - `language: str`
   - `name: str`
   - `format: str`
   - `default: bool`
   - `forced: bool`
3. Discover sidecars next to the video source path using these filename patterns:
   - `{stem}.srt`
   - `{stem}.vtt`
   - `{stem}.sub`
   - `{stem}.{language}.srt`
   - `{stem}.{language}.vtt`
   - `{stem}.{language}.sub`
4. Infer language from the final filename component before the extension when it is 2 to 8 characters. Use `und` otherwise.
5. Mark the first non-forced track as `default=True`.
6. Run:

```bash
rtk pytest tests/test_subtitles.py
```

Expected result: discovery tests pass; conversion tests still fail.

### Task 3: Add Subtitle Conversion Tests

1. In `tests/test_subtitles.py`, add `.srt` conversion coverage:

```text
1
00:00:01,000 --> 00:00:03,500
Hello
```

Expected WebVTT cue:

```text
00:00:01.000 --> 00:00:03.500
Hello
```

2. Add timestamp-based `.sub` conversion coverage:

```text
00:00:01.00,00:00:03.50
Hello
```

3. Add MicroDVD `.sub` coverage:

```text
{24}{84}Hello
```

With `fps=24`, expected cue is `00:00:01.000 --> 00:00:03.500`.

4. Assert every generated VTT file starts with:

```text
WEBVTT
X-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:0
```

5. Run:

```bash
rtk pytest tests/test_subtitles.py
```

Expected result: conversion tests fail.

### Task 4: Implement WebVTT Conversion

1. In `subtitles.py`, implement:
   - `convert_to_webvtt(track, output_path, fps=None)`
   - SRT timestamp normalization from commas to dots.
   - Timestamp-based `.sub` parsing.
   - MicroDVD frame-based `.sub` parsing using the supplied fps.
2. Escape or preserve cue text without HTML rewriting.
3. Normalize line endings to `\n`.
4. Write WebVTT atomically by writing to a temp file in the target directory and renaming it.
5. Run:

```bash
rtk pytest tests/test_subtitles.py
```

Expected result: subtitle tests pass.

### Task 5: Add HLS Command and Playlist Tests

1. In `tests/test_hls.py`, drive `build_hls_package(video_id, source_path, output_root)` with a **probe stub** so codec policy is deterministic:
   - Given an already-compatible source (H.264/AAC probe), assert the ffmpeg command uses `-c copy` and selects **no** `libx264`/`aac` encoder — the no-reencode path.
   - Given an incompatible source (e.g. HEVC/AC3 probe), assert the command transcodes the offending stream(s) (`libx264`/`aac`) — proving copy is not applied blindly.
   - Both cases assert `-hls_playlist_type vod`, `-hls_segment_type fmp4`, and `-hls_segment_filename`.
2. Test generated files are placed under:

```text
data/hls/{video_id}/
```

3. Test `master.m3u8` includes:

```text
#EXTM3U
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",LANGUAGE="en",NAME="English",DEFAULT=YES,AUTOSELECT=YES,FORCED=NO,URI="subtitles/en.m3u8"
#EXT-X-STREAM-INF:...,SUBTITLES="subs",...
video.m3u8
```

4. Test each subtitle media playlist includes:

```text
#EXTM3U
#EXT-X-TARGETDURATION:
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:
en.vtt
#EXT-X-ENDLIST
```

5. Run:

```bash
rtk pytest tests/test_hls.py
```

Expected result: tests fail because `hls.py` does not exist.

### Task 6: Implement HLS Packaging

1. Create `hls.py`.
2. Add configurable root:

```python
HLS_DIR = Path(os.getenv("HLS_DIR", "data/hls"))
```

3. Add `probe_media(path)` using existing ffprobe patterns from `library.py`.
4. Extract:
   - duration
   - video codec
   - audio codec
   - resolution
   - frame rate
   - bitrate when available
5. Decide per-stream copy vs transcode via `library.plan_conversion` (or the same codec policy it encodes). Use `-c copy` only when the probed video/audio codecs are already iPad/HLS-compatible (H.264 + AAC); otherwise transcode the incompatible stream(s). Download rows are pre-normalized, so they take the copy path; library sources may not. Generate fMP4 HLS, e.g. for the copy path:

```bash
ffmpeg -y -i input.mp4 -map 0:v:0 -map 0:a? -c copy -f hls -hls_playlist_type vod -hls_time 6 -hls_segment_type fmp4 -hls_fmp4_init_filename init.mp4 -hls_segment_filename data/hls/{id}/segment_%05d.m4s data/hls/{id}/video.m3u8
```

   For a source needing transcode, swap `-c copy` for the target encoders (`-c:v libx264 -c:a aac`, matching `library.py`'s transcode settings) on the offending stream(s) only.

6. Generate `master.m3u8` after ffmpeg succeeds.
7. Generate subtitle WebVTT files under:

```text
data/hls/{id}/subtitles/{language}.vtt
data/hls/{id}/subtitles/{language}.m3u8
```

8. Use relative URIs in playlists.
9. Ensure every returned/served path is constrained below `HLS_DIR / str(video_id)`.
10. Run:

```bash
rtk pytest tests/test_hls.py tests/test_subtitles.py
```

Expected result: HLS and subtitle unit tests pass.

### Task 7: Add Backend API Tests

1. In `tests/test_api.py`, add a `done` library video with a source MP4 and a sidecar subtitle (library rows are the ones that can have sidecars). Also add a `done` download row to cover the no-subtitle path.
2. Add tests for:
   - `GET /videos/{id}/hls/master.m3u8` requires auth.
   - The route returns `404` for missing videos.
   - The route returns `409` when the resolved source is not ready — download row not `done`, or library version status not `done`. (There is no `"completed"` status; do not test for it.)
   - When no package exists yet, the route **schedules async preparation and returns `409`** (still preparing); it does not run ffmpeg inline. A follow-up request after preparation completes serves the playlist. Assert the handler does not block on ffmpeg (the prep call is monkeypatched/backgrounded).
   - The route returns `application/vnd.apple.mpegurl` or `application/x-mpegURL` once ready.
   - `GET /videos/{id}/hls/video.m3u8` serves the media playlist.
   - `GET /videos/{id}/hls/segment_00000.m4s` serves a segment.
   - `GET /videos/{id}/hls/subtitles/en.m3u8` serves the subtitle playlist.
   - `GET /videos/{id}/hls/subtitles/en.vtt` serves `text/vtt`.
3. Use monkeypatching for ffmpeg in endpoint tests so the test suite does not require actual media segmentation.
4. Run:

```bash
rtk pytest tests/test_api.py tests/test_hls.py tests/test_subtitles.py
```

Expected result: API tests fail until routes are added.

### Task 8: Implement Backend Routes

1. In `main.py`, add:

```text
GET /videos/{video_id}/hls/master.m3u8
GET /videos/{video_id}/hls/{asset_path:path}
```

2. Reuse the same auth dependency/helper the stream route uses (`_check_token_or_query`, so `?token=` works for AVPlayer sub-requests too).
3. Resolve the video record using the existing DB helpers.
4. Resolve the source **exactly as `/videos/{id}/stream` does** (`main.py:372-389`), preserving both branches:
   - library row → `db.get_video_version(video_id, version_id)`, `404` if no version, `409` if `version["status"] != "done"`, source = `version["converted_path"] or version["source_path"]`.
   - download row → `409`/`404` unless `video["status"] == "done"` and `video["filename"]`; source = `VIDEOS_DIR / video["filename"]`.
   There is no `"completed"` status — do not check for it.
5. When `master.m3u8` is missing: set `hls_status="converting"`, schedule preparation off the event loop (BackgroundTask / thread, like the download and library-convert paths), and return `409`. Do **not** await ffmpeg in the handler.
6. Once `hls_status == "done"` and files exist, serve them.
7. Serve files only from `data/hls/{video_id}` (path-constrained, per Task 6 step 9).
8. Add content types:
   - `.m3u8`: `application/vnd.apple.mpegurl`
   - `.vtt`: `text/vtt`
   - `.m4s`: `video/iso.segment`
   - `.mp4`: `video/mp4`
9. Run:

```bash
rtk pytest tests/test_api.py tests/test_hls.py tests/test_subtitles.py
```

Expected result: backend tests pass.

### Task 9: Add Serialized HLS Metadata

1. In `views/serializers.py`, extend video JSON with:

```json
{
  "hls_path": "/videos/7/hls/master.m3u8",
  "subtitle_tracks": [
    {
      "language": "en",
      "name": "English",
      "default": true,
      "forced": false
    }
  ]
}
```

2. Derive `hls_path`/`subtitle_tracks` from the **persisted** `hls_status` column and cached subtitle metadata — no filesystem walks in `serialize_video` (it runs per-row in the list endpoint). Return `hls_path` only when the source can support HLS.
3. Return `subtitle_tracks` as an empty array when no text subtitles are discovered — always the case for download rows, which have no sidecars.
4. Update `tests/test_serializers.py`. Cover a library row with tracks and a download row with `subtitle_tracks: []`.
5. Run:

```bash
rtk pytest tests/test_serializers.py tests/test_api.py
```

Expected result: serializer tests pass.

## iOS Plan

### Task 10: Add iOS Model Tests

1. In `ios/PatataTubeKit/Tests/PatataTubeKitTests/APIClientReadTests.swift`, extend an existing video fixture with:

```json
"hls_path": "/videos/1/hls/master.m3u8",
"subtitle_tracks": [
  {"language":"en","name":"English","default":true,"forced":false}
]
```

2. Assert decoded `Video.hlsPath == "/videos/1/hls/master.m3u8"`.
3. Assert decoded subtitle metadata has language `en` and name `English`.
4. Add a fixture without these fields and assert decoding still succeeds.
5. Run:

```bash
cd ios/PatataTubeKit && rtk swift test
```

Expected result: tests fail until the model is updated.

### Task 11: Decode HLS Metadata

1. In `ios/PatataTubeKit/Sources/PatataTubeKit/Video.swift`, add:

```swift
public let hlsPath: String?
public let subtitleTracks: [SubtitleTrack]
```

2. Add:

```swift
public struct SubtitleTrack: Codable, Equatable, Sendable {
    public let language: String
    public let name: String
    public let `default`: Bool
    public let forced: Bool
}
```

3. Decode missing `subtitle_tracks` as `[]`.
4. Preserve the existing initializer by adding default arguments.
5. Run:

```bash
cd ios/PatataTubeKit && rtk swift test
```

Expected result: iOS package tests pass.

### Task 12: Add HLS URL Helper

1. In `ios/PatataTube/Sources/AppModel.swift`, add:

```swift
func hlsURL(for video: Video) -> URL?
```

2. Build the absolute URL from `credentials.baseURL` plus `video.hlsPath`.
3. Return `nil` when `hlsPath` is missing or empty.
4. Keep `streamURL(for:)` unchanged.
5. Build the app from Xcode or with the existing project workflow.

Expected result: build passes.

### Task 13: Prefer HLS in Playback

1. In `ios/PatataTube/Sources/VideoPlayerView.swift`, update `setup()` selection order:
   - If MP4 is cached, play the cached MP4 using existing behavior.
   - Else if `model.hlsURL(for: video)` exists, create an `AVURLAsset` from the HLS master URL.
   - Else play the existing direct MP4 stream URL.
2. Preserve `AVURLAssetHTTPHeaderFieldsKey` with the bearer token for HLS. AVPlayer uses the asset headers for playlist and segment requests on the same asset.
3. Keep the existing end-of-playback observer.
4. Run a simulator/device build.

Expected result: uncached videos use HLS and expose native subtitle tracks.

### Task 14: Verify Native Subtitle UI

1. On iPhone simulator or device, open an uncached video with subtitles.
2. Confirm the AVKit control surface exposes subtitle selection.
3. Confirm the default subtitle track displays automatically when the playlist marks it `DEFAULT=YES`.
4. Toggle subtitles off and on.
5. Confirm pull-down-to-dismiss still works.
6. If SwiftUI `VideoPlayer` does not expose usable subtitle controls, replace it with a small `UIViewControllerRepresentable` wrapper around `AVPlayerViewController` in `VideoPlayerView.swift`.
7. Re-run the same manual checks.

Expected result: subtitles are selectable and visible during HLS playback.

## Offline HLS Phase

### Task 15: Add HLS Offline Design Tests

1. Keep MP4 cache behavior intact.
2. Add a new HLS cache state only when implementing HLS downloads:

```swift
case hlsCached
```

3. Add tests or manual coverage that cached MP4 playback remains available when no HLS package is cached.

Expected result: existing offline playback remains stable.

### Task 16: Implement HLS Offline Downloads

1. Add an HLS-specific cache manager path under the app caches directory:

```text
hls/{video_id}/
```

2. Use `AVAssetDownloadURLSession` for HLS assets so AVFoundation downloads playlists, variants, and selected media options correctly.
3. Request the default subtitle media selection during download.
4. Prefer cached HLS playback over cached MP4 when a complete HLS offline package exists.
5. Keep raw MP4 cache as fallback.
6. Add manual tests:
   - Download HLS asset.
   - Disable network.
   - Play video with subtitles.
   - Toggle subtitles.
   - Delete cache and confirm remote HLS still works.

Expected result: offline playback supports subtitles without removing the existing MP4 fallback.

## Validation Commands

Backend:

```bash
rtk pytest tests/test_subtitles.py tests/test_hls.py tests/test_api.py tests/test_serializers.py
```

iOS package:

```bash
cd ios/PatataTubeKit && rtk swift test
```

Server smoke test:

```bash
rtk uvicorn main:app --reload --host 0.0.0.0 --port 3050
```

Manual HLS checks:

```bash
rtk ffprobe http://127.0.0.1:3050/videos/1/hls/master.m3u8
```

Apple HLS validator when installed:

```bash
rtk mediastreamvalidator http://127.0.0.1:3050/videos/1/hls/master.m3u8
```

## Acceptance Criteria

1. Existing MP4 streaming still works at `/videos/{id}/stream`.
2. Existing MP4 cache playback still works.
3. A video with a text subtitle sidecar exposes `/videos/{id}/hls/master.m3u8`.
4. The HLS master playlist references WebVTT subtitles through `EXT-X-MEDIA:TYPE=SUBTITLES`.
5. HLS generation uses ffmpeg stream copy for already-compatible (H.264/AAC) sources — no re-encode; incompatible library sources transcode only the offending stream(s) per `library.plan_conversion`.
6. AVPlayer on iOS plays the HLS URL with bearer-authenticated playlist and segment requests.
7. Subtitles display natively in the iOS player for uncached HLS playback.
8. Videos without subtitles still play through HLS or MP4 fallback.
9. Backend and iOS model tests pass.
