# Unified Range Download Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make downloads and playback share one partial file per video, so a partly-downloaded video plays instantly and a partly-watched video downloads only the rest.

**Architecture:** One `RangeFetcher` actor per video owns a sparse partial file plus a manifest of captured byte ranges. Playback (via `AVAssetResourceLoaderDelegate`) and explicit download (via a new parallel `fetchAll`) both go through that single actor, so every byte either side fetches is immediately visible to the other. The old `SegmentedDownload` machinery — whose bytes only reached disk when a whole segment finished — is deleted.

**Tech Stack:** Swift 6, SwiftPM package `ios/PatataTubeKit` (`swift build`, `swift test`), swift-testing (`@Test`/`#expect`), `AVFoundation`, `URLSession` (`.default`), SwiftUI app shell `ios/PatataTube` built via XcodeGen.

Spec: `docs/superpowers/specs/2026-07-25-unified-range-download-design.md`

## Execution Status (resume here)

- Task 1 — DONE, reviewed clean. Commit `3c40a24`.
- Task 2 — DONE, committed `d273252`, full package builds. **Task review NOT yet run.**
- Tasks 3-9 — not started.
- Ledger: `.superpowers/sdd/2026-07-25-unified-range-download/progress.md`
- Briefs/reports/diffs for tasks 1-2 live in that same directory.
- Work is on `main` (human approved, no worktree).
- Resume by re-invoking superpowers:subagent-driven-development on this plan; it will
  read the ledger, skip Task 1, run Task 2's review, then continue at Task 3.

## Global Constraints

- All logic lives in `ios/PatataTubeKit`; the app target `ios/PatataTube` only consumes it. Build the package with `cd ios/PatataTubeKit && swift build`, test with `swift test`.
- Tests use swift-testing (`import Testing`, `@Test`, `#expect`), not XCTest. Network is stubbed with the existing `MockURLProtocol` / `mockSession()` helpers in `Tests/PatataTubeKitTests/MockURLProtocol.swift`.
- Suites that install `MockURLProtocol.handler` must be marked `.serialized` — the handler is global mutable state. Follow `RangeFetcherTests`.
- Chunk size for range fetches is exactly `4 * 1_048_576` (4 MiB).
- Worker concurrency is clamped to `1...4` (`min(max(streamCount, 1), 4)`), matching today's `download(streamCount:)`.
- Cache keys are `"\(videoId)"` or `"\(videoId):\(versionId)"` — always build them with the existing `cacheKey(videoId:versionId:)` helper in `CacheManager`.
- Cancel must never delete the partial or the manifest. Only `removeCached`, `removeAllCached`, `clearAllVideos`, and an explicit user delete may.
- `isEligibleForCapture: false` continues to disable *passive* watch-capture only. Explicit download always uses the range path, library rows included.
- Commit after every task with a Conventional Commits message.

---

## File Structure

**Modified:**
- `ios/PatataTubeKit/Sources/PatataTubeKit/RangeFetcher.swift` — gains `fetchAll`, `downloadAll`, player-activity tracking, reentrancy fix. Stays the single owner of a video's partial.
- `ios/PatataTubeKit/Sources/PatataTubeKit/CaptureManager.swift` — loses the fetcher registry (moves to the new file), keeps the resource-loader delegate.
- `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift` — `download`, `cancel`, `state(for:)`, `resumeInterrupted` rewritten onto the registry; segmented machinery and `URLSessionDownloadDelegate` removed.
- `ios/PatataTubeKit/Sources/PatataTubeKit/DownloadActivity.swift` — `overrideProgress` removed (superseded by real byte-rate `record`).
- `ios/PatataTube/Sources/DownloadButton.swift`, `ios/PatataTube/Sources/VideoCell.swift` — handle the new `.paused` state.

**Created:**
- `ios/PatataTubeKit/Sources/PatataTubeKit/RangeFetcherRegistry.swift` — one fetcher per cache key, shared by capture and download.
- `ios/PatataTubeKit/Tests/PatataTubeKitTests/RangeFetcherConcurrencyTests.swift`
- `ios/PatataTubeKit/Tests/PatataTubeKitTests/RangeFetcherFetchAllTests.swift`
- `ios/PatataTubeKit/Tests/PatataTubeKitTests/RangeFetcherRegistryTests.swift`
- `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerRangeDownloadTests.swift`

**Deleted:**
- `ios/PatataTubeKit/Sources/PatataTubeKit/SegmentedDownload.swift`
- `ios/PatataTubeKit/Tests/PatataTubeKitTests/SegmentedDownloadTests.swift`
- The segmented/legacy-resume portions of `CacheManagerTests.swift`

---

### Task 1: Fix range loss under concurrent fetches

`data(for:)` snapshots the manifest, awaits the network, then writes the stale snapshot back. Two concurrent callers lose one range. This is a prerequisite: every later task creates concurrency on this actor.

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/RangeFetcher.swift:100-120` (the `data(for:)` body)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/RangeFetcherConcurrencyTests.swift` (create)

**Interfaces:**
- Consumes: nothing (first task).
- Produces: `RangeFetcher.data(for:)` becomes safe under reentrancy. No signature change.

- [x] **Step 1: Write the failing test**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/RangeFetcherConcurrencyTests.swift`:

```swift
import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Range fetcher concurrency", .serialized)
struct RangeFetcherConcurrencyTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fetcher-concurrency-\(UUID().uuidString)")
    }
    private let body = Data((0..<100).map { UInt8($0) })
    private let remote = URL(string: "https://srv.test/videos/1/stream")!

    /// Serves 206 range responses over `body`, delaying each GET so the two
    /// concurrent calls genuinely overlap across their `await` points.
    private func installSlowHandler() {
        let body = body
        MockURLProtocol.handler = { request in
            let spec = (request.value(forHTTPHeaderField: "Range") ?? "bytes=0-0")
                .replacingOccurrences(of: "bytes=", with: "")
            let parts = spec.split(separator: "-")
            let start = Int(parts[0])!
            let end = parts.count > 1 && !parts[1].isEmpty ? Int(parts[1])! : body.count - 1
            if !(start == 0 && end == 0) { Thread.sleep(forTimeInterval: 0.05) }
            let slice = body.subdata(in: start..<(end + 1))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 206, httpVersion: nil,
                headerFields: [
                    "Accept-Ranges": "bytes",
                    "ETag": "\"v1\"",
                    "Content-Range": "bytes \(start)-\(end)/\(body.count)",
                    "Content-Length": "\(slice.count)",
                ])!
            return (response, slice)
        }
    }

    private func makeFetcher(store: CapturedDownloadStore) -> RangeFetcher {
        RangeFetcher(
            cacheKey: "1", remoteURL: remote, bearerToken: "t",
            videoId: 1, versionId: nil,
            store: store, session: mockSession(), onProgress: { _ in })
    }

    @Test func concurrentFetchesRecordEveryRange() async throws {
        installSlowHandler()
        let fetcher = makeFetcher(store: CapturedDownloadStore(root: root()))
        _ = try await fetcher.loadContentInfo()

        async let low: Data = fetcher.data(for: .init(start: 0, end: 9))
        async let high: Data = fetcher.data(for: .init(start: 50, end: 59))
        let (lowData, highData) = try await (low, high)

        #expect(lowData == body.subdata(in: 0..<10))
        #expect(highData == body.subdata(in: 50..<60))
        #expect(await fetcher.manifestSnapshot?.capturedRanges == [
            .init(start: 0, end: 9),
            .init(start: 50, end: 59),
        ])
    }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter RangeFetcherConcurrencyTests`
Expected: FAIL — `capturedRanges` holds only one of the two ranges (the later writer's snapshot overwrote the earlier one).

- [x] **Step 3: Make the manifest write read-modify-write after the await**

In `RangeFetcher.data(for:)`, replace the snapshot-then-write pattern. The method currently opens with `guard var m = manifest` and ends with `m.capture(range); try store.write(m); manifest = m`. Change to:

```swift
    func data(for range: DownloadByteRange) async throws -> Data {
        guard let m = manifest else {
            _ = try await loadContentInfo()
            return try await data(for: range)
        }
        // Fully captured already → serve from disk.
        if CapturedRanges.complement(of: m.capturedRanges, over: m.totalByteCount)
            .allSatisfy({ $0.end < range.start || $0.start > range.end }) {
            return try store.readRange(cacheKey: cacheKey, range: range)
        }
        // Fetch the requested range from the network (simple whole-range fetch;
        // overlaps with existing captured bytes are harmless — same content).
        let (data, response) = try await session.data(for: authedRequest(range: range.headerValue))
        guard let http = response as? HTTPURLResponse else { throw RangeFetcherError.invalidProbe }
        if (400..<600).contains(http.statusCode) { throw RangeFetcherError.badStatus(http.statusCode) }
        guard http.statusCode == 206 else { throw RangeFetcherError.invalidProbe }
        guard http.value(forHTTPHeaderField: "ETag") == m.etag else { throw RangeFetcherError.changedEntity }
        guard Int64(data.count) == range.length else { throw RangeFetcherError.lengthMismatch }

        try store.writeRange(cacheKey: cacheKey, offset: range.start, data: data)
        // Re-read after the await: this actor is reentrant, so another caller may
        // have captured ranges while this fetch was in flight. Mutating the
        // pre-await snapshot would silently drop their work.
        guard var current = manifest else { return data }
        current.capture(range)
        try store.write(current)
        manifest = current
        onProgress(current.progress)
        return data
    }
