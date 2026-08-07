# Download Speed Meter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the aggregate throughput of all in-flight offline downloads, averaged over a 5-second rolling window, on the right side of the Downloads view's "In Progress" section header.

**Architecture:** `CacheManager` gains a monotonic cumulative byte counter (a snapshot sum of `activeDownloads()` would go *negative* when a download finishes and its bytes leave the set). The counter is produced by wrapping the existing `inFlight` dictionary in a struct whose subscript setter accumulates deltas, so no existing progress call site changes. A pure `DownloadSpeedMeter` value type in PatataTubeKit holds a 5s ring of `(Date, Int64)` samples and divides. `DownloadsView` owns the meter as `@State` and feeds it from a 0.25s timer.

**Tech Stack:** Swift 6, SwiftUI, swift-testing (`import Testing`, `@Test`, `#expect`), SwiftPM package `ios/PatataTubeKit`, XcodeGen app target `ios/PatataTube`.

**Design doc:** `docs/superpowers/specs/2026-08-07-download-speed-meter-design.md`

## Global Constraints

- Tests in `ios/PatataTubeKit/Tests/PatataTubeKitTests/` use **swift-testing**, not XCTest: `import Testing`, `@Suite`, `@Test`, `#expect`. Follow `DownloadActivityTests.swift` for style.
- Counted bytes are **`CacheManager` in-flight downloads only** — MP4, segmented, and HLS asset fetches. `StreamProxy` playback traffic is excluded and falls out for free (it never touches `inFlight`).
- Rate format: **decimal megabytes**, `bytes / 1_000_000`, one decimal place, e.g. `12.4 MB/s`, rendered `.monospacedDigit()`.
- Rolling window: **5 seconds**. Sampling cadence: **0.25s**.
- The counter is per-process, never persisted, never reset, and must never decrease.
- Do **not** mutate `@State` from inside a `TimelineView` body — that is a render-phase write. The meter updates via `.onReceive`.
- Per `CLAUDE.md`, run **both** `swift test` and the app target's `xcodebuild ... test` when app `Sources/` change; the app-target suite only builds through `xcodebuild` and silently rots otherwise.
- Do not add an app-target test that inspects a *large* SwiftUI view — ViewInspector segfaults the test process. `DownloadsView` is small and is already inspected by `ios/PatataTube/Tests/DownloadsViewTests.swift`; that file stays valid.

---

## File Structure

**Create:**
- `ios/PatataTubeKit/Sources/PatataTubeKit/DownloadSpeedMeter.swift` — the pure rolling-window rate calculator and its string formatting. No clock, no concurrency; the caller supplies dates.
- `ios/PatataTubeKit/Tests/PatataTubeKitTests/DownloadSpeedMeterTests.swift` — meter tests with injected dates, no sleeps.
- `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerByteCounterTests.swift` — cumulative counter tests.

**Modify:**
- `ios/PatataTubeKit/Sources/PatataTubeKit/DownloadActivity.swift` — add the `InFlightActivities` wrapper struct next to `DownloadActivityAccumulator`, which it wraps.
- `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift:167` — change the `inFlight` declaration; `:445` — `activeDownloads()` iteration; add `downloadedByteCount()`.
- `ios/PatataTube/Sources/DownloadsView.swift` — meter state, timer, section header.
- `ios/PatataTube/Sources/VideoGridView.swift:686-696` — pass the new `byteCount` closure.

---

### Task 1: `DownloadSpeedMeter`

A pure value type: append `(date, cumulativeBytes)` samples, evict anything older than the window, divide. Returns `nil` until the retained span reaches `minimumSpan`, so the first quarter-second after the view opens cannot produce a wild reading.

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/DownloadSpeedMeter.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/DownloadSpeedMeterTests.swift`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces:
  - `public struct DownloadSpeedMeter: Sendable`
  - `public init(window: TimeInterval = 5, minimumSpan: TimeInterval = 1)`
  - `public mutating func record(byteCount: Int64, at date: Date)`
  - `public var bytesPerSecond: Double?`
  - `public var formattedRate: String?` — e.g. `"12.4 MB/s"`, `nil` when `bytesPerSecond` is `nil`

- [ ] **Step 1: Write the failing tests**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/DownloadSpeedMeterTests.swift`:

```swift
import Foundation
import Testing
@testable import PatataTubeKit

private func t(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSinceReferenceDate: seconds)
}

@Suite("Download speed meter")
struct DownloadSpeedMeterTests {
    @Test func steadyTransferReportsThatRate() {
        var meter = DownloadSpeedMeter()
        for second in 0...5 {
            meter.record(byteCount: Int64(second) * 1_000_000, at: t(TimeInterval(second)))
        }
        #expect(meter.bytesPerSecond == 1_000_000)
    }

    @Test func aSingleSampleHasNoRate() {
        var meter = DownloadSpeedMeter()
        meter.record(byteCount: 5_000_000, at: t(0))
        #expect(meter.bytesPerSecond == nil)
    }

    @Test func spanBelowTheMinimumHasNoRate() {
        var meter = DownloadSpeedMeter()
        meter.record(byteCount: 0, at: t(0))
        meter.record(byteCount: 1_000_000, at: t(0.5))
        #expect(meter.bytesPerSecond == nil)
    }

    @Test func idleAfterABurstDecaysToZero() throws {
        var meter = DownloadSpeedMeter()
        meter.record(byteCount: 0, at: t(0))
        meter.record(byteCount: 5_000_000, at: t(1))
        // Counter flat from here: nothing is transferring.
        meter.record(byteCount: 5_000_000, at: t(3))
        let midWindow = try #require(meter.bytesPerSecond)
        #expect(midWindow > 0)

        for second in 4...6 {
            meter.record(byteCount: 5_000_000, at: t(TimeInterval(second)))
        }
        #expect(meter.bytesPerSecond == 0)
    }

    @Test func samplesOlderThanTheWindowAreEvicted() {
        var meter = DownloadSpeedMeter()
        var bytes: Int64 = 0
        // 5 MB/s for five seconds...
        for second in 0...5 {
            meter.record(byteCount: bytes, at: t(TimeInterval(second)))
            bytes += 5_000_000
        }
        // ...then 1 MB/s for five more. The fast era must fall out of the window.
        bytes = 25_000_000
        for second in 6...10 {
            bytes += 1_000_000
            meter.record(byteCount: bytes, at: t(TimeInterval(second)))
        }
        #expect(meter.bytesPerSecond == 1_000_000)
    }

    @Test func aCompletedDownloadNeverProducesANegativeRate() throws {
        // The counter is monotonic, so a download leaving the active set is
        // simply a flat stretch, not a drop.
        var meter = DownloadSpeedMeter()
        meter.record(byteCount: 0, at: t(0))
        meter.record(byteCount: 3_000_000, at: t(1))
        meter.record(byteCount: 3_000_000, at: t(2))
        let rate = try #require(meter.bytesPerSecond)
        #expect(rate == 1_500_000)
    }

    @Test func formatsDecimalMegabytesToOneDecimal() {
        var meter = DownloadSpeedMeter()
        meter.record(byteCount: 0, at: t(0))
        meter.record(byteCount: 24_800_000, at: t(2))
        #expect(meter.formattedRate == "12.4 MB/s")
    }

    @Test func formattedRateIsNilWithoutEnoughSamples() {
        var meter = DownloadSpeedMeter()
        meter.record(byteCount: 1_000, at: t(0))
        #expect(meter.formattedRate == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd ios/PatataTubeKit && swift test --filter DownloadSpeedMeterTests
```

Expected: compile failure — `cannot find 'DownloadSpeedMeter' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ios/PatataTubeKit/Sources/PatataTubeKit/DownloadSpeedMeter.swift`:

