# Stream Read-Through Cache — Design

Date: 2026-07-26
Scope: iOS app only (`ios/PatataTubeKit`, `ios/PatataTube`). No server changes required.

## Problem

Streaming and downloading are fully independent today. Watching a video streams
bytes that are thrown away; hitting Download afterwards refetches everything.
Rewatching or scrubbing also refetches from the server. Additionally, HLS
videos (the preferred streaming path) have no offline story at all — downloads
are MP4-only ("HLS offline is a later phase").

Goals, equally weighted:

1. **Bandwidth reuse** — the download manager must reuse bytes already streamed
   and fetch only the missing pieces.
2. **Instant replay** — rewatching / scrubbing previously-streamed portions
   serves from local disk.

## Decision

**Local HTTP proxy** (approach A). AVPlayer never talks to the network
directly; it always requests `http://127.0.0.1:{port}/...`. The proxy is a
read-through cache for both HLS segments and MP4 byte ranges.

Rejected alternatives:

- **`AVAssetDownloadTask`** (Apple-native offline HLS): storage is opaque;
  cannot be seeded from streamed bytes. Defeats the core requirement.
- **`AVAssetResourceLoaderDelegate`**: cannot intercept HLS media segment
  requests (Apple limitation — only playlists/keys go through the loader).
  Would force a split MP4/HLS implementation with no gain over the proxy.

Because HLS segments and the MP4 file are different encodes (different bytes),
byte reuse between an HLS stream and an MP4 download is impossible. Resolution:
**HLS-native downloads**. For videos with an HLS package, "download" means
completing the segment set; offline playback plays those segments through the
proxy. This also delivers HLS offline (native subtitle tracks preserved).

## Architecture

```
AVPlayer ──► StreamProxy (FlyingFox, 127.0.0.1 only, per-launch secret)
                │  cache hit → serve from disk
                │  miss → fetch upstream (+Bearer), tee: disk + player
                ▼
        SegmentCache (HLS)      RangeStore (MP4)
                └──────┬────────────┘
                  StreamCacheLRU (10 GB, temp entries only)
                       ▲
        CacheManager download: fetch missing only, promote to permanent
```

All new logic lives in `PatataTubeKit` (testable via `swift test`). New
dependency: **FlyingFox** (Swift, async, SPM) in `Package.swift`.

## Components

### 1. StreamProxy

In-app HTTP server. Ephemeral port, bound to loopback only. Routes:

| Route | Behavior |
|---|---|
| `/{secret}/hls/{videoId}/master.m3u8` | Fetch remote master, rewrite all URIs to point at the proxy, serve. |
| `/{secret}/hls/{videoId}/{asset}` | Read-through for `init.mp4`, `*.m4s`, media playlists, `*.vtt`. |
| `/{secret}/mp4/{videoId}` and `/{secret}/mp4/{videoId}/{versionId}` | HTTP Range read-through against the sparse MP4 cache. |

- `{secret}` is a per-launch random token. The loopback port is reachable by
  other processes on the device; the secret is the access control. Requests
  without it get 404.
- The proxy injects `Authorization: Bearer <token>` on upstream requests. The
  player's `AVURLAsset` no longer needs auth headers for proxied playback.
- Proxy start failure or death is non-fatal: the player falls back to direct
  remote URLs (current behavior).

### 2. SegmentCache (HLS)

- Location: `Caches/stream/{videoId}/{packageHash}/`.
- `packageHash` = hash of the `video.m3u8` media playlist content. Server-side
  `hls.invalidate` (e.g. audio-language change) regenerates segments under the
  same names — the hash changes, the old directory becomes garbage and is
  evicted lazily.
- Cache unit = one file (segment / init / playlist / vtt). Presence bitmap +
  sizes + last-access in `index.json`.
- Writes are atomic: temp file + rename. Only renamed files count as cached;
  crash mid-write leaves ignorable temp files.
- **Single-flight**: player and downloader requesting the same segment
  concurrently trigger one upstream fetch.

### 3. RangeStore (MP4 range manager)

Per remote MP4 (keyed `videoId[:versionId]`):

- Pre-sized sparse data file, written at offsets.
- Manifest: ETag, total byte count, sorted disjoint `[start, end]` runs,
  coalesced on insert.
- API: `cachedRanges()`, `missingRanges(in:)`, `read(range:)`,
  `write(at:data:)`.
- Concurrency: one writer actor per file; readers open independent read-only
  `FileHandle`s (POSIX-safe alongside the writer). The player is only ever
  served bytes whose runs are committed to the manifest.
- ETag mismatch against upstream → wipe entry, restart from empty.

### 4. StreamCacheLRU

- Budget: **10 GB**, covering temporary stream-cache entries only.
- Eviction granularity: whole video (drop the oldest-accessed video's stream
  directory). Per-segment LRU not worth the bookkeeping.
- Promoted (downloaded) entries live outside the budget and are exempt.
- Eviction runs before cache writes when over budget.

### 5. CacheManager / download integration

- **HLS video download**: read the (cached or fetched) media playlist →
  enumerate segments → fetch only missing ones through the existing download
  concurrency gate → verify sizes → **promote** the cache directory into the
  permanent downloads area → record an offline-HLS cached state. Progress =
  bytes complete / total bytes.
- **MP4 video download**: existing `SegmentedDownload` gains seeding — parts
  are pre-filled from `RangeStore` runs (only when the stored ETag matches the
  probe), then only the holes are fetched. Assembly and publish unchanged.
- Existing already-downloaded MP4s remain valid and play as today.

### 6. Player changes

`playerItem(for:)` source order becomes:

1. Cached MP4 file (direct file URL — unchanged)
2. Offline HLS (promoted package) via proxy
3. Remote HLS via proxy
4. Remote MP4 via proxy
5. Proxy unavailable → direct remote URL (today's behavior)

## Error handling

- Upstream 404 / ETag mismatch mid-package → drop that video's stream cache,
  refetch playlist, continue playback pass-through.
- Disk-full or write failure → evict, retry once, else serve pass-through
  without caching. **Playback never blocks on the cache.**
- Corrupt manifest / index on load → wipe that entry (mirrors
  `SegmentedDownload`'s posture: never trust, never repair).
- App backgrounding: background audio keeps the process alive; the proxy keeps
  serving. Suspension implies no playback, so nothing to serve.

## Testing

Unit tests in `PatataTubeKit` (`swift test`):

- RangeStore: run coalescing, hole computation, concurrent reader/writer,
  ETag reset, manifest corruption handling.
- SegmentCache: atomic write semantics, packageHash change behavior,
  single-flight dedup.
- StreamCacheLRU: eviction order, budget enforcement, exemption of promoted
  entries.
- Playlist rewrite: master and media playlists point at proxy, subtitle URIs
  included.
- Download seeding: MP4 holes-only fetch given pre-cached runs; HLS
  missing-segment enumeration and promote flow.
- Upstream mocked with existing `MockURLProtocol`; proxy exercised with real
  loopback requests.

Manual checklist additions to `ios/README.md`: stream → download reuses bytes
(observe server log), offline HLS playback with subtitles, eviction under
pressure, audio-language switch invalidation.

## Out of scope

- Web PWA / Service Worker caching.
- Server changes (existing ETags and Range support suffice).
- Per-segment LRU, cache encryption, adaptive multi-variant HLS.
