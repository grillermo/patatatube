# Bounded Download-All Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop `Download all` from spawning one unbounded task per video, so no user action holds more than `maxConcurrentDownloads` prepare+download operations in flight.

**Architecture:** A `withBoundedTaskGroup` helper in the `PatataTubeKit` SwiftPM package runs a sliding window of at most N concurrent operations. Both Download-all call sites — the grid toolbar and the per-show episode list — use it at `CacheManager.maxConcurrentDownloads`. The grid additionally gains a confirmation alert showing the target count and the device's free space.

**Tech Stack:** Swift 6 language mode, SwiftUI, swift-testing (`@Suite`/`@Test`/`#expect`), SwiftPM local package `PatataTubeKit`, XcodeGen for the app target.

**Spec:** `docs/superpowers/specs/2026-07-31-bounded-download-all-design.md`

## Global Constraints

- **Swift 6 language mode.** `Package.swift` is `swift-tools-version: 6.0`; `project.yml` sets `SWIFT_VERSION: "6.0"` in both configs. Strict concurrency is on. Closures crossing into a `TaskGroup` must be `@Sendable`, and closures that touch view state must be `@MainActor`.
- **No new dependencies.** Everything here is stdlib + SwiftUI + what the package already links.
- **Testable logic lives in `PatataTubeKit`.** The app target (`ios/PatataTube`) has no test target and is not getting one. That is why the bounded-window logic is a package function rather than inline view code. Code that must live in the view stays wiring-only.
- **Test style is swift-testing, not XCTest.** `import Testing`, `@Suite("Name") struct …`, `@Test func …`, `#expect(…)`. See `ios/PatataTubeKit/Tests/PatataTubeKitTests/DownloadConcurrencyGateTests.swift` for the house pattern, including the `private actor` recorder used to observe concurrency.
- **Run both test configurations** per `CLAUDE.md`: `swift test` (DEVLOG on) and `swift test -c release` (DEVLOG off).
- Pre-existing and unrelated: the full parallel `swift test` run prints `Fatal error: Index out of range` from the swift-testing suites. It reproduces on a clean checkout and every test still reports passing. Do not chase it.
- **Depends on the ffmpeg job queue plan's Task 6**, which adds the `bulk:` parameter to `VideoGridView.download` and `VideoStore.ensureReady`. If that task has not been applied yet, omit `bulk: true` from the call in Task 5 Step 4 — everything else in this plan is independent of it.
- Do not touch `CacheManager`'s existing `DownloadConcurrencyGate`. It correctly bounds transfers. This plan bounds what happens *before* the gate.

---

## File Structure

**Create:**
- `ios/PatataTubeKit/Sources/PatataTubeKit/BoundedTaskGroup.swift` — the sliding-window helper. One free function, no state.
- `ios/PatataTubeKit/Sources/PatataTubeKit/DeviceStorage.swift` — free-space query. One namespace enum, one function.
- `ios/PatataTubeKit/Tests/PatataTubeKitTests/BoundedTaskGroupTests.swift`
- `ios/PatataTubeKit/Tests/PatataTubeKitTests/DeviceStorageTests.swift`

**Modify:**
- `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift` — expose `cacheRootURL` for the free-space query.
- `ios/PatataTube/Sources/ShowsView.swift` — `onDownload` closure isolation.
- `ios/PatataTube/Sources/EpisodesView.swift` — closure isolation; `downloadEligibleEpisodes` becomes a bounded window.
- `ios/PatataTube/Sources/VideoGridView.swift` — confirmation alert, bounded window, and the `filteredVideos` fix.
- `CLAUDE.md` — one paragraph on the client-side bound.

**Dependency direction:** the app target depends on `PatataTubeKit`. Nothing in the package knows about the views.

---

### Task 1: `withBoundedTaskGroup` in PatataTubeKit

The sliding-window primitive, with no callers yet. Pure concurrency logic, fully testable in the package — this is where the "never more than N in flight" guarantee is proved, once, for both call sites.

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/BoundedTaskGroup.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/BoundedTaskGroupTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `@MainActor public func withBoundedTaskGroup<T: Sendable>(limit: Int, over items: [T], operation: @escaping @MainActor @Sendable (T) async -> Void) async`

