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
