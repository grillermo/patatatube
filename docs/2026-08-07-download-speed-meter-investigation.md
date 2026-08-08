# Download speed meter stuck at 0.0 MB/s — investigation

**Date:** 2026-08-07
**Shipped in:** iOS v2.0.8 (instrumented / `DEVLOG`), commits `81c80d4` (fix) and `418855a` (release)
**Feature plan:** `docs/superpowers/plans/2026-08-07-download-speed-meter.md`
**Status:** root cause found and fixed; **fix not yet confirmed on device**, and tests are written but **not run**.

## Symptom

The Downloads view's "In Progress" header rendered `0.0 MB/s` permanently while
real downloads were running. Note that the readout *appeared* — it was not
`nil` — which already narrowed things down: `DownloadSpeedMeter.formattedRate`
only returns a string once it holds ≥ `minimumSpan` (1 s) of samples. So the
0.25 s timer, the `.onReceive`, and the `@State` meter were all working, and
the number they were dividing was flat.

## Root cause

`ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager+HLS.swift` reports its
progress in **permille units, not bytes**:

```swift
beginExternalActivity(key: key, videoId: id, versionId: versionId, totalUnits: 10_000)
…
updateExternalActivity(key: key, completedUnits: Int64(completed * 10_000 / total))
```

`CacheManager.updateExternalActivity` then stored `completedUnits` straight into
`DownloadActivity.transferredByteCount`. Offline HLS is *the* download path for
Plex library items, so an entire movie contributed at most **10 000** to
`CacheManager`'s cumulative byte counter. `DownloadSpeedMeter` divided roughly
10 kB over a 5 s window — about 0.002 MB/s — and `String(format: "%.1f")`
rendered that as `0.0`.

The plan's Global Constraints said the counter covers "MP4, segmented, and HLS
asset fetches", assuming all three feed byte counts. Two of the three do. HLS
feeds an abstract progress unit, and nothing in the type system distinguished
the two — `transferredByteCount` was simply being used for both meanings.

## Fix

Progress and transferred bytes are now separate arguments:

```swift
func updateExternalActivity(key: String, completedUnits: Int64, transferredByteCount: Int64)
```

`completedUnits` still drives `progress` (permille out of `totalUnits`);
`transferredByteCount` carries real cumulative network bytes. In
`CacheManager+HLS`, the download task group's element type became
`(String, Data, Int64)` where the third member is the bytes actually pulled off
the network for that asset — **a segment-cache hit reports 0**, so a reused
asset advances progress without inflating the meter.

Everything downstream was already correct and is unchanged: the
`InFlightActivities` subscript still derives the monotonic delta, and
`DownloadSpeedMeter` still just divides.

### Known imperfection

For HLS rows, `DownloadActivity.totalByteCount` still holds `10_000` units while
`transferredByteCount` now holds real bytes — the two fields no longer share a
unit on that path. It is invisible today because the Downloads rows render
`progress` only and nothing displays `totalByteCount`. If a future view shows a
"X MB of Y MB" label, this is what will bite; the clean fix is a separate
`totalUnits` field on the accumulator rather than overloading `totalByteCount`.

## Plan assumptions, validated

| Assumption | Verdict | How |
|---|---|---|
| The subscript wrapper catches `inFlight[k]?.record(…)` writebacks | ✅ | Standalone `swiftc` repro of the exact shape (class holding a struct with a get/set subscript, mutating call through optional chaining): `cumulative=250`. Swift does perform the get-modify-set through the setter. |
| Counter is monotonic; insert/remove transitions contribute 0 | ✅ | Code read + `registeringAnAlreadySeededDownloadDoesNotSpikeTheCounter` |
| `activeDownloads()` unaffected by the wrapper (`.values`) | ✅ | Code read |
| `byteCount:` is wired from `VideoGridView.swift:696`, not the `{ 0 }` default | ✅ | Code read; now also proven at runtime by the `downloads view appeared` record |
| `.onReceive` keeps the meter out of `TimelineView`'s render phase | ✅ | Code read |
| **In-flight byte counts are bytes on every path** | ❌ | **This was the bug.** HLS feeds permille. |

