# Pause/Resume Byte-Continuation Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A download paused at N% resumes by fetching only the remaining bytes — never restarting from zero.

**Architecture:** The pause machinery (2026-08-08 plan) already persists per-segment resume data + manifest and re-requests with `If-Range`. But byte continuation has never been verified end-to-end: no test covers it (`MockURLProtocol` cannot produce URLSession resume data), and the whole preservation rides on `cancel(byProducingResumeData:)` handing back a non-nil blob. This plan (1) instruments the exact decision points, (2) reproduces on simulator against the real backend to pinpoint where bytes are lost, (3) fixes per a decision table, with the primary fix being resume-data-independent durability: segments append to part files via data tasks, so the part file itself is the durable state.

**Tech Stack:** Swift 5.x SwiftPM package (`ios/PatataTubeKit`), swift-testing, URLSession, DevLog JSONL instrumentation, FastAPI backend (`router.py` stream endpoint).

## Global Constraints

- **Never run iOS tests unless the user explicitly asks** (CLAUDE.md). Tasks below that say "run swift test" mean: ship the change and *ask the user* to run it, unless the user already said to run tests for this plan. When asked to run: both `swift test` and `swift test -c release` for DevLog-touching changes.
- Debug via `log/ios.jsonl` (simulator writes directly with `PATATATUBE_DEV_LOG`); backend via `log/backend.log`. `./serve` truncates both on restart.
- All DevLog call sites use `DevLog.event`/`DevLog.error`, never `print`; meta values cheap; no tokens/response bodies.
- Cancel wipes resume state (by design); pause preserves it. Do not blur the two.
- HLS packages have no partial state on disk — restart-from-zero on HLS is currently by design; Task 6 decides whether to change it, separately.
- The segmented engine's locking/races were heavily reviewed (commit 8d0fbcb). Any fix must not re-open the permit-leak/pause races: keep the `pausedKeys` / `pausedPermitKeys` / `pauseTeardownKeys` contracts exactly as documented in `CacheManager.swift:172-198`.

---

### Task 1: Instrument the byte-preservation decision points