```

Note `guard var m` becomes `guard let m` — the snapshot is now read-only.

- [x] **Step 4: Run tests to verify they pass**

Run: `cd ios/PatataTubeKit && swift test --filter RangeFetcher`
Expected: PASS — `RangeFetcherConcurrencyTests`, `RangeFetcherTests`, `RangeFetcherFinalizeTests` all green.

- [x] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/RangeFetcher.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/RangeFetcherConcurrencyTests.swift
git commit -m "fix(ios): keep every captured range under concurrent range fetches"
```

---

### Task 2: Report captured bytes, not just a ratio

Progress becomes `(capturedBytes, totalByteCount)` so the activity accumulator can compute transfer rate and ETA for both capture and download. `overrideProgress` (rate-less) goes away.

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/RangeFetcher.swift` (`onProgress` property, `init`, both call sites)
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CaptureManager.swift` (`asset(...)` signature)
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift:317-370` (`captureAsset`, `registerCaptureProgress`)
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/DownloadActivity.swift:70-82` (delete `overrideProgress`)
- Modify: `ios/PatataTubeKit/Tests/PatataTubeKitTests/RangeFetcherTests.swift`, `RangeFetcherFinalizeTests.swift`, `RangeFetcherConcurrencyTests.swift` (closure arity)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerCaptureStateTests.swift`

**Interfaces:**
- Consumes: Task 1's `data(for:)`.
- Produces:
  - `RangeFetcher.init(..., onProgress: @escaping @Sendable (Int64, Int64) -> Void)` — `(capturedBytes, totalByteCount)`.
  - `CaptureManager.asset(videoId:versionId:remoteURL:bearerToken:onProgress:)` with the same closure type.
  - `CacheManager.registerCaptureProgress(key:videoId:versionId:capturedBytes:totalByteCount:)`.

- [x] **Step 1: Write the failing test**

Append to `ios/PatataTubeKit/Tests/PatataTubeKitTests/RangeFetcherConcurrencyTests.swift`, inside the suite:

```swift
    @Test func progressReportsCapturedAndTotalBytes() async throws {
        installSlowHandler()
        let reports = Reports()
        let fetcher = RangeFetcher(
            cacheKey: "1", remoteURL: remote, bearerToken: "t",
            videoId: 1, versionId: nil,
            store: CapturedDownloadStore(root: root()), session: mockSession(),
            onProgress: { captured, total in reports.append(captured, total) })
        _ = try await fetcher.loadContentInfo()
        _ = try await fetcher.data(for: .init(start: 0, end: 39))

        #expect(reports.last() == Pair(captured: 40, total: 100))
    }
```

And at file scope, below the suite:

```swift
struct Pair: Equatable, Sendable {
    let captured: Int64
    let total: Int64
}

/// Thread-safe collector: `onProgress` is `@Sendable` and fires off-actor.
final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Pair] = []
    func append(_ captured: Int64, _ total: Int64) {
        lock.withLock { values.append(Pair(captured: captured, total: total)) }
    }
    func last() -> Pair? { lock.withLock { values.last } }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter RangeFetcherConcurrencyTests`
Expected: FAIL to compile — `onProgress` takes one `Double`, not two `Int64`s.

- [x] **Step 3: Change the callback type through the stack**

In `RangeFetcher.swift`, change the stored property and initializer parameter:

```swift
    private let onProgress: @Sendable (Int64, Int64) -> Void
```
```swift
        onProgress: @escaping @Sendable (Int64, Int64) -> Void,
```

Replace both emission sites. In `loadContentInfo()`, `onProgress(m.progress)` becomes:

```swift
        onProgress(CapturedRanges.coveredBytes(m.capturedRanges), m.totalByteCount)
```

In `data(for:)`, `onProgress(current.progress)` becomes:

```swift
        onProgress(CapturedRanges.coveredBytes(current.capturedRanges), current.totalByteCount)
```

In `CaptureManager.asset(...)`, change the parameter type to match:

```swift
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
```

In `CacheManager.captureAsset(...)`, forward both values:

```swift
            onProgress: { [weak self] captured, total in
                self?.registerCaptureProgress(
                    key: key, videoId: videoId, versionId: versionId,
                    capturedBytes: captured, totalByteCount: total)
            })
```

Rewrite `registerCaptureProgress` to feed the accumulator real bytes:

```swift
    /// Publishes capture progress into `inFlight` so the grid shows a capturing
    /// video as `.downloading`. A manual download always wins: if one already
    /// owns the key, capture never claims it.
    private func registerCaptureProgress(
        key: String, videoId: Int, versionId: Int?,
        capturedBytes: Int64, totalByteCount: Int64
    ) {
        let progress = totalByteCount > 0
            ? min(max(Double(capturedBytes) / Double(totalByteCount), 0), 1)
            : 0
        lock.withLock {
            // A capture-progress callback means the manifest was just written to
            // disk — mirror it so `state(for:)` never has to read it back.
            capturedManifestProgress[key] = progress
            guard tasksByKey[key] == nil,
                  segmentedAttempts[key] == nil,
                  probeAttempts[key] == nil
            else { return }
            if inFlight[key] == nil {
                inFlight[key] = DownloadActivityAccumulator(
                    videoID: videoId, versionID: versionId,
                    totalByteCount: totalByteCount, now: now())
            }
            inFlight[key]?.record(
                transferredByteCount: capturedBytes,
                progress: progress,
                totalByteCount: totalByteCount,
                now: now())
        }
    }
