# Watch-to-Cache (iOS) — Design

**Date:** 2026-07-25
**Scope:** iOS app only. Capture streamed bytes during playback so a full linear watch of a direct-MP4 video leaves it fully cached — identical on disk and in the UI to a manual download.

## Goal

When the user plays an uncached video that streams as a **direct MP4**, feed the AVPlayer from an intercepting resource loader that also writes every fetched byte to disk. On play-to-end, fill any byte ranges the player skipped, then atomically publish the assembled file to the existing cached-MP4 location. A half-watch persists a resumable partial; a later full watch completes it.

## Non-goals

- **HLS videos** (library/Plex rows with an `hls_path`) are out of scope. They keep streaming HLS and are never auto-cached. No native-subtitle regression, because the capturing path is only used where playback would already fall back to direct MP4.
- No change to the manual download button's behavior beyond sharing state (§5).
- No new server work — `/videos/{id}/stream` already emits strong `ETag`, `Accept-Ranges: bytes`, and 206 range responses (`router.py:466`, `_range_headers` at `:317`).

## 1. Trigger point

`VideoPlayerView.playerItem(for:)` keeps its branch order:

```
cached local file      → AVPlayerItem(localURL)         (unchanged)
library && != "done"   → nil                             (unchanged)
hlsURL present         → HLS asset                        (unchanged — no capture)
streamURL present      → CAPTURING asset                  (changed)
```

Only the final branch changes: instead of `AVPlayerItem(asset: authedAsset(streamURL))`, build a capturing asset via a new `CaptureManager` (see §2). Because HLS videos exit one branch earlier, only videos without an HLS package (the Twitter/X & YouTube rows) ever capture — exactly the "MP4-streamed only" scope.

The capturing asset is requested from `PatataTubeKit`, so the app shell stays thin: `model.cache.captureAsset(for: video, streamURL:, bearerToken:)` returns an `AVURLAsset` with its resource-loader delegate already wired.

## 2. CaptureManager + resource loader

New type in `PatataTubeKit`, one instance owned by (or alongside) `CacheManager` so it shares the `root`/`.downloads` directory and can register into `CacheManager`'s `inFlight` for unified state (§5).

### Asset construction

- Rewrite the real stream URL's scheme to a private scheme `ptcapture` so `AVAssetResourceLoaderDelegate` is invoked for every request. Keep the original URL (with `version_id` query + real https scheme) inside the loader to make network calls.
- Set the delegate on a dedicated serial queue. Auth is handled by the loader's own `URLSession` requests adding `Authorization: Bearer <token>` — not `AVURLAssetHTTPHeaderFieldsKey` (custom-scheme requests don't carry it).

### Loading requests

`resourceLoader(_:shouldWaitForLoadingOf:)` handles two request kinds:

1. **Content-information request** — issue one `bytes=0-0` probe (same shape the segmented downloader validates, `SegmentedDownloadStore.validateProbe`) to learn `totalByteCount` + strong `ETag`. Fill `contentLength`, `contentType = "public.mpeg-4"` (UTType.mpeg4Movie), `isByteRangeAccessSupported = true`. This ETag becomes the manifest's entity tag (§3).

2. **Data request** — for `[requestedOffset, requestedOffset+requestedLength)`:
   - Serve any sub-range already present on disk directly from the sparse file (`FileHandle`, chunked, no full-file buffering).
   - For gaps, issue an HTTP range `GET` (`bytes=start-end`) with the bearer header, validate `206` + matching `ETag` (reuse the segmented validators where practical), stream the body to the player **and** write it into the sparse file at the right offset, recording the range in the manifest.
   - Respect `dataRequest.requestsAllDataToEndOfResource`.

Multiple loading requests run concurrently; each owns its own network task. `resourceLoader(_:didCancel:)` cancels the task and finishes the request. All disk writes for one video funnel through a per-key serialized writer so overlapping ranges don't corrupt the file.

### Memory