The current log says "pause" and "resume" happened, but not whether resume data was produced, how large it was, or why `startIncompleteSegments` chose fresh-start over continuation. Add permanent instrumentation (it's compiled out without `DEVLOG`).

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift`
  - `pausePlain` (~line 1022): log resume-data outcome
  - `preserveSegmentResumeData` (~line 2337): log per-segment outcome
  - `startIncompleteSegments` (~line 1612): log per-segment start decision

**Interfaces:**
- Produces: DevLog records with msgs `"pause resume data"` and `"segment start decision"` — Task 2's reproduction reads these exact strings.

- [ ] **Step 1: Log plain-path resume data size in `pausePlain`'s cancel callback**

Inside the `task.cancel(byProducingResumeData:)` closure, before the `guard let data`:

```swift
DevLog.event(.download, "pause resume data", [
    "key": key,
    "path": "plain",
    "bytes": "\(data?.count ?? -1)",   // -1 = nil: URLSession refused to produce resume data
])
```

- [ ] **Step 2: Log segmented resume-data outcome in `preserveSegmentResumeData`**

After the `shouldPersist` lock block, before the write:

```swift
DevLog.event(.download, "pause resume data", [
    "key": attempt.cacheKey,
    "path": "segmented",
    "segment": "\(segmentIndex)",
    "bytes": "\(data?.count ?? -1)",
    "persisting": "\(shouldPersist)",
])
```

And after the write attempt, if `persistenceFailed`, add:

```swift
DevLog.error(.download, "segment resume data write failed", [
    "key": attempt.cacheKey,
    "segment": "\(segmentIndex)",
])
```

- [ ] **Step 3: Log each segment's start decision in `startIncompleteSegments`**

Inside the `starts` map, after computing `durablePrefixByteCount`:

```swift
DevLog.event(.download, "segment start decision", [
    "key": attempt.cacheKey,
    "segment": "\(segment.index)",
    "resume_data": "\(resumeData?.count ?? -1)",
    "part_bytes": partSize.map(String.init) ?? "-",
    "persisted": "\(segment.persistedByteCount)",
    "durable_prefix": "\(durablePrefixByteCount)",
])
```

A record with `resume_data:-1, durable_prefix:0, persisted:>0` is the smoking gun for "bytes lost at pause".

- [ ] **Step 4: Build the package**

Run: `cd ios/PatataTubeKit && swift build`
Expected: builds clean. (Do not run tests — user runs them.)

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift
git commit -m "feat(ios): instrument pause resume-data and segment start decisions"
```

---

### Task 2: Reproduce on simulator and produce the evidence verdict

**Files:**
- No code changes. Output: a short findings note appended to this plan file under "## Findings".

**Interfaces:**
- Consumes: DevLog msgs from Task 1.
- Produces: a verdict selecting Task 3, 4, 5, and/or 6.

- [ ] **Step 1: Start the backend fresh** — `./serve` (truncates `log/ios.jsonl` and `log/backend.log`).

- [ ] **Step 2: Run the app in Simulator via Xcode** (Debug ⇒ `DEVLOG` on, `PATATATUBE_DEV_LOG` scheme var writes to `log/ios.jsonl`). Pick a *download* row (Twitter/YouTube MP4, not a library/HLS item), large enough to take >30s.

- [ ] **Step 3: Start download; at ~50% pause it from the Downloads menu. Capture:**

```bash
grep -E '"msg":"(pause|pause resume data)"' log/ios.jsonl | tail -20
ls -la ~/Library/Developer/CoreSimulator/Devices/*/data/Containers/Data/Application/*/Library/Caches/ 2>/dev/null | grep -iE "resume|part|manifest" || true
```

(Or locate the cache root via the app's DevLog `cache` records.) Note per segment: resume-data bytes, `.resume` files on disk, part files, manifest `persistedByteCount`.

- [ ] **Step 4: Resume. Capture:**

```bash
grep -E '"msg":"(resume|segment start decision)"' log/ios.jsonl | tail -20
grep -E "GET /videos/.*/stream" log/backend.log | tail -10   # look at Range: request offsets via caddy/access lines
```

- [ ] **Step 5: Also repeat once with a kill/relaunch between pause and resume** (the persisted-entry path).

- [ ] **Step 6: Record the verdict in "## Findings" using this decision table:**

| Evidence | Verdict → Task |
|---|---|
| `pause resume data` shows `bytes:-1` (nil) | URLSession refuses resume data → **Task 3** (durable part-file appending) |
| resume data written, but `segment start decision` shows `resume_data:-1` on resume | teardown race / file path mismatch → **Task 4** |
| resume data used, but backend receives `Range: bytes=0-` | server rejected `If-Range`/validator (check caddy stripping `ETag`) → **Task 5** |
| Bytes actually continue; only UI progress restarts at 0 | display bug: seed `inFlight` accumulator from manifest persisted bytes on resume → **Task 4 Step 4 variant** (note it in Findings) |
| Paused item was HLS | by-design restart → **Task 6** |

---

### Task 3: Primary fix — durable part-file appending (resume-data-independent)

Run only if Task 2's verdict is nil resume data (expected). Root cause framing: partial bytes live solely in URLSession's private temp file; when `cancel(byProducingResumeData:)` yields nil, they are unrecoverable by design. Fix: stop depending on that blob. Each segment downloads via a **data task appending directly to its part file**; the part file becomes the durable state, and resume re-requests `Range: bytes=(segmentStart+partSize)-(segmentEnd)` with `If-Range` — machinery `startIncompleteSegments` already has (`durablePrefixByteCount`).

This is a bounded rewrite of the segment transport, not the state machine: attempt/permit/pause bookkeeping stays identical; only "how bytes reach disk" changes.

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/SegmentByteSink.swift`
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift` (`startIncompleteSegments`, `relaunchSegment`, the segment URLSession delegate paths, `pauseSegmented`)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/SegmentByteSinkTests.swift`, plus a continuation test in `CacheManagerPauseTests.swift`

**Interfaces:**
- Produces: `final class SegmentByteSink { init(partURL: URL, expectedOffset: Int64) throws; func append(_ data: Data) throws; func close(); var byteCount: Int64 { get } }` — append-only writer that opens the part file, seeks to `expectedOffset` (truncating anything beyond it), and appends off the delegate queue. All I/O errors throw; CacheManager maps them to the existing per-segment failure path.
- Consumes: existing `SegmentedDownloadManifest.segments[i].persistedByteCount`, `segmentedStore.partURL(cacheKey:index:)`, `DownloadByteRange.headerValue`, `If-Range` etag plumbing from `startIncompleteSegments`.

- [ ] **Step 1: Write failing tests for `SegmentByteSink`**

```swift
import Testing
import Foundation
@testable import PatataTubeKit

struct SegmentByteSinkTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sink-\(UUID().uuidString).part")
    }

    @Test func appendsFromZeroOnFreshFile() throws {
        let url = tempFile()
        let sink = try SegmentByteSink(partURL: url, expectedOffset: 0)
        try sink.append(Data([1, 2, 3]))
        sink.close()
        #expect(try Data(contentsOf: url) == Data([1, 2, 3]))
    }

    @Test func continuesFromExistingPrefix() throws {
        let url = tempFile()
        try Data([1, 2, 3]).write(to: url)
        let sink = try SegmentByteSink(partURL: url, expectedOffset: 3)
        try sink.append(Data([4, 5]))
        sink.close()
        #expect(try Data(contentsOf: url) == Data([1, 2, 3, 4, 5]))
    }

    @Test func truncatesBytesBeyondExpectedOffset() throws {
        // A pause can land mid-write; anything past the offset the server
        // will re-send must be dropped, or the file corrupts on resume.
        let url = tempFile()
        try Data([1, 2, 3, 9, 9]).write(to: url)
        let sink = try SegmentByteSink(partURL: url, expectedOffset: 3)
        try sink.append(Data([4]))
        sink.close()
        #expect(try Data(contentsOf: url) == Data([1, 2, 3, 4]))
    }

    @Test func refusesWhenFileShorterThanOffset() {
        let url = tempFile()
        try? Data([1]).write(to: url)
        #expect(throws: (any Error).self) {
            _ = try SegmentByteSink(partURL: url, expectedOffset: 5)
        }
    }
}
```

- [ ] **Step 2: Ask the user to run** `cd ios/PatataTubeKit && swift test --filter SegmentByteSinkTests` — expected FAIL (type missing).

- [ ] **Step 3: Implement `SegmentByteSink`**

```swift
import Foundation