```

Delete `overrideProgress` from `DownloadActivity.swift` (lines 70-82) — `record` now covers both callers.

Update the three existing fetcher test files: every `onProgress: { _ in }` becomes `onProgress: { _, _ in }`.

- [x] **Step 4: Run tests to verify they pass**

Run: `cd ios/PatataTubeKit && swift test`
Expected: PASS, full suite.

- [x] **Step 5: Commit**

```bash
git add ios/PatataTubeKit
git commit -m "feat(ios): report capture progress as captured/total bytes"
```

---

### Task 3: Parallel gap fetching — `fetchAll` and `downloadAll`

The download engine. Fetches only the manifest's complement, in ascending order (byte 0 first, so the faststart `moov` lands immediately), across a bounded worker pool.

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/RangeFetcher.swift` (add `fetchAll`, `downloadAll`, rewrite `finalize`)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/RangeFetcherFetchAllTests.swift` (create)

**Interfaces:**
- Consumes: `data(for:)`, `loadContentInfo()`, `CapturedRanges.complement(of:over:)`, `CapturedDownloadStore.publish(cacheKey:to:)`.
- Produces:
  - `RangeFetcher.fetchAll(concurrency: Int) async throws` — fills every gap; does not publish.
  - `RangeFetcher.downloadAll(concurrency: Int, destination: URL) async throws` — `fetchAll` then publish; throws `RangeFetcherError.lengthMismatch` if incomplete.
  - `RangeFetcher.chunkSize: Int64 = 4 * 1_048_576` (static).

- [ ] **Step 1: Write the failing test**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/RangeFetcherFetchAllTests.swift`:

```swift
import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Range fetcher fetchAll", .serialized)
struct RangeFetcherFetchAllTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fetchall-\(UUID().uuidString)")
    }
    private let body = Data((0..<100).map { UInt8($0) })
    private let remote = URL(string: "https://srv.test/videos/1/stream")!

    /// Serves 206 responses and records every GET range (the 0-0 probe excluded).
    private func installHandler(recorder: RangeRecorder) {
        let body = body
        MockURLProtocol.handler = { request in
            let spec = (request.value(forHTTPHeaderField: "Range") ?? "bytes=0-0")
                .replacingOccurrences(of: "bytes=", with: "")
            let parts = spec.split(separator: "-")
            let start = Int(parts[0])!
            let end = parts.count > 1 && !parts[1].isEmpty ? Int(parts[1])! : body.count - 1
            if !(start == 0 && end == 0) { recorder.record(start: start, end: end) }
            let slice = body.subdata(in: start..<(end + 1))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 206, httpVersion: nil,
                headerFields: [
                    "Accept-Ranges": "bytes",
                    "ETag": "\"v1\"",
                    "Content-Range": "bytes \(start)-\(end)/\(body.count)",
                    "Content-Length": "\(slice.count)",
                ])!
            return (response, slice)
        }
    }

    private func makeFetcher(store: CapturedDownloadStore) -> RangeFetcher {
        RangeFetcher(
            cacheKey: "1", remoteURL: remote, bearerToken: "t",
            videoId: 1, versionId: nil,
            store: store, session: mockSession(), onProgress: { _, _ in })
    }

    @Test func downloadAllPublishesCompleteFile() async throws {
        let recorder = RangeRecorder()
        installHandler(recorder: recorder)
        let root = root()
        let fetcher = makeFetcher(store: CapturedDownloadStore(root: root))
        let destination = root.appendingPathComponent("1.mp4")

        try await fetcher.downloadAll(concurrency: 4, destination: destination)

        #expect(try Data(contentsOf: destination) == body)
        #expect(recorder.covered() == [0...99])
    }

    @Test func fetchAllRequestsOnlyTheGaps() async throws {
        let recorder = RangeRecorder()
        installHandler(recorder: recorder)
        let root = root()
        let fetcher = makeFetcher(store: CapturedDownloadStore(root: root))
        // Simulate a half-watched video: capture the first half through the
        // same path playback uses.
        _ = try await fetcher.loadContentInfo()
        _ = try await fetcher.data(for: .init(start: 0, end: 49))
        recorder.reset()

        try await fetcher.fetchAll(concurrency: 2)

        #expect(recorder.covered() == [50...99])
        #expect(await fetcher.manifestSnapshot?.isComplete == true)
    }

    @Test func fetchAllFillsHolesLeftBySeeking() async throws {
        let recorder = RangeRecorder()
        installHandler(recorder: recorder)
        let fetcher = makeFetcher(store: CapturedDownloadStore(root: root()))
        _ = try await fetcher.loadContentInfo()
        _ = try await fetcher.data(for: .init(start: 20, end: 29))
        _ = try await fetcher.data(for: .init(start: 60, end: 69))
        recorder.reset()

        try await fetcher.fetchAll(concurrency: 1)

        #expect(recorder.covered() == [0...19, 30...59, 70...99])
    }

    @Test func capturedRangesAreServedFromDiskWithoutNetwork() async throws {
        let recorder = RangeRecorder()
        installHandler(recorder: recorder)
        let fetcher = makeFetcher(store: CapturedDownloadStore(root: root()))
        try await fetcher.fetchAll(concurrency: 2)
        recorder.reset()

        let data = try await fetcher.data(for: .init(start: 30, end: 39))

        #expect(data == body.subdata(in: 30..<40))
        #expect(recorder.covered().isEmpty)
    }
}

/// Collects requested ranges and merges them into minimal closed ranges so a
/// test can assert on coverage without depending on chunk boundaries.
final class RangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var ranges: [ClosedRange<Int>] = []

    func record(start: Int, end: Int) {
        lock.withLock { ranges.append(start...end) }
    }
    func reset() { lock.withLock { ranges = [] } }
    func covered() -> [ClosedRange<Int>] {
        let sorted = lock.withLock { ranges }.sorted { $0.lowerBound < $1.lowerBound }
        guard var current = sorted.first else { return [] }
        var merged: [ClosedRange<Int>] = []
        for next in sorted.dropFirst() {
            if next.lowerBound <= current.upperBound + 1 {
                current = current.lowerBound...max(current.upperBound, next.upperBound)
            } else {
                merged.append(current)
                current = next
            }
        }
        merged.append(current)
        return merged
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter RangeFetcherFetchAllTests`
Expected: FAIL to compile — `fetchAll` and `downloadAll` do not exist.

- [ ] **Step 3: Implement `fetchAll` / `downloadAll`**

In `RangeFetcher.swift`, add the chunk constant next to the other stored properties:

```swift
    /// Gap-fill request size. Also the maximum work lost when the app is
    /// suspended mid-transfer.
    static let chunkSize: Int64 = 4 * 1_048_576
```

Replace the existing `finalize(destination:)` with:

```swift
    /// Fetches every uncaptured byte using `concurrency` parallel workers,
    /// ascending by offset so the file head (and its faststart `moov`) lands
    /// first and playback can start off disk immediately.
    func fetchAll(concurrency: Int) async throws {
        let info = try await loadContentInfo()
        let workers = min(max(concurrency, 1), 4)
        var chunks: [DownloadByteRange] = []
        for gap in CapturedRanges.complement(
            of: manifest?.capturedRanges ?? [], over: info.totalByteCount
        ) {
            var start = gap.start
            while start <= gap.end {
                let end = min(start + Self.chunkSize - 1, gap.end)
                chunks.append(DownloadByteRange(start: start, end: end))
                start = end + 1
            }
        }
        guard !chunks.isEmpty else { return }

        var next = 0
        try await withThrowingTaskGroup(of: Void.self) { group in
            func addNext() {
                guard next < chunks.count else { return }
                let range = chunks[next]
                next += 1
                group.addTask { _ = try await self.data(for: range) }
            }
            for _ in 0..<min(workers, chunks.count) { addNext() }
            while try await group.next() != nil {
                try Task.checkCancellation()
                addNext()
            }
        }
    }

    /// `fetchAll` plus publication into the cache. Leaves the partial intact and
    /// rethrows on any failure (never publishes a partial).
    func downloadAll(concurrency: Int, destination: URL) async throws {
        try await fetchAll(concurrency: concurrency)
        guard let m = manifest, m.isComplete else { throw RangeFetcherError.lengthMismatch }
        try store.publish(cacheKey: cacheKey, to: destination)
        manifest = nil
    }

    /// Watch-to-cache finalisation: single-worker completion of a partial.
    func finalize(destination: URL) async throws {
        try await downloadAll(concurrency: 1, destination: destination)
    }
}
```