```swift
import Foundation

/// Aggregate download throughput over a sliding time window.
///
/// Fed with a **monotonic** cumulative byte count (see
/// `CacheManager.downloadedByteCount()`): a snapshot sum over the active
/// downloads would drop when a transfer finishes and its bytes leave the set,
/// which reads as a negative rate. A counter that only grows turns a finished
/// download into a flat stretch instead, so the average decays across the
/// window rather than lying.
///
/// Owns no clock and does no I/O — the caller supplies each sample's date,
/// which is what makes it testable without sleeping.
public struct DownloadSpeedMeter: Sendable {
    private struct Sample {
        let date: Date
        let byteCount: Int64
    }

    private let window: TimeInterval
    private let minimumSpan: TimeInterval
    private var samples: [Sample] = []

    /// - Parameters:
    ///   - window: how far back the average reaches.
    ///   - minimumSpan: the shortest span that yields a rate at all. Below it
    ///     the divisor is small enough that one sample's jitter dominates.
    public init(window: TimeInterval = 5, minimumSpan: TimeInterval = 1) {
        self.window = window
        self.minimumSpan = minimumSpan
    }

    public mutating func record(byteCount: Int64, at date: Date) {
        samples.append(Sample(date: date, byteCount: byteCount))
        let cutoff = date.addingTimeInterval(-window)
        // Retain the sample that straddles the cutoff, so the measured span
        // stays close to a full window instead of collapsing to the newest
        // few samples.
        while samples.count > 1, samples[1].date <= cutoff {
            samples.removeFirst()
        }
    }

    public var bytesPerSecond: Double? {
        guard let oldest = samples.first, let newest = samples.last else { return nil }
        let span = newest.date.timeIntervalSince(oldest.date)
        guard span >= minimumSpan else { return nil }
        return Double(newest.byteCount - oldest.byteCount) / span
    }

    /// Decimal megabytes per second to one decimal place, e.g. `"12.4 MB/s"`.
    public var formattedRate: String? {
        guard let bytesPerSecond else { return nil }
        return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd ios/PatataTubeKit && swift test --filter DownloadSpeedMeterTests
```

Expected: all 8 tests pass.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/DownloadSpeedMeter.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/DownloadSpeedMeterTests.swift
git commit -m "feat(ios): add DownloadSpeedMeter rolling-window rate calculator"
```

---

### Task 2: Monotonic byte counter in `CacheManager`

`inFlight` is written at roughly nineteen sites (`inFlight[key] = …`, `inFlight[key] = nil`, `inFlight[key]?.record(…)`). Instead of editing all of them, wrap the dictionary in a struct whose subscript setter accumulates the delta. `inFlight[key]?.record(…)` is a get-modify-set through that subscript, so the setter observes the new value — every progress path (plain download, segmented, external/HLS) feeds the counter with **zero call-site edits**.

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/DownloadActivity.swift` (append `InFlightActivities`)
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift:167` and `:445`, plus a new accessor next to `activeDownloads()`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerByteCounterTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces:
  - `struct InFlightActivities` (internal) with `subscript(key: String) -> DownloadActivityAccumulator?`, `var values: Dictionary<String, DownloadActivityAccumulator>.Values`, `private(set) var cumulativeByteCount: Int64`
  - `public func downloadedByteCount() -> Int64` on `CacheManager` — used by Task 3.

- [ ] **Step 1: Write the failing tests**

The external-activity API (`beginExternalActivity` / `updateExternalActivity` / `endExternalActivity`) is internal and drives the same `inFlight` subscript every other path uses, so it is the cheapest way to exercise the counter without a network.

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerByteCounterTests.swift`:

```swift
import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Cache manager cumulative byte counter")
struct CacheManagerByteCounterTests {
    private func makeManager() -> CacheManager {
        CacheManager(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("byte-counter-\(UUID().uuidString)"),
            configuration: .ephemeral,
            fileManager: .default
        )
    }

    @Test func accumulatesProgressAcrossDownloads() {
        let manager = makeManager()
        #expect(manager.downloadedByteCount() == 0)

        manager.beginExternalActivity(key: "1", videoId: 1, versionId: nil, totalUnits: 1_000)
        manager.updateExternalActivity(key: "1", completedUnits: 400)
        #expect(manager.downloadedByteCount() == 400)

        manager.updateExternalActivity(key: "1", completedUnits: 900)
        #expect(manager.downloadedByteCount() == 900)
    }

    @Test func aFinishedDownloadDoesNotSubtractItsBytes() {
        let manager = makeManager()
        manager.beginExternalActivity(key: "1", videoId: 1, versionId: nil, totalUnits: 1_000)
        manager.updateExternalActivity(key: "1", completedUnits: 400)
        manager.endExternalActivity(key: "1")
        #expect(manager.activeDownloads().isEmpty)
        #expect(manager.downloadedByteCount() == 400)

        manager.beginExternalActivity(key: "2", videoId: 2, versionId: nil, totalUnits: 1_000)
        manager.updateExternalActivity(key: "2", completedUnits: 300)
        #expect(manager.downloadedByteCount() == 700)
    }

    @Test func aCancelledDownloadDoesNotSubtractItsBytes() {
        let manager = makeManager()
        manager.beginExternalActivity(key: "1", videoId: 1, versionId: nil, totalUnits: 1_000)
        manager.updateExternalActivity(key: "1", completedUnits: 250)
        manager.cancelExternalActivity(key: "1")
        #expect(manager.downloadedByteCount() == 250)
    }

    @Test func aRegressingProgressReportAddsNothing() {
        // A restarted transfer can report fewer completed units than before.
        let manager = makeManager()
        manager.beginExternalActivity(key: "1", videoId: 1, versionId: nil, totalUnits: 1_000)
        manager.updateExternalActivity(key: "1", completedUnits: 600)
        manager.updateExternalActivity(key: "1", completedUnits: 100)
        #expect(manager.downloadedByteCount() == 600)
    }

    @Test func activeDownloadsStillReportsEveryInFlightTransfer() {
        let manager = makeManager()
        manager.beginExternalActivity(key: "1", videoId: 1, versionId: nil, totalUnits: 1_000)
        manager.beginExternalActivity(key: "2", videoId: 2, versionId: 7, totalUnits: 2_000)
        manager.updateExternalActivity(key: "2", completedUnits: 1_000)

        let active = manager.activeDownloads()
        #expect(active.count == 2)
        #expect(active.map(\.videoID).sorted() == [1, 2])
        #expect(active.first { $0.videoID == 2 }?.progress == 0.5)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd ios/PatataTubeKit && swift test --filter CacheManagerByteCounterTests
```

Expected: compile failure — `value of type 'CacheManager' has no member 'downloadedByteCount'`.

- [ ] **Step 3: Add the `InFlightActivities` wrapper**

Append to `ios/PatataTubeKit/Sources/PatataTubeKit/DownloadActivity.swift`:

```swift
/// The in-flight download table, plus a cumulative byte counter derived from
/// writes to it.
///
/// Exists so `CacheManager` gets a **monotonic** total for the speed meter
/// without touching its ~19 `inFlight[key] = …` sites: `inFlight[key]?.record(…)`
/// is a get-modify-set through this subscript, so the setter sees every
/// progress update from the plain, segmented, and external/HLS paths alike.
///
/// Removing a key contributes zero, so a finishing or cancelled download can
/// never make the counter go down.
struct InFlightActivities {
    private(set) var cumulativeByteCount: Int64 = 0
    private var storage: [String: DownloadActivityAccumulator] = [:]

    subscript(key: String) -> DownloadActivityAccumulator? {
        get { storage[key] }
        set {
            let before = storage[key]?.activity.transferredByteCount ?? 0
            let after = newValue?.activity.transferredByteCount ?? before
            cumulativeByteCount += max(after - before, 0)
            storage[key] = newValue
        }
    }

    var values: Dictionary<String, DownloadActivityAccumulator>.Values { storage.values }
}
```

- [ ] **Step 4: Wire it into `CacheManager`**

In `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift`, replace line 167:

```swift
    private var inFlight: [String: DownloadActivityAccumulator] = [:]
```

with:

```swift
    private var inFlight = InFlightActivities()
```

Then, immediately after `activeDownloads()` (around line 446), add:

```swift
    /// Total bytes this process has downloaded since launch, across every
    /// transfer, finished or not. Monotonic by construction — feed it to
    /// `DownloadSpeedMeter`, not the sum of `activeDownloads()`.
    public func downloadedByteCount() -> Int64 {
        lock.withLock { inFlight.cumulativeByteCount }
    }
```

