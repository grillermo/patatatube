# Bounded Download-All — Design

**Date:** 2026-07-31
**Status:** approved, ready for planning
**Related:** `docs/superpowers/specs/2026-07-31-ffmpeg-job-queue-design.md` (ships first)

## Problem

`VideoGridView.downloadAll` (`ios/PatataTube/Sources/VideoGridView.swift:347`) snapshots
every not-yet-cached video and spawns one task per video with no bound:

```swift
await withTaskGroup(of: Void.self) { group in
    for video in targets {
        group.addTask { await download(video) }   // 226 tasks, all at once
    }
}
```

Its comment claims "the CacheManager gate bounds how many actually download at
once." That is false for library rows. `download(_:)` calls
`store.ensureReady(id:)` → `POST /api/videos/{id}/prepare` *before* reaching
`CacheManager.download`, which is where the gate is acquired
(`CacheManager.swift:459`). Everything before the gate is unbounded.

On 2026-07-31 this fired 226 simultaneous `/prepare` calls. Each queued a
`BackgroundTask` ffmpeg conversion on the server; ~124 ffmpeg processes started
within one minute against 8 cores and 16 GB RAM, and the machine stopped
responding to SSH.

The ffmpeg job queue fixes the server: conversions are now capped at
`FFMPEG_JOB_LIMIT` (default 1). This spec covers what remains on the client.

## What remains after the server is fixed

With the server capped, 226 unbounded client tasks still cause:

1. **iPad memory.** 226 live Swift tasks plus their URLSession requests, on a
   device that already has OOM watchdog kills on record (PATATATUBE-6, and the
   `MemoryProbe` instrumentation added to chase them).
2. **Poll flood.** `VideoStore.ensureReady` (`VideoStore.swift:249`) polls
   `GET /api/videos/{id}` every 2 s until *that* video reports `done`, with no
   timeout. 226 loops is ~113 req/s, sustained for as long as the queue takes to
   drain — which, at one conversion at a time, is on the order of days.
3. **UX.** Nothing warns that Download-all on the `all` filter means hundreds of
   gigabytes onto a device that cannot hold them, and there is no way to
   estimate the cost before tapping.

## Goals

- No user action spawns more than `maxConcurrentDownloads` in-flight
  prepare+download operations.
- Download-all on a large set asks for confirmation, showing what is about to
  happen and how much room the device has.
- The bounded-window guarantee is covered by a real test.

## Non-goals

- Any server-side change. The job queue owns that.
- Free-space *enforcement* (halting a drain when the disk fills). Only the
  advisory number in the dialog is in scope.
- Reworking `CacheManager`'s existing `DownloadConcurrencyGate`. It correctly
  bounds transfers; it was never meant to bound prepares.

## Approach

A shared bounded-task-group helper in `PatataTubeKit`, used by both
Download-all call sites.

Two approaches were rejected:

- **Inline sliding window in the view.** ~8 lines, no new API, but the
  assertion that matters — "never more than N in flight" — is a concurrency
  assertion, and the app target has no test target. Untestable.
- **Expose `CacheManager`'s gate** via `withDownloadSlot { }`. Genuinely one
  semaphore, so the misleading comment becomes literally true. But
  `CacheManager.download` acquires the same gate internally, so three nested
  acquires on a limit-3 gate deadlocks. Avoiding that needs a parallel un-gated
  download path — a worse invariant than the one being fixed.

## Components

### `BoundedTaskGroup.swift` (new, PatataTubeKit)

```swift
@MainActor
public func withBoundedTaskGroup<T: Sendable>(
    limit: Int,
    over items: [T],
    operation: @escaping @MainActor @Sendable (T) async -> Void
) async
```

Sliding window over `withTaskGroup`: seed `min(limit, items.count)` tasks, then
on each completion seed the next. `limit` clamps to `>= 1`. Honours cooperative
cancellation — a cancelled parent stops seeding new work; already-running
operations are left to finish or cancel themselves.

The isolation annotations are forced by Swift 6 language mode
(`swift-tools-version: 6.0`, `SWIFT_VERSION: "6.0"`): `@MainActor` because both
call sites are MainActor-isolated views, `@Sendable` because
`TaskGroup.addTask` requires it.

### `DeviceStorage.swift` (new, PatataTubeKit)

```swift
public enum DeviceStorage {
    public static func availableBytes(at url: URL) -> Int64?
}
```

Wraps `URLResourceValues.volumeAvailableCapacityForImportantUsage`. `DevLog.swift:76`
already reads this key, but that call site is compiled out unless `DEVLOG` is
set, so it cannot be reused. Returns `nil` on failure rather than throwing.