(The old `finalize` body — the serial gap loop plus publish — is fully replaced; delete it.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios/PatataTubeKit && swift test --filter RangeFetcher`
Expected: PASS — including the existing `RangeFetcherFinalizeTests`, which now exercises `finalize` via `downloadAll`.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit
git commit -m "feat(ios): fill partial gaps with parallel ascending range fetches"
```

---

### Task 4: Shared fetcher registry, with playback back-pressure

Downloads and playback must resolve the *same* actor for a key. The registry also carries the rule that a background download drops to one worker while the same video is playing, so it cannot starve the playhead.

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/RangeFetcherRegistry.swift`
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/RangeFetcher.swift` (fetch origin + player-activity clock)
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CaptureManager.swift` (use the registry, tag loader fetches as `.player`)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/RangeFetcherRegistryTests.swift` (create)

**Interfaces:**
- Consumes: `RangeFetcher.init`, `fetchAll(concurrency:)` from Task 3.
- Produces:
  - `enum FetchOrigin: Sendable { case player, downloader }`
  - `RangeFetcher.data(for:origin:)` — `origin` defaults to `.downloader`.
  - `static RangeFetcher.effectiveConcurrency(requested: Int, lastPlayerRequestAt: Date?, now: Date) -> Int`
  - `final class RangeFetcherRegistry: @unchecked Sendable` with
    `fetcher(videoId:versionId:remoteURL:bearerToken:onProgress:) -> RangeFetcher` (get-or-create by cache key),
    `existing(cacheKey:) -> RangeFetcher?`,
    `remove(cacheKey:)`.

- [ ] **Step 1: Write the failing test**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/RangeFetcherRegistryTests.swift`:

```swift
import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Range fetcher registry")
struct RangeFetcherRegistryTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-\(UUID().uuidString)")
    }
    private let remote = URL(string: "https://srv.test/videos/7/stream")!

    private func makeRegistry() -> RangeFetcherRegistry {
        RangeFetcherRegistry(
            store: CapturedDownloadStore(root: root()), session: mockSession())
    }

    @Test func sameKeyReturnsSameFetcher() {
        let registry = makeRegistry()
        let a = registry.fetcher(
            videoId: 7, versionId: nil, remoteURL: remote,
            bearerToken: "t", onProgress: { _, _ in })
        let b = registry.fetcher(
            videoId: 7, versionId: nil, remoteURL: remote,
            bearerToken: "t", onProgress: { _, _ in })
        #expect(a === b)
        #expect(registry.existing(cacheKey: "7") === a)
    }

    @Test func versionedKeysAreDistinct() {
        let registry = makeRegistry()
        let plain = registry.fetcher(
            videoId: 7, versionId: nil, remoteURL: remote,
            bearerToken: "t", onProgress: { _, _ in })
        let versioned = registry.fetcher(
            videoId: 7, versionId: 3, remoteURL: remote,
            bearerToken: "t", onProgress: { _, _ in })
        #expect(plain !== versioned)
        #expect(registry.existing(cacheKey: "7:3") === versioned)
    }

    @Test func removeDropsTheFetcher() {
        let registry = makeRegistry()
        _ = registry.fetcher(
            videoId: 7, versionId: nil, remoteURL: remote,
            bearerToken: "t", onProgress: { _, _ in })
        registry.remove(cacheKey: "7")
        #expect(registry.existing(cacheKey: "7") == nil)
    }

    @Test func concurrencyDropsToOneWhilePlaybackIsRecent() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(RangeFetcher.effectiveConcurrency(
            requested: 4, lastPlayerRequestAt: now.addingTimeInterval(-2), now: now) == 1)
    }

    @Test func concurrencyRestoresAfterPlaybackGoesQuiet() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(RangeFetcher.effectiveConcurrency(
            requested: 4, lastPlayerRequestAt: now.addingTimeInterval(-60), now: now) == 4)
        #expect(RangeFetcher.effectiveConcurrency(
            requested: 4, lastPlayerRequestAt: nil, now: now) == 4)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter RangeFetcherRegistryTests`
Expected: FAIL to compile — `RangeFetcherRegistry` and `effectiveConcurrency` do not exist.

- [ ] **Step 3: Add fetch origin and the concurrency rule to `RangeFetcher`**

At file scope in `RangeFetcher.swift`:

```swift
/// Who asked for a range. Player requests are latency-sensitive and throttle
/// any concurrent background download of the same video.
enum FetchOrigin: Sendable {
    case player
    case downloader
}
```

Inside the actor, add the stored clock and property:

```swift
    /// When the resource loader last asked for bytes. Drives back-pressure on a
    /// concurrent background download of the same video.
    private var lastPlayerRequestAt: Date?
    private let now: @Sendable () -> Date
