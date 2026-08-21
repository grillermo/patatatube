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

**Never run the iOS tests unless explicitly asked.** Neither `swift test` nor
`xcodebuild ... test`. They take many minutes on this machine and are the
user's call to start, not an agent's. Ship the change and say which tests
*would* cover it; wait to be asked before running any of them. The rest of this
section documents how to run them **when asked**.

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
2. A YouTube **playlist** URL (`/playlist?list=…`, on `youtube.com`,
   `m.youtube.com` or `music.youtube.com`) classifies as `youtube_playlist` and
   takes a different route: no row is inserted, `body.group_id` is ignored, and
   `downloader.import_playlist` runs as a BackgroundTask. It calls
   `yt-dlp --flat-playlist -J` once, creates a **new** group named after the
   playlist title (`name` slugified, suffixed `-2`, `-3`… on collision — an
   existing group is never reused), inserts one row per entry, and downloads
   them **sequentially**. An entry that's already a completed `youtube` video
   elsewhere is *not* re-downloaded — it's moved into the new group via
   `db.set_video_group`, so a video already in another group can end up moved
   into this one. `watch?v=X&list=Y` is deliberately *not* a playlist:
   shared links routinely carry a Mix id nobody meant to hand over. The
   response is `202 {"status": "queued", "playlist": "<list_id>"}` — no ids,
   because neither the group nor the rows exist yet; clients poll
   `/api/groups`. A failed or empty playlist creates nothing and is only
   visible in `log/backend.log`.
3. `downloader.py` runs the download off the event loop: **pybalt** for Twitter/X, **yt-dlp** (`--cookies-from-browser`) for YouTube — a run that fails with a cookie-decryption/lock error (Chrome rotates its key) is retried once with cookies dropped, for both single videos and playlist metadata. Every file is passed through `_normalize_media_for_ios` — an ffmpeg step that guarantees H.264/AAC + `+faststart` so iOS can stream it. Output lands at `videos/{id}.mp4`.
4. Status transitions queued → downloading → done. **Failures don't get an `error` status** — `db.update_video(status="error")` and the download exception handler both *delete the row* instead. Don't rely on error rows existing.
5. `GET /videos/{id}/stream` serves the MP4 with HTTP Range support (206 partial content), hand-rolled in `_parse_byte_range` / `_iter_file_range`, gated by an asyncio semaphore (`VIDEO_STREAM_LIMIT`).

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

**Per-group display settings live on the group row, not in a client's
UserDefaults.** `groups.display_titles` (added by an idempotent `ALTER TABLE`
guard, default 0) overlays each video's title on its player in that group's
view — white with a small black shadow — and both clients read it: the iOS grid
via `VideoGroup.displayTitles`, the web page via a `.title-overlay` div in the
`card` macro (`pointer-events: none`, hidden while the video plays). Only iOS
can *set* it, through the `⋯` menu's "Display titles" toggle, which PATCHes
`display_titles` **alone** — `APIClient.updateGroup` always sends `emoji`, so
reusing it here would clear the group's cover. `VideoGroup` decodes the field
with `decodeIfPresent ?? false` because `GroupStore`'s UserDefaults mirror holds
blobs written before it existed. A Plex kind is not a group, so TV/Movies never
overlay titles and never show the toggle.

### The response cache invalidates on writes, not on time

`middleware.RedisCacheMiddleware` caches **every** 200 GET (`cache.py`, keyed by
path + query + token fingerprint). Its only invalidation signals are: a mutating
HTTP request (which flushes everything), `CACHE_TTL_SECONDS` (300s, safety net),
and `_NEVER_CACHED_PATHS`.

