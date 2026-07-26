# Proxy-measured download network and cache rates

Date: 2026-07-26
Scope: iOS (`ios/PatataTubeKit`, `ios/PatataTube`). No backend change.

## Problem

The Downloads page currently presents `DownloadActivity.bytesPerSecond` as a
byte rate. That is approximately true for MP4 downloads, whose progress
callbacks carry written byte counts, but false for HLS downloads.

`CacheManager.downloadHLS` represents the entire package as 10,000 progress
units and advances those units when media assets finish. Those synthetic units
are passed through `transferredByteCount`, averaged over 2.5 seconds, and
formatted as KB/s. The last non-zero rate is also retained when new samples
cannot produce a rate. A fast 600 MB HLS download can therefore display a stale
value such as 1 KB/s even though that value has no relationship to network
throughput.

Stream-cache reuse makes one speed insufficient. During an offline download,
some bytes can arrive from the upstream server while other bytes are supplied
from the local HLS segment cache or MP4 range store. The Downloads page must
show both sources independently:

- **Network** — bytes received from successful or partially successful upstream
  response bodies.
- **Cache** — bytes read from an existing local stream cache and delivered to
  the offline downloader.

The counters must not overlap. A byte fetched upstream, written to the cache,
and forwarded during the same request counts only as network. Playback traffic
must not affect either offline-download rate.

## Chosen approach

Route explicit offline HLS and MP4 downloads through dedicated endpoints on the
existing loopback `StreamProxy`. The proxy is the only component that decides
whether each delivered chunk came from upstream or from pre-existing cache
storage, so it becomes the common measurement boundary for both media formats.

Rejected alternatives:

1. **Instrument `CacheManager` separately for HLS and MP4.** This is smaller,
   but duplicates source-accounting rules across two download implementations
   and does not put measurement at the cache/upstream decision boundary.
2. **Use `URLSessionTaskMetrics`.** Task metrics are useful after a request
   finishes but do not provide the live chunk cadence needed by the Downloads
   page. They also cannot measure local cache reads.

## Public download routes

`StreamProxy` gains URL builders and loopback routes dedicated to offline
downloads:

- `/download/hls/:id/:version/*`
- `/download/mp4/:id/:version`

Existing `/hls` and `/mp4` routes remain playback routes. They continue their
current read-through behavior but never update offline-download meters.

`AppModel` supplies the dedicated proxy URL to `CacheManager` when the proxy is
available. The download APIs identify a proxy-managed source explicitly; they
do not infer behavior by inspecting a loopback hostname or URL path.

MP4 manifests continue to persist the stable upstream URL, not the ephemeral
loopback URL. A live `SegmentedAttempt` carries a separate request URL, which is
the current proxy URL when proxy measurement is active. On app relaunch,
`resumeInterrupted` resolves a new proxy URL for the video/version and discards
opaque URLSession resume blobs that contain the previous launch's port and
secret; durable completed parts remain resumable through the manifest. Direct
downloads retain their existing resume-data behavior.

When using a proxy-managed source, `CacheManager` must not reuse `StreamCache`
directly:

- MP4 skips `StreamCache.seedSegments`.
- HLS skips its direct `SegmentCache.cachedData` lookup.

This prevents cache bytes from bypassing the proxy and prevents the same cached
byte from being measured twice. Percentage progress still advances from bytes
delivered to the downloader, regardless of their source.

If no dedicated proxy URL is available before a download begins, the app keeps
the existing direct-download fallback. The transfer continues, but proxy
network and cache rates are unavailable and the UI displays em dashes. It does
not fall back to synthetic HLS speed.

## Streaming transport

The existing MP4 playback handler is not suitable for offline downloads. It
caps responses at 8 MiB and buffers upstream misses in `Data`; the segmented
downloader requests larger exact ranges and validates `Content-Range`.

The dedicated MP4 download route therefore:

1. Honors the complete requested range instead of applying the playback
   8 MiB window.
2. Snapshots which portions were cached before the request.
3. Produces an `HTTPBodySequence` that streams cached spans and upstream holes
   in byte order using bounded chunks.
4. Returns the exact status and `Content-Range` expected by the existing
   downloader.
5. Writes upstream chunks to `RangeStore` on a best-effort basis while
   forwarding them.

Cached spans record cache bytes as their chunks are yielded. Upstream holes use
`URLSession.bytes(for:)` and record network bytes as chunks are received. A
newly received chunk is not counted again when it is committed to `RangeStore`.
Concurrent segmented download requests remain concurrent; each individual
response streams rather than accumulating a segment-sized in-memory buffer.

For HLS:

- Master and media playlists remain small buffered requests because the proxy
  must parse and hash them before choosing a package cache.
- A cached media asset is streamed from its existing `Data` in bounded chunks,
  recording cache bytes as those chunks are consumed.
- A media-asset miss streams upstream in bounded chunks, recording network
  bytes live and accumulating the asset for one best-effort cache commit after
  successful completion.
- Download routes do not join playback `SingleFlight` requests. This keeps
  playback ownership from making offline-download source attribution
  ambiguous.

## Transfer meter

