# Stream cache: possible effects on download-speed measurement

This is an investigation map, not a diagnosis or a proposed fix. It covers
changes introduced by the stream-cache branch that can change what the UI
reports as `bytesPerSecond` during an offline download.

## The speed calculation itself

`DownloadActivityAccumulator` reports speed from the byte delta between the
oldest and newest callback in a rolling **2.5 second** window
(`DownloadActivity.swift`). It deliberately keeps the previous non-nil speed
when the current samples do not produce a positive delta.

That means the displayed number is a rate of *reported download progress*,
not necessarily a rate of bytes received from the network. Anything that
changes the progress counter, callback cadence, or time spent before the
first callback can affect it.

## MP4: streamed-byte seeding

The new MP4 path seeds a segmented offline download from `RangeStore` through
`StreamCache.seedSegments` and `CacheManager.downloadVideo`.

### Seeded bytes are local, but progress can include them

- A cache hit copies a contiguous prefix into a staged segment part and sets
  `SegmentedDownloadSegment.persistedByteCount`.
- `SegmentedDownload.progress` counts persisted bytes as already received,
  alongside bytes actively arriving from the network.
- Consequently, a download can start with non-zero progress even though no
  offline-download network byte has been received yet. If a rate sample spans
  the seed publication or the first completion bookkeeping, the UI can appear
  to attribute local work to download progress.

Relevant code: `StreamCache.seedSegments`, `CacheManager.startSegmentedAttempt`,
and `SegmentedDownload.progress`.

### Resume baselines deliberately alter the sample origin

`DownloadActivityAccumulator.establishResumeSamplingBaseline` subtracts the
current write from prior written bytes, intending to avoid treating already
persisted/resumed data as a new transfer. The new seeded-prefix path creates
another kind of resumed segment (a part file without URLSession resume data),
so correctness depends on the same baseline being applied with the right
`totalBytesWritten` and current write values.

Things to compare in logs/debugging:

- persisted prefix size for each segment;
- initial `activeByteCounts` value;
- accumulator sample bytes before and after the first suffix callback;
- whether the first speed sample is based solely on a network suffix.

### Prefix/suffix requests change callback shape

For a partially seeded segment, the downloader now requests only the missing
suffix and appends it to the local prefix. This makes each request smaller and
can make callbacks shorter-lived or less frequent. A 2.5-second average over
one small suffix completion has materially different behavior than the old
full-segment request pattern, even if the server throughput is unchanged.

### Local disk work delays or interleaves progress updates

Seeding copies cached ranges to temporary segment parts before the network
attempt is registered. The cache has been hardened to make long copies
cooperative, but copying, synchronizing, publishing staged parts, and
assembling completed segments still consume time without network bytes. This
can create a long apparent startup interval followed by a concentrated set of
network callbacks, which changes a rolling calculation.

### Cache misses and recovery retries add elapsed time

The stream cache now attempts eviction and one cache-write retry after storage
failures. Playback/download should still fall through if that fails, but the
extra filesystem work can delay progress callbacks. If elapsed time includes
that delay while the byte counter does not advance, the next rate can be lower;
if callbacks are re-anchored after it, it can instead look like a burst.

## HLS offline downloads: progress is not byte based

`CacheManager.downloadHLS` registers an external activity with a fixed total
of **10,000 units**, then increments completed units once per media asset:

```
completedUnits = completedAssetCount * 10_000 / assetCount
```

`updateExternalActivity` passes those units as both the accumulator's
`transferredByteCount` and its progress basis. Therefore HLS
`bytesPerSecond` is actually **synthetic progress-units per second**, not
network bytes per second.

This is the most direct stream-cache-related reason the displayed value can
be semantically wrong for HLS downloads.

Additional consequences:

- A 20-byte subtitle file and a multi-megabyte media segment advance the
  counter by the same amount.
- Three asset fetches run concurrently. Completion order, rather than byte
  volume or request start order, drives the samples.
- Reused streamed HLS assets advance the same units without a network fetch.
  A warm cache can therefore report a high apparent “speed” even when it
  downloaded zero bytes from the server.
- Playlist files are fetched/written before the asset counter starts. Their
  elapsed time is not represented by transferred units, so the first reported
  rate can be skewed by playlist latency.
- When there is only one asset, the first completion jumps from 0 to 10,000;
  the displayed rate becomes almost entirely a function of that task's timing.

## Shared activity and lifecycle effects

- MP4 and HLS downloads use the same cache key and `inFlight` activity map.
  The atomic ownership guard prevents simultaneous ownership, but transitions
  between probe, seeded download registration, external HLS activity, cancel,
  and completion can change when the accumulator is created or removed.
- Cancellation and promotion are now fenced. This is correct for integrity,
  but it can leave the final visible rate unchanged while cancellation/promotion
  work happens because the accumulator retains its last rate when no newer
  positive sample exists.
- HLS artwork caching happens after package completion and is intentionally
  outside HLS progress. It can make the overall “download button finished”
  time longer than the transfer/rate history suggests.

## Suggested evidence to collect before changing anything

For one cold MP4, warm MP4, cold HLS, and warm HLS download, capture:

1. wall-clock start/end and actual HTTP response byte totals;
2. every accumulator sample: timestamp, transferred count, total, progress,
   and resulting `bytesPerSecond`;
3. per-segment persisted prefix, request `Range`, response `Content-Range`,
   and bytes written;
4. HLS asset name, size, source (`SegmentCache` or network), start/end time,
   and completion index;
5. cache eviction/retry and disk-write events;
6. whether the displayed speed is intended to mean network throughput,
   end-to-end completion throughput, or progress velocity.

The final definition matters: the current implementation uses one field for
two different quantities—byte-rate-like MP4 progress and asset-count-derived
HLS progress—so comparing them directly is inherently misleading.
