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
- **Debugging: read `log/backend.log`.** `./serve` mirrors every labeled stream (`dev`/`web`/`caddy`/`access`/`app`/`convert`) to it, uncolored, alongside the terminal output. Same interleaved view, persisted. Override path with `LOG_FILE=...` (dir is gitignored).

### iOS (`ios/`)

```bash
cd ios/PatataTube && xcodegen generate && open PatataTube.xcodeproj   # project.pbxproj is generated from project.yml
cd ios/PatataTubeKit && swift build                                   # build the logic package standalone
cd ios/PatataTubeKit && swift test                                    # debug: DEVLOG on
cd ios/PatataTubeKit && swift test -c release                         # release: DEVLOG off (silence guarantee)

# app target's own tests (SwiftUI/UIKit; swift-testing + ViewInspector)
cd ios/PatataTube && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube \
  -destination "platform=iOS Simulator,id=$(xcrun simctl list devices available | grep -m1 -o '[0-9A-F-]\{36\}')" test
```

See `ios/README.md` for the full manual test checklist.

Run **both** `swift test` invocations when touching `DevLog` — the two
configurations exercise opposite halves of the gating (see below).

**There are two iOS test targets, and only one of them is `swift test`.**
`ios/PatataTube/Tests/*.swift` (target `PatataTubeTests`, 73 tests) only ever
builds through `xcodebuild`, so it silently rots: a stale call there breaks the
*test* build while `xcodebuild ... build` and `./deploy` keep succeeding. It sat
broken for four days that way (`docs/player-view-controller-tests-broken.md`).
Run it whenever you touch `ios/PatataTube/Sources/`.

- `build`/`build-for-testing` differ on destinations: `generic/platform=iOS
  Simulator` is fine for `build`, rejected by anything that runs tests, and
  named destinations (`name=iPad Pro 13-inch (M4)`) fail on this machine. Use a
  concrete udid from `xcrun simctl list devices available`.
- **Run the whole target, not a filtered suite.** `-only-testing:` on
  `EpisodesDownloadAllViewTests` hangs indefinitely; the same tests pass in ~1s
  in a full run.
- ViewInspector reaches an `@EnvironmentObject` by writing sentinel bytes at
  guessed offsets inside a copy of the view struct. On a big view it guesses
  into a refcounted field and **segfaults the whole test process** — which no
  `withKnownIssue` can absorb. That is why
  `normalAndSleepPlayersBothContainTheOrientationOverlay` is `.disabled`. New
  tests that inspect a large SwiftUI view are the risk here.

- Pre-existing, unrelated: the full parallel `swift test` run prints a
  `Fatal error: Index out of range` from the swift-testing suites. It reproduces
  on a clean checkout. A full parallel run can also show other pre-existing
  flaky test failures (e.g. in `VideoStoreTests`) that don't reproduce under
  filtered/targeted runs — don't take a full-suite failure alone as a
  regression signal; re-run the specific test(s) filtered before concluding
  something broke.

### Debugging the iOS app: read `log/ios.jsonl`

Instrumented builds emit structured JSONL — one JSON object per line, fields in
a fixed order: `ts`, `seq`, `kind`, `msg`, `src`, `fn`, `session`, `meta`.
`kind` is one of `tap` `nav` `play` `proxy` `cache` `download` `net` `state`
`error` `lifecycle`. `session` identifies one app run; `seq` is monotonic within
it, so ordering survives batching. A `lifecycle` record with `meta.dropped`
marks records discarded to ring-buffer overflow — a gap in `seq` is never
silent.

- **Simulator**: the app writes straight to the host path in the
  `PATATATUBE_DEV_LOG` scheme env var (`log/ios.jsonl`). Launching outside
  Xcode needs `SIMCTL_CHILD_PATATATUBE_DEV_LOG=...` on `xcrun simctl launch`.
- **Device**: there is no host path, so the app batches records to
  `POST /api/devlog` (Bearer `UPLOAD_TOKEN`) and `devlog.py` appends them to the
  same file, rotating to `ios.jsonl.1` at 32 MB. Nothing is recorded until
  `DevLog.connect` gets credentials — `AppModel` calls it at init and on save.

`./serve` truncates `log/ios.jsonl` (and drops `ios.jsonl.1`) on every start,
exactly like `log/backend.log`, so a run's iOS and server logs cover the same
window. Override the path with `IOS_LOG_FILE=...`. **A restart discards the
previous run's records** — copy the file elsewhere before restarting if a
reproduction is still being analysed.

```bash
tail -n 300 log/ios.jsonl
grep '"kind":"error"' log/ios.jsonl | tail -30
jq -c 'select(.meta.video_id=="812")' log/ios.jsonl              # one video's whole story
jq -c 'select(.kind=="play" or .kind=="proxy" or .kind=="cache")' log/ios.jsonl
```

