# PatataTube iOS — Manual Testing Guide

SwiftUI app, backend-driven video grid. Talks to PatataTube FastAPI server (repo root `main.py`).

## Features

### Video grid
- Backend-driven grid of video previews, populated from the JSON API
- Video title shown as an overlay on the preview (on a black background in each cell)
- Filter tabs — all / children / adults / education / entertainment; tapping one reloads the grid filtered to that category
- Selected category persists across app launches
- Adjustable grid cell size via +/- zoom buttons (originally a pinch/spread gesture, since replaced)
- Pull-to-refresh
- Red error banner at the bottom when the server is unreachable

### Playback
- Tap a cell to open a fullscreen player that autoplays
- Auto-dismisses on end of video
- Tap to dismiss
- Pull-down-to-dismiss gesture (the close "X" was removed in favor of gestures)

### Per-video actions
- Reorder with up/down controls
- Classify — move a video to a different category
- Delete videos
- Download a single video for offline playback, with visual feedback on the download button

### Offline / caching
- Downloaded MP4s stream from a local cache (works with no network to the server)
- The videos JSON API response is cached so the grid loads offline
- Video previews are cached too
- "Cache all videos" action in Settings downloads every visible video

### Upload
- Add a video by pasting a Twitter/X or YouTube URL; it appears in the grid once the backend finishes processing
- Requires a valid upload token (backend returns 401 otherwise)

### Settings & connection
- Configurable base URL and upload token
- "Test connection" to verify server reachability
- Optimistic UI: classify/move/upload reflect immediately, then reconcile with the server

### App shell
- App icon and launch splash generated from SVG

## Prereqs

- Xcode 26+ (tested w/ Xcode 26.3)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
- Backend server running (local or reachable host)

## 1. Start backend

From repo root:

```bash
./serve
```

Runs uvicorn on `http://0.0.0.0:3050` w/ reload.

Set upload token first (write endpoints require it):

```bash
cp .env.example .env
# edit .env, set UPLOAD_TOKEN=your-secret-token-here
```

## 2. Generate + open Xcode project

```bash
cd ios/PatataTube
xcodegen generate
open PatataTube.xcodeproj
```

(project.pbxproj is generated from `project.yml` — regenerate after pulling changes to that file.)

## 3. Run on simulator

Select scheme `PatataTube`, pick any iPhone simulator (17.0+ deployment target), hit Run (⌘R).

Sim → localhost networking: if server runs on your Mac, `http://localhost:3050` or `http://127.0.0.1:3050` reaches host machine directly from simulator (no extra config needed, unlike real device).

## 4. Configure app

On first launch grid is empty / errors — need server config:

1. Tap gear icon (top-left) → Settings
2. Base URL: `http://127.0.0.1:3050`
3. Upload token: same value as `UPLOAD_TOKEN` in `.env`
4. Tap Done

## 5. Manual test checklist

- **Grid loads**: after saving settings, pull-to-refresh or relaunch → videos populate grid
- **Filter tabs**: horizontal scroll tabs (all / children / adults / education / entertainment) — tap one, grid reloads filtered
- **Play video**: tap a cell → fullscreen player opens, autoplays, closes automatically on end-of-video; X button also dismisses
- **Reorder**: use up/down controls on cell → move video, confirm grid order updates
- **Classify**: use classify control on cell → pick new classification, confirm video moves/reflects under new filter tab
- **Download/cache**: tap download on a cell → check cache state changes (icon/indicator); play same video again → should stream from local cache (test by killing network access to server and replaying)
- **Resume download**: start downloading a large video, kill network access before it finishes, restore network, then tap download again → progress should resume instead of restarting from 0%
- **Cache all**: Settings → "Cache all videos" → downloads every visible video
- **Upload**: tap + (top-right) → paste video URL → Add → new video appears in grid after processing
- **Error banner**: point Base URL at unreachable host → red error banner appears at bottom of grid
- **Missing token**: clear upload token in Settings, try Add Video → upload should fail (401 from backend)

### Plex library

- [ ] Settings has valid base URL + token; tap the refresh (↻) toolbar button — spinner shows, then movie/TV items appear.
- [ ] "movies" tab shows the movie grid with Plex posters.
- [ ] "tv" tab shows one card per show with poster + episode count; tapping opens seasons → episodes with thumbs and summaries.
- [ ] Playing an unprepared mkv episode (from the pushed episode list) shows "Preparing…" over the episode list and blocks further taps (e.g. double-tapping Play does not fire a second prepare), then plays (remux takes seconds).
- [ ] Playing an already-compatible mp4 movie starts without any conversion wait.
- [ ] Downloading an unprepared episode prepares first, then caches; airplane mode playback works from cache.
- [ ] Delete on a library video removes it from the list; the original file on /Volumes/Media is untouched; a later refresh does not resurrect it.
- [ ] A conversion failure (e.g. unplug the Media volume mid-convert) shows an error and the episode can be retried.
- [ ] Movies tab shows portrait 2:3 poster cards (no letterbox bars); other tabs unchanged.
- [ ] "all" tab still shows movies as 16:9 letterboxed VideoCells.
- [ ] Tap a movie card poster → detail page with poster, title, summary.
- [ ] Play from the detail page works for an unconverted library movie (Preparing… overlay appears over the pushed page).
- [ ] Download from the detail page and from the movie card both show the progress ring and end in a green checkmark; cancel mid-download resets to the arrow.
- [ ] Version picker on the movie card and detail page switches versions; download state resets accordingly.
- [ ] Movie card ellipsis menu still offers Info / Move / classify / Delete.

### Background audio
- [ ] Play a video, lock the phone → audio continues; lock screen shows title, artwork, and controls
- [ ] Play/pause and scrub from the lock screen and Control Center
- [ ] Switch apps mid-playback → audio continues
- [ ] Pause a video, then lock the phone or switch apps → playback remains paused
- [ ] Return to the app → video resumes in sync with audio
- [ ] Video ends while locked → playback stops and lock screen controls clear
- [ ] Pull-down-to-dismiss still works; AVKit tap/scrub controls still work
- [ ] AirPlay still works (full video on the external screen)

## Notes

- No unit/UI test target yet — this is the only verification path.
- `PatataTubeKit` (Sources/PatataTubeKit) is a local SwiftPM package with the networking/cache/model logic — build it standalone with `swift build` inside `ios/PatataTubeKit` if isolating a bug there.
