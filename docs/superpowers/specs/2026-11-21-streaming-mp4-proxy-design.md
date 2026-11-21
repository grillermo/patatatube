Status: DRAFT

# Streaming MP4 playback — design

## Problem

With the server no longer advertising `hls_path` (remove-HLS plan, Part A,
live since 2026-11-21), every video the iOS app streams goes through
`StreamProxy`'s `proxy_mp4` route. Long videos never start; only files under
8 MB play. Playing a video while it downloads has the same problem, so a
video only becomes watchable once its download has finished and
`PlaybackSource` picks `local_mp4`.

## Root cause (verified)

`StreamProxy.handleMP4` caps every response at `mp4Window` (8 MB, since the
proxy was written on 2026-07-26) and buffers the whole window in memory
(`session.data`) before answering. AVPlayer asks for `bytes=0-1`, then for the
whole file (`bytes=0-<size-1>`). It receives a well-formed `206` that covers
only the first 8 MB, **fails the item** and never requests more.

Evidence:

- Caddy's access log on the macmini, 2026-11-21 15:04–15:12 UTC: for videos
  873, 859, 844 and 835 the phone made exactly three upstream requests per
  tap: `bytes=0-0` (the proxy's probe), `bytes=0-1`, `bytes=2-8388607`. Then
  nothing more. Videos 2 (445 KB) and 13 (3.3 MB) fit in one window and played.
- Every file has `moov` right after `ftyp` (faststart), so file layout is not
  the cause.
- A macOS reproduction (same AVFoundation HTTP loader) against a local
  range server: with an 8 MB cap per response, AVPlayer requested
  `bytes=0-45612657`, got `0-8388607`, and the item went to `.failed`
  ("unknown error") with nothing buffered. The same server uncapped:
  playback started in under a second.

`proxy_mp4` was only a fallback while HLS existed (videos without an HLS
package), so the cap was never exercised on long files until now. HLS hid it,
because a proxied HLS response was one small segment.

The remove-HLS branch (`remove-hls`, 2.9.0, not deployed) keeps the same
`handleMP4`, so shipping it as-is would not fix this.

## Decisions

- **No server rollback.** Part A stays live; long videos stay broken on 2.8.0
  until a fixed app ships. (Owner, 2026-11-21.)
- **Design before code.** A spec, reviewed in Plannotator, then a plan.
  (Owner, 2026-11-21.)
- **Keep watched bytes.** Streaming without a download still keeps what was
  watched, so replays and resumed watches come from the phone, offline too for
  the parts already seen. The proxy stays and is rewritten to stream full
  ranges, saving bytes as they pass. (Owner, 2026-11-21; plain direct
  streaming was offered and declined.)
- **One store per video.** Downloads write into the same per-video byte store
  the player reads. Download-then-play starts at once from the bytes already
  there; the player fetches only what is missing; a video watched to the end
  is a finished download. This replaces the download's part files, and
  pause/resume becomes "keep the committed ranges". (Owner, 2026-11-21;
  keeping them separate was offered and declined.)
- **One release.** The streaming store and downloads moved onto it ship
  together, with no intermediate release. (Owner, 2026-11-21; shipping the
  playback fix first was offered and declined.)
- **Front end: the loopback proxy, streaming.** `StreamProxy` (FlyingFox on
  127.0.0.1) stays and answers full ranges with a streamed body.
  AVAssetResourceLoader was offered and declined. (Owner, 2026-11-21.)
- **Architecture (section 1) approved** as written below. (Owner, 2026-11-21.)
- **Data flow (section 2) approved** as written below. (Owner, 2026-11-21.)

## Architecture

`CacheManager` keeps its public API (`download`, `pause`, `resume`, `cancel`,
`state`, `activeDownloads`, `removeCached`, …); its internals are replaced.

| Unit | Job | Replaces |
|---|---|---|
| `MediaStore` (actor) | One entry per video key (`812`, `812:3`): sparse `data.bin` + `entry.json` (etag, size, committed ranges, pinned, paused, stream count, last access), plus in-memory **claims**: ranges a fetcher is downloading right now. | `RangeStore`, `SegmentedDownloadStore`, part files, `.resume` files, `paused-downloads.json` |
| `RangeFetcher` | One upstream `Range` request streaming into a claim, committing every ~256 KB and waking waiting readers. Stops when it reaches bytes someone else already has. | segment tasks, the plain resume-data path |
| `StreamProxy.handleMP4` | Answers the **full** requested range as a streamed 206: committed bytes from disk, bytes a nearby fetcher is about to commit by waiting, otherwise its own fetcher at the playhead. On hang-up, cancels only the fetcher it started. | 8 MB buffered windows |
| Download job (in `CacheManager`) | `download` pins the entry and runs up to `streamCount` fetchers over the holes. Pause cancels them and keeps committed ranges; resume refills the holes; cancel unpins and deletes. | plain and segmented transfer paths |
| Promotion | When committed ranges cover the whole file, `data.bin` is renamed to `videos/<id>.mp4` (today's `localURL`), whether the bytes came from a download or from watching. | — |

Storage:

- Entries live in `Documents/videos/.store/<key>/`, excluded from backup.
- Unpinned partial entries (watched, not downloaded) are LRU-evicted under the
  existing 50 GB budget. Pinned entries and finished mp4s are never evicted.
- First launch of the new version: the old `Caches/stream` cache, segmented part
  files and `.resume` files are deleted. Each paused download becomes a paused,
  pinned entry that starts from zero bytes once.

## Data flow

**Playback**: a proxy reader at `p`, AVPlayer asked for `p…E`:

1. If the finished `videos/<id>.mp4` exists, stream that file's range; done.
2. If `p` is committed, read up to 256 KB from `data.bin`, send it, advance.
3. If a claim covers `p` and its fetcher is at most 4 MB behind `p`, wait for
   its next commit.
4. Otherwise start a **playback fetcher** at `p`, ending at `E` or at the next
   committed or claimed byte. This reader owns it.
5. On hang-up (seek, close, next video), cancel the fetcher this reader owns,
   nothing else. A seek is a new request at a new `p`.

**Bounded read-ahead.** AVPlayer asks for the whole file and reads slowly. A
playback fetcher suspends its transfer once it is **32 MB ahead** of what the
reader has sent, and resumes as the reader advances. Watching keeps what was
watched plus a margin, without downloading every tapped video.

**Downloading.** `download` pins the entry and plans up to `streamCount`
fetchers over the holes (skipping committed and claimed ranges, splitting the
largest hole). A fetcher runs until it reaches committed bytes or another
claim; the planner then picks the next hole. When a playback claim ends, its
unfetched remainder becomes a hole again and the job is woken for it. Progress
is committed bytes over size.

**Downloading while watching.** Both run at once: the playback fetcher stays at
the playhead with its 32 MB lead, download fetchers fill everything else and
never throttle. When the last hole closes the entry is promoted; open responses
keep reading the same bytes (the open file handle survives the rename), and the
next request is served from the mp4.

**Identity.** The first open of an entry in a process probes `bytes=0-0` for
ETag and size. Every fetcher checks its 206's ETag and `Content-Range`. A
mismatch resets the entry: open playback responses end (AVPlayer errors and
retries) and downloads restart.
