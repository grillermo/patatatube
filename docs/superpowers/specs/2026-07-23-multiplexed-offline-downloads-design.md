# Multiplexed Offline Downloads (iOS)

**Date:** 2026-07-23  
**Status:** Approved design

## Problem

The iOS app currently caches each offline MP4 with one
`URLSessionDownloadTask`. A single connection can leave bandwidth unused,
especially for large files. PatataTube controls both the app and the FastAPI
server, and the existing `/videos/{id}/stream` endpoint already supports
authenticated single byte-range requests.

The app should download different parts of one video concurrently, while
preserving the existing offline-cache behavior: one final MP4, determinate
progress, cancellation, interrupted-download resume, versioned cache keys, and
best-effort preview/poster caching.

## Goal

Add a persistent iOS setting for 1–4 simultaneous streams per video, defaulting
to 2. A download snapshots the selected count, divides the remote MP4 into that
many contiguous byte ranges, downloads the ranges concurrently, and assembles
them into the existing cache destination.

The shared download button keeps its current appearance. Its existing progress
ring advances from aggregate bytes received across all segments, so it
generally moves faster when multiple streams increase throughput.

## User-visible behavior

Settings gains a **Downloads** section containing a **Streams per video**
stepper:

- Default: `2`
- Allowed values: `1...4`
- `1` uses the same segmented engine with one full-file byte range.
- The value is stored in `UserDefaults` under `downloadStreamCount`.
- Invalid persisted values are clamped into `1...4`.

Each new video download snapshots the current value. Changing Settings does not
reshape an in-progress or interrupted download. A resumed download uses the
count stored in its manifest; the new setting applies to downloads started
after the change.

Normal per-video downloads, **Download all**, and **Cache all videos** use the
same setting. Downloads of separate videos remain sequential where they are
sequential today; this feature adds concurrency within one video only.

## Scope

### In scope

- Persistent iOS stream-count setting.
- Concurrent authenticated byte-range downloads for offline MP4 caching.
- Aggregate progress through the existing `CacheState.downloading(Double)`.
- Per-segment persistence and resume.
- Ordered, validated assembly into the existing final MP4 path.
- Explicit server contract tests for recombinable ranges.
- Compatibility with legacy single-task `.resume` files already on devices.

### Out of scope

- A new progress animation or separate progress indicator per stream.
- Simultaneously downloading multiple videos where callers are sequential
  today.
- Background `URLSession` transfers while iOS has suspended or terminated the
  app.
- Dynamically changing the segment count of a started download.
- A compatibility fallback when a server ignores byte ranges.
- A new server endpoint or multipart response format.
- Changes to preview-image or show-poster download behavior.

## Existing system

`CacheManager` in `PatataTubeKit` owns offline MP4 files and uses a
delegate-backed foreground `URLSession`. It tracks one task per video/version
cache key, exposes aggregate state through `state(for:versionId:)`, stores
opaque URLSession resume data beside cached files, and restarts interrupted
downloads when the app becomes active.

`DownloadButton` polls that cache state and renders a 44-by-44 determinate
progress ring. No observation or rendering change is needed.

The FastAPI stream endpoint already:

- accepts one `Range: bytes=start-end` interval;
- returns `206 Partial Content`;
- returns exact `Content-Range` and `Content-Length` headers;
- advertises `Accept-Ranges: bytes`;
- returns a strong ETag and `Last-Modified`;
- honors matching `If-Range`;
- authorizes bearer-token and query-token requests; and
- allows up to 16 concurrent file streams by default.

## Architecture

### Settings ownership

An app-internal `DownloadStreamSettings` value defines the defaults key,
default value, allowed range, clamped loading, and persistence. `AppModel`
gains `@Published var downloadStreamCount: Int`; it loads the value during
initialization and persists it from `saveSettings()`. Keeping the small
UserDefaults policy separate makes invalid-value behavior testable without
constructing the app's credential and API dependencies.

Both production call sites pass the snapped value explicitly:

```swift
try await cache.download(
    id: video.id,
    versionId: video.chosenVersionId,
    from: remote,
    streamCount: model.downloadStreamCount,
    ...
)
```