- [ ] **Step 1: Write the failing tests**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/BoundedTaskGroupTests.swift`:

```swift
import Foundation
import Testing
@testable import PatataTubeKit

/// Observes concurrency from outside the operations themselves. An actor
/// because the operations run on MainActor but the counters must be safe to
/// read from the test's own context.
private actor Tracker {
    private(set) var active = 0
    private(set) var maxActive = 0
    private(set) var seen: [Int] = []

    func enter(_ id: Int) {
        active += 1
        maxActive = max(maxActive, active)
        seen.append(id)
    }

    func leave() { active -= 1 }
}

@Suite("Bounded task group")
@MainActor
struct BoundedTaskGroupTests {

    @Test
    func neverExceedsTheLimit() async {
        let tracker = Tracker()

        await withBoundedTaskGroup(limit: 3, over: Array(0..<20)) { id in
            await tracker.enter(id)
            try? await Task.sleep(nanoseconds: 5_000_000)
            await tracker.leave()
        }

        #expect(await tracker.maxActive <= 3)
        // Proves the window is actually parallel, not accidentally serial.
        #expect(await tracker.maxActive > 1)
        #expect(await tracker.seen.count == 20)
    }

    @Test
    func runsEveryItemExactlyOnce() async {
        let tracker = Tracker()

        await withBoundedTaskGroup(limit: 4, over: Array(0..<50)) { id in
            await tracker.enter(id)
            await tracker.leave()
        }

        #expect(await tracker.seen.count == 50)
        #expect(Set(await tracker.seen) == Set(0..<50))
    }

    @Test
    func clampsNonPositiveLimitToOne() async {
        let tracker = Tracker()

        await withBoundedTaskGroup(limit: 0, over: Array(0..<5)) { id in
            await tracker.enter(id)
            try? await Task.sleep(nanoseconds: 2_000_000)
            await tracker.leave()
        }

        #expect(await tracker.maxActive == 1)
        #expect(await tracker.seen.count == 5)
    }

    @Test
    func emptyInputRunsNothing() async {
        let tracker = Tracker()

        await withBoundedTaskGroup(limit: 3, over: [Int]()) { id in
            await tracker.enter(id)
            await tracker.leave()
        }

        #expect(await tracker.seen.isEmpty)
    }

    @Test
    func cancelledParentStopsSeeding() async {
        let tracker = Tracker()

        let task = Task { @MainActor in
            await withBoundedTaskGroup(limit: 1, over: Array(0..<50)) { id in
                await tracker.enter(id)
                try? await Task.sleep(nanoseconds: 10_000_000)
                await tracker.leave()
            }
        }

        try? await Task.sleep(nanoseconds: 30_000_000)
        task.cancel()
        await task.value

        // Without the cancellation check the loop keeps seeding, and because a
        // cancelled Task.sleep returns immediately all 50 would run anyway.
        #expect(await tracker.seen.count < 50)
    }
}
```

- [ ] **Step 2: Run the tests and verify they fail**

```bash
cd ios/PatataTubeKit && swift test --filter BoundedTaskGroupTests
```

Expected: compile failure — `cannot find 'withBoundedTaskGroup' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ios/PatataTubeKit/Sources/PatataTubeKit/BoundedTaskGroup.swift`:

```swift
import Foundation

