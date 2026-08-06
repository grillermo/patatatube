# HLS stream caching (read-through) — design

**Date**: 2026-07-25
**Scope**: iOS app only (`ios/PatataTubeKit`, `ios/PatataTube`) plus small backend additions.

## Problem

Streaming and offline download use two different formats today, so no byte is
shared between them:

- Online playback uses the server's HLS package (`/videos/{id}/hls/master.m3u8`)
  — chosen because it exposes native subtitle tracks and the audio picker in the
  AVKit controls (`VideoPlayerView.swift:218`).
- Offline playback uses a separately downloaded MP4 (`/videos/{id}/stream` with
  HTTP Range), captured by `RangeFetcher`/`CaptureManager` into
  `videos/{id}.mp4`.

Watching a video therefore downloads its bytes twice: once as HLS segments that
are discarded, once as an MP4 when the user taps Download.

The existing MP4 layer already does true read-through caching (non-contiguous
range tracking, concurrent read/write, download-fills-holes, atomic publish).
The gap is that it cannot be applied to HLS: `AVAssetResourceLoader` is not
invoked for HLS **media segments** — only for playlists and encryption keys — so
the `ptcapture://` interception trick cannot see segment traffic.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Surface | iOS only | Native app is where offline playback matters. |
| Interception mechanism | Apple's `AVAssetDownloadURLSession` | No local HTTP proxy (explicitly ruled out). Playing `task.urlAsset` makes player and downloader share one AVFoundation-managed store, giving reuse in both directions. |
| Offline artifact | HLS `.movpkg` for every video | Only format that shares bytes with HLS playback. Bonus: subtitles + audio picker work offline too. |
| MP4 capture stack | Deleted | ~800 src lines + ~2600 test lines removed. Simpler architecture chosen deliberately over a fallback path. |
| MP4 fallback for unpackageable videos | None | An MP4 fallback rescues fewer videos than it appears: for library rows `/stream` serves `converted_path or source_path`, and a source ffmpeg cannot package is often one the iPad cannot decode either. Replaced by explicit error + retry (below). |
| Auto-download rule | Fill-ahead task reaching 100% during a watch | No playhead bookkeeping; what is on disk is the truth. Skip-heavy watches leave a partial that a Download tap resumes. |
| Fill-ahead network | Wi-Fi only | Explicit Download taps may use cellular. |
| Temp cache cap | Configurable, default 10 GB, LRU | New row in `SettingsView` beside the existing download settings. |

## Architecture

All new units live in `ios/PatataTubeKit/Sources/PatataTubeKit/`.

| Unit | Job | Depends on |
|---|---|---|
| `HLSAssetStore` | Disk bookkeeping only: the cache index. No AVFoundation import. Fully unit-testable. | Foundation |
| `HLSDownloadEngine` | Owns the single `AVAssetDownloadURLSession` (background config, fixed identifier, `allowsCellularAccess = false` for fill-ahead). Creates one `AVAggregateAssetDownloadTask` per video with media selections (video + chosen audio + all subtitle renditions). Emits `(cacheKey, fractionComplete)` and terminal events. `start` / `cancel` / `restoreTasksOnLaunch`. Hidden behind a protocol so callers can be tested with a fake. | AVFoundation, `HLSAssetStore` |
| `PlaybackAssetProvider` | Chooses the asset for playback (truth table below). This is where read-through happens: handing back `task.urlAsset` means the player reads downloaded segments off disk and only holes hit the network. | engine, store |
| `CacheEvictor` | LRU over `temp` entries against the cap. Never touches `permanent` or in-flight keys. Pure logic + injected deleter. | store |
| `CacheManager` | Keeps its current public API; becomes a thin coordinator over the four units above. Preview/cover-image code untouched. | all |

### Deleted

`RangeFetcher`, `RangeFetcherRegistry`, `RangeFetcherLifetime`, `CaptureManager`,
`CapturedDownload` (manifest + store), `CapturedRanges`, `CacheManager.captureAsset`,
`CacheManager.finalizeCapture`, the `videos/{id}.mp4` cache directory, and these
test files: `CacheManagerRangeDownloadTests`, `CacheManagerCaptureStateTests`,
`CapturedDownloadManifestTests`, `CapturedDownloadStoreTests`, `CapturedRangesTests`,
`CaptureManagerSchemeTests`, `RangeFetcherTests`, `RangeFetcherFetchAllTests`,
`RangeFetcherFinalizeTests`, `RangeFetcherConcurrencyTests`, `RangeFetcherRegistryTests`.

## Data model