**All of it is compiled out unless the `DEVLOG` condition is set, so a normal
release logs nothing.** Add call sites with `DevLog.event` / `DevLog.error` /
`View.logTap` — never `print`. Both arguments are `@autoclosure`, so with the
flag off nothing is even interpolated; keep `meta` values cheap anyway
(precomputed, no filesystem walks) since they *do* run when it is on.

Getting `DEVLOG` set is the fiddly part, and it is deliberately independent of
`DEBUG` — the build that misbehaves is the Release `.ipa` AltStore sideloads:

- **Debug** (Xcode Run, Simulator): on automatically. The app target gets it
  from `settings.configs.Debug` in `project.yml`; **PatataTubeKit gets it from
  its own `Package.swift`** — an Xcode project-level setting does not reach
  SwiftPM package targets, and most instrumented code (`CacheManager`,
  `StreamProxy`) lives in the package. Both are needed.
- **Release**: off, unless built via `./deploy --instrumented`, which passes
  `SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) DEVLOG'` on the
  `xcodebuild` command line — the one place that does reach every target.

`DevLog` never propagates its own failures into the code it observes: emission
only takes a lock and appends to a bounded ring buffer, all I/O happens later on
a utility queue, and overflow drops records rather than applying backpressure to
the playback path. Keep it that way — this app has already shipped a main-thread
hang from a synchronous `NSFileHandle.write` (`VideoStore.swift:100`, Sentry
PATATATUBE-2). Records carry ids, statuses, byte counts and error codes only —
never bearer tokens, never response bodies.

The backend also prints a stream-permit gauge to `log/backend.log` —
`[stream] +1 <file> active=N/16`, `-1`, and `[stream] saturated: …` when
`/videos/{id}/stream`'s semaphore is fully held. Those permits are held for the
*entire* response body, so comparing that gauge against the app's
`gate acquired`/`gate released` records is how download-storm starvation gets
confirmed.

Design, the full list of instrumented call sites, and a hypothesis → evidence
map for the intermittent-playback investigation:
`docs/ios-devlog-instrumentation-plan.md` (§7).

## Architecture

### Request → download → serve flow

1. `POST /upload` (or `/api/videos` paths) — `main.py` classifies the URL (`_classify_url`) into `twitter` or `youtube`, inserts a `queued` row via `db.add_video`, and schedules `downloader.download_video` as a FastAPI `BackgroundTask`.
2. `downloader.py` runs the download off the event loop: **pybalt** for Twitter/X, **yt-dlp** (`--cookies-from-browser`) for YouTube. Every file is passed through `_normalize_media_for_ios` — an ffmpeg step that guarantees H.264/AAC + `+faststart` so iOS can stream it. Output lands at `videos/{id}.mp4`.
3. Status transitions queued → downloading → done. **Failures don't get an `error` status** — `db.update_video(status="error")` and the download exception handler both *delete the row* instead. Don't rely on error rows existing.
4. `GET /videos/{id}/stream` serves the MP4 with HTTP Range support (206 partial content), hand-rolled in `_parse_byte_range` / `_iter_file_range`, gated by an asyncio semaphore (`VIDEO_STREAM_LIMIT`).

### ffmpeg runs in exactly one process

`converter.py` is the only process that spawns ffmpeg. Web workers never do —
`/api/videos/{id}/prepare`, a cold `master.m3u8`, and upload normalization all
call `db.enqueue_job` and return immediately. The runner claims jobs
`FFMPEG_JOB_LIMIT` at a time (default 2, env-overridable) from the `jobs` table,
ordered by `priority` then `id`; `priority=100` is the iOS Download-all path and
queues behind interactive taps at `priority=0`.

`./serve` starts it as a supervised child (`until ... do sleep 1; done`) that
exits with its parent via `--watch-pid`. Queue depth is visible in
`log/backend.log`:

    [job] +1 kind=convert id=812 priority=100 queued=225
    [job] -1 kind=convert id=812 status=done secs=412

`ffmpeg_progress.run_ffmpeg` is the only place `convert` and `hls` jobs spawn
ffmpeg (the `normalize` job still shells out via `downloader.py`, and the
preview endpoints grab frames directly in the web worker).
It appends `-progress pipe:1 -nostats` when given a duration and a callback,
and writes a 0..1 fraction to `jobs.progress` (throttled to ≥1% or ≥2s). stderr
gets its own pipe drained on a thread — merging it into stdout would corrupt the
progress stream, and not draining it deadlocks a verbose failure.

