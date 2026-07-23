# iOS Downloads Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Downloads page that exposes active iOS downloads with an aggregate per-download transfer rate and the three most recent playable completions.

**Architecture:** `CacheManager` remains the only transfer owner. It will publish immutable activity snapshots built from the same legacy and segmented delegate byte events that currently drive `CacheState`, and it will persist a bounded completion history beside its cache files. A new SwiftUI screen will read those snapshots on a short periodic refresh, resolve identities against `VideoStore`, and reuse the grid's existing cancel and local-playback closures.

**Tech Stack:** Swift 6, SwiftUI, Foundation/URLSession, Swift Testing, ViewInspector, SwiftPM (`PatataTubeKit`), XcodeGen iOS project.

## Global Constraints

- Deployment target remains iOS 17.0 and Swift 6.0.
- Do not create another download manager, URLSession, cancellation path, or playback path.
- Speed is aggregate per video/version download across all of its segments, never app-wide or per segment.
- Explicit cancellation retains current semantics: discard partial data and return the item to not-cached.
- Persist exactly the three latest successful completions; omit history entries whose local MP4 no longer exists.
- Rate copy is `Calculating…` until measurable, then `KB/s` below 1 MB/s and `MB/s` otherwise.

---

## File structure

| File | Responsibility |
| --- | --- |
| `ios/PatataTubeKit/Sources/PatataTubeKit/DownloadActivity.swift` | Public activity/history value types; deterministic rate sampling and bounded JSON completion-history storage. |
| `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift` | Populate and expose activity snapshots and record successful completions within the existing transfer lifecycle. |
| `ios/PatataTubeKit/Tests/PatataTubeKitTests/DownloadActivityTests.swift` | Unit-test per-download aggregation, rate sampling, history persistence/order/pruning. |
| `ios/PatataTube/Sources/DownloadsView.swift` | Downloads page, rate formatting, row actions, and periodic refresh. |
| `ios/PatataTube/Sources/VideoGridView.swift` | Add the top-right menu entry and route cancellation/playback into `DownloadsView`. |
| `ios/PatataTubeKit/Sources/PatataTubeKit/Video.swift` | Publicly expose the existing version-selecting copy used to play the exact downloaded version. |
| `ios/PatataTube/Tests/DownloadsViewTests.swift` | Test rate copy and active/completed/empty screen states and user actions. |

### Task 1: Add cache-owned activity snapshots and completion history

**Files:**

- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/DownloadActivity.swift`
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift:4-11, 171-185, 227-235, 365-381, 447-470, 686-704, 911-947`
- Create: `ios/PatataTubeKit/Tests/PatataTubeKitTests/DownloadActivityTests.swift`

**Interfaces:**

- Produces `public struct DownloadActivity: Equatable, Identifiable, Sendable` with `videoID`, `versionID`, `progress`, `transferredByteCount`, `totalByteCount`, and optional `bytesPerSecond`.
- Produces `public struct DownloadCompletion: Codable, Equatable, Hashable, Identifiable, Sendable` with `videoID`, `versionID`, and `completedAt`.
- Produces `CacheManager.activeDownloads() -> [DownloadActivity]` and `CacheManager.recentDownloads() -> [DownloadCompletion]`.
- Consumed by Task 2 through these two public `CacheManager` methods only.

- [ ] **Step 1: Write failing activity/history tests**

Create `DownloadActivityTests.swift` using the package's `Testing` framework. Use an injected `Date` in the accumulator so the rate is deterministic; this verifies a segmented download's summed bytes, not a single segment rate.

```swift
import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Download activity")
struct DownloadActivityTests {
    @Test func aggregateSamplesProduceOnePerDownloadRate() {
        var accumulator = DownloadActivityAccumulator(
            videoID: 7, versionID: 2, totalByteCount: 10_000,
            now: Date(timeIntervalSinceReferenceDate: 10)
        )
        accumulator.record(transferredByteCount: 2_000,
                           progress: 0.2,
                           now: Date(timeIntervalSinceReferenceDate: 11))
        accumulator.record(transferredByteCount: 5_000,
                           progress: 0.5,
                           now: Date(timeIntervalSinceReferenceDate: 13))

        #expect(accumulator.activity.transferredByteCount == 5_000)
        #expect(accumulator.activity.bytesPerSecond == 1_500)
        #expect(accumulator.activity.progress == 0.5)
    }

    @Test func historyKeepsNewestThreeAndReloads() throws {
        let root = temporaryRoot()
        var store = DownloadCompletionHistoryStore(root: root)
        for id in 1...4 {
            store.record(DownloadCompletion(videoID: id, versionID: nil,
                completedAt: Date(timeIntervalSinceReferenceDate: TimeInterval(id))))
        }
        let reloaded = DownloadCompletionHistoryStore(root: root)
        #expect(reloaded.entries.map(\.videoID) == [4, 3, 2])
    }

    @Test func historyPrunesEntriesWithoutLocalFile() throws {
        let root = temporaryRoot()
        let completion = DownloadCompletion(videoID: 9, versionID: 1, completedAt: .now)
        var store = DownloadCompletionHistoryStore(root: root)
        store.record(completion)
        #expect(store.prune { _ in false }.isEmpty)
    }
}
```