/// Append-only writer for one segment's part file. The part file is the
/// durable record of a segment's progress: pause simply stops appending,
/// and resume re-requests from `byteCount`. No URLSession resume data.
final class SegmentByteSink {
    private let handle: FileHandle
    private(set) var byteCount: Int64

    init(partURL: URL, expectedOffset: Int64, fileManager: FileManager = .default) throws {
        if !fileManager.fileExists(atPath: partURL.path) {
            guard expectedOffset == 0,
                  fileManager.createFile(atPath: partURL.path, contents: nil) else {
                throw SegmentedDownloadError.lengthMismatch(expected: expectedOffset, actual: -1)
            }
        }
        let size = ((try fileManager.attributesOfItem(atPath: partURL.path)[.size])
            as? NSNumber)?.int64Value ?? -1
        guard size >= expectedOffset else {
            throw SegmentedDownloadError.lengthMismatch(expected: expectedOffset, actual: size)
        }
        handle = try FileHandle(forWritingTo: partURL)
        try handle.truncate(atOffset: UInt64(expectedOffset))
        try handle.seekToEnd()
        byteCount = expectedOffset
    }

    func append(_ data: Data) throws {
        try handle.write(contentsOf: data)
        byteCount += Int64(data.count)
    }

    func close() {
        try? handle.synchronize()
        try? handle.close()
    }
}
```

- [ ] **Step 4: Ask the user to run the filtered test again** — expected PASS. Commit:

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/SegmentByteSink.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/SegmentByteSinkTests.swift
git commit -m "feat(ios): add SegmentByteSink append-only part writer"
```