`GET /api/jobs` exposes running jobs plus the next 20 queued (`convert` and
`hls` only; `normalize` is excluded) with a `queued_total`. The iOS `JobsStore`
polls it every 2s while any view is subscribed, and both the download button's
determinate ring and the Downloads view's "Converting" section read from it.

Only this process may run ffmpeg — that is the invariant that makes the startup
orphan reset correct (nothing else can hold a `running` job) and the cap real.
Adding a fourth ffmpeg call site means adding a job kind, not a BackgroundTask.
This exists because 226 concurrent BackgroundTask conversions took the machine
down on 2026-07-31; see `docs/superpowers/specs/2026-07-31-ffmpeg-job-queue-design.md`.

**Dev caveat:** `--reload` restarts uvicorn but not the converter. Editing
`converter.py` or `library.py` needs a full `./serve` restart.

### Layering — the SSR page and the JSON API share logic, don't duplicate it

- `db.py` — the only SQLite layer. Single `videos` table. `init_db()` is an **idempotent migration runner**: it does `CREATE TABLE IF NOT EXISTS`, then additive `ALTER TABLE` guards for each newer column, then backfills (`_backfill_positions`, `_backfill_youtube_preview_urls`) and cleanup. Schema changes go here as new idempotent guards, not a migrations framework.
- `services.py` — mutation logic (`set_group`, `promote`) called by **both** the HTML form endpoints and the JSON API endpoints in `main.py`. Put shared write logic here.
- `views/serializers.py` — `serialize_video` is the canonical video-to-dict presenter for the JSON API. Keep the API shape here.
- `views/render.py` + `views/templates/*.html` — the server-rendered HTML page + PWA splash images.

The `groups` table is the source of truth for video groups. `db.PLEX_KINDS` covers the separate Plex axis. The iOS Videos tab renders `GET /api/groups` and no longer hardcodes anything, so there is no list to keep in sync.

Adding a group is `POST /api/groups`; there is deliberately no UI for it, and no delete endpoint.

### Auth

Write endpoints call `_check_token`: `Authorization: Bearer <UPLOAD_TOKEN>` compared with `secrets.compare_digest`. If `UPLOAD_TOKEN` is unset the server returns 503 (upload disabled). The SSR endpoints are `/videos/{id}/group` and `/videos/{id}/promote`; the group endpoint is **not** token-gated, matching the old behavior.

### iOS

- `ios/PatataTubeKit/` — a local SwiftPM package holding all logic (`APIClient`, `CacheManager`, `VideoStore`, `Video`, `CredentialStore`). This is the testable core; build/isolate bugs here with `swift build`.
- `ios/PatataTube/` — the SwiftUI app shell (`Sources/*.swift`), an XcodeGen target. `Video` decodes the server's snake_case JSON; `CacheManager` downloads MP4s for offline playback; `VideoStore` does optimistic group/upload against `APIClient`.
- **Navigation is a `TabView` over `MediaTab` (videos/tv/movies).** `RootTabView`
  builds one `VideoGridView` per tab, each with its own `NavigationStack`;
  `VideoStore.feed` is the single source of what's loaded, and tab selection
  calls `switchFeed`. `Feed` distinguishes all videos, a group ID, and a Plex
  kind for both API queries and persisted per-feed state. The Videos tab's root
  is `GroupsView`, which renders the server-owned group list. Its `GroupStore`
  is the single UserDefaults mirror of that list, covering both groups and
  their emoji so the offline-first screen renders before any fetch. Tapping a
  card pushes `Route.group(id:)`, and the `path` change selects that group feed,
  so a hand tap and a restored path take the same code path.
- **Download-all is bounded on the client too.** `withBoundedTaskGroup`
  (PatataTubeKit) runs at most `CacheManager.maxConcurrentDownloads` operations
  at once. This is not the same bound as `DownloadConcurrencyGate`, which covers
  only the transfer: `download` calls `ensureReady` -> `POST /prepare` and then
  polls every 2s *before* acquiring the gate. One task per video is what sent
  226 concurrent prepare calls at the server on 2026-07-31. New bulk actions go
  through the bounded window, not a bare `withTaskGroup`. The grid's own
  Download-all passes `bulk: true` (server priority=100), but the per-show
  Download-all in `EpisodesView` shares its `onDownload` closure with
  individual per-episode taps and deliberately does not, so it enqueues at
  interactive (non-bulk) priority.
- **The in-app web bridge has an address bar.** `WebBridgeView` opens on the
  last committed page (`WebHistoryStore.lastURL`, `UserDefaults` key
  `webBridgeHistory`, 200 entries) rather than a hardcoded URL. Typing
  fuzzy-searches that history — whitespace is a wildcard, tokens must match in
  order. Enter routes through `WebAddress.destination`: **typed addresses win
  over the top history match**, so text that resolves as a URL always navigates
  there, and history only decides for text that isn't an address on its own.
  Resolution fills in `https://` and refuses anything without a host. There is
  deliberately no search-engine fallback.