Add a local `temporaryRoot()` helper that creates a unique directory under `FileManager.default.temporaryDirectory` and deletes it with `defer`; do not use a shared user cache directory.

- [ ] **Step 2: Run the new tests to verify they fail**

Run from `ios/PatataTubeKit`:

```bash
rtk proxy swift test --filter DownloadActivityTests
```

Expected: compilation fails because `DownloadActivityAccumulator`, `DownloadCompletion`, and `DownloadCompletionHistoryStore` do not exist.

- [ ] **Step 3: Add the activity and history types**

Create `DownloadActivity.swift`. Keep the store file private to the cache root so tests and the app use identical persistence behavior.

```swift
import Foundation

public struct DownloadActivity: Equatable, Identifiable, Sendable {
    public let videoID: Int
    public let versionID: Int?
    public let progress: Double
    public let transferredByteCount: Int64
    public let totalByteCount: Int64?
    public let bytesPerSecond: Double?

    public var id: String { versionID.map { "\(videoID):\($0)" } ?? "\(videoID)" }
}

public struct DownloadCompletion: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let videoID: Int
    public let versionID: Int?
    public let completedAt: Date

    public var id: String { versionID.map { "\(videoID):\($0)" } ?? "\(videoID)" }
}

struct DownloadActivityAccumulator {
    private let videoID: Int
    private let versionID: Int?
    private let totalByteCount: Int64?
    private var lastSample: (bytes: Int64, date: Date)
    private(set) var activity: DownloadActivity

    init(videoID: Int, versionID: Int?, totalByteCount: Int64?, now: Date) {
        self.videoID = videoID
        self.versionID = versionID
        self.totalByteCount = totalByteCount
        self.lastSample = (0, now)
        self.activity = DownloadActivity(videoID: videoID, versionID: versionID,
            progress: 0, transferredByteCount: 0, totalByteCount: totalByteCount,
            bytesPerSecond: nil)
    }

    mutating func record(transferredByteCount: Int64, progress: Double, now: Date) {
        let elapsed = now.timeIntervalSince(lastSample.date)
        let delta = max(0, transferredByteCount - lastSample.bytes)
        let rate = elapsed > 0 && delta > 0 ? Double(delta) / elapsed : activity.bytesPerSecond
        activity = DownloadActivity(videoID: videoID, versionID: versionID,
            progress: min(max(progress, 0), 1),
            transferredByteCount: max(transferredByteCount, 0),
            totalByteCount: totalByteCount, bytesPerSecond: rate)
        if elapsed > 0 { lastSample = (max(transferredByteCount, 0), now) }
    }
}

struct DownloadCompletionHistoryStore {
    private let url: URL
    private(set) var entries: [DownloadCompletion]

    init(root: URL, fileManager: FileManager = .default) {
        url = root.appendingPathComponent("download-completions.json")
        entries = ((try? Data(contentsOf: url)).flatMap {
            try? JSONDecoder().decode([DownloadCompletion].self, from: $0)
        } ?? []).sorted { $0.completedAt > $1.completedAt }
        entries = Array(entries.prefix(3))
    }

    mutating func record(_ entry: DownloadCompletion) {
        entries.removeAll { $0.id == entry.id }
        entries = Array(([entry] + entries).sorted { $0.completedAt > $1.completedAt }.prefix(3))
        persist()
    }

    mutating func prune(_ isPlayable: (DownloadCompletion) -> Bool) -> [DownloadCompletion] {
        let retained = entries.filter(isPlayable)
        if retained != entries { entries = retained; persist() }
        return entries
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
```

Use the injected `fileManager` consistently in the final store implementation (including `persist`) so all test roots remain isolated.

- [ ] **Step 4: Replace progress-only in-flight state with activity accumulators**

In `CacheManager`, replace `inFlight: [String: Double]` with a dictionary of `DownloadActivityAccumulator`, and retain the existing `state(for:)` API by reading `accumulator.activity.progress`.