/// Runs `operation` over `items` with at most `limit` running at once.
///
/// Seeds `limit` tasks, then replaces each one as it finishes — a sliding
/// window rather than a batch, so a slow item never stalls the others.
///
/// This exists because `CacheManager`'s `DownloadConcurrencyGate` bounds
/// *transfers*, and the work a Download-all does before reaching a transfer
/// (`ensureReady` -> `POST /prepare` -> a 2s poll loop) is not covered by it.
/// Spawning one task per video sent 226 concurrent prepare calls at the server
/// on 2026-07-31 and took the machine down.
///
/// `operation` is `@MainActor` because both call sites are SwiftUI views, and
/// `@Sendable` because `TaskGroup.addTask` requires it. Callers that need to
/// skip items should test inside `operation`, not by pre-filtering `items` —
/// an item can sit queued long enough for its eligibility to change.
@MainActor
public func withBoundedTaskGroup<T: Sendable>(
    limit: Int,
    over items: [T],
    operation: @escaping @MainActor @Sendable (T) async -> Void
) async {
    guard !items.isEmpty else { return }
    let bound = max(limit, 1)

    await withTaskGroup(of: Void.self) { group in
        var next = 0

        while next < items.count, next < bound {
            let item = items[next]
            group.addTask { await operation(item) }
            next += 1
        }

        while await group.next() != nil {
            // Stop seeding on cancellation; the group still awaits whatever is
            // already running when this scope exits.
            if Task.isCancelled { break }
            guard next < items.count else { continue }
            let item = items[next]
            group.addTask { await operation(item) }
            next += 1
        }
    }
}
```

- [ ] **Step 4: Run the tests and verify they pass**

```bash
cd ios/PatataTubeKit && swift test --filter BoundedTaskGroupTests
cd ios/PatataTubeKit && swift test -c release --filter BoundedTaskGroupTests
```

Expected: all five tests pass in both configurations.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/BoundedTaskGroup.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/BoundedTaskGroupTests.swift
git commit -m "feat(ios): add withBoundedTaskGroup

A sliding window of at most N concurrent operations. Download-all spawns
one task per video today, which is what sent 226 concurrent /prepare
calls at the server.

Lives in the package so the concurrency bound is actually tested — the
app target has no test target.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: `DeviceStorage` and the cache root URL

The free-space number for the confirmation dialog. Split from Task 1 because it is a separate unit with its own tests, and from Task 5 because it is package code rather than view wiring.

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/DeviceStorage.swift`
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift` (add an accessor next to `maxConcurrentDownloads` at `:244-247`)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/DeviceStorageTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public enum DeviceStorage { public static func availableBytes(at url: URL) -> Int64? }`
  - `CacheManager.cacheRootURL: URL` (public computed property)

- [ ] **Step 1: Write the failing tests**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/DeviceStorageTests.swift`:

```swift
import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Device storage")
struct DeviceStorageTests {

    @Test
    func reportsAvailableBytesForARealDirectory() {
        let bytes = DeviceStorage.availableBytes(at: URL(fileURLWithPath: NSTemporaryDirectory()))

        #expect(bytes != nil)
        #expect((bytes ?? 0) > 0)
    }

    @Test
    func returnsNilForAMissingPath() {
        let missing = URL(fileURLWithPath: "/no-such-volume-\(UUID().uuidString)/x")

        #expect(DeviceStorage.availableBytes(at: missing) == nil)
    }
}
```

- [ ] **Step 2: Run the tests and verify they fail**

```bash
cd ios/PatataTubeKit && swift test --filter DeviceStorageTests
```

Expected: compile failure — `cannot find 'DeviceStorage' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ios/PatataTubeKit/Sources/PatataTubeKit/DeviceStorage.swift`:

```swift
import Foundation

/// Free-space queries for the volume backing a given path.
public enum DeviceStorage {
    /// Bytes available for "important" usage — the number iOS actually lets an
    /// app consume, which is smaller than the raw free space on the volume.
    ///
    /// Returns `nil` rather than throwing: every caller here is advisory, and a
    /// failed lookup must never block the action it is describing.
    ///
    /// `DevLog.swift` reads the same key, but that call site is compiled out
    /// unless `DEVLOG` is defined, so it cannot be reused.
    public static func availableBytes(at url: URL) -> Int64? {
        guard
            let values = try? url.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            ),
            let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return available
    }
}
```

- [ ] **Step 4: Expose the cache root**

In `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift`, immediately after the `maxConcurrentDownloads` property (currently at lines 244-247):

```swift
    /// Current global simultaneous-download cap.
    public var maxConcurrentDownloads: Int {
        concurrencyGate.currentLimit
    }

    /// Directory holding the cached videos. Exposed so callers can ask how much
    /// room is left on the volume that downloads actually land on.
    public var cacheRootURL: URL { root }
