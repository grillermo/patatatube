# Handoff: iPad crash on tapping a video right after app launch (fresh install)

**Generated**: 2026-07-19
**Branch**: main (clean, at `5a74bf0` Release iOS v1.0.48)
**Status**: In Progress — root cause NOT confirmed; blocked on getting the iPad's crash log

## Goal

User's iPad (fresh install, presumably v1.0.48 via AltStore) crashes when tapping a video in the **children** section. Refined repro from user mid-session:

- Crash happens **only right after the app is opened** (first tap after cold launch).
- Crash does **NOT** happen if the user first taps an *unconverted* video, then taps the converted one.

Find root cause (systematic-debugging skill active — no fixes without confirmed root cause).

## Completed

- [x] Read the full tap→play flow: `VideoGridView.play()` → `startPlayback()` → `fullScreenCover` → `VideoPlayerView.setup()` → `playerItem()` / `NowPlayingManager.attach()` / `loadArtwork()`.
- [x] Audited `VideoGridView.swift`, `VideoPlayerView.swift`, `VideoCell.swift`, `PlayerViewController.swift`, `NowPlayingManager.swift`, `AppModel.swift`, `CacheManager.swift` — **no force unwraps / index-out-of-range candidates found**. `playQueue` can't be empty (falls back to `[video]`).
- [x] Found synced crash logs on this Mac: `~/Library/Logs/CrashReporter/MobileDevice/iPhone 16e/Retired/PatataTube-2026-07-18-*.ips` (5 logs, **iPhone**, app version **1.0.40**, not the iPad).
- [x] Parsed them. Faulting thread (log `PatataTube-2026-07-18-132058.ips`, thread 7, queue `*/accessQueue`):
  ```
  libdispatch  _dispatch_assert_queue_fail
  libdispatch  dispatch_assert_queue
  libswift_Concurrency  swift_task_isCurrentExecutorWithFlagsImpl
  PatataTube (2 unsymbolicated frames)
  MediaPlayer  -[MPMediaItemArtwork jpegDataWithSize:]
  MediaPlayer  ___MPToMRNowPlayingInfoDictionary_block_invoke
  MediaPlayer  -[MPNowPlayingInfoCenter(NowPlayingInfo) _onQueue_pushNowPlayingInfoAndRetry:]
  ```
  = SIGTRAP: lock-screen **artwork request handler** ran on MediaPlayer's private queue while the closure was actor-isolated (Swift executor assert).
- [x] Verified git history: commit `9ae72ea` "fix(ios): make artwork provider concurrency-safe" (the `nonisolated static makeArtwork` in current `NowPlayingManager.swift:85-92`) is **NOT in v1.0.40**, first shipped in **v1.0.41**. So those iPhone logs show an already-fixed bug.
- [x] Checked device access: `xcrun devicectl list devices` → only "iPhone 16e", state *unavailable*. **iPad is not paired/connected — no iPad crash log obtained yet.**
- [x] Noticed app embeds **bitdrift Capture SDK** (`bd-tokio*` threads, `KSCrash_bitdrift` handler). Init in `ios/PatataTube/Sources/PatataTubeApp.swift:10-13` (`Logger.start(withAPIKey:..., sessionStrategy: .fixed())`). Crashes may be visible in the bitdrift dashboard — was about to explore this when the session ended.

## Not Yet Done

- [ ] **Get the actual iPad crash log** — this is the blocker. Options:
  1. bitdrift dashboard (SDK is installed; check if crash reports upload there).
  2. On iPad: Settings → Privacy & Security → Analytics & Improvements → Analytics Data → `PatataTube-*.ips`, AirDrop/share to Mac.
  3. Pair iPad with this Mac and pull via Finder sync / devicectl.
- [ ] Confirm which app version the iPad's fresh install actually got (AltStore source should serve v1.0.48 — verify; if the source lags, the iPad might be running a pre-1.0.41 build and the crash is the already-fixed artwork bug).
- [ ] Once log obtained: symbolicate PatataTube frames against the v-matching dSYM, confirm root cause, then TDD a fix.

## Failed Approaches (Don't Repeat These)