- **Resume positions live on the server.** `videos.resume_secs` is written by
  `POST /api/videos/{id}/position`; the iOS player reports every 10s and on
  pause/background/dismiss/advance via `PlaybackPositionReporter`, mirroring
  each write into `UserDefaults` (`ResumePositionStore`) so offline playback
  still resumes and failed writes flush later. The Resume/Play-from-start
  alert only appears for Plex items (`plex_kind` non-null) past 60s (`ResumeDecision`);
  reaching the last 30s stores 0, and auto-advance inside the player always
  starts the next item at 0.

### Plex library (library rows)

- `plex.py` fetches metadata from the local Plex server (`PLEX_URL`/`PLEX_TOKEN`); its JSON contains raw control characters, so it parses with `json.loads(text, strict=False)`.
- `library.py` owns scanning (`scan_library`) and on-demand ffmpeg conversion (`convert_library_video`): passthrough / remux / transcode per the iPad codec policy (`plan_conversion`), converted file written as a sibling `{name}.mp4`.
- Library rows live in the same `videos` table with `source='library'`, statuses `unconverted → converting → done`; failures set `error_msg` and revert to `unconverted` (never row-delete). Deletes tombstone via `deleted_at` and never touch `source_path`.
- Stream endpoint is token-gated (Bearer or `?token=`); library previews proxy Plex thumbs at `/videos/{id}/preview` with a disk cache in `data/previews/`. The same endpoint serves **download** rows that have no external thumbnail (Twitter, file uploads — only YouTube fills `preview_url`) by grabbing a frame `PREVIEW_FRAME_OFFSET` seconds into the mp4; frame 0 is black in most clips, which is what left those rows posterless.
- Conversions keep every audio track matching `LIBRARY_AUDIO_LANGS` (default `eng,spa`; first track as fallback). Per-version `audio_langs`/`converted_langs` are JSON columns filled at scan/convert time; the per-movie choice lives in `videos.audio_lang` (`POST /api/videos/{id}/audio`), and the HLS package carries only the chosen language (invalidated via `hls.invalidate` on change).
- Sidecar subtitles work the same way, mirrored: `video_versions.subtitle_langs` is a JSON column filled only at scan time by `library._probe_missing_subtitle_langs` — there is no per-request probe. **Deploying this feature onto an existing library needs one `POST /api/library/scan`** before pre-existing rows report any `subtitle_tracks`; until then the picker silently shows none. The per-movie choice lives in `videos.subtitle_lang` (`POST /api/videos/{id}/subtitle`), which never re-converts since every discovered language is already packaged into the HLS multivariant playlist at conversion time.

### Promoting downloads into Plex

- `POST /api/videos/{id}/promote` hands a **download** row to Plex: `promote.py` copies `videos/{id}.mp4` to `<LIBRARY_TV_DIR|LIBRARY_MOVIES_DIR>/<sanitized title>.mp4` (flat, no folders), unlinks the source, invalidates HLS, **hard-deletes the row**, and best-effort triggers a Plex section rescan. The video reappears later as a library row via `scan_library`. Setting a group never promotes it.
- The copy is deliberate: `videos/` and `/Volumes/Media` are different filesystems, so `os.rename` raises `EXDEV`. It copies to a hidden `.name.part` inside the destination, then `os.replace`s it — same-volume and atomic, so Plex never scans a partial file.
- Any failure (volume unmounted, collision, permissions) raises `promote.PromotionError` → **409**, and nothing changes: no move, no delete.
- **Library** rows never move. Their `plex_kind` comes from the Plex section they live in (`plex.py`), and is refreshed by the next scan.
- `/upload/file` takes a `group_id`; its former `tv`/`movies` rejection is gone because that case is structurally impossible.

## Conventions

- ffmpeg/ffprobe/yt-dlp binaries and behavior are all env-overridable (`FFMPEG_BIN`, `FFPROBE_BIN`, `YTDLP_BIN`, `YTDLP_BROWSER`, `YTDLP_FORMAT`). Downloader code should keep reading these rather than hardcoding paths.
- `ALLOWED_HOSTS` env drives `TrustedHostMiddleware`; the default includes the production hosts plus `testserver` (FastAPI TestClient's host).
- Tests reload `db` then `main` after setting `DB_PATH`/`UPLOAD_TOKEN` env vars (see the `client` fixture in `tests/test_api.py`) — because both modules read env at import time. Follow that pattern for new integration tests.
