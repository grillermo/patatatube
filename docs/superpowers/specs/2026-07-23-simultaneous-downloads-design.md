# Configurable simultaneous downloads (iOS)

## Goal

Let the user configure how many videos download at once, default 3. This is
distinct from the existing "Streams per video" setting (multiplexing = parallel
byte-range segments *within* a single video). The new setting caps concurrency
*across* videos.

## Terminology

| Setting | Key | Range | Default | Meaning |
|---|---|---|---|---|
| Streams per video (existing) | `downloadStreamCount` | 1–4 | 2 | Parallel byte-range segments within one video |
| Simultaneous downloads (new) | `simultaneousDownloadCount` | 1–4 | 3 | How many videos download at once (global cap) |

Total open connections ≈ simultaneous × streams-per-video (worst case 4×4 = 16).

## Current state

- `downloadAll()` (`VideoGridView.swift`) iterates videos **sequentially**
  (`await download(video)` one at a time).
- Individual tap downloads each spawn their own `Task` → **unbounded**
  concurrency.
- No single knob governs cross-video concurrency today.

## Design

### 1. Setting storage

New struct `SimultaneousDownloadSettings`, mirroring `DownloadStreamSettings`
exactly:

- `static let key = "simultaneousDownloadCount"`
- `static let defaultCount = 3`
- `static let allowedCounts = 1...4`
- `init(defaults: UserDefaults = .standard)`
- `load() -> Int` — returns default when unset; otherwise clamps stored value
  into `allowedCounts`.
- `save(_ count: Int)` — clamps then persists.

`AppModel`:
- Holds `downloadConcurrency: Int`, injected `SimultaneousDownloadSettings`
  (default arg, like `downloadSettings`).
- Loads `downloadConcurrency` from the setting in init.
- In `saveSettings()`: clamp `downloadConcurrency` into `allowedCounts`, save it,
  and push the value to the cache gate (`cache.setMaxConcurrentDownloads(_:)`).
- Also push the loaded value to the gate once during init.

### 2. Concurrency gate in CacheManager (PatataTubeKit)

Add a FIFO counting async-semaphore `DownloadConcurrencyGate`:

- Backed by a lock + `permits: Int` + FIFO array of
  `CheckedContinuation<Void, Never>` waiters.
- `acquire() async` — if a permit is available, take it and return; else append a
  continuation and suspend. Waiters resume in enqueue order (FIFO).
- `release()` — if waiters queued, resume the head waiter (permit handed off
  directly); else increment `permits`.
- `setLimit(_ n: Int)` — adjust max permits. Raising frees the delta by resuming
  that many waiters (or crediting permits). Lowering reduces the ceiling for
  *future* acquisitions only; never cancels or preempts in-flight downloads.

Gate lives on `CacheManager`. Public surface:
- `public func setMaxConcurrentDownloads(_ n: Int)` → forwards to gate.
- Default limit at construction = 3 (matches setting default, so behavior is
  sane before AppModel pushes a value).

Integration in `CacheManager.download(...)`:
- `await gate.acquire()` at the top of the public `download(...)` entry.
- `defer { gate.release() }` so the slot is returned on success, thrown error,
  and cancellation.
- One slot covers the whole per-video body (probe + segmented transfer +
  best-effort preview/poster). One video = one slot regardless of its internal
  `streamCount`.

### 3. UI

`SettingsView` "Downloads" section: add a second `Stepper` below "Streams per
video":

```
Stepper(value: $model.downloadConcurrency,
        in: SimultaneousDownloadSettings.allowedCounts) {
    LabeledContent("Simultaneous downloads",
                   value: "\(model.downloadConcurrency)")
}
```

Queued (waiting-for-slot) downloads reuse the **existing** 0% progress ring: a
tapped `.notCached` button immediately calls `state.begin()` →
`.downloading(0)`, so a queued download already renders as a 0% ring until its
slot frees and real progress arrives. **No new `CacheState` case**; no changes to
`DownloadButton` `effectiveState`/`cacheControl` switches or their tests.

### 4. downloadAll() fan-out

Replace the sequential `for … { await download(video) }` loop with concurrent
fan-out (e.g. a `TaskGroup` / spawning child tasks for each not-cached video).
The gate bounds real concurrency to the configured limit, so fan-out is safe and
actually exercises the cap. `downloadingAll` stays true until all child tasks
finish. Same treatment for the "Cache all videos" loop in `SettingsView`.

## Known limitations (v1)

- `resumeInterrupted` starts `URLSession` tasks directly, bypassing the gate.
  Naturally bounded: only downloads that had actually started leave resume data;
  queued-but-never-started videos have no tasks/resume files and won't resume.
  Left ungated in v1.

## Testing (PatataTubeKit)

- `DownloadConcurrencyGate`:
  - Cap enforcement — no more than N concurrent holders.
  - FIFO — waiters resume in enqueue order.
  - Permit release on the holder throwing / being cancelled.
  - `setLimit` raise wakes waiters; lower throttles only new acquisitions.
- `SimultaneousDownloadSettings`: load default when unset, load clamps
  out-of-range stored values, save clamps.
- Optional integration: `CacheManager` honors `setMaxConcurrentDownloads` (guard
  against regressions in the `download` acquire/defer wiring).

## Out of scope

- Per-download priority / reordering the queue.
- Persisting the queue across app launches.
- Gating `resumeInterrupted`.