### `VideoGridView` (modified)

`downloadAll` gains a confirmation step and the bounded window:

```
tap Download all
  → targets = filteredVideos.filter { cache.state(...) == .notCached }
  → targets.isEmpty ? no-op
  → alert: "Download N videos?" / "X GB free on this iPad." / [Cancel] [Download]
  → confirm → withBoundedTaskGroup(limit: cache.maxConcurrentDownloads,
                                   over: targets) { await download($0, bulk: true) }
```

The bound is read at tap time from `model.cache.maxConcurrentDownloads` — the
existing 1–4 Settings slider (`SimultaneousDownloadSettings`, default 3). One
knob, and it matches what the transfer gate would allow anyway, so no task sits
idle holding a poll loop open.

### `EpisodesView` (modified)

`downloadEligibleEpisodes` (`EpisodesView.swift:84`) is currently serial — a
plain `for … await onDownload(episode)`, one at a time. It was never part of the
outage. It changes to the same bounded window at the same limit, so a season
downloads 3 at a time when the slider says 3. This is a speedup, not a fix.

No confirmation dialog here: a single show is a deliberate, small, bounded
choice.

### Closure isolation ripple

`EpisodesView`'s `onDownload` is a stored property, so passing it into a
`@Sendable` task-group body requires it to be `@MainActor @Sendable`. That
changes three declarations:

- `ShowsView.swift:9` — `let onDownload: (Video) async -> Bool`
- `EpisodesView.swift:25` — same
- `EpisodesView.init` — the matching parameter

`VideoGridView.download` is a method on a `Sendable` View struct, so the origin
needs nothing. Mechanical, but real, and worth budgeting for.

## Behaviour details

### Re-check eligibility at seed time, not snapshot time

Both call sites filter on cache state. With a bounded window, an item can sit
queued for minutes while its cache state changes underneath it. The filter must
be re-evaluated as each item is seeded, not once up front, or a video that
finished downloading while queued gets downloaded again.

The dialog's count is necessarily a snapshot — it is an estimate shown to a
human, and a small drift between "226" and what actually runs is acceptable.

### `downloadAll` ignores the search box (existing bug, fixed here)

`downloadAll` filters `store.videos` (`VideoGridView.swift:352`), but its own doc
comment says "every not-yet-cached video currently in view (respects the active
filter)", and the grid renders `filteredVideos` (`VideoGridView.swift:58`), which
also applies the search text. Today, searching "bear" and tapping Download all
downloads all 226, not the 8 on screen.

Silent and survivable while nothing announces a count. Once the dialog says
"Download 226 videos?" over a screen showing 8, it becomes a visible lie. The
fix is to filter `filteredVideos`.

## Error handling

- **Free-space read fails** → dialog drops the free-space line and still shows
  the count. Never blocks the action.
- **Per-video failure** → unchanged. `download` catches, sets `store.errorText`,
  returns `false`. One failure does not stop the group.
- **Cancellation** → leaving the view cancels the parent task, and the window
  stops seeding. In-flight transfers remain `CacheManager`'s business.

## Testing

Package tests only — the app target has no test target, which is why the logic
lives in `PatataTubeKit` in the first place. This is the same reason
`EpisodesView` already hoists `hasEligibleEpisode` / `downloadEligibleEpisodes`
into testable statics.

`BoundedTaskGroupTests`:
- peak concurrency never exceeds `limit` (actor-tracked high-water mark)
- every item runs exactly once
- `limit: 0` clamps to 1
- empty input returns immediately
- a cancelled parent stops seeding

`DeviceStorageTests`:
- returns a positive value for a real temporary directory
- returns `nil` for a bogus URL

The bounded-window guarantee is proved once, in `BoundedTaskGroupTests`. Both
call sites inherit it; neither is tested directly, and no plan should claim
otherwise.

Run both configurations per `CLAUDE.md`:

```bash
cd ios/PatataTubeKit && swift test
cd ios/PatataTubeKit && swift test -c release
```

## Manual verification

With the converter running and the job queue deployed, tap Download all on the
`all` filter and confirm:

- the dialog reports a count matching the visible grid, plus free space
- `grep '\[job\]' log/backend.log` shows queue depth rising to the target count
- no more than `maxConcurrentDownloads` prepare/poll pairs are in flight, via
  `jq -c 'select(.kind=="download")' log/ios.jsonl` and the gate gauge
- `pgrep -fc ffmpeg` stays at 1
