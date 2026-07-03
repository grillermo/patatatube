# PatataTube iOS — Manual Testing Guide

SwiftUI app, backend-driven video grid. Talks to PatataTube FastAPI server (repo root `main.py`).

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
- **Cache all**: Settings → "Cache all videos" → downloads every visible video
- **Upload**: tap + (top-right) → paste video URL → Add → new video appears in grid after processing
- **Error banner**: point Base URL at unreachable host → red error banner appears at bottom of grid
- **Missing token**: clear upload token in Settings, try Add Video → upload should fail (401 from backend)

## Notes

- No unit/UI test target yet — this is the only verification path.
- `PatataTubeKit` (Sources/PatataTubeKit) is a local SwiftPM package with the networking/cache/model logic — build it standalone with `swift build` inside `ios/PatataTubeKit` if isolating a bug there.