No other line changes: `activeDownloads()` at line 445 already goes through `inFlight.values`, which the wrapper provides, and every other use is a subscript.

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd ios/PatataTubeKit && swift test --filter CacheManagerByteCounterTests
```

Expected: all 5 tests pass.

- [ ] **Step 6: Run the whole Kit suite in both configurations**

```bash
cd ios/PatataTubeKit && swift test
cd ios/PatataTubeKit && swift test -c release
```

Expected: no new failures. Per `CLAUDE.md`, a full parallel run has pre-existing flakes (a `Fatal error: Index out of range` from the swift-testing suites, occasional `VideoStoreTests` failures). If something fails, re-run that test filtered before treating it as a regression:

```bash
cd ios/PatataTubeKit && swift test --filter <FailingTestName>
```

- [ ] **Step 7: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/DownloadActivity.swift \
        ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerByteCounterTests.swift
git commit -m "feat(ios): track a monotonic cumulative download byte count"
```

---

### Task 3: Show the rate on the "In Progress" section header

**Files:**
- Modify: `ios/PatataTube/Sources/DownloadsView.swift`
- Modify: `ios/PatataTube/Sources/VideoGridView.swift:686-696`
- Test: `ios/PatataTube/Tests/DownloadsViewTests.swift` (one added test; the existing five constructions must keep compiling)

**Interfaces:**
- Consumes: `DownloadSpeedMeter` (Task 1), `CacheManager.downloadedByteCount()` (Task 2).
- Produces: `DownloadsView.byteCount: () -> Int64`, a new stored property with a default of `{ 0 }` so existing call sites and tests compile untouched.

- [ ] **Step 1: Add the meter state and its timer to `DownloadsView`**

In `ios/PatataTube/Sources/DownloadsView.swift`, add the new seam and state after `onPlay`:

```swift
    let onPlay: (Video) -> Void
    /// Monotonic cumulative downloaded bytes. Defaults to a constant so tests
    /// and previews that don't care about the speed readout stay untouched.
    var byteCount: () -> Int64 = { 0 }
    // Optional lifecycle seam for hosted inspection of SwiftUI-resolved environment values.
    var didAppear: ((Self) -> Void)? = nil
    @EnvironmentObject var model: AppModel
    @Environment(JobsStore.self) private var jobsStore: JobsStore?
    @State private var meter = DownloadSpeedMeter()
    // Deliberately not driven from inside the TimelineView body below:
    // mutating @State during body evaluation is a render-phase write.
    @State private var speedTicks = Timer
        .publish(every: 0.25, on: .main, in: .common)
        .autoconnect()
```

- [ ] **Step 2: Replace the "In Progress" section with a header-carrying form**

Still in `DownloadsView.swift`, replace:

```swift
                if !activeItems.isEmpty {
                    Section("In Progress") {
                        ForEach(activeItems) { item in
                            activeRow(item)
                        }
                    }
                }
```

with:

```swift
                if !activeItems.isEmpty {
                    Section {
                        ForEach(activeItems) { item in
                            activeRow(item)
                        }
                    } header: {
                        HStack {
                            Text("In Progress")
                            Spacer()
                            if let rate = meter.formattedRate {
                                Text(rate).monospacedDigit()
                            }
                        }
                    }
                }
```

- [ ] **Step 3: Feed the meter from the timer**

Still in `DownloadsView.swift`, add `.onReceive` to the `List` — on the same chain as `.navigationTitle("Downloads")`, inside the `TimelineView` closure:

```swift
            .navigationTitle("Downloads")
            .onReceive(speedTicks) { date in
                meter.record(byteCount: byteCount(), at: date)
            }
```

- [ ] **Step 4: Pass the real counter from `VideoGridView`**

In `ios/PatataTube/Sources/VideoGridView.swift`, in the `case .downloads:` branch, add the argument after `onPlay`:

```swift
            DownloadsView(
                active: { model.cache.activeDownloads() },
                recent: { model.cache.recentDownloads() },
                video: { id, versionID in
                    Self.downloadVideo(id: id, versionID: versionID, videos: store.videos)
                },
                onCancel: { activity in
                    model.cache.cancel(id: activity.videoID, versionId: activity.versionID)
                },
                onPlay: { video in play(video, caller: "downloads") },
                byteCount: { model.cache.downloadedByteCount() }
            )
```

- [ ] **Step 5: Add the app-target test for the header**

The rate string itself is covered by Task 1. This asserts only that the header still renders its label in the new `Section { } header: { }` form — `DownloadsView` is small, so ViewInspector is safe here (it already inspects this view).

Append to the `DownloadsViewTests` suite in `ios/PatataTube/Tests/DownloadsViewTests.swift`:

```swift
    @Test func inProgressHeaderRendersWithActiveDownloads() throws {
        let activity = DownloadActivity(
            videoID: 3,
            versionID: nil,
            progress: 0.1,
            transferredByteCount: 100,
            totalByteCount: 1_000
        )
        let sut = DownloadsView(
            active: { [activity] },
            recent: { [] },
            video: { id, _ in sampleVideo(id: id) },
            onCancel: { _ in },
            onPlay: { _ in },
            byteCount: { 4_000_000 }
        )
        .environmentObject(AppModel())

        #expect(throws: Never.self) { try sut.inspect().find(text: "In Progress") }
    }
```

- [ ] **Step 6: Build and run both test targets**

```bash
cd ios/PatataTube && xcodegen generate
cd ios/PatataTube && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube \
  -destination "platform=iOS Simulator,id=$(xcrun simctl list devices available | grep -m1 -o '[0-9A-F-]\{36\}')" test
```

Expected: build succeeds and the full `PatataTubeTests` target passes (74 tests). Run the **whole** target — per `CLAUDE.md`, `-only-testing:` filters hang indefinitely here.

- [ ] **Step 7: Commit**

```bash
git add ios/PatataTube/Sources/DownloadsView.swift \
        ios/PatataTube/Sources/VideoGridView.swift \
        ios/PatataTube/Tests/DownloadsViewTests.swift
git commit -m "feat(ios): show aggregate download speed on the Downloads view"
```

---

### Task 4: Manual verification and docs

**Files:**
- Modify: `ios/README.md` (manual test checklist)

- [ ] **Step 1: Run the app against the dev server and watch a real download**

```bash
./serve
```

Then in Xcode, Run on a simulator, open the Downloads tab and start a Download-all from a group. Confirm:
1. `12.4 MB/s`-shaped text appears at the right of the "In Progress" header within ~1s of the first bytes.
2. The value is plausible against the transfer (cross-check with `log/backend.log`'s `[stream] +1 … active=N/16` gauge for how many transfers are live).
3. It never shows a negative number as individual downloads complete.
4. Both the readout and the section disappear when the last download finishes.

- [ ] **Step 2: Add the checklist entry**

In `ios/README.md`, add to the manual test checklist:

```markdown
- Downloads tab: with several downloads running, the "In Progress" header shows
  an aggregate `MB/s` averaged over 5s; it stays non-negative as individual
  downloads finish, and disappears with the section when the queue empties.
```

- [ ] **Step 3: Commit**

```bash
git add ios/README.md
git commit -m "docs(ios): note the Downloads speed readout in the manual checklist"
```

---

## Notes for the implementer

- **Why not just sum `activeDownloads()`?** Each `DownloadActivity` carries an *absolute* `transferredByteCount`. When a transfer completes it leaves `inFlight`, so the sum drops and the derived rate goes negative. That is the whole reason Task 2 exists; don't "simplify" it away.
- **Why a subscript wrapper instead of a helper method?** There are ~19 write sites across the plain, segmented, and external/HLS paths. The wrapper catches all of them by construction, including future ones, and cannot be forgotten by a new call site the way an explicit `bump()` call could.
- **One refinement from the spec:** formatting lives on `DownloadSpeedMeter.formattedRate` rather than inline `String(format:)` in the view, so the `MB/s` string is unit-tested in the Kit rather than only through a view inspection.