```

Leave `maxConcurrentDownloads` itself unchanged; the new property goes below it.

- [ ] **Step 5: Run the tests and verify they pass**

```bash
cd ios/PatataTubeKit && swift test --filter DeviceStorageTests
cd ios/PatataTubeKit && swift build
```

Expected: both tests pass, package builds.

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/DeviceStorage.swift \
        ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/DeviceStorageTests.swift
git commit -m "feat(ios): add DeviceStorage free-space query

Advisory number for the Download-all confirmation dialog. Returns nil on
failure so a failed lookup never blocks the action it describes.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Closure isolation for the episode download chain

Pure signature change, no behaviour. `EpisodesView.onDownload` is a *stored* closure, so passing it into a `@Sendable` task-group body in Task 4 fails to compile under Swift 6 unless it is marked. Doing it as its own task keeps the "did I break the build?" question separate from the "did I change concurrency?" question.

**Files:**
- Modify: `ios/PatataTube/Sources/ShowsView.swift:9`
- Modify: `ios/PatataTube/Sources/EpisodesView.swift:25` and the `init` at `:32-41`

**Interfaces:**
- Consumes: nothing.
- Produces: `onDownload` and `currentCacheState` typed as `@MainActor @Sendable` closures, so Task 4 can pass them into a task group.

- [ ] **Step 1: Mark `ShowsView.onDownload`**

In `ios/PatataTube/Sources/ShowsView.swift`, change line 9:

```swift
    let onDownload: @MainActor @Sendable (Video) async -> Bool
```

Nothing else in `ShowsView` changes. Its only construction site is `VideoGridView.swift:88` (`onDownload: { await download($0) }`), which is already a MainActor closure over a `Sendable` View struct and needs no edit.

- [ ] **Step 2: Mark `EpisodesView`'s stored closures and init**

In `ios/PatataTube/Sources/EpisodesView.swift`, change the property at line 25:

```swift
    let onDownload: @MainActor @Sendable (Video) async -> Bool
```

and the stored override at line 26:

```swift
    private let cacheStateOverride: (@MainActor @Sendable (Video) -> CacheState)?