Worth noting for next time: the pre-existing `CacheManagerByteCounterTests`
exercised the counter exclusively through `beginExternalActivity` /
`updateExternalActivity` — the one path that was lying about its units — and
passed, because it asserted the same wrong assumption the production code made
(`completedUnits: 400` → `downloadedByteCount() == 400`). The tests encoded the
bug rather than catching it.

## Instrumentation added (all `DEVLOG`-gated)

Added while hunting the bug; kept, because it is what localises a stuck readout
to a specific layer next time.

- `InFlightActivities` — `writeCount`, `updateWriteCount`, `zeroDeltaCount`,
  `transitionCount` tallies, plus a `download` record on every insert/remove
  transition (rare enough to log unthrottled).
- `CacheManager.downloadedByteCount()` — logs the full counter snapshot plus
  per-path progress-callback tallies (`seg_progress_calls`,
  `ext_progress_calls`, `plain_progress_calls`) on every read. Only called at
  the meter's 0.25 s cadence while the Downloads view is open, so ~4 records/s.
- `CacheManager+HLS` — `hls asset stored` with `net_bytes`, `transferred`,
  `completed`.
- `DownloadSpeedMeter.diagnostics` — `(samples, span, oldest, newest)`.
- `DownloadsView` — a `speed tick` record per 0.25 s, and
  `downloads view appeared`.

The hot per-segment progress path is deliberately *not* logged per call; it is
counted instead, and the counters ride along with the 0.25 s reads. Logging
each `didWriteData` callback would flood the ring buffer and drop the records
that matter.

## How to verify on device

Install v2.0.8 through AltStore, start several downloads, open the Downloads
tab, then on the server:

```bash
jq -c 'select(.msg=="downloads view appeared")' log/ios.jsonl
grep '"msg":"hls asset stored"'  log/ios.jsonl | tail -20
grep '"msg":"byte counter read"' log/ios.jsonl | tail -20
grep '"msg":"speed tick"'        log/ios.jsonl | tail -20
```

Read them as:

- `downloads view appeared` — the real `byteCount` closure is wired, not the
  `{ 0 }` default the view falls back to in tests and previews.
- `hls asset stored` — `net_bytes` should be in the megabytes for media
  segments, and `0` only where the segment cache served the asset.
- `byte counter read` — `cumulative` should climb; `updates` should dominate
  `zero_deltas`. A flat `cumulative` while `ext_progress_calls` rises means the
  fix missed a path.
- `speed tick` — `rate` is `window_delta / span`. `shown: "-"` just means fewer
  than 1 s of samples so far, not a failure.

## Open follow-ups

1. **Ship a clean build over v2.0.8** (`./deploy patch`). The AltStore source is
   currently serving an instrumented public release, and AltStore auto-installs
   it on the iPad.
2. **Run the tests.** They were written but deliberately not executed (see
   below). Coverage: `CacheManagerByteCounterTests` (new cases
   `unitProgressDoesNotStandInForTransferredBytes`,
   `progressWithoutNewBytesAddsNothing`,
   `writeTalliesDistinguishUpdatesFromTransitions`) and `CacheManagerHLSTests`
   (signature change at line 864).
3. Consider the `totalByteCount` unit mismatch described above.

## Two environment gotchas hit during this session

- **`swift test` must not be run behind a `cd`.** The rtk hook rewrites
  `cd X && swift test` into `rtk swift test`, which hangs producing no output at
  all — no compiler processes, empty log. Use
  `swift test --package-path ios/PatataTubeKit …` instead. Several apparently
  "slow" runs were actually this.
- **Do not run the iOS tests unless explicitly asked.** Now recorded in
  `CLAUDE.md`. They take many minutes on this machine and starting them is the
  user's call.
