# Unified range download — play partially-downloaded videos immediately

Date: 2026-07-25
Scope: iOS (`ios/PatataTubeKit`, `ios/PatataTube`). No backend change.

## Problem

Start a download, watch the ring climb to 40%, hit play — the player still buffers from
zero. None of the downloaded bytes are used.

Two independent causes:

1. **The downloaded bytes are not on disk in a readable form.** `SegmentedDownload` splits
   the file into up to 4 ranges and downloads each with a `URLSessionDownloadTask`. A
   `segment-N.part` file only appears when that whole segment *finishes*
   (`CacheManager.swift:1220-1226` moves URLSession's private tmp file into place). At 40%
   overall progress, with 4 segments each 40% done, **zero** `.part` files exist. The bytes
   live inside URLSession's tmp files, unreadable by anything else.
2. **Even if they were readable, playback wouldn't look.** `VideoPlayerView.playerItem`
   uses the local file only when `state == .cached` (fully assembled). Otherwise plain MP4
   playback goes through `CaptureManager`/`RangeFetcher`, which keeps its *own* sparse
   partial (`.downloads/<key>/capture.part`) — a different file from the segment parts.

So the app maintains two unrelated partial-byte stores and neither can read the other's.

Scope decision: this targets **plain MP4 videos** (twitter/youtube rows). Library movies
play via remote HLS and are out of scope for the playback-reuse benefit, though they share
the rewritten download path.

## Approach

One writer-owner per video: `RangeFetcher`. Downloads and playback capture become the same
mechanism writing the same sparse file, so bytes are shared in both directions by
construction rather than by a synchronisation layer.

Rejected alternative: keep `SegmentedDownload` and teach the player to read completed
`.part` files. To make that useful, segments must shrink to small fixed chunks (so
completions accumulate), which is most of the cost of the rewrite — while still leaving two
partial stores that duplicate bytes whenever a video is both downloading and playing.

`.default` URLSession is already in use (not a background session), so no background-transfer
capability is lost.

## Architecture

### Shared fetcher registry

The `fetchers: [String: RangeFetcher]` registry moves out of `CaptureManager` into a small
type owned by `CacheManager`, keyed on the existing `videoId[:versionId]` cache key. Both
`captureAsset(...)` and `download(...)` resolve the *same* actor instance for a key.
`CaptureManager` keeps `keysByCaptureURL` and the `AVAssetResourceLoaderDelegate` work; it
asks the registry for fetchers instead of owning them.

### `RangeFetcher.fetchAll(concurrency:)`

New method, a parallel generalisation of the existing `finalize(destination:)`:

- Compute `CapturedRanges.complement(of: capturedRanges, over: totalByteCount)`.
- Emit gap chunks of 4 MiB in ascending byte order into a bounded worker pool of
  `concurrency` workers (1–4, from the existing `streamCount` setting).
- Each worker calls the existing `data(for:)`, which fetches, writes to the sparse file,
  and records the range in the manifest.
- When `manifest.isComplete`, `publish(cacheKey:to:)` moves the partial to `localURL`.

Ascending order means byte 0 lands first. Every served MP4 is `+faststart` (guaranteed by
the backend's `_normalize_media_for_ios`), so the `moov` atom is at the head and the player
can start immediately off disk.

### Playback needs no new code

The resource loader already routes every content-info and data request to the fetcher for
that key. `data(for:)` already serves fully-captured ranges from disk and only hits the
network for gaps. Once the downloader writes into that same manifest and file, a
mid-download play reads whatever has landed and fetches only the holes.

### Both directions, and both at once

The requirement is symmetric, and unification satisfies both halves with the same code:

- **Download → play.** Bytes fetched by `fetchAll` are in the manifest, so the resource
  loader serves them from disk. Play starts immediately.
- **Play → download.** Bytes fetched by the resource loader are in the *same* manifest, so
  a later `fetchAll` sees them as captured and requests only the complement. Watching half
  an uncached video leaves the download 50% done; tapping download then transfers the
  remaining 50%.

The second half only holds if watch-capture is genuinely progressive, and it is: the loader
streams each `AVAssetResourceLoadingRequest` in 1 MiB sub-chunks, recording each into the
manifest as it lands, rather than one write at request completion. Seeking produces holes
rather than lost work — `CapturedRanges.complement` handles a non-contiguous set, so a
sought-around watch resumes correctly, just with less captured.

**Both writers active on one key** (playing an uncached video, then tapping download) is a
supported state, not a race to avoid: one actor, one manifest, one sparse file. Two rules
keep it well-behaved:

- The reentrancy fix below is what makes concurrent captures safe to record. Without it this
  case silently loses ranges.
- While a capturing asset is attached to a key, `fetchAll` runs at concurrency 1 so the
  background transfer cannot starve the playhead's own gap fetches. It returns to the full
  `streamCount` when playback detaches.

Overlapping fetches of the same bytes are harmless (identical content, idempotent writes at
fixed offsets); no locking beyond the actor is needed.

### Prerequisite bugfix: reentrancy in `data(for:)`

`data(for:)` snapshots `var m = manifest`, awaits the network, then writes `m.capture(range)`
back into `self.manifest`. Actor methods are reentrant across `await`, so two concurrent
callers each hold a pre-await snapshot and the later write **clobbers the earlier caller's
captured range** — bytes on disk, absent from the manifest, silently re-downloaded.

Today this is nearly unreachable (playback requests are effectively serial). Approach A
makes concurrency the normal case: N workers plus the player, all on one actor. Fix by
re-reading `self.manifest` after the await and inserting into the current value. This lands
first, with its own regression test.

### Deleted

`SegmentedDownload.swift`'s part/assemble/probe machinery, `SegmentedAttempt`, the
`resumeData` plumbing and `.resume` files, the `assemblyURL` whole-file copy pass, and
`CacheManager`'s `URLSessionDownloadDelegate` conformance. `DownloadByteRange` and
`CapturedRanges` survive — they are the shared vocabulary.

Resume becomes "the manifest's complement", which is strictly more precise than opaque
resume data.

## Lifecycle and state

- `download(...)`: resolve the shared fetcher → `loadContentInfo()` (the existing 1-byte
  probe yields length + strong ETag) → register the `inFlight` accumulator →
  `fetchAll(concurrency: streamCount)` → publish → record completion history → clear the
  progress mirror.
- `onProgress` changes from `(Double)` to `(capturedBytes: Int64, total: Int64)` so
  `DownloadActivityAccumulator.record` can compute speed and ETA. The capture path today
  calls `overrideProgress`, which shows no rate; unifying gives both paths a real ETA from
  one source.
- `resumeInterrupted()` collapses to: scan `capturedStore.manifests()`, skip keys already
  cached, restart `fetchAll` on the rest. App suspension now loses at most one in-flight
  4 MiB chunk per worker instead of a whole segment.
- `capturedManifestProgress` stays as the render-cheap in-memory mirror behind
  `state(for:)`, now fed identically by both paths.
- ETag mismatch on resume discards the partial and restarts from zero (existing
  `loadContentInfo` behaviour, unchanged).

### Cancel keeps bytes

`cancel(id:versionId:)` stops the workers and **leaves the partial and manifest on disk**.
Re-tapping download resumes from the manifest gaps. This is the point of the feature: a
precise manifest makes discarding gigabytes of transfer indefensible.

Library and HLS videos share the rewritten download path. The `isEligibleForCapture: false`
gate stays exactly as it is — it blocks *passive* watch-capture (whose partial would never
finalise), not explicit download, which always finalises to `localURL`.

## UI

- New `CacheState.paused(Double)`: a manifest exists on disk, no live workers, not cached.
  It covers cancelled downloads and also the partials left behind by watch-capture — today
  those report `.downloading` forever with no way to clear them, so this fixes an existing
  orphan-state bug as a side effect.
- `DownloadButton` gains a `.paused` case: partial ring plus `arrow.down.circle`; tap
  resumes. Deleting the partial reuses the arm-then-confirm gesture already implemented for
  `.cached` (tap → red `x.circle.fill` → tap deletes). No new interaction vocabulary, no
  long-press.
- `.downloading`, `.cached`, `.notCached` cases unchanged.

## Testing

`PatataTubeKit` builds standalone (`swift build`), and `CapturedRanges` /
`SegmentedDownload` already have unit-test precedent. Network is stubbed via `URLProtocol`.

1. `CapturedRanges` insert/complement — extend existing coverage for concurrent inserts.
2. **Reentrancy regression**: two concurrent `data(for:)` calls on disjoint ranges; assert
   both ranges appear in the manifest. Must fail against today's code; written first.
3. `fetchAll` resume: seed a manifest with holes; assert only gaps are requested (stub
   records `Range` headers), the file is byte-identical to the source, and it is published
   to `localURL`.
4. Byte sharing: after `fetchAll`, request a captured range and assert zero network
   requests.
5. Cancel/resume: cancel mid-`fetchAll`; assert manifest and partial survive and
   `state(for:)` is `.paused(p)`; resume and assert completion.
6. ETag change between sessions discards the partial and restarts from 0.
7. `DownloadButtonTests` covers the `.paused` case, following existing patterns in that
   file.
8. **Play → download**: drive the resource loader over the first half of a file, then run
   `fetchAll`; assert the stub sees requests covering only the second half, and the
   published file is byte-identical to the source.
9. **Sought-around watch**: capture two disjoint middle ranges, then `fetchAll`; assert the
   three complement gaps are requested and nothing else.
10. **Both writers at once**: run `fetchAll` while serving loader requests on the same key;
    assert no manifest range is lost, the file is byte-identical, and `fetchAll` ran at
    concurrency 1.

Manual (per `ios/README.md`), both directions:

- Download a large MP4 to roughly 30%, hit play — playback starts with no spinner and the
  percentage keeps climbing.
- Play an uncached MP4 through roughly half, exit — the cell shows a paused ring near 50%.
  Tap download — it completes from there rather than restarting.

## Risk

This replaces a load-bearing, heavily hardened downloader. The retry, cancel-fence and
segment-recovery logic in `CacheManager` exists because those edge cases bit in production.
The replacement is substantially smaller but has to re-earn that hardening; expect the
rewrite, not the feature itself, to be the bulk of the work. The cancellation fence and the
global `DownloadConcurrencyGate` are retained as-is.