The public `CacheManager.download` parameter defaults to `1` so existing
non-app callers remain source compatible. The production app always passes the
configured value.

### Focused segmented-download model

`CacheManager.swift` keeps responsibility for:

- the public cache API;
- `CacheState`;
- URLSession construction and delegate routing;
- active-attempt and task lookup;
- cancellation;
- resume discovery;
- final cache-state transitions; and
- preview/poster caching.

A new internal PatataTubeKit source file owns the deterministic and
disk-oriented parts of multiplexing:

- byte-range planning;
- manifest types and atomic encoding;
- scratch paths;
- response-contract validation;
- segment-size validation;
- aggregate byte accounting; and
- ordered assembly.

This keeps the already-large `CacheManager` from mixing cache orchestration
with range mathematics and manifest serialization.

## Range discovery and planning

Before starting new segmented work, the app sends an authenticated probe:

```http
Range: bytes=0-0
```

The probe must return:

- status `206`;
- `Accept-Ranges: bytes`;
- `Content-Range: bytes 0-0/<positive-total-size>`;
- `Content-Length: 1`; and
- a strong ETag.

There is deliberately no normal-download fallback. A missing or malformed
contract fails the attempt before any final cache file is created.

For requested stream count `requestedCount`, the effective count `n` is
`min(requestedCount, totalByteCount)`, preventing empty ranges for pathological
files smaller than four bytes. For ordinary video files it is exactly the
configured count.

Segment `i`, where `i` is zero-based, uses:

```text
start = floor(totalByteCount * i / n)
end   = floor(totalByteCount * (i + 1) / n) - 1
```

The implementation calculates these boundaries without overflowing `Int64`.
The ranges are contiguous, non-overlapping, cover byte zero through the final
byte exactly once, and differ in size by at most one byte.

Every segment request includes:

```http
Authorization: Bearer <token>   # when configured
Range: bytes=<start>-<end>
If-Range: <probe-etag>
```

A fresh segment response must be `206`, carry the same strong ETag, and return
the exact requested `Content-Range` and `Content-Length`. A task reconstructed
by URLSession from opaque resume data may request only the remaining suffix of
its planned segment. Its response must still be `206`, carry the original
ETag, describe a non-empty suffix wholly inside the planned range, and end at
the planned final byte. The reconstructed temporary file must equal the full
planned segment length before it is accepted.

A `200` response is always an error, including the `200` produced when
`If-Range` is stale.

## Scratch layout and manifest

Segmented scratch data lives below the cache root:

```text
.downloads/
  <video-version-key>/
    manifest.json
    segment-0.part
    segment-0.resume
    segment-1.part
    segment-1.resume
    assembled.tmp
```

The manifest is versioned and `Codable`. It contains:

- schema version;
- video ID and optional version ID;
- remote URL, without separately persisting credentials;
- snapped requested and effective stream counts;
- total byte count;
- strong ETag;
- each segment's index, inclusive start/end, completed status, and persisted
  received-byte count.

The manifest is written atomically after the probe and after each durable state
transition. Bearer tokens are not stored as manifest fields.

`PatataTubeApp` passes the current bearer token into
`resumeInterrupted(...)` when the app becomes active. URLSession resume data
may already contain its original authorized request, but the explicit token is
available for any unfinished segment that must be recreated from its manifest.

## Task orchestration

One active attempt owns one video/version cache key and contains:

- a unique attempt identifier;
- the manifest and scratch directory;
- one URLSession task per unfinished segment;
- downloaded-byte counters per task;
- the caller continuation, when the work came from `download(...)`; and
- an operation mode distinguishing a new download, an automatic resume, and a
  legacy single-task resume.

URLSession task identifiers map back to the attempt identifier and segment
index. All shared maps and progress counters remain protected by the existing
lock discipline.

The attempt identifier is checked by every delegate callback. A callback from
a cancelled attempt cannot update progress, move a file, complete the
continuation, or interfere with an immediate retry for the same cache key.

Only unfinished segments receive tasks. A segment completed before an
interruption remains on disk and is not requested again.