- [ ] **Step 5: Switch segment transport from download tasks to data tasks**

In `startIncompleteSegments` / `relaunchSegment`: build the same ranged `URLRequest` (unchanged `Range` + `If-Range` + bearer), but create `session.dataTask(with: request)` instead. In the URLSession delegate:

- `didReceive response`: validate 206 + `Content-Range` start == `segmentStart + durablePrefix` (a 200 means the validator failed — fall back to `expectedOffset: 0` by recreating the sink, and reset `persistedByteCount`), then create the segment's `SegmentByteSink(partURL:expectedOffset: durablePrefix)`.
- `didReceive data`: `try sink.append(data)`; on throw, cancel the task and route through the existing per-segment failure path. Keep the existing `activeByteCounts`/progress updates.
- `didComplete`: `sink.close()`; on success verify part size == segment length (reuse the existing `lengthMismatch` check), mark `isComplete`, `persistedByteCount = range.length` — same bookkeeping as today’s `didFinishDownloadingTo` move, minus the move.
- Throttle durability bookkeeping: update `manifest.segments[i].persistedByteCount = sink.byteCount` and rewrite the manifest at most every 2s or 1 MB (mirror `ffmpeg_progress`'s throttle spirit) so a crash loses little without hammering disk.

`pauseSegmented` simplifies: plain `task.cancel()` per segment task (no `byProducingResumeData`), keep `preservingResumeData = true` solely so `finishFailedSegmentedAttemptIfReady` writes the manifest and skips `segmentedStore.remove`. Delete the now-dead `.resume`-file branches in `startIncompleteSegments` (`resumeData` always nil ⇒ `durablePrefixByteCount = partSize` when `partSize > 0`, and relax the equality check to `partSize <= segment.range.length` with the manifest updated to match `partSize`).

Keep `pausePlain`/`downloadLegacy` untouched — the legacy `.resume` path still serves old on-disk state; it dies naturally once no `.resume` files remain.

- [ ] **Step 6: Write the end-to-end continuation test in `CacheManagerPauseTests.swift`**

`MockURLProtocol` *can* serve ranged data-task responses. Test: serve a 1 MB body honoring `Range`; start download (streamCount 1); after the first ~256 KB arrive, `pause`; assert part file size > 0 and manifest `persistedByteCount` == part size; `resume`; assert the second request's `Range` header starts at the part size (record request headers in the mock) and the finished file's bytes equal the full body.

```swift
@Test func resumeContinuesFromPersistedBytesNotZero() async throws { /* per the description above; use the existing MockURLProtocol handler pattern from pausingASegmentedDownloadKeepsItsManifest */ }
```

- [ ] **Step 7: Ask the user to run** `swift test` **and** `swift test -c release` (DevLog gating) — expected PASS both.

- [ ] **Step 8: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerPauseTests.swift
git commit -m "fix(ios): make paused download bytes durable via part-file appending"
```

- [ ] **Step 9: Re-run the Task 2 reproduction** on simulator: pause at 50%, resume, confirm backend log shows `Range` starting mid-file and `segment start decision` shows `durable_prefix > 0`.

---

### Task 4: Alternate fix — teardown race / accumulator seeding (only per Task 2 verdict)

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerPauseTests.swift`

- [ ] **Step 1:** If resume data is written but not found on resume: diff the write path (`segmentedStore.resumeURL(cacheKey:index:)` vs plain `resumeURL(for:)`) against the read path in `startIncompleteSegments`, and check `awaitPauseTeardown` actually covered the segmented case (`pauseTeardownInProgressLocked` requires `segmentedAttempts[key] != nil` — verify the attempt is still registered while resume-data callbacks are pending; if `resumeDataPendingTaskIDs` outlives the attempt entry, add those keys to `pauseTeardownKeys` in `pauseSegmented` and remove them in `preserveSegmentResumeData`'s final lock block). Write a failing test capturing the exact mismatch found before fixing.

- [ ] **Step 2 (display variant):** If bytes continue but UI restarts at 0: in `resume`, after claiming the entry, seed the accumulator so the ring never dips:

```swift
lock.withLock {
    inFlight[key] = DownloadActivityAccumulator(
        videoID: id, versionID: versionId,
        totalByteCount: entry.totalByteCount
    )
    inFlight[key]?.record(
        transferredByteCount: entry.transferredByteCount,
        progress: entry.progress
    )
}
```

- [ ] **Step 3:** Ask user to run `swift test`; commit `fix(ios): <per finding>`.

---

### Task 5: Alternate fix — server/proxy validator (only per Task 2 verdict)

**Files:**
- Modify: `router.py` (stream endpoint, ~lines 383-665), possibly Caddyfile
- Test: `tests/test_api.py`

- [ ] **Step 1:** If the device's resumed request carried `If-Range` but got a 200: reproduce with curl through the same host the device uses:

```bash
curl -sI -H "Range: bytes=0-0" https://<prod-host>/videos/<id>/stream | grep -iE "etag|last-modified|accept-ranges"
curl -s -o /dev/null -w "%{http_code}" -H 'If-Range: "<etag>"' -H "Range: bytes=1000-" https://<prod-host>/videos/<id>/stream
```

Expected 206. If the ETag differs from direct-to-uvicorn (Caddy rewriting/stripping), fix the Caddyfile to pass `ETag`/`Last-Modified` through untouched; if `_if_range_matches` is the problem (e.g. weak-validator prefix `W/`), fix the comparison and add a pytest:

```python
@pytest.mark.asyncio
async def test_if_range_with_matching_etag_returns_206(client, uploaded_video):
    head = client.get(f"/videos/{uploaded_video}/stream", headers={"Range": "bytes=0-0"})
    etag = head.headers["ETag"]
    r = client.get(f"/videos/{uploaded_video}/stream",
                   headers={"Range": "bytes=10-", "If-Range": etag})
    assert r.status_code == 206
```

- [ ] **Step 2:** `python -m pytest tests/test_api.py` — PASS. Commit `fix: honor If-Range validators on /videos/{id}/stream`.

---

### Task 6: HLS pause parity — decide, don't silently ship

HLS packages currently restart from zero by design (`pauseExternal` is a cancel; documented in CLAUDE.md). If Task 2 shows the user's paused items are HLS, that "bug" is this design.

- [ ] **Step 1:** Ask the user: is restart-from-zero acceptable for HLS/library items for now, with MP4 continuation fixed? If yes, update the Downloads row UI to caption paused HLS entries "Resumes from start" and stop here.
- [ ] **Step 2:** If HLS continuation is wanted: separate plan (persist fetched `.ts`/`.m4s` segment files under the offline HLS dir keyed by media-playlist URI, skip existing files on resume — `SegmentCache` already has most of the shape). Do not bolt it onto this plan.

---

### Task 7: Docs

- [ ] **Step 1:** Update CLAUDE.md's pause bullet and `docs/` (whichever of `docs/superpowers/plans/2026-08-08-download-pause.md`'s companion docs describe resume) to state the new durability contract: part files are the durable state; resume re-requests `Range` from part size with `If-Range`; Apple resume data no longer load-bearing (legacy `.resume` files still honored on read).
- [ ] **Step 2:** Commit `docs: describe resume-data-independent pause durability`.

## Findings

(filled in by Task 2)