```

Add `now` to the initializer with a default (`now: @escaping @Sendable () -> Date = Date.init`) and assign it, keeping every existing call site source-compatible.

Change `data(for:)` to take an origin and stamp the clock:

```swift
    func data(for range: DownloadByteRange, origin: FetchOrigin = .downloader) async throws -> Data {
        if origin == .player { lastPlayerRequestAt = now() }
```

(the rest of the body is unchanged from Task 1).

Add the rule and apply it in `fetchAll`:

```swift
    /// A background download yields to a live playhead: while the resource
    /// loader has asked for bytes within this window, only one worker runs.
    static let playbackBackPressureWindow: TimeInterval = 10

    static func effectiveConcurrency(
        requested: Int, lastPlayerRequestAt: Date?, now: Date
    ) -> Int {
        let clamped = min(max(requested, 1), 4)
        guard let lastPlayerRequestAt,
              now.timeIntervalSince(lastPlayerRequestAt) < playbackBackPressureWindow
        else { return clamped }
        return 1
    }
```

In `fetchAll`, replace `let workers = min(max(concurrency, 1), 4)` with a per-dispatch check so back-pressure engages and releases mid-download:

```swift
        func workerBudget() -> Int {
            Self.effectiveConcurrency(
                requested: concurrency, lastPlayerRequestAt: lastPlayerRequestAt, now: now())
        }
```

and use `for _ in 0..<min(workerBudget(), chunks.count) { addNext() }` for the initial fill, and inside the drain loop:

```swift
            while try await group.next() != nil {
                try Task.checkCancellation()
                // One completion frees one slot; add a replacement only while the
                // budget allows, so a playing video shrinks the pool live.
                if workerBudget() > 0 { addNext() }
            }
```

Because the group shrinks by one per completion and grows by at most one, the pool converges down to the budget as workers finish.

- [ ] **Step 4: Create the registry**

Create `ios/PatataTubeKit/Sources/PatataTubeKit/RangeFetcherRegistry.swift`:

```swift
import Foundation

/// One `RangeFetcher` per video, shared by playback capture and explicit
/// download. Both paths must reach the *same* actor for a cache key — that is
/// what makes their bytes visible to each other.
final class RangeFetcherRegistry: @unchecked Sendable {
    private let store: CapturedDownloadStore
    private let session: URLSession
    private let lock = NSLock()
    private var fetchers: [String: RangeFetcher] = [:]

    init(store: CapturedDownloadStore, session: URLSession) {
        self.store = store
        self.session = session
    }

    static func cacheKey(videoId: Int, versionId: Int?) -> String {
        versionId.map { "\(videoId):\($0)" } ?? "\(videoId)"
    }

    /// Existing fetcher for the key, or a new one. `onProgress` is used only
    /// when creating — an existing fetcher keeps the callback it was built with,
    /// which is already wired to the same `CacheManager`.
    func fetcher(
        videoId: Int,
        versionId: Int?,
        remoteURL: URL,
        bearerToken: String?,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) -> RangeFetcher {
        let key = Self.cacheKey(videoId: videoId, versionId: versionId)
        return lock.withLock {
            if let existing = fetchers[key] { return existing }
            let fetcher = RangeFetcher(
                cacheKey: key, remoteURL: remoteURL, bearerToken: bearerToken,
                videoId: videoId, versionId: versionId,
                store: store, session: session, onProgress: onProgress)
            fetchers[key] = fetcher
            return fetcher
        }
    }

    func existing(cacheKey: String) -> RangeFetcher? {
        lock.withLock { fetchers[cacheKey] }
    }

    func remove(cacheKey: String) {
        lock.withLock { fetchers[cacheKey] = nil }
    }
}
```

- [ ] **Step 5: Point `CaptureManager` at the registry**

In `CaptureManager.swift`: delete the `fetchers` dictionary and the `store`/`session` properties; take a registry instead.

```swift
    private let registry: RangeFetcherRegistry
    private let delegateQueue = DispatchQueue(label: "patatatube.capture.loader")
    private let lock = NSLock()
    private var keysByCaptureURL: [URL: String] = [:]

    init(registry: RangeFetcherRegistry) {
        self.registry = registry
    }
```

`fetcher(forCacheKey:)` becomes `registry.existing(cacheKey: key)`. In `asset(...)`, replace the local `RangeFetcher(...)` construction with:

```swift
        let fetcher = registry.fetcher(
            videoId: videoId, versionId: versionId, remoteURL: remoteURL,
            bearerToken: bearerToken, onProgress: onProgress)
        _ = fetcher
        let captureURL = Self.captureURL(from: remoteURL) ?? remoteURL
        lock.withLock { keysByCaptureURL[captureURL] = key }
```

In the resource-loader delegate, tag the fetch as a player request:

```swift
                        let data = try await fetcher.data(
                            for: DownloadByteRange(start: offset, end: chunkEnd),
                            origin: .player)
```

In `CacheManager`, replace the `captureManager` lazy property's construction with the registry (add `private lazy var fetcherRegistry = RangeFetcherRegistry(store: capturedStore, session: session)` and pass it):

```swift
    private lazy var captureManager = CaptureManager(registry: fetcherRegistry)
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd ios/PatataTubeKit && swift test`
Expected: PASS, full suite (`CaptureManagerSchemeTests` and `CacheManagerCaptureStateTests` included).

- [ ] **Step 7: Commit**

```bash
git add ios/PatataTubeKit
git commit -m "feat(ios): share one range fetcher per video across capture and download"
```

---

### Task 5: Rewrite `download` onto the range path

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift` — `download(...)` (line ~387), `resumeInterrupted(...)` (line ~414)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerRangeDownloadTests.swift` (create)

**Interfaces:**
- Consumes: `RangeFetcherRegistry.fetcher(...)`, `RangeFetcher.downloadAll(concurrency:destination:)`, `registerCaptureProgress(...)` from Task 2.
- Produces:
  - `CacheManager.download(id:versionId:from:preview:showPosterKey:showPoster:bearerToken:streamCount:)` — signature unchanged, implementation replaced.
  - `private var downloadTasks: [String: Task<Void, Error>]` — the cancellation handle used by Task 6.

- [ ] **Step 1: Write the failing test**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerRangeDownloadTests.swift`:

```swift
import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Cache manager range download", .serialized)
struct CacheManagerRangeDownloadTests {
    private let body = Data((0..<100).map { UInt8($0) })
    private let remote = URL(string: "https://srv.test/videos/1/stream")!

    private func root() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cm-range-\(UUID().uuidString)")
    }

    private func installHandler() {
        let body = body
        MockURLProtocol.handler = { request in
            let spec = (request.value(forHTTPHeaderField: "Range") ?? "bytes=0-0")
                .replacingOccurrences(of: "bytes=", with: "")
            let parts = spec.split(separator: "-")
            let start = Int(parts[0])!
            let end = parts.count > 1 && !parts[1].isEmpty ? Int(parts[1])! : body.count - 1
            let slice = body.subdata(in: start..<(end + 1))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 206, httpVersion: nil,
                headerFields: [
                    "Accept-Ranges": "bytes",
                    "ETag": "\"v1\"",
                    "Content-Range": "bytes \(start)-\(end)/\(body.count)",
                    "Content-Length": "\(slice.count)",
                ])!
            return (response, slice)
        }
    }

    private func makeManager(root: URL) -> CacheManager {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return CacheManager(root: root, configuration: config)
    }

    @Test func downloadWritesCompleteFileAndReportsCached() async throws {
        installHandler()
        let root = root()
        let manager = makeManager(root: root)

        try await manager.download(id: 1, from: remote, bearerToken: "t", streamCount: 4)

        #expect(manager.state(for: 1) == .cached)
        #expect(try Data(contentsOf: manager.localURL(for: 1)) == body)
        #expect(manager.recentDownloads().contains { $0.videoID == 1 })
    }

    @Test func downloadResumesFromBytesLeftByPlayback() async throws {
        installHandler()
        let root = root()
        let manager = makeManager(root: root)
        // Watch-capture the first half through the public capture path.
        let asset = manager.captureAsset(
            videoId: 1, remoteURL: remote, bearerToken: "t")
        #expect(asset.url.scheme == CaptureManager.scheme)
        let fetcher = try #require(manager.testFetcher(videoId: 1, versionId: nil))
        _ = try await fetcher.data(for: .init(start: 0, end: 49), origin: .player)
        #expect(manager.state(for: 1) == .downloading(0.5))

        try await manager.download(id: 1, from: remote, bearerToken: "t", streamCount: 2)

        #expect(manager.state(for: 1) == .cached)
        #expect(try Data(contentsOf: manager.localURL(for: 1)) == body)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter CacheManagerRangeDownloadTests`
Expected: FAIL to compile — `testFetcher(videoId:versionId:)` does not exist.

- [ ] **Step 3: Rewrite `download` and add the test hook**

In `CacheManager.swift`, add the task registry alongside the other stored properties:

```swift
    /// Live range downloads, keyed by cache key. Cancelling one stops its
    /// workers and leaves the partial on disk for a later resume.
    private var downloadTasks: [String: Task<Void, Error>] = [:]
```

Replace the body of `download(...)`:

```swift
    public func download(id: Int, versionId: Int? = nil, from remote: URL, preview: URL? = nil,
                         showPosterKey: String? = nil, showPoster: URL? = nil,
                         bearerToken: String? = nil, streamCount: Int = 1) async throws {
        await concurrencyGate.acquire()
        defer { concurrencyGate.release() }
        let key = cacheKey(videoId: id, versionId: versionId)
        let destination = localURL(for: id, versionId: versionId)

        if !fileManager.fileExists(atPath: destination.path) {
            let fetcher = fetcherRegistry.fetcher(
                videoId: id, versionId: versionId, remoteURL: remote, bearerToken: bearerToken,
                onProgress: { [weak self] captured, total in
                    self?.registerCaptureProgress(
                        key: key, videoId: id, versionId: versionId,
                        capturedBytes: captured, totalByteCount: total)
                })
            let workers = min(max(streamCount, 1), 4)
            let task = Task { try await fetcher.downloadAll(
                concurrency: workers, destination: destination) }
            lock.withLock {
                downloadTasks[key] = task
                if inFlight[key] == nil {
                    inFlight[key] = DownloadActivityAccumulator(
                        videoID: id, versionID: versionId, totalByteCount: nil, now: now())
                }
            }
            do {
                try await task.value
            } catch {
                lock.withLock {
                    downloadTasks[key] = nil
                    inFlight[key] = nil
                }
                throw error
            }
            lock.withLock {
                downloadTasks[key] = nil
                inFlight[key] = nil
                // Publishing removed the manifest; drop the mirror so the video
                // stops reporting as in-progress.
                capturedManifestProgress[key] = nil
                completionHistory.record(DownloadCompletion(
                    videoID: id, versionID: versionId, completedAt: now()))
            }
            fetcherRegistry.remove(cacheKey: key)
        }
        // Best-effort: a missing preview must not fail the cached video.
        if let preview { try? await cachePreview(id: id, from: preview, bearerToken: bearerToken) }
        // Show poster is shared across episodes: fetch once, skip when cached.
        if let showPosterKey, let showPoster, cachedShowPosterURL(for: showPosterKey) == nil {
            try? await cacheShowPoster(key: showPosterKey, from: showPoster, bearerToken: bearerToken)
        }
    }
```

Update the "a manual download wins" guard inside `registerCaptureProgress` — the segmented and probe maps are gone after Task 7, and the live-download check is now the task map:

```swift
            guard downloadTasks[key] == nil else { return }
```

Add the test hook near the other internal helpers:

```swift
    /// Test seam: the live fetcher for a key, so a test can drive playback-side
    /// captures without an `AVPlayer`.
    func testFetcher(videoId: Int, versionId: Int?) -> RangeFetcher? {
        fetcherRegistry.existing(cacheKey: cacheKey(videoId: videoId, versionId: versionId))
    }
```

Replace `resumeInterrupted(...)` entirely:

```swift
    /// Restarts downloads interrupted by app suspension. Call when the app
    /// returns to the foreground (and on launch): every partial on disk carries
    /// a manifest of exactly which bytes it holds, so a restart re-requests only
    /// the gaps. Fire-and-forget — no caller awaits the result. Returns the
    /// video ids it resumed.
    @discardableResult
    public func resumeInterrupted(bearerToken: String? = nil) -> [Int] {
        var resumed: [Int] = []
        for manifest in capturedStore.manifests() {
            let key = manifest.cacheKey
            let destination = localURL(for: manifest.videoId, versionId: manifest.versionId)
            if fileManager.fileExists(atPath: destination.path) {
                capturedStore.remove(cacheKey: key)
                lock.withLock { capturedManifestProgress[key] = nil }
                continue
            }
            guard lock.withLock({ downloadTasks[key] == nil }) else { continue }
            let videoId = manifest.videoId
            let versionId = manifest.versionId
            let fetcher = fetcherRegistry.fetcher(
                videoId: videoId, versionId: versionId, remoteURL: manifest.remoteURL,
                bearerToken: bearerToken,
                onProgress: { [weak self] captured, total in
                    self?.registerCaptureProgress(
                        key: key, videoId: videoId, versionId: versionId,
                        capturedBytes: captured, totalByteCount: total)
                })
            let task = Task { try await fetcher.downloadAll(
                concurrency: 1, destination: destination) }
            lock.withLock {
                downloadTasks[key] = task
                if inFlight[key] == nil {
                    inFlight[key] = DownloadActivityAccumulator(
                        videoID: videoId, versionID: versionId,
                        totalByteCount: manifest.totalByteCount, now: now())
                }
            }
            resumed.append(videoId)
        }
        return resumed
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios/PatataTubeKit && swift test --filter CacheManagerRangeDownloadTests`
Expected: PASS, both tests.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit
git commit -m "feat(ios): download videos through the shared range fetcher"
```

---

### Task 6: Cancel keeps bytes, and `.paused` names that state

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift:5-9` (`CacheState`), `cancel(...)` (~line 502), `state(for:)` (~line 287)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerRangeDownloadTests.swift`

**Interfaces:**
- Consumes: `downloadTasks` from Task 5.
- Produces:
  - `CacheState.paused(Double)` — partial on disk, nothing running, not cached.
  - `CacheManager.removePartial(id:versionId:)` — deletes a partial and its manifest.

- [ ] **Step 1: Write the failing test**

Append to the suite in `CacheManagerRangeDownloadTests.swift`:

```swift
    @Test func cancelKeepsPartialAndReportsPaused() async throws {
        installHandler()
        let root = root()
        let manager = makeManager(root: root)
        let asset = manager.captureAsset(videoId: 1, remoteURL: remote, bearerToken: "t")
        #expect(asset.url.scheme == CaptureManager.scheme)
        let fetcher = try #require(manager.testFetcher(videoId: 1, versionId: nil))
        _ = try await fetcher.data(for: .init(start: 0, end: 39), origin: .player)

        manager.cancel(id: 1)

        #expect(manager.state(for: 1) == .paused(0.4))
        let partial = CapturedDownloadStore(root: root).partURL(cacheKey: "1")
        #expect(FileManager.default.fileExists(atPath: partial.path))
    }

    @Test func resumeAfterCancelCompletesFromGaps() async throws {
        installHandler()
        let root = root()
        let manager = makeManager(root: root)
        let asset = manager.captureAsset(videoId: 1, remoteURL: remote, bearerToken: "t")
        #expect(asset.url.scheme == CaptureManager.scheme)
        let fetcher = try #require(manager.testFetcher(videoId: 1, versionId: nil))
        _ = try await fetcher.data(for: .init(start: 0, end: 39), origin: .player)
        manager.cancel(id: 1)

        try await manager.download(id: 1, from: remote, bearerToken: "t", streamCount: 2)

        #expect(manager.state(for: 1) == .cached)
        #expect(try Data(contentsOf: manager.localURL(for: 1)) == body)
    }

    @Test func removePartialClearsPausedState() async throws {
        installHandler()
        let root = root()
        let manager = makeManager(root: root)
        let asset = manager.captureAsset(videoId: 1, remoteURL: remote, bearerToken: "t")
        #expect(asset.url.scheme == CaptureManager.scheme)
        let fetcher = try #require(manager.testFetcher(videoId: 1, versionId: nil))
        _ = try await fetcher.data(for: .init(start: 0, end: 39), origin: .player)
        manager.cancel(id: 1)

        manager.removePartial(id: 1)

        #expect(manager.state(for: 1) == .notCached)
        let partial = CapturedDownloadStore(root: root).partURL(cacheKey: "1")
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter CacheManagerRangeDownloadTests`
Expected: FAIL to compile — `.paused` and `removePartial` do not exist.

- [ ] **Step 3: Add the state, the cancel semantics, and the delete**

Extend the enum:

```swift
public enum CacheState: Equatable, Sendable {
    case notCached
    case downloading(Double)
    /// Bytes on disk, nothing transferring. Re-downloading resumes from the gaps.
    case paused(Double)
    case cached
}
```

Rewrite `state(for:)`:

```swift
    public func state(for id: Int, versionId: Int? = nil) -> CacheState {
        let key = cacheKey(videoId: id, versionId: versionId)
        if fileManager.fileExists(atPath: localURL(for: id, versionId: versionId).path) { return .cached }
        return lock.withLock {
            // An `inFlight` entry means something is transferring right now —
            // a download task or a live capture.
            if let accumulator = inFlight[key] { return .downloading(accumulator.activity.progress) }
            if let progress = capturedManifestProgress[key] { return .paused(progress) }
            return .notCached
        }
    }
```

Note the ordering: a live `inFlight` entry (download *or* active capture) still reads `.downloading`; only a manifest with nothing running reads `.paused`.

Rewrite `cancel(...)` — it now only stops workers:

```swift
    /// Stops an in-flight download for this id/version. The awaiting `download`
    /// call throws. The partial and its manifest stay on disk: `state(for:)`
    /// reports `.paused(progress)` and a later download resumes from the gaps.
    /// Use `removePartial` to reclaim the disk.
    public func cancel(id: Int, versionId: Int? = nil) {
        let key = cacheKey(videoId: id, versionId: versionId)
        let task = lock.withLock { () -> Task<Void, Error>? in
            let task = downloadTasks.removeValue(forKey: key)
            inFlight[key] = nil
            return task
        }
        task?.cancel()
    }
```

Add the explicit delete:

```swift
    /// Deletes a partial download and its manifest, reclaiming the disk. Leaves
    /// any fully cached MP4 alone (see `removeCached`).
    public func removePartial(id: Int, versionId: Int? = nil) {
        let key = cacheKey(videoId: id, versionId: versionId)
        cancel(id: id, versionId: versionId)
        capturedStore.remove(cacheKey: key)
        fetcherRegistry.remove(cacheKey: key)
        lock.withLock { capturedManifestProgress[key] = nil }
    }
```

In `removeCached`, `removeAllCached`, and `clearAllVideos`, add `fetcherRegistry.remove(cacheKey:)` next to each existing `capturedStore.remove(cacheKey:)` call, so a deleted partial does not leave a stale actor holding an in-memory manifest.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios/PatataTubeKit && swift test --filter CacheManagerRangeDownloadTests`
Expected: PASS, all five tests.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit
git commit -m "feat(ios): keep partial bytes on cancel and surface a paused state"
```

---

### Task 7: Delete the segmented downloader

Everything the new path replaced comes out. This is the task that shrinks the codebase; run the whole suite before committing.

**Files:**
- Delete: `ios/PatataTubeKit/Sources/PatataTubeKit/SegmentedDownload.swift`
- Delete: `ios/PatataTubeKit/Tests/PatataTubeKitTests/SegmentedDownloadTests.swift`
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift` (remove segmented state, delegate conformance, resume-data plumbing)
- Modify: `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift` (drop segmented/legacy-resume tests)
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/DownloadActivity.swift` (remove `establishResumeSamplingBaseline`)

**Interfaces:**
- Consumes: the range path from Tasks 5-6.
- Produces: `DownloadByteRange` moves into `RangeFetcher.swift` (it is the only surviving type from the deleted file, and every remaining user is the fetcher).

- [ ] **Step 1: Move the surviving type, delete the file**

Move `struct DownloadByteRange` (with its `headerValue`, `length`, and `split` members — `split` is used only by the deleted code, so drop `split` and keep the rest) from `SegmentedDownload.swift` into the top of `RangeFetcher.swift`:

```swift
struct DownloadByteRange: Codable, Equatable, Sendable {
    let start: Int64
    let end: Int64

    var length: Int64 { end - start + 1 }
    var headerValue: String { "bytes=\(start)-\(end)" }
}
```

Then:

```bash
git rm ios/PatataTubeKit/Sources/PatataTubeKit/SegmentedDownload.swift
git rm ios/PatataTubeKit/Tests/PatataTubeKitTests/SegmentedDownloadTests.swift
```

- [ ] **Step 2: Strip `CacheManager` down**

Delete from `CacheManager.swift`:

- the `SegmentedAttempt` class, `SegmentTaskContext`, and `FreshProbeAttempt` types
- the stored properties `segmentedStore`, `segmentedAttempts`, `probeAttempts`, `segmentContextByTask`, `tasksByIdentifier`, `tasksByKey`, `idByTask`, `completedResults`, `continuations`, `legacyResumeBaselineTaskIDs`
- every `URLSessionDownloadDelegate` method (`didWriteData`, `didFinishDownloadingTo`, `didCompleteWithError`) and the `URLSessionDownloadDelegate` conformance in the class declaration
- `downloadVideo`, `downloadLegacy`, `startIncompleteSegments`, `recordSegmentFile`, `completeSegmentTask`, `claimSegmentedAttemptLocked`, `completeSegmentedClaim`, `updateSegmentProgress`, `cancelProbeAttempt`, `finish(key:taskIdentifier:result:)`, `persistResumeData`, `resumeData(from:)`, `resumeURL(for:)`, and `activityAccumulator(manifest:activeByteCounts:)`
- the `.resume` file handling in `removeAllCached` and `clearAllVideos`, and the `segmentedStore.manifests()` loops in `removeAllCached` and `clearAllVideos`

The class declaration becomes:

```swift
public final class CacheManager: NSObject, @unchecked Sendable {
```

and the session is now a plain delegate-less session:

```swift
        self.session = URLSession(configuration: configuration)
```

Keep: `cancellationFence` and `concurrencyGate` (still used), `completionHistory`, `capturedStore`, `capturedManifestProgress`, `inFlight`, `downloadTasks`.

Delete `establishResumeSamplingBaseline` from `DownloadActivity.swift` and its test in `DownloadActivityTests.swift:45`.

- [ ] **Step 3: Prune the tests that covered deleted code**

In `CacheManagerTests.swift`, delete every test that references `segmentedStore`, `SegmentedDownloadManifest`, `.resume` files, `resumeInterrupted` with resume data, or the URLSession delegate callbacks directly. Keep tests covering `localURL`, previews, posters, `removeCached`/`removeAllCached`/`clearAllVideos`/`clearAllCovers`, `hasAnyCached`, `recentDownloads`, and the concurrency gate.

- [ ] **Step 4: Run the full suite**

Run: `cd ios/PatataTubeKit && swift build && swift test`
Expected: PASS, no build warnings about unused properties. If a deleted test covered behaviour the new path still has (e.g. "download of an already-cached file is a no-op"), port it to `CacheManagerRangeDownloadTests` rather than dropping it.

- [ ] **Step 5: Commit**

```bash
git add -A ios/PatataTubeKit
git commit -m "refactor(ios): delete segmented downloader in favour of range fetching"
```

---

### Task 8: Surface `.paused` in the UI

**Files:**
- Modify: `ios/PatataTube/Sources/DownloadButton.swift:33-107` (`effectiveState`, `clampedProgress`, `showsArmedDelete`), `:214-278` (`cacheControl`)
- Modify: `ios/PatataTube/Sources/VideoCell.swift:236-242` (`cacheStateLabel`)
- Modify: `ios/PatataTube/Sources/VideoGridView.swift:116` (wire delete-partial)
- Test: `ios/PatataTube/Tests/DownloadButtonTests.swift`

**Interfaces:**
- Consumes: `CacheState.paused(Double)`, `CacheManager.removePartial(id:versionId:)` from Task 6.
- Produces: `DownloadButton.onDeletePartial: () -> Void` — a new required closure parameter on the initializer.

- [ ] **Step 1: Write the failing test**

Append to `ios/PatataTube/Tests/DownloadButtonTests.swift`:

```swift
    @Test func pausedStateExposesItsProgress() {
        let state = DownloadButtonState(initialCacheState: .paused(0.4))
        #expect(state.effectiveState == .paused(0.4))
        #expect(state.clampedProgress == 0.4)
        #expect(state.isDownloading == false)
    }

    @Test func pausedStateArmsForDelete() {
        let state = DownloadButtonState(initialCacheState: .paused(0.4))
        #expect(state.showsArmedDelete == false)
        state.arm()
        #expect(state.showsArmedDelete == true)
    }

    @Test func beginningADownloadFromPausedShowsDownloading() {
        let state = DownloadButtonState(initialCacheState: .paused(0.4))
        state.begin()
        #expect(state.isDownloading == true)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/PatataTube/PatataTube && xcodegen generate` then run the `PatataTube` test target in Xcode (⌘U), or `xcodebuild test -scheme PatataTube -destination 'platform=iOS Simulator,name=iPad (10th generation)'`.
Expected: FAIL to compile — `.paused` is not handled and `showsArmedDelete` is `cached`-only.

- [ ] **Step 3: Handle `.paused` in the button**

In `DownloadButtonState`, widen the armed-delete predicate to cover both deletable states:

```swift
    var showsArmedDelete: Bool {
        guard isArmed else { return false }
        if case .paused = effectiveState { return true }
        return effectiveState == .cached
    }
```

`clampedProgress` already falls through to `self.progress` for non-`.downloading` states; make it read a paused progress too:

```swift
    var clampedProgress: Double {
        let value: Double
        switch effectiveState {
        case .downloading(let progress), .paused(let progress):
            value = progress
        default:
            value = self.progress
        }
        return min(max(value, 0), 1)
    }
```

In `DownloadButton`, add the parameter `let onDeletePartial: () -> Void` (and to the memberwise initializer, next to `onCancel`), then add the case to `cacheControl`:

```swift
        case .paused(let progress):
            Button {
                if state.showsArmedDelete {
                    onDeletePartial()
                    withAnimation { state.reset(to: .notCached) }
                } else if state.isArmed {
                    withAnimation { state.arm() }
                } else {
                    Task { @MainActor in
                        let attemptID = withAnimation { state.begin() }
                        let succeeded = await onDownload()
                        withAnimation {
                            state.finish(attemptID: attemptID, succeeded: succeeded)
                        }
                    }
                }
            } label: {
                ZStack {
                    Circle()
                        .stroke(Color.gray.opacity(0.25), lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: min(max(progress, 0), 1))
                        .stroke(
                            Color.secondary,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    Image(systemName: state.showsArmedDelete ? "x.circle.fill" : "arrow.down.circle")
                        .foregroundStyle(state.showsArmedDelete ? .red : Color.accentColor)
                        .font(.system(size: 18))
                }
                .frame(width: 30, height: 30)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state.showsArmedDelete ? "Delete partial download" : "Resume download")
            .accessibilityValue("\(Int(min(max(progress, 0), 1) * 100))%")
```

A long-press is deliberately not used: this reuses the arm-then-confirm tap already established for `.cached`.

Also handle the new case in the `switch cacheState` at `DownloadButton.swift:101` (the initial-progress mapping) — `case .paused(let p): progress = p`.

In `VideoCell.swift`:

```swift
        case .paused(let p): return "Paused (\(Int(p * 100))%)"
```

In `VideoGridView.swift:116`, pass the new closure next to `onCancel`:

```swift
                                onDeletePartial: { cache.removePartial(id: videoId, versionId: versionId) },
```

Add the same argument at every other `DownloadButton(` call site the compiler flags (`EpisodesView.swift`, `MovieDetailView.swift`, `DownloadsView.swift` if present) using the same `cache.removePartial(...)` call.

- [ ] **Step 4: Run tests to verify they pass**

Run the `PatataTube` test target (⌘U in Xcode, or the `xcodebuild test` command above).
Expected: PASS, including the existing `DownloadButtonTests`, `VideoGridViewTests`, `EpisodesViewTests`.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTube
git commit -m "feat(ios): show paused partial downloads with resume and delete"
```

---

### Task 9: Manual verification and checklist update

**Files:**
- Modify: `ios/README.md` (manual test checklist)

**Interfaces:**
- Consumes: everything.
- Produces: no code.

- [ ] **Step 1: Build and run on a device or simulator**

```bash
cd ios/PatataTube && xcodegen generate && open PatataTube.xcodeproj
```

Run the app against the dev server (`./serve` from the repo root, backend log at `log/backend.log`).

- [ ] **Step 2: Verify download → play**

Start downloading a large MP4 (a twitter/youtube row, not a library movie). At roughly 30%, tap play. Expect: playback starts with no buffering spinner, and the ring keeps climbing during playback.

- [ ] **Step 3: Verify play → download**

On a different uncached MP4, play through roughly half, then leave the player. Expect: the cell shows a paused ring near 50%. Tap it. Expect: it resumes and finishes rather than restarting from 0 (confirm in `log/backend.log` that the served `Range` requests start around the halfway offset, not at 0).

- [ ] **Step 4: Verify cancel and delete**

Start a download, cancel at ~20%. Expect: paused ring at 20%, bytes retained. Tap once → red x. Tap again → partial deleted, button returns to the download arrow.

- [ ] **Step 5: Add the checks to the checklist and commit**

Append to the manual test checklist in `ios/README.md`:

```markdown
- [ ] Download an MP4 to ~30%, then play it — playback starts immediately with no
      buffering spinner, and the download ring keeps advancing.
- [ ] Play an uncached MP4 halfway, exit, then tap download — the ring starts near
      50% and only the remaining bytes transfer.
- [ ] Cancel a download mid-way — the ring stays at its progress (paused), and a
      second tap resumes rather than restarting.
- [ ] Tap a paused ring twice — the partial is deleted and the button returns to
      the download arrow.
```

```bash
git add ios/README.md
git commit -m "docs(ios): add manual checks for partial-download playback"
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| Shared fetcher registry | 4 |
| `fetchAll(concurrency:)`, 4 MiB chunks, ascending order | 3 |
| Playback needs no new code (loader reads disk) | 3 (test `capturedRangesAreServedFromDiskWithoutNetwork`), 5 |
| Both directions / both writers at once | 3, 5 (`downloadResumesFromBytesLeftByPlayback`), 4 (back-pressure) |
| Reentrancy bugfix | 1 |
| Deleted segmented machinery | 7 |
| `onProgress` → captured/total bytes, ETA | 2 |
| `resumeInterrupted` rewrite | 5 |
| Cancel keeps bytes | 6 |
| `CacheState.paused` + button | 6, 8 |
| ETag change discards partial | already covered by `RangeFetcherTests.changedEtagOnFetchThrows` (unchanged behaviour) |
| Manual checks | 9 |

**Placeholders:** none — every code step carries the actual code.

**Type consistency:** `onProgress` is `(Int64, Int64)` from Task 2 onward in every call site (`RangeFetcher`, `CaptureManager.asset`, `RangeFetcherRegistry.fetcher`, `CacheManager.download`, `resumeInterrupted`). `data(for:origin:)` defaults `origin` to `.downloader`, so Task 1-3 call sites stay valid after Task 4. `cacheKey` formatting is identical in `RangeFetcherRegistry.cacheKey` and `CacheManager.cacheKey`. `removePartial` is defined in Task 6 and consumed in Task 8.