## Progress

Progress remains one `Double` per video/version cache key:

```text
(validated completed-segment bytes
 + current bytes received by active segment tasks
 + persisted partial bytes represented by resumed tasks)
/ total byte count
```

The result is clamped to `0...1`. Delegate callbacks update this aggregate in
`inFlight`, and the existing `DownloadButton` polling and 0.15-second linear
animation remain unchanged.

When URLSession resumes an opaque partial transfer, the attempt normalizes its
delegate counters against the manifest so prior bytes are counted exactly once
and no segment contributes more than its planned length. Progress is
presentation state only; final segment and whole-file length validation
determine correctness.

## Segment completion and assembly

`didFinishDownloadingTo` must move URLSession's temporary file before the
delegate callback returns. For each segment it:

1. verifies the HTTP response contract;
2. verifies the downloaded segment length;
3. moves the temporary file to `segment-i.part`;
4. deletes that segment's obsolete resume data;
5. atomically marks the segment complete in the manifest; and
6. waits for the remaining segments.

After every segment is complete:

1. create `assembled.tmp` inside the same cache filesystem;
2. append `segment-0.part` through the final segment in index order;
3. verify the assembled byte count equals the probed total;
4. close and synchronize the assembled file;
5. remove any existing final destination;
6. atomically move `assembled.tmp` to `localURL(for:versionId:)`;
7. delete the segmented scratch directory; and
8. finish the attempt successfully.

The existing best-effort preview and show-poster work runs after an awaited
download succeeds, as it does today. The final MP4 path is absent until
assembly and validation finish, so playback never observes a partial file.

## Interruption and resume

Completed segment files and valid per-segment resume data survive transient
network failures, app suspension, and app relaunch.

When one segment encounters a resumable transport interruption:

1. persist that segment's URLSession resume data;
2. ask still-running sibling tasks to cancel while producing resume data;
3. wait until every sibling has either completed or persisted its resume data;
4. atomically update the manifest; and
5. end the active attempt while leaving safe scratch data in place.

An awaited caller receives the transport error, matching current behavior.
The next explicit download attempt or `resumeInterrupted(...)` restarts only
the incomplete segments.

The manifest's stream count and boundaries always win during resume. A Settings
change never invalidates or repartitions an interrupted download.

## Cancellation

Explicit user cancellation remains a restart-from-zero operation:

1. mark the attempt cancelled;
2. cancel every active segment without preserving resume data;
3. prevent late callbacks through the attempt-identifier check;
4. remove the manifest, segment files, resume files, and assembly temp file;
5. remove the in-flight progress entry; and
6. make `state(for:versionId:)` return `.notCached`.

The waiting `download(...)` call throws cancellation as it does today.

`removeAllCached(id:)` deletes segmented scratch directories for every version
of that video in addition to final MP4s and legacy resume files.

## Legacy resume compatibility

An existing root-level `{key}.resume` file with no segmented manifest is a
legacy single-task download created by an older app version.

The upgraded app resumes it with the existing URLSession resume-data path and
lets it finish as one stream. It does not discard or repartition the opaque
partial transfer. On success it writes the normal final MP4 and removes the
legacy resume file. Future downloads use the configured segmented engine.

## Error handling

Errors fall into two categories.

### Safely resumable transport errors

Network loss, suspension, and similar URL loading interruptions preserve
completed parts plus valid resume data. The current attempt ends, and a later
resume continues the stored plan.

### Unsafe or non-resumable errors

The following invalidate the segmented scratch directory:

- probe response is not the required range contract;
- segment status is not `206`;
- ETag differs from the probe;
- `Content-Range` or `Content-Length` differs from the planned range;
- HTTP `4xx` or `5xx`;
- segment length differs after download;
- manifest decoding or consistency validation fails; or
- assembled length differs from the probed total.

Active siblings are cancelled, unsafe scratch data is removed after tasks
settle, and the existing caller path surfaces a download failure. The next tap
starts with a new probe. The app never silently falls back to a non-ranged
request.

Disk-write and atomic-move failures also surface as download failures and never
publish a partial final MP4.

## Server contract