```swift
private var inFlight: [String: DownloadActivityAccumulator] = [:]
private var completionHistory: DownloadCompletionHistoryStore

public func activeDownloads() -> [DownloadActivity] {
    lock.withLock { inFlight.values.map(\.activity).sorted { $0.id < $1.id } }
}

public func recentDownloads() -> [DownloadCompletion] {
    lock.withLock {
        completionHistory.prune { completion in
            fileManager.fileExists(atPath: localURL(for: completion.videoID,
                versionId: completion.versionID).path)
        }
    }
}

public func state(for id: Int, versionId: Int? = nil) -> CacheState {
    let key = cacheKey(videoId: id, versionId: versionId)
    if fileManager.fileExists(atPath: localURL(for: id, versionId: versionId).path) { return .cached }
    return lock.withLock { inFlight[key].map { .downloading($0.activity.progress) } ?? .notCached }
}
```

Initialize an accumulator whenever the current code writes `inFlight[key] = 0`: probe with no total-byte count, legacy resumptions with no total-byte count, and fresh segmented attempts with `manifest.totalByteCount`. Replace all subsequent numeric writes with `record(transferredByteCount:progress:now:)`. For segmented transfers, calculate the total as persisted completed segment bytes plus `attempt.activeByteCounts.values.reduce(0, +)` before recording; for legacy transfers use `totalBytesWritten` and pass the delegate's expected byte count when positive. Remove the accumulator at every existing `inFlight[key] = nil` site.

Record the completion in both success terminals before removing the accumulator: `finish(key:taskIdentifier:result:)` for legacy transfers and `completeSegmentedClaim(_:continuation:result:)` for segmented transfers. Decode each identity from the existing cache key or the segmented manifest and append `DownloadCompletion(videoID:versionID:completedAt: Date())` only for `.success`; never record failures or cancellations.

- [ ] **Step 5: Run package tests and preserve existing cancellation tests**

Run from `ios/PatataTubeKit`:

```bash
rtk proxy swift test
```

Expected: all `PatataTubeKitTests` pass, including the pre-existing segmented cancellation/ownership tests and the new activity/history suite.

- [ ] **Step 6: Commit the cache activity unit**

```bash
rtk git add ios/PatataTubeKit/Sources/PatataTubeKit/DownloadActivity.swift \
        ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/DownloadActivityTests.swift
rtk git commit -m "feat(ios): expose download activity and history"
```

### Task 2: Build and test the Downloads screen

**Files:**

- Create: `ios/PatataTube/Sources/DownloadsView.swift`
- Create: `ios/PatataTube/Tests/DownloadsViewTests.swift`

**Interfaces:**

- Consumes `DownloadActivity`, `DownloadCompletion`, `Video`, `CacheManager.activeDownloads()`, and `CacheManager.recentDownloads()` from Task 1.
- Produces `DownloadsView`, initialized with providers for active/completed records, a video resolver, `onCancel`, and `onPlay` closures.
- Produces `DownloadRateFormatter.text(bytesPerSecond:) -> String` for focused UI-copy tests.
- Consumed by Task 3.

- [ ] **Step 1: Write failing screen tests**

Create `DownloadsViewTests.swift`. Test the formatter directly and use ViewInspector to ensure active, completed, and no-content states do not regress.

```swift
import PatataTubeKit
import SwiftUI
import Testing
import ViewInspector
@testable import PatataTube

@Suite("Downloads view")
@MainActor
struct DownloadsViewTests {
    @Test func rateFormatterUsesCalculatingKilobytesAndMegabytes() {
        #expect(DownloadRateFormatter.text(bytesPerSecond: nil) == "Calculating…")
        #expect(DownloadRateFormatter.text(bytesPerSecond: 12_000) == "12 KB/s")
        #expect(DownloadRateFormatter.text(bytesPerSecond: 2_500_000) == "2.5 MB/s")
    }

    @Test func activeRowShowsRateAndCancelInvokesIdentity() async throws {
        var cancelled: DownloadActivity.ID?
        let activity = DownloadActivity(videoID: 7, versionID: 2, progress: 0.5,
            transferredByteCount: 5_000, totalByteCount: 10_000, bytesPerSecond: 1_500)
        let sut = DownloadsView(active: { [activity] }, recent: { [] },
            video: { id, _ in sampleVideo(id: id) },
            onCancel: { cancelled = $0.id }, onPlay: { _ in })

        let inspected = try sut.inspect()
        #expect(try inspected.find(text: "1.5 KB/s").string() == "1.5 KB/s")
        try inspected.find(button: "Cancel").tap()
        #expect(cancelled == activity.id)
    }

    @Test func completedRowPlaysAndEmptyViewOmitsBothSections() async throws {
        var played: Int?
        let completion = DownloadCompletion(videoID: 8, versionID: nil, completedAt: .now)
        let recent = DownloadsView(active: { [] }, recent: { [completion] },
            video: { id, _ in sampleVideo(id: id) }, onCancel: { _ in },
            onPlay: { played = $0.id })
        try recent.inspect().find(text: "Recently Completed").callOnTapGesture()
        #expect(played == 8)
        let empty = DownloadsView(active: { [] }, recent: { [] },
            video: { _, _ in nil }, onCancel: { _ in }, onPlay: { _ in })
        #expect(try? empty.inspect().find(text: "In Progress") == nil)
        #expect(try? empty.inspect().find(text: "Recently Completed") == nil)
    }
}
```