`Library/hls-cache/index.json`, written atomically on a single serialized queue
(same discipline as today's `CapturedDownloadStore.write`):

```swift
struct HLSCacheEntry: Codable, Sendable {
    let cacheKey: String          // "videoId" or "videoId:versionId" — existing scheme
    let videoId: Int
    let versionId: Int?
    var bookmark: Data            // resolves to the .movpkg AVFoundation created
    var kind: Kind                // .temp | .permanent
    var isComplete: Bool
    var fractionComplete: Double  // time-based, not bytes
    var byteCount: Int64          // size of the .movpkg, refreshed on task end
    var lastPlayedAt: Date
    var audioLang: String?        // audio track the package was built with
    enum Kind: String, Codable { case temp, permanent }
}
```

A bookmark, not a path: AVFoundation assigns the `.movpkg` location and the file
must not be moved. The index never assumes the file exists — iOS can purge these.

## State mapping

`CacheState` and every consumer (`DownloadButton`, `VideoGridView`,
`DownloadsView`) stay as they are:

| Disk / engine reality | `state(for:)` |
|---|---|
| entry `permanent` + `isComplete` | `.cached` |
| engine task running for key | `.downloading(fraction)` |
| entry exists, incomplete, no task | `.paused(fraction)` |
| no entry (or bookmark unresolvable) | `.notCached` |

Only two meanings change: `localURL(for:)` returns a `.movpkg`, and progress is a
time fraction rather than a byte count.

## Flows

**Play**: `VideoPlayerView` → `PlaybackAssetProvider` → whole-asset task started
(Wi-Fi) → play `task.urlAsset`. Delegate `didLoad(timeRange:totalTimeRangesLoaded:
timeRangeExpectedToLoad:)` drives progress into the existing
`inFlight`/`DownloadActivity` plumbing.

**Playback ends**: complete → `kind = .permanent`, `isComplete = true` (the
auto-download). Incomplete → cancel task, keep the `temp` partial, stamp
`lastPlayedAt`, run the evictor.

**Download tapped**: same engine, same cache key, resumes the existing partial so
only missing segments are fetched. Entry marked `permanent` up front; cellular
allowed for explicit taps.

**Offline play**: local `.movpkg`. A partial `temp` entry plays its downloaded
region; the missing region requires network.

**Invalidation**: `audioLang` change, or server `hls_status` leaving `done` →
delete the `.movpkg` and drop the index row. Segment numbering can shift across a
repackage, so a partial from a previous package is never trusted.

## Concurrency

`AVAssetDownloadURLSession` is one-per-identifier and must never be invalidated;
`CacheManager` holds it for the app lifetime. `setMaxConcurrentDownloads` becomes
a gate on how many aggregate tasks are resumed at once, reusing
`DownloadConcurrencyGate` unchanged. The current playback back-pressure window
(`RangeFetcher.playbackBackPressureWindow`) disappears: the fill-ahead task *is*
the playback fetch, and AVFoundation prioritizes within its own session.

## Backend changes

1. `hls.prepare` failure sets `hls_status = 'error'` plus a message instead of
   reverting to `'none'` (`hls.py:279-281`). Today's revert makes "not built yet"
   and "cannot build" indistinguishable, and every `master.m3u8` poll relaunches
   ffmpeg — a silent retry storm.
2. `serialize_video` exposes `hls_status` so the client picks its path
   deterministically instead of inferring from the presence of `hls_path`
   (`views/serializers.py:33-43` is a pure status check and never looks at disk).
3. `POST /api/videos/{id}/hls/rebuild` (token-gated): rmtree the package, reset
   status to `none`. Backs the client's Retry action.

## Error handling

| Case | Behavior |
|---|---|
| `hls_status == 'error'` | "Cannot package" + Retry (delete local entry, call rebuild). No download button, no spinner. |
| `hls_status` `none` / `converting` | Existing "Preparing…" overlay (`VideoGridView.play()` → `ensureReady`), extended to poll status. |
| Task fails mid-download (segments 404 after `hls.invalidate`) | Delete the local entry — partial is untrustworthy — and surface a retryable error through the existing `recentDownloads` completion history. |
| Device disk full | Cancel task, keep entry, run evictor, report error. Evictor also runs before starting a download when free space is low. |
| Bookmark unresolvable (OS purged the `.movpkg`) | Treat as `.notCached`, drop the index row. |
| App killed mid-download | Background session; `restoreTasksOnLaunch` reattaches via `getAllTasks` and reconciles the index with live tasks. |
| Server offline | Local entries play; no new tasks start. |

## Testing

Unit (`cd ios/PatataTubeKit && swift test`):

- `HLSAssetStore`: round-trip, atomic write, corrupt-index recovery, unresolvable
  bookmark, stale-`audioLang` invalidation.
- `CacheEvictor`: LRU order, cap boundary, never evicts `permanent`, never evicts
  in-flight, no-op under cap.
- `CacheManager.state(for:)`: the full truth table, with a fake engine and an
  in-memory store.
- `PlaybackAssetProvider`: asset choice across (entry kind × completeness ×
  network × `hls_status`).
- Promotion rule: complete-during-watch → `permanent`; incomplete → `temp` + cancel.

Backend (`python -m pytest tests/`): `hls_status='error'` on prepare failure,
`hls_status` present in `serialize_video`, rebuild endpoint auth + rmtree + reset,
and no re-trigger of packaging while status is `error`.

Manual, added to `ios/README.md` (the engine itself is not unit-testable):

- Watch a video to the end → it appears as downloaded, with no second download.
- Watch with skips, then tap Download → only the remainder transfers (verify in
  `log/backend.log`: no repeated segment requests).
- Airplane mode → a permanent entry plays, subtitles and audio picker present.
- Cap enforcement: exceed the configured size → oldest temp entry evicted,
  permanent entries survive.

## Rollout

0. **Spike (throwaway branch)** — confirm on device, before any production code:
   1. resuming a *cancelled* aggregate task reuses the partial `.movpkg` instead
      of restarting from zero;
   2. `task.urlAsset` playback while the task runs serves already-downloaded
      segments from disk;
   3. a partial `.movpkg` is playable offline for its downloaded region;
   4. aggregate task + subtitle media selections preserve AVKit's subtitle and
      audio pickers.

   Apple's documentation is thin on all four. If (1) or (2) turns out false, the
   no-proxy constraint and this design collide and the design is revisited before
   step 3.
1. Backend: status + serializer + rebuild endpoint, with tests. Ships
   independently and harmlessly.
2. `HLSAssetStore` + `CacheEvictor` + settings row, TDD, nothing wired yet.
3. `HLSDownloadEngine` + `PlaybackAssetProvider`; wire `CacheManager` behind its
   unchanged public API.
4. Delete the MP4 capture stack and its tests; `VideoPlayerView.playerItem()`
   collapses to two branches (local `.movpkg` → remote HLS).
5. One-shot first-launch cleanup of the orphaned `videos/*.mp4` cache directory.
6. Device verification against the manual checklist, then `/deploy-ios`.

## Spike findings (2026-07-26)

No physical iPad was available to run Task 0's device spike. These findings are
from Apple developer forum reports and Apple's own guidance instead of a
measured device run — **weaker evidence than a device test**. Device
verification stays required before shipping (Task 8 Step 7 / manual checklist).

1. **Cancelled-task resume**: **unresolved / likely restarts from 0**. Multiple
   Apple Developer Forum threads (e.g. threads 703666, 65602) report
   `AVAggregateAssetDownloadTask` has **no `resumeData` mechanism** — cancel()
   drops the task and Apple engineers have not documented a supported way to
   resume a *cancelled* aggregate task from its partial `.movpkg`. One developer
   claims cancel-then-recreate "picks up right where it left off"; another
   directly contradicts this ("task will be gone... starts from the beginning").
   Treat as **not resumable via a fresh task pointed at the same asset** absent
   proof otherwise.
   - This does not affect `restoreTasks()` (Task 4): background `URLSession`
     tasks that are still *running* (not explicitly cancelled) reattach fine
     across app suspend/relaunch per standard `URLSession` background-task
     semantics — that is a different code path from resuming a cancelled task.
   - Per the plan's own contingency: Task 4's `makeAsset(for:)` already
     constructs the resume attempt from the persisted local `.movpkg` bookmark
     URL rather than the remote master, which is the safer of the two options
     but is **not guaranteed by Apple docs** to actually skip already-downloaded
     segments. Real risk: manual checklist item "kill app mid-download,
     relaunch: progress resumes rather than restarting" may fail on device.
2. **`task.urlAsset` playback while downloading**: **works, and is Apple's
   documented pattern**. Apple's own sample/guidance explicitly recommends
   creating the `AVPlayerItem` from the download task's own `urlAsset` so
   AVFoundation shares state between playback and download. High confidence.
3. **Partial `.movpkg` offline playback**: **works but reported unreliable**.
   Multiple forum threads (e.g. thread 776053) report real-world problems:
   10-60s load delays, inconsistent playback, occasional "asset loss" on
   partially-downloaded offline content, with no fix from Apple beyond "try our
   sample code." Treat as **works in the common case, budget for a loading
   spinner / retry, and confirm on device** rather than assuming instant seek.
4. **Aggregate task media selections**: **works, well documented**.
   `AVAggregateAssetDownloadTask` is specifically designed to download multiple
   `AVMediaSelection`s (audio + subtitle renditions) in one task, and the
   resulting `AVAssetCache` exposes which selections are available offline.
   High confidence `allMediaSelections count > 1` and legible options survive
   offline for a multi-track master playlist.

**Net effect on the plan**: proceed with Tasks 1-8 as written — Task 4 and 6's
code already assume the conservative answers to (1) and (3) (local-URL resume
attempt, `.paused`/partial states rather than a guarantee of instant resume).
The two open risks (cancelled-task resume; partial-offline reliability) are
exactly the two items the manual checklist (Task 8 Step 5, items 6 and 8) is
designed to catch on real hardware before `/deploy-ios`. Do not skip that
device pass.