```

and the matching `init` parameters (lines 32-36):

```swift
    init(
        show: ShowGroup,
        onPlay: @escaping (Video, [Video]) -> Void,
        onDownload: @escaping @MainActor @Sendable (Video) async -> Bool,
        currentCacheState: (@MainActor @Sendable (Video) -> CacheState)? = nil
    ) {
```

The init body is unchanged. `onPlay` is deliberately left alone — it never crosses into a task group.

- [ ] **Step 3: Build the app target and verify it compiles**

```bash
cd ios/PatataTube && xcodegen generate
xcodebuild -project ios/PatataTube/PatataTube.xcodeproj -scheme PatataTube \
  -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`. No behaviour changed, so no test run is needed here.

- [ ] **Step 4: Commit**

```bash
git add ios/PatataTube/Sources/ShowsView.swift ios/PatataTube/Sources/EpisodesView.swift
git commit -m "refactor(ios): mark episode download closures MainActor Sendable

Signature-only. TaskGroup.addTask requires a Sendable body, and these are
stored closures, so bounding the episode download-all needs them marked
before it can compile under Swift 6.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Bound the episode-list Download-all

`downloadEligibleEpisodes` is serial today — a plain `for … await`, one episode at a time. It was never part of the outage; this makes a season download at the user's configured concurrency instead of one at a time.

**Files:**
- Modify: `ios/PatataTube/Sources/EpisodesView.swift:84-94` (the static) and `:124-138` (`downloadAll`)

**Interfaces:**
- Consumes: `withBoundedTaskGroup` from Task 1; the closure isolation from Task 3; `CacheManager.maxConcurrentDownloads` (existing).
- Produces: `EpisodesView.downloadEligibleEpisodes(_:limit:currentCacheState:onDownload:)` — note the new `limit` parameter, second position.

- [ ] **Step 1: Rewrite the static as a bounded window**

In `ios/PatataTube/Sources/EpisodesView.swift`, replace the whole of `downloadEligibleEpisodes` (lines 84-94):

```swift
    @MainActor
    static func downloadEligibleEpisodes(
        _ episodes: [Video],
        limit: Int,
        currentCacheState: @escaping @MainActor @Sendable (Video) -> CacheState,
        onDownload: @escaping @MainActor @Sendable (Video) async -> Bool
    ) async {
        // Eligibility is checked inside the operation, not by pre-filtering:
        // an episode can sit queued in the window long enough to finish
        // downloading by another route, and re-downloading it wastes the slot.
        await withBoundedTaskGroup(limit: limit, over: episodes) { episode in
            guard currentCacheState(episode) == .notCached else { return }
            _ = await onDownload(episode)
        }
    }
```

- [ ] **Step 2: Pass the limit from the caller**

In the same file, in `downloadAll` (lines 124-138), change only the call at the end:

```swift
        await Self.downloadEligibleEpisodes(
            show.episodes,
            limit: model.cache.maxConcurrentDownloads,
            currentCacheState: currentCacheState(for:),
            onDownload: onDownload
        )
```

The surrounding `setDownloading(true)` / `defer { … }` block is unchanged.

- [ ] **Step 3: Build and verify**

```bash
cd ios/PatataTubeKit && swift build
cd ios/PatataTube && xcodegen generate
xcodebuild -project ios/PatataTube/PatataTube.xcodeproj -scheme PatataTube \
  -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`. The bounded-window behaviour itself is covered by `BoundedTaskGroupTests` from Task 1 — `EpisodesView` lives in the app target, which has no test target, so there is no direct test to add here and none should be invented.

- [ ] **Step 4: Commit**

```bash
git add ios/PatataTube/Sources/EpisodesView.swift
git commit -m "feat(ios): download episodes at the configured concurrency

Download-all on a show ran strictly one episode at a time. It now uses
the same 1-4 slider the rest of the app uses.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Bound and confirm the grid Download-all

The actual outage path. Three changes that must land together, because splitting them ships a dialog announcing a count that does not match what runs.

**Files:**
- Modify: `ios/PatataTube/Sources/VideoGridView.swift` — state at `:18`, statics near `:33-39`, the menu button at `:172-175`, the modifier stack at `:203-211`, and `downloadAll` at `:346-361`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: `withBoundedTaskGroup` (Task 1), `DeviceStorage.availableBytes(at:)` and `CacheManager.cacheRootURL` (Task 2).
- Produces: nothing other tasks depend on. This is the last task.

- [ ] **Step 1: Add the confirmation state**

In `ios/PatataTube/Sources/VideoGridView.swift`, add the request type just above the `struct VideoGridView` declaration at line 5:

```swift
/// Confirmation payload for Download all. Carries the snapshot the dialog
/// describes so the count shown and the work started cannot drift apart.
struct DownloadAllRequest: Identifiable {
    let id = UUID()
    let targets: [Video]
    let freeBytes: Int64?
}
```

Then add the state property directly after `downloadingAll` (line 18):

```swift
    @State private var downloadingAll = false
    @State private var pendingDownloadAll: DownloadAllRequest?
```

- [ ] **Step 2: Add the message builder**

In the same file, after `shouldClearErrorBanner` (line 37-39), add:

```swift
    static func downloadAllMessage(count: Int, freeBytes: Int64?) -> String {
        let videos = count == 1 ? "1 video" : "\(count) videos"
        guard let freeBytes else {
            return "Download \(videos) to this iPad?"
        }
        let free = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
        return "Download \(videos) to this iPad? \(free) free."
    }
```

This follows the file's existing habit of hoisting pure logic to statics (`shouldDismissErrorBanner`, `shouldClearErrorBanner`, `downloadVideo`), even though the app target cannot test them.

- [ ] **Step 3: Replace `downloadAll` with a present-then-run pair**

Replace the whole of `downloadAll` (lines 346-361, including its doc comment) with:

```swift
    /// Collects the not-yet-cached videos currently on screen and asks for
    /// confirmation. Filters `filteredVideos`, not `store.videos`: the grid
    /// renders the search-filtered list, and a dialog announcing a count has to
    /// match what the user is looking at.
    private func presentDownloadAll() {
        let targets = filteredVideos.filter {
            model.cache.state(for: $0.id, versionId: $0.chosenVersionId) == .notCached
        }
        guard !targets.isEmpty else { return }
        pendingDownloadAll = DownloadAllRequest(
            targets: targets,
            freeBytes: DeviceStorage.availableBytes(at: model.cache.cacheRootURL)
        )
    }

    private func runDownloadAll(_ targets: [Video]) async {
        downloadingAll = true
        defer { downloadingAll = false }
        // The CacheManager gate bounds transfers, NOT this. `download` calls
        // ensureReady -> POST /prepare and then polls every 2s, all before the
        // gate is acquired. One task per video is what sent 226 simultaneous
        // prepare calls at the server on 2026-07-31.
        await withBoundedTaskGroup(
            limit: model.cache.maxConcurrentDownloads,
            over: targets
        ) { video in
            // Re-checked per item at seed time, not snapshotted: an item can
            // sit queued while its cache state changes underneath it.
            guard model.cache.state(for: video.id, versionId: video.chosenVersionId) == .notCached else { return }
            await download(video, bulk: true)
        }
    }
```

(If the ffmpeg job queue plan's Task 6 has not landed, write `await download(video)` instead — see Global Constraints.)

- [ ] **Step 4: Point the menu button at the new entry point**

In the toolbar menu (lines 172-175), replace:

```swift
                        Button {
                            Task { await downloadAll() }
                        } label: { Label("Download all", systemImage: "arrow.down.circle") }
                        .disabled(downloadingAll)
```

with:

```swift
                        Button {
                            presentDownloadAll()
                        } label: { Label("Download all", systemImage: "arrow.down.circle") }
                        .disabled(downloadingAll)
```

- [ ] **Step 5: Attach the alert**

In the modifier stack, directly after `.sheet(isPresented: $showUpload) { UploadView() }` (line 205):

```swift
            .alert(
                "Download all",
                isPresented: Binding(
                    get: { pendingDownloadAll != nil },
                    set: { if !$0 { pendingDownloadAll = nil } }
                ),
                presenting: pendingDownloadAll
            ) { request in
                Button("Cancel", role: .cancel) { pendingDownloadAll = nil }
                Button("Download") {
                    let targets = request.targets
                    pendingDownloadAll = nil
                    Task { await runDownloadAll(targets) }
                }
            } message: { request in
                Text(Self.downloadAllMessage(count: request.targets.count, freeBytes: request.freeBytes))
            }
```

- [ ] **Step 6: Build and verify**

```bash
cd ios/PatataTubeKit && swift build && swift test
cd ios/PatataTube && xcodegen generate
xcodebuild -project ios/PatataTube/PatataTube.xcodeproj -scheme PatataTube \
  -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`, package tests pass. (The pre-existing unrelated `Fatal error: Index out of range` from the parallel swift-testing suites still appears; every test still reports passing.)

- [ ] **Step 7: Document the bound**

In `CLAUDE.md`, in the `### iOS` subsection of Architecture, add after the existing `ios/PatataTube/` bullet:

```markdown
- **Download-all is bounded on the client too.** `withBoundedTaskGroup`
  (PatataTubeKit) runs at most `CacheManager.maxConcurrentDownloads` operations
  at once. This is not the same bound as `DownloadConcurrencyGate`, which covers
  only the transfer: `download` calls `ensureReady` -> `POST /prepare` and then
  polls every 2s *before* acquiring the gate. One task per video is what sent
  226 concurrent prepare calls at the server on 2026-07-31. New bulk actions go
  through the bounded window, not a bare `withTaskGroup`.
```

- [ ] **Step 8: Commit**

```bash
git add ios/PatataTube/Sources/VideoGridView.swift CLAUDE.md
git commit -m "feat(ios): bound and confirm Download all

Three changes that have to land together:

- Download-all runs at most maxConcurrentDownloads operations at once.
  It spawned one task per video, and because ensureReady runs before the
  CacheManager gate is acquired, nothing bounded the prepare calls. That
  is what took the server down on 2026-07-31.
- Tapping it now asks first, showing the target count and free space.
- It filters filteredVideos rather than store.videos, so the search box
  is respected. Its doc comment already claimed this; the count in the
  dialog would otherwise contradict the visible grid.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Manual verification

Not code. Do this once, on device, with the converter running.

- [ ] **Step 1: Confirm the dialog**

Search for something narrow in the grid, then tap Download all. The count must match the number of uncached videos visible, not the whole library. Clear the search and tap again — the count should jump to the full set, with a free-space figure.

- [ ] **Step 2: Confirm the bound**

Accept the dialog on the `all` filter, then:

```bash
jq -c 'select(.kind=="download" and (.msg|test("gate")))' log/ios.jsonl | tail -30
grep '\[job\]' log/backend.log | tail -20
pgrep -fc ffmpeg
```

Expected: no more than `maxConcurrentDownloads` concurrent prepare/poll pairs, `[job]` queue depth rising then draining, `ffmpeg` count steady at 1.

- [ ] **Step 3: Confirm the machine survives**

```bash
uptime
```

Expected: load average stays in single digits and SSH keeps answering — the condition that failed on 2026-07-31.