- **Static code audit for the crash**: read all player/cell/cache/nowplaying code — no crashing pattern found. Don't keep re-reading the same files hoping to spot it; get the crash log instead.
- **Mac-synced crash logs as evidence for THIS bug**: the only synced logs are iPhone v1.0.40 and show the artwork-isolation crash fixed in v1.0.41. Useful family-of-bug hint, but NOT proof of the iPad v1.0.48 crash.

## Key Decisions

| Decision | Rationale |
|----------|-----------|
| Following superpowers:systematic-debugging | No fix until root cause confirmed by a crash log |
| Prioritize bitdrift / device log over more code reading | Code audit exhausted; need evidence |

## Current State

**Working**: repo clean at v1.0.48; nothing changed this session (no code edits made).

**Broken**: iPad crash unreproduced locally, root cause unconfirmed.

**Uncommitted Changes**: none (this HANDOFF.md only).

## Files to Know

| File | Why It Matters |
|------|----------------|
| `ios/PatataTube/Sources/VideoGridView.swift` | Tap entry: `play()` (line ~223) — cached→direct play; library+!done→`ensureReady()` w/ "Preparing…" overlay; else direct play. Queue snapshot in `startPlayback()` |
| `ios/PatataTube/Sources/VideoPlayerView.swift` | `setup()` (~94): audio session, `playerItem()` (cached MP4 → HLS → direct MP4), `applyAudioSelection`, `NowPlayingManager.attach`, `loadArtwork()` |
| `ios/PatataTube/Sources/NowPlayingManager.swift` | Lock-screen integration. `makeArtwork` (line ~85) is the *fixed* concurrency-safe artwork provider (fix commit `9ae72ea`, shipped v1.0.41) |
| `ios/PatataTube/Sources/PatataTubeApp.swift` | bitdrift `Logger.start` — remote crash reporting lead |
| `~/Library/Logs/CrashReporter/MobileDevice/iPhone 16e/Retired/PatataTube-*.ips` | Old v1.0.40 crash logs (artwork bug). Parse with `json.loads` per line (header line + body line) |

## Code Context

Crash-log parsing snippet used (works on `.ips`):

```python
import json
hdr, body = open(f).read().split('\n', 1)
hdr, body = json.loads(hdr), json.loads(body)
body['faultingThread']; body['threads'][i]['frames']; body['usedImages'][idx]['name']
```

Repro semantics (from user):
- "unconverted video" tap → `play()` takes the `ensureReady` branch (library row, status != "done") → long "Preparing…" overlay → by the time real playback happens, startup work (e.g. `store.bootLoad()` refresh, first `initialLoad`) has finished. This is why "tap unconverted first" masks the crash → points at a **race between startup loading and first player presentation**.

## Resume Instructions

1. Check bitdrift for the iPad crash: app API key is in `PatataTubeApp.swift`. Look for a bitdrift dashboard/CLI the user has access to; ask user for dashboard access if needed.
2. If bitdrift dead end, ask user to share iPad log: Settings → Privacy & Security → Analytics & Improvements → Analytics Data → files named `PatataTube-…ips` → AirDrop to Mac. Then parse with snippet above.
3. Verify iPad app version (crash log header `app_version`). If < 1.0.41 → root cause is the known artwork bug; fix = update AltStore source / reinstall.
4. If ≥ 1.0.47: symbolicate the two `PatataTube` frames (dSYMs should be produced by `./deploy` builds — check GitHub Releases artifacts for the .ipa/dSYM of that version).
5. Root cause confirmed → write failing test where feasible (PatataTubeKit: `cd ios/PatataTubeKit && swift build` / `swift test`), fix, then user-verify on device before release (`/deploy-ios` skill exists for shipping).

## Warnings

- CAVEMAN MODE hook is active in the user's sessions (terse replies) — technical content must stay complete.
- Failures in the backend delete video rows instead of marking `status=error` (see CLAUDE.md) — don't rely on error rows when reasoning about the children list.
- Crash logs' `bd-tokio` / `KSCrash_bitdrift` threads are bitdrift SDK internals — noise, not the app's own code.
- The 4 crash logs at 13:20:58–13:21:16 (v1.0.40) are a ~20s crash loop — consistent with "crashes right after open" but on the *old* version; don't treat as current evidence.