Implement `sampleVideo(id:)` with the same minimal fully-initialized `Video` fixture pattern already used by the app test target. Make the completed row a `Button` so the test taps the actual accessibility label/title rather than a gesture on a section header.

- [ ] **Step 2: Run the view tests to verify they fail**

Run from `ios/PatataTube`:

```bash
rtk proxy xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -only-testing:PatataTubeTests/DownloadsViewTests
```

Expected: compilation fails because `DownloadsView` and `DownloadRateFormatter` do not exist.

- [ ] **Step 3: Implement the focused screen and formatter**

Create `DownloadsView.swift`. Use providers rather than copying cache data into `@State`; `TimelineView` re-reads current snapshots every 250 ms and naturally stops after the page is dismissed.

```swift
import PatataTubeKit
import SwiftUI

enum DownloadRateFormatter {
    static func text(bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return "Calculating…" }
        if bytesPerSecond >= 1_000_000 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
                .replacingOccurrences(of: ".0 MB/s", with: " MB/s")
        }
        return String(format: "%.1f KB/s", bytesPerSecond / 1_000)
            .replacingOccurrences(of: ".0 KB/s", with: " KB/s")
    }
}

struct DownloadsView: View {
    let active: () -> [DownloadActivity]
    let recent: () -> [DownloadCompletion]
    let video: (Int, Int?) -> Video?
    let onCancel: (DownloadActivity) -> Void
    let onPlay: (Video) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let activeItems = active()
            let completed = recent().compactMap { completion in
                video(completion.videoID, completion.versionID).map { (completion, $0) }
            }
            List {
                if !activeItems.isEmpty {
                    Section("In Progress") {
                        ForEach(activeItems) { item in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(video(item.videoID, item.versionID)?.title ?? "Video \(item.videoID)")
                                    ProgressView(value: item.progress)
                                }
                                Spacer()
                                Text(DownloadRateFormatter.text(bytesPerSecond: item.bytesPerSecond))
                                    .monospacedDigit()
                                Button("Cancel") { onCancel(item) }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                }
                if !completed.isEmpty {
                    Section("Recently Completed") {
                        ForEach(completed, id: \.0.id) { _, item in
                            Button { onPlay(item) } label: {
                                Label(item.title ?? "Video \(item.id)", systemImage: "play.fill")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Downloads")
        }
    }
}
```

In the final code, make `Video` title access match its existing public API and mark rate copy as an accessibility value on the active row. Do not add an empty-state section: an entirely empty `List` meets the approved requirement that empty sections are omitted.

- [ ] **Step 4: Run the app test target**

Run:

```bash
rtk proxy xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -only-testing:PatataTubeTests/DownloadsViewTests
```

Expected: all new formatter, row-action, section, and empty-list tests pass.

- [ ] **Step 5: Commit the screen**

```bash
rtk git add ios/PatataTube/Sources/DownloadsView.swift ios/PatataTube/Tests/DownloadsViewTests.swift
rtk git commit -m "feat(ios): add downloads screen"
```

### Task 3: Wire the top-right menu to existing cancel and playback paths

**Files:**