A small lock-protected `DownloadTransferMeter` is shared by `StreamProxy` and
`CacheManager`. It is keyed by the existing video/version cache key and has an
explicit `begin`/`record`/`snapshot`/`end` lifecycle.

Each active entry stores:

- session start time;
- cumulative network bytes;
- cumulative cache bytes;
- timestamped network chunk sizes;
- timestamped cache chunk sizes.

The two rates are computed independently over the trailing 2.5 seconds:

```
recent channel bytes / min(2.5 seconds, elapsed session time)
```

The calculation includes idle time inside the window. A channel with no bytes
in the current window returns `nil`, so its display decays to an em dash rather
than freezing the last non-zero value. Old chunk events are pruned during
recording and snapshots, bounding memory use independently of download size.

`CacheManager` begins the meter only after it has claimed the download
identity. It ends and removes the meter entry on success, cancellation, or
failure. A generation token prevents late chunks from a cancelled attempt from
being attributed to a later attempt for the same video/version.

## Download activity and progress

`DownloadActivity.bytesPerSecond` remains the network-rate field for source
compatibility, but its documented meaning becomes explicit: upstream response
body bytes per second measured by the proxy.

`DownloadActivity` gains:

```swift
public let cacheBytesPerSecond: Double?
```

`CacheManager.activeDownloads()` overlays the current meter snapshot onto its
progress accumulator. The Downloads view already polls this method every 250
milliseconds through `TimelineView`, so no new observation or callback layer is
needed.

Progress and transfer rate are intentionally separate:

- MP4 progress remains persisted plus actively delivered bytes divided by the
  known file size.
- HLS progress remains completed assets divided by total assets.
- HLS retains its internal 10,000-unit representation exclusively for progress,
  but it can never populate `bytesPerSecond` or
  `cacheBytesPerSecond`.

The existing `transferredByteCount` is no longer used to calculate public
speed. It continues to carry the download path's existing progress bookkeeping
value; this change does not add unrelated public byte-total fields.

## UI

The active-download row replaces the single unlabeled rate with one compact,
monospaced trailing label:

```
Net 42 MB/s · Cache 180 MB/s
```

Each value is formatted independently with the existing decimal KB/s and MB/s
conventions. A channel with no bytes in the current rolling window uses an em
dash:

```
Net 42 MB/s · Cache —
Net — · Cache 180 MB/s
```

The accessibility value reads both labels and values. Progress, title, Cancel,
and row layout remain otherwise unchanged.

## Failure and cancellation behavior

- A cache read failure falls through to upstream. Delivered bytes count only as
  network.
- Cache prepare/write/eviction failures never interrupt a successful upstream
  stream. They only prevent future cache reuse.
- Upstream bytes already received count as network even if the response later
  fails. The downloader retains its existing retry and terminal-error behavior.
- A malformed status, ETag, or `Content-Range` terminates the stream and is
  handled by the downloader's existing validation and retry paths.
- Cancellation stops the streaming response, removes the metering generation,
  and prevents late callbacks from changing a new attempt.
- Proxy startup unavailability uses the existing direct download fallback with
  both rates unavailable; it never restores synthetic progress-unit speed.

## Testing

Tests use injected dates and existing `URLProtocol` stubs.

### Meter unit tests

1. Network and cache chunks update only their own totals and rates.
2. Early-session rates divide by elapsed session time.
3. Rates use the trailing 2.5-second window and include idle time.
4. A channel becomes `nil` after 2.5 seconds without bytes.
5. Ending and restarting the same key rejects late records from the old
   generation.

### Proxy tests

1. A cold HLS asset records network bytes and zero cache bytes.
2. A warm HLS asset records cache bytes and makes no upstream request.
3. A mixed HLS package produces independent non-zero channel rates.
4. A cold MP4 range preserves the exact requested `Content-Range`, streams the
   complete body, and records only network.
5. A fully cached MP4 range records only cache.
6. A partially cached MP4 range returns byte-identical ordered data and assigns
   pre-existing spans to cache and holes to network without overlap.
7. MP4 download ranges larger than 8 MiB are not truncated.
8. Playback HLS and MP4 routes do not update an active download meter.
9. Cache read/write failure falls through without double-counting.
10. Cancellation stops metering for that generation.

### Cache manager tests

1. Proxy-managed MP4 downloads skip direct range seeding.
2. Proxy-managed HLS downloads skip direct segment-cache reuse.
3. HLS progress units never populate either public speed.
4. `activeDownloads()` exposes current network and cache snapshots.
5. Direct fallback leaves both rates unavailable.
6. A persisted MP4 manifest keeps its upstream URL while a live attempt uses
   the current proxy URL, including after app relaunch.
7. Relaunch through a new proxy URL drops stale proxy resume blobs but retains
   durable completed segment parts.

### UI tests

1. Both populated rates render as `Net … · Cache …`.
2. Either unavailable channel renders as an em dash.
3. The accessibility value includes both source labels.

Full `PatataTubeKit` and iOS app tests run after the focused suites.

## Out of scope

- Backend or Caddy traffic metrics.
- Historical speed graphs or completed-download statistics.
- Combining network and cache into a third aggregate speed.
- Displaying protocol overhead; rates count response-body bytes.
- Changing download concurrency, progress presentation, cancellation semantics,
  or cache eviction policy.