No production server change is required. The current FastAPI implementation
already supplies the exact single-range semantics and strong validators used by
the design.

The backend suite gains an explicit multiplexing contract test that:

1. creates a known source file;
2. requests the exact ranges produced for four streams;
3. asserts `206`, exact `Content-Range`, `Content-Length`, `Accept-Ranges`, and
   consistent strong ETags for every response; and
4. concatenates the four bodies and asserts byte equality with the source.

Existing semaphore coverage continues to verify bounded concurrent file opens.
The app's maximum of four streams per video remains below the server's default
global limit of 16.

## Testing

### PatataTubeKit unit tests

Pure planning and manifest tests cover:

- default and clamped counts;
- exact 1-, 2-, 3-, and 4-stream boundaries;
- uneven file sizes;
- full coverage without overlap or gaps;
- tiny files using fewer non-empty ranges;
- manifest round trips and schema rejection;
- stored-count precedence over changed Settings;
- scratch-path isolation by video and version;
- aggregate-progress arithmetic; and
- ordered assembly and final-length rejection.

Delegate-backed tests with a range-aware `URLProtocol` cover:

- probe headers and validation;
- exact `Range`, `If-Range`, and bearer headers on every segment;
- byte-identical assembly from out-of-order segment completions;
- final cache visibility only after all segments complete;
- rejection of `200`, wrong ranges, changed ETags, short bodies, and HTTP
  errors;
- cancellation of every segment and scratch cleanup;
- completed-segment reuse;
- independent video/version keys;
- immediate same-key retry isolation; and
- unchanged best-effort preview/poster behavior.

Legacy tests confirm that root-level `.resume` files still select the old
single-task resume path.

Opaque URLSession resume bytes cannot be synthesized faithfully by
`URLProtocol`, so preservation and replay of real partial transfers also
requires manual verification.

### iOS app tests

Tests cover:

- default stream count `2`;
- clamping persisted values into `1...4`;
- persistence from `saveSettings()`;
- Settings stepper label and bounds; and
- production download call sites passing the snapped model value.

The existing `DownloadButton` tests remain unchanged and verify that its
determinate ring still consumes `CacheState.downloading(Double)`.

### Manual acceptance

1. Select four streams and download a large video. Confirm server requests show
   four disjoint ranges and the existing ring advances smoothly to completion.
2. Play the cached MP4 offline and verify it is complete and seekable.
3. Interrupt a four-stream download with Airplane Mode, restore connectivity,
   and verify only unfinished segments resume.
4. Interrupt, terminate, relaunch, and verify foreground resume completes.
5. Change Settings while a download is interrupted and verify its original
   boundaries are retained; verify the next new download uses the new count.
6. Cancel a multiplexed download, immediately retry, and verify it restarts at
   zero without stale callback or scratch-file interference.
7. Install over a build containing a legacy `.resume` file and verify that
   download completes.

## Files expected to change

- `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift`
- `ios/PatataTubeKit/Sources/PatataTubeKit/SegmentedDownload.swift` (new)
- `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift`
- `ios/PatataTubeKit/Tests/PatataTubeKitTests/SegmentedDownloadTests.swift`
  (new)
- `ios/PatataTube/Sources/DownloadStreamSettings.swift` (new)
- `ios/PatataTube/Sources/AppModel.swift`
- `ios/PatataTube/Sources/SettingsView.swift`
- `ios/PatataTube/Sources/VideoGridView.swift`
- `ios/PatataTube/Sources/PatataTubeApp.swift`
- `ios/PatataTube/Tests/DownloadStreamSettingsTests.swift` (new)
- `ios/PatataTube/Tests/SettingsViewTests.swift` (new)
- `tests/test_api.py`
- `ios/README.md`

`router.py` and `DownloadButton.swift` are not expected to change.

## Rollback

The feature is isolated to iOS cache orchestration and additive scratch data.
Reverting the app code restores single-task downloads. Segmented scratch
directories are not mistaken for cached MP4s and may be deleted safely by a
rollback cleanup or later cache removal. Final MP4 paths and playback behavior
remain unchanged.