That means **any process that changes state without an HTTP request must flush
it itself**, or the iOS poll loops read a frozen snapshot. `converter.py` calls
`cache.clear_blocking()` after every job — a cached `/api/videos/{id}` reporting
`converting` is what leaves `VideoStore.ensureReady` polling a video the server
already finished. `/api/jobs` is in `_NEVER_CACHED_PATHS` because it is polled
every 2s *for* live job state; caching it froze the download ring and the
Downloads "Converting" section indefinitely. New out-of-band writers need the
same flush; new live-state endpoints belong in that set.

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
- **Downloads can be paused, and a pause outlives the process.** Each row in
  the Downloads view carries a three-dot menu holding Cancel plus Pause (or
  Resume). `CacheManager.pause` is deliberately not `cancel`: cancel wipes
  resume state so a re-tap starts clean, pause preserves it. The segmented path
  (HLS segments) stops transferring but keeps its partial part files and manifest
  intact, the durable state for byte-by-byte continuation; on resume, segments
  re-request only the remaining bytes via `Range` + `If-Range` computed from the
  part file's size on disk. The plain `URLSession` path is unchanged: still
  cancels tasks `byProducingResumeData`, still writes `{key}.resume` files, and
  still resumes via `session.downloadTask(withResumeData:)` — Apple's resume-data
  mechanism. Entries live in `paused-downloads.json` (`PausedDownloadStore`) in
  the cache root, and `resumeInterrupted()` skips their keys, which is the only
  thing stopping the next foreground from silently un-pausing them. A paused
  download **keeps its concurrency permit**: `download`'s `defer` hands ownership
  to the paused-permit table instead of releasing, and every stored entry
  re-reserves one at launch, so pausing everything means nothing downloads until
  the user acts. HLS packages have no partial state on disk, so pausing one
  restarts it from zero on resume.
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
- Subtitles come from two places, and `subtitles.discover_subtitles` merges both: **sidecar files** next to the media, and **text tracks embedded in the container** (SRT/ASS/mov_text — bitmap PGS/VobSub/DVD tracks are rejected, they would need OCR). A sidecar outranks an embedded track of the same language. Embedded discovery only happens when the caller passes an ffprobe dict; `subtitles.py` never shells out to ffprobe itself, so `discover_subtitles(path)` alone stays a pure filesystem walk.
- **Exactly one track ships per language** (`_one_per_language`), preferring the plain variant over SDH and Forced, and never dropping a language whose only track is one of those. This is not cosmetic: selection is language-keyed the whole way through (`videos.subtitle_lang`, `POST /api/videos/{id}/subtitle`, the picker's `.tag`), and AVKit's in-player list groups HLS renditions by `LANGUAGE` regardless of `NAME`. Ship several renditions per language and the app's own picker (one row per track) and the player's (one row per language) show different lists. Per-track selection would mean changing that key end-to-end, not just the playlist.
- **Hidden files are never subtitles** (`_list_files`). macOS leaves a binary AppleDouble `._X` twin beside every `X` on a non-HFS volume, and a release folder full of them doubled every track — worse, `._English.eng.srt` sorts first, so the junk twin won the `en` key and shipped as the `DEFAULT=YES` rendition with an AppleDouble blob inside a `.vtt`.
- **Filename tokens are NFC-folded before any table lookup** (`_fold`). macOS returns decomposed filenames, so `Français.fre.srt` arrives as `Franc\u0327ais...`; unfolded, the language word misses `_NAME_CODES`, gets mistaken for a descriptor ("French (Français)" instead of "French"), and stops counting as the plain variant.
- `video_versions.subtitle_langs` is a JSON column filled only at scan time by `library._probe_missing_track_langs`, which fills `audio_langs` from the same single ffprobe pass — there is no per-request probe. **Deploying subtitle changes onto an existing library needs one `POST /api/library/scan`** before pre-existing rows report any `subtitle_tracks`; until then the picker silently shows none. The per-movie choice lives in `videos.subtitle_lang` (`POST /api/videos/{id}/subtitle`), which never re-converts since every discovered language is already packaged into the HLS multivariant playlist at conversion time.
- **A packaged playlist is not invalidated by anything else, so the re-probe does it.** After writing `subtitle_langs`, `library._invalidate_stale_hls` compares the computed languages against `hls.packaged_subtitle_languages(video_id)` (parsed out of the on-disk `master.m3u8`) and calls `hls.invalidate` on a mismatch; `None` means nothing is packaged, which is not a mismatch. Without this a package built before its tracks were known serves that empty rendition set forever — the app's picker reads the fresh DB, the player reads the stale playlist, and the two disagree permanently. `hls` imports `library`, so the import is function-local.
- **HLS packaging searches the original file for subtitles, not the file it streams.** A converted library row streams our own sibling mp4, and `library.convert_library_video` passes `-sn`, so that mp4 has no subtitle streams at all. `router` sends the version's `source_path` as the job payload's `subtitle_source_path`, and `hls.build_hls_package` searches it instead (costing one extra ffprobe when the two differ). Package from the converted file alone and every embedded track disappears exactly at the point it would have shipped.

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
- **Storage layout**: `paths.py` holds `VIDEOS_DIR`/`HLS_DIR`, both derived from `MEDIA_ROOT` (env, default `.` — repo-relative). Setting `MEDIA_ROOT` moves downloaded MP4s and HLS packages off the boot disk onto an external volume; `paths.ensure_media_root()` runs at both `main.py` and `converter.py` startup and raises loudly if that volume isn't mounted, rather than silently refilling the boot disk. `data/watch_later.sqlite` and `data/previews/` always stay local.
