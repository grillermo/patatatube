# Resumable Offline Downloads (iOS)

**Date:** 2026-07-07
**Status:** Approved design

## Problem

The iOS app caches MP4s to the device for offline playback via
`CacheManager.download(id:from:preview:bearerToken:)`. It uses the async
convenience call `session.download(for:)`, which:

- Provides **no progress** — the `CacheState.downloading(Double)` bar shown in
  `VideoCell` and `EpisodesView` is stuck at `0` for the whole transfer.
- Provides **no resume** — any interruption (network drop, app backgrounded,
  app killed) discards partial bytes; the next attempt restarts from 0%.

For large videos on flaky connections this means downloads may never finish.

## Goal

An interrupted offline download resumes from where it stopped instead of
restarting, triggered automatically the next time the user taps download (or
"Download All") for that video. As a direct consequence of the rewrite, the
progress value becomes real.

Non-goals (explicitly out of scope):

- Background `URLSession` (downloads continuing while the app is
  suspended/terminated). Foreground only; resume data persists across app kill
  and is used on the next re-tap.
- New "paused/resume" UI. Interrupted downloads keep reading as `.notCached`.
- Live progress push to SwiftUI. The delegate updates the internal progress
  value; live UI refresh (making the cache observable) is a separate change.
- Server-side download retry (the Twitter/YouTube fetch). Different subsystem.

## Scope of change

- `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift` — rewritten.
- `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift` — helper
  updated to inject a configuration instead of a session.
- `ios/README.md` — one manual-test line for the resume round-trip.

**Public API is unchanged.** `download(id:from:preview:bearerToken:)`,
`state(for:)`, `localURL(for:)`, `cachedPreviewURL(for:)` keep their signatures,
so `VideoGridView` and `SettingsView` callers are untouched.

## Design

### Delegate-backed session

`CacheManager` conforms to `URLSessionDownloadDelegate` and builds its own
session once in `init`:

```
session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
```

Because a delegate can only be set at session creation, the injected dependency
changes from a `URLSession` to a `URLSessionConfiguration`:

```
public init(root: URL? = nil, configuration: URLSessionConfiguration = .default)
```

Production callers use the default. Tests pass an ephemeral config carrying the
mock `URLProtocol`.

### Bridging delegate callbacks to async/await

`download(id:from:preview:bearerToken:)` keeps its `async throws` shape. It
starts a `URLSessionDownloadTask` and suspends on a
`CheckedContinuation<URL, Error>` that the delegate resolves.

State tracked under the existing `NSLock`:

- `inFlight: [Int: Double]` — progress per id (existing field, now actually
  updated).
- `continuations: [Int: CheckedContinuation<URL, Error>]` — one per active id.
- `idByTask: [Int: Int]` — maps `URLSessionTask.taskIdentifier` → video id, so
  delegate callbacks (which hand back a task, not an id) resolve to the right
  entry.

Only one active download per id is expected; a second `download(id:)` for an
id already in flight is not a supported concurrent case (callers serialize:
`downloadAll` is sequential, and per-cell taps are guarded by cache state).

### Progress

`urlSession(_:downloadTask:didWriteData:totalBytesWritten:totalBytesExpectedToWrite:)`
computes `written / expected` (guarding `expected <= 0`) and stores it in
`inFlight[id]`. `state(for:)` continues to read `inFlight`, so a redraw during
download now shows a moving bar. No new observation mechanism is added.

### Success

`urlSession(_:downloadTask:didFinishDownloadingTo:)` runs on the delegate queue.
It must move the temp file synchronously before returning (the temp file is
deleted once the callback returns). Steps:

1. Read the task's `response`; if it is an `HTTPURLResponse` outside `200..<300`,
   resolve the continuation with `APIError.badStatus(code)` and stop (no file
   move). This preserves the existing bad-status contract.
2. Move temp → `localURL(for: id)` (remove any existing file first).
3. Delete `{id}.resume` if present.
4. Resolve the continuation with the destination URL.

The `download` method, after the continuation returns normally, does the
best-effort preview caching exactly as today (a failed preview never fails the
video).

### Interruption and resume-data persistence

`urlSession(_:task:didCompleteWithError:)` fires on failure/cancel:

- If `error` is non-nil and its `userInfo` contains
  `NSURLSessionDownloadTaskResumeData`, write those bytes to `{id}.resume` in
  `root`. Resolve the continuation by throwing the error.
- If `error` is nil, the success path already resolved the continuation; do
  nothing here (guard on a still-present continuation entry).

`{id}.resume` lives beside the MP4 in `root`, and `root` is already excluded
from backup, so resume files inherit that.

### Resuming

At the top of `download(id:)`, before creating a task:

- If `{id}.resume` exists and is readable, create the task with
  `session.downloadTask(withResumeData:)`. The resume data carries the original
  request (URL + `Authorization` header), so the bearer token is preserved
  automatically.
- Otherwise create a fresh `session.downloadTask(with:)` from a request built as
  today (URL + optional bearer header).

The `{id}.resume` file is **not** deleted at resume time — only on successful
completion — so repeated interruptions keep resuming from the latest partial.

### Corrupt / stale resume data

If a task created from resume data fails immediately (server no longer supports
the range, data is stale), the delegate captures the failure. Recovery: on that
failure, if no *new* resume data is produced, delete `{id}.resume` and throw.
The user's next re-tap then starts a clean fresh download. (We do not silently
auto-retry within a single call — keep one call = one attempt, matching current
behavior.)

## Error handling summary

| Situation | Behavior |
|---|---|
| HTTP 4xx/5xx | `APIError.badStatus(code)` thrown; no file written; no resume file |
| Network drop mid-transfer | `{id}.resume` written; error thrown; next re-tap resumes |
| App killed mid-transfer | `{id}.resume` already on disk; next re-tap resumes |
| Stale/corrupt resume data | `{id}.resume` deleted on the failed attempt; next re-tap is fresh |
| Preview fetch fails | Video still cached (unchanged best-effort behavior) |

## Testing

### Automated (`swift build` + `swift test` in `PatataTubeKit`)

The delegate rewrite must keep every existing `CacheManagerTests` green, with
the helper switched from returning a `URLSession` to returning a
`URLSessionConfiguration`:

- `stateIsNotCachedThenCachedAfterDownload`
- `downloadAlsoCachesPreview`
- `previewFailureStillCachesVideo`
- `downloadThrowsOnBadStatus`
- `testDownloadSendsBearerToken`
- `localURLUsesIdAndMp4`

New assertions that the mock can support:

- After a successful download, no `{id}.resume` file exists in `root`.
- Progress: not reliably assertable through the instantaneous mock; covered by
  the manual test instead.

**Why resume itself is not unit-tested:** genuine resume data is opaque bytes
generated by `URLSession` from a real partial HTTP transfer with range support.
A `URLProtocol` mock cannot synthesize valid resume data, so an end-to-end
resume cannot be exercised in the Kit's unit tests without a real ranged server.

### Manual (added to `ios/README.md` checklist)

1. Start downloading a large video; enable Airplane Mode mid-transfer (or force
   quit the app).
2. Re-enable network; tap download again on the same video.
3. Confirm it completes and plays — and that it resumed rather than restarting
   (verify via smaller total bytes transferred / faster completion on a large
   file, or Xcode network logs).

## Rollback

Single-file, additive to disk (`{id}.resume` files are ignorable leftovers).
Reverting `CacheManager.swift` and the test helper restores prior behavior;
stray `.resume` files are harmless and can be left or cleared on next cache use.