Stream-to-disk only. Never hold a whole segment in memory; copy network→disk and network→player in bounded chunks (mirror `assemble`'s 1 MiB loop). Consistent with the app's memory sensitivity (`MemoryProbe`).

## 3. Manifest & resumable partial

The segmented downloader's manifest assumes a fixed N-way contiguous split — wrong shape for arbitrary player ranges. Introduce a sibling type instead of overloading it.

```
struct CapturedDownloadManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int          // start at 1
    let videoId: Int
    let versionId: Int?
    let remoteURL: URL              // real https stream URL
    let totalByteCount: Int64
    let etag: String                // strong ETag from the content-info probe
    var capturedRanges: [DownloadByteRange]  // sorted, coalesced, non-overlapping
    var cacheKey: String { versionId.map { "\(videoId):\($0)" } ?? "\(videoId)" }
}
```

- **Sparse file:** a single `{cacheKey}.capture.part` preallocated to `totalByteCount`, written at absolute offsets. Reuse the existing `.downloads/{cacheKey}/` directory convention so cleanup/clear paths already reach it.
- **Coalescing:** on each successful range write, merge into `capturedRanges` (union of intervals). Persist the manifest atomically (same `.write` pattern as `SegmentedDownloadStore`).
- **Progress:** `sum(capturedRanges.length) / totalByteCount`.
- **Resume:** reopening a partly-captured video loads the manifest; the loader serves captured ranges from disk and fetches only the complement. If the persisted `etag` no longer matches a fresh probe (server re-encoded the file), discard the partial and start fresh (§6).
- **Completion:** `capturedRanges == [0, total-1]` → assemble is a no-op rename (the sparse file *is* the whole file) → atomically move/replace into `localURL(for:id,versionId:)` → remove manifest/part. `state()` now returns `.cached`.

A `CapturedDownloadStore` mirrors `SegmentedDownloadStore` (write/load/manifests/remove) so `resumeInterrupted`, `clearAllVideos`, `removeAllCached`, and `removeCached` can enumerate and tear down capture state the same way they do segments.

## 4. Gap-fill on play-to-end

`VideoPlayerView` already observes `.AVPlayerItemDidPlayToEndTime` (`bindPlayToEnd`). Add a hook: when the item that ended was a capturing item and its manifest is incomplete, ask `CaptureManager` to **finalize** — compute the complement of `capturedRanges` over `[0,total)` and fetch those ranges (bearer + ETag-checked, bounded concurrency), writing them into the sparse file. On success, publish to `localURL` → `.cached`.

- Finalize is fire-and-forget from the view's perspective (no UI block); progress surfaces through `CacheState.downloading` until it flips to `.cached`.
- Gap-fill is bounded (a small internal concurrency, independent of the user-facing download-stream setting) and does **not** take the `concurrencyGate` (playback-initiated, not a queued download) — but finalize's extra fetches may take it to stay polite. (Decision recorded in the plan; default: ungated, low fixed concurrency.)
- Advancing to the next queue item (`advance`) does **not** cancel an in-flight finalize for the previous item.

## 5. Unified CacheState + dedup

One owner per `cacheKey` across manual download and capture.

- `state(for:)` gains a capture branch: cached file → `.cached`; else if a capture or download is registered in `inFlight[key]` → `.downloading(progress)`; else if a persisted capture manifest exists → `.downloading(manifestProgress)` (resumable partial shows progress even when idle); else `.notCached`.
- **Capture registers into `inFlight[key]`** on first byte, using the same `DownloadActivityAccumulator` shape so the grid ring, `activeDownloads()`, and Downloads page treat it identically.
- **Dedup rule — first writer wins the key:**
  - Manual `download()` sees an active capture (`inFlight[key]` owned by capture) → it **adopts** the existing partial: it can either wait on capture/finalize, or (simpler, chosen) cancel capture's passive mode and run its own segmented download over the same `.downloads` dir, reusing already-captured bytes if cheaply possible; at minimum it must not double-register `inFlight[key]`. **Chosen: manual download takes over** — cancels the capture loader's fetching, starts segmented download; captured ranges already on disk are a best-effort head start (segmented may refetch; acceptable).
  - Opening the player while a **manual download is in flight** → the player streams normally (still via the capturing asset for the served-from-disk benefit) but does **not** register a second `inFlight` entry; the manual download owns completion.
  - Only when `inFlight[key]` is empty does capture claim the key.
- Lock discipline follows `CacheManager`'s existing `lock.withLock` pattern; capture registration/deregistration is a critical section like segmented attempts.

## 6. Edge cases

- **File changed mid-watch / mismatched ETag:** any range GET returning a different strong ETag → abort capture for that session, discard the partial + manifest, let the player keep streaming (reissue as a plain fetch). Never publish a mixed-entity file.
- **Seek / skip:** produces gaps; handled by §4 finalize. If the user never plays to end, gaps persist as a resumable partial (§3).
- **Half-watch then close:** `onDisappear` tears down the player; the manifest + sparse file remain. No finalize runs (only play-to-end triggers it). Next open resumes.
- **App suspend/resume:** capture uses a `.default` `URLSession`; suspension cancels tasks. `resumeInterrupted` is extended to also re-hydrate `inFlight` progress from persisted capture manifests (it does not auto-fetch — capture is demand-driven — but a pending finalize is not auto-resumed in v1; the partial simply waits for the next watch). Documented limitation.
- **Server with no strong ETag or no range support:** the content-info probe fails validation → fall back to a plain, non-capturing `authedAsset` so playback still works. Capture is best-effort.
- **Disk pressure / write failure:** any write error aborts capture silently (partial discarded), playback continues from the network.

## Testing

`PatataTubeKit` is the testable core (`swift build`). Cover in unit tests against a stubbed `URLProtocol`/session:

- Content-info probe parses total + ETag; bad probe → non-capturing fallback signalled.
- Range write coalescing: overlapping/adjacent ranges merge to the minimal set; progress math.
- Serve-from-disk: a captured range is returned without a network call.
- Manifest persist/load/resume round-trip; ETag-mismatch discards the partial.
- Completion: contiguous full coverage publishes to `localURL` and flips `state()` to `.cached`; manifest/part removed.
- Finalize: given a manifest with gaps, complement ranges are computed and fetched; a partial-coverage finalize with a network failure leaves a resumable partial, not a corrupt cached file.
- Dedup: capture + manual download never double-register `inFlight[key]`; manual download takeover path.

No automated iOS UI target exists; the `VideoPlayerView` wiring (§1, §4 hook) is verified via the manual checklist in `ios/README.md`.

## Files touched (anticipated)

- `ios/PatataTubeKit/Sources/PatataTubeKit/CaptureManager.swift` (new) — resource-loader delegate + finalize.
- `ios/PatataTubeKit/Sources/PatataTubeKit/CapturedDownload.swift` (new) — `CapturedDownloadManifest` + `CapturedDownloadStore`.
- `CacheManager.swift` — `captureAsset(...)`, `state(for:)` capture branch, `inFlight` registration hooks, teardown in clear/remove/resumeInterrupted.
- `ios/PatataTube/Sources/VideoPlayerView.swift` — `playerItem(for:)` final branch + play-to-end finalize hook.
- Tests under `ios/PatataTubeKit/Tests/…`.