- Modify: `ios/PatataTube/Sources/VideoGridView.swift:10-18, 112-117, 137-166`
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/Video.swift:147-166`
- Modify: `ios/PatataTube/Tests/DownloadsViewTests.swift`

**Interfaces:**

- Consumes `DownloadsView` from Task 2.
- Consumes `CacheManager.activeDownloads()`, `recentDownloads()`, `cancel(id:versionId:)`, and the existing `play(_:)` method.
- Produces navigation from the current ellipsis menu to the Downloads screen.

- [ ] **Step 1: Add a failing navigation/action integration test**

Extend `DownloadsViewTests.swift` with a closure-level integration test that proves the view uses the versioned identity on cancel and routes a completed item through the provided playback closure:

```swift
@Test func versionedActionsKeepTheDownloadIdentity() throws {
    let activity = DownloadActivity(videoID: 12, versionID: 99, progress: 0.2,
        transferredByteCount: 200, totalByteCount: 1_000, bytesPerSecond: 100)
    var cancelled: (Int, Int?)?
    let sut = DownloadsView(active: { [activity] }, recent: { [] },
        video: { id, _ in sampleVideo(id: id) },
        onCancel: { cancelled = ($0.videoID, $0.versionID) }, onPlay: { _ in })

    try sut.inspect().find(button: "Cancel").tap()
    #expect(cancelled?.0 == 12)
    #expect(cancelled?.1 == 99)
}
```

- [ ] **Step 2: Run the focused app test and verify the new behavior is not yet wired from the grid**

Run the Task 2 command. Expected: the closure-level test passes once Task 2 is complete; manual inspection still finds no `Downloads` menu entry in `VideoGridView`, establishing the remaining wiring work.

- [ ] **Step 3: Add navigation state, menu item, and destination**

Add `@State private var showDownloads = false` beside the existing `showSettings`/`showUpload` flags. Insert this menu item after `Download all` and before cell sizing, so download-related controls remain grouped:

```swift
Button {
    showDownloads = true
} label: {
    Label("Downloads", systemImage: "arrow.down.circle")
}
```

First, make the existing `Video.withChosenVersion(_:)` public; it already returns a copy with the exact version's cache identity and status, so this changes no behavior for existing callers:

```swift
public func withChosenVersion(_ versionId: Int) -> Video {
    // keep the existing function body unchanged
}
```

Attach a destination inside the existing `NavigationStack`, adjacent to the existing `navigationDestination(for: Video.self)`:

```swift
.navigationDestination(isPresented: $showDownloads) {
    DownloadsView(
        active: { model.cache.activeDownloads() },
        recent: { model.cache.recentDownloads() },
        video: { id, versionID in
            guard let stored = store.videos.first(where: { $0.id == id }) else { return nil }
            guard let versionID else { return stored }
            return stored.versions.contains(where: { $0.id == versionID })
                ? stored.withChosenVersion(versionID) : nil
        },
        onCancel: { activity in
            model.cache.cancel(id: activity.videoID, versionId: activity.versionID)
        },
        onPlay: { video in play(video) }
    )
}
```

If an item is not present in the live `VideoStore`, the Downloads screen omits it. Do not reconstruct a `Video` from history, and do not call `ensureReady`; cached rows already follow the `play(_:)` local-file fast path.

- [ ] **Step 4: Run the complete automated test suites**

Run the first command from `ios/PatataTubeKit`, then run the second from `ios/PatataTube`:

```bash
rtk proxy swift test
rtk proxy xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1'
```

Expected: both commands finish successfully, including existing cancellation ownership, download-button, and app UI tests.

- [ ] **Step 5: Perform a concise simulator smoke test**

1. Start two downloads, open the ellipsis menu, and choose **Downloads**.
2. Confirm each active row shows its own changing KB/s or MB/s value, rather than a shared rate.
3. Cancel one row and confirm it follows today's partial-data cleanup behavior and disappears.
4. Let four downloads finish; confirm only the last three, newest first, remain under **Recently Completed**.
5. Relaunch the app and confirm those three remain; tap one while offline and confirm it plays locally.

- [ ] **Step 6: Commit the integration**

```bash
rtk git add ios/PatataTube/Sources/VideoGridView.swift ios/PatataTubeKit/Sources/PatataTubeKit/Video.swift ios/PatataTube/Tests/DownloadsViewTests.swift
rtk git commit -m "feat(ios): open downloads from menu"
```

## Self-review

**Spec coverage:** Task 1 supplies aggregate active speed and a persisted three-item completion order; Task 2 specifies both visible sections, rate formatting, cancel/play actions, and omitted empty sections; Task 3 adds the ellipsis-menu entry and verifies existing cancellation and local playback are reused. The simulator check covers the final user-facing flow.

**Placeholder scan:** No TBD/TODO markers, deferred error handling, or undefined implementation dependencies remain. The only implementation-specific inputs are existing `Video` fixture construction and simulator availability, each called out at its use site.

**Type consistency:** Every consumer uses `DownloadActivity.videoID/versionID`, `DownloadCompletion.videoID/versionID`, `CacheManager.activeDownloads()`, and `CacheManager.recentDownloads()` exactly as defined in Task 1. `DownloadsView` accepts and returns no alternate identity type.
