# Pausable Downloads Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Each in-progress row in the iOS Downloads view gets a trailing three-dot menu holding Cancel plus Pause; a paused download shows Resume instead, and the pause survives quitting the app.

**Architecture:** A new `PausedDownloadStore` in PatataTubeKit persists paused entries as JSON in the cache root. `CacheManager` gains `pause(id:versionId:)` / `resume(id:versionId:)` that tear down and restart the transfer without destroying its on-disk resume state (unlike `cancel`, which deliberately wipes it). The gate permit is never returned while paused: `download`'s `defer` hands ownership to a paused-permit table, and at launch each stored entry re-reserves a permit through the same gate.

**Tech Stack:** Swift 6, SwiftUI, swift-testing (`@Test`/`#expect`), ViewInspector for the app target, `URLSession` download tasks.

## Global Constraints

- **Never run the iOS test suites** (`swift test`, `xcodebuild … test`) unless the user explicitly asks. Write the tests, state which ones cover the change, stop there. (`CLAUDE.md`)
- Logic lives in `ios/PatataTubeKit/`; the app shell in `ios/PatataTube/Sources/` only wires closures.
- Instrumentation uses `DevLog.event` / `DevLog.error`, never `print`. `meta` values stay cheap; no tokens, no response bodies.
- New PatataTubeKit test files go in `ios/PatataTubeKit/Tests/PatataTubeKitTests/`; app-target tests in `ios/PatataTube/Tests/` (built only by `xcodebuild`, so they rot silently — keep them compiling).
- Adding a file under `ios/PatataTubeKit/Sources/PatataTubeKit/` needs no project regeneration (SwiftPM globs). Adding one under `ios/PatataTube/Sources/` does: `cd ios/PatataTube && xcodegen generate`.
- Public API added to PatataTubeKit must be `public`; types crossing concurrency domains must be `Sendable`.
- Existing call sites must keep compiling: every new parameter or property gets a default value.

## Spec addendum

The spec's `PausedDownload` gains one field the spec omitted: `isHLS: Bool`. The
HLS path is a different entry point (`downloadHLS(id:versionId:masterURL:…)` in
`CacheManager+HLS.swift`) from the MP4 path (`download(id:versionId:from:…)`),
so resume has to know which one to call. `remoteURL` holds the master playlist
URL when `isHLS` is true.

## File structure

**Create:**
- `ios/PatataTubeKit/Sources/PatataTubeKit/PausedDownloadStore.swift` — the `PausedDownload` value type, `DownloadPausedError`, and the JSON-backed store. No dependency on `CacheManager`.
- `ios/PatataTubeKit/Tests/PatataTubeKitTests/PausedDownloadStoreTests.swift`
- `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerPauseTests.swift`

**Modify:**
- `ios/PatataTubeKit/Sources/PatataTubeKit/DownloadActivity.swift` — `isPaused` flag.
- `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift` — paused store wiring, permit ownership, `pause`, `resume`, `cancel` cleanup, `resumeInterrupted` guard, `activeDownloads` merge, `state(for:)`, `clearAllVideos`.
- `ios/PatataTubeKit/Sources/PatataTubeKit/VideoStore.swift:174` — `isCancellation` swallows `DownloadPausedError`.
- `ios/PatataTube/Sources/DownloadsView.swift` — the three-dot menu, the Paused caption, `onPause` / `onResume`.
- `ios/PatataTube/Sources/VideoGridView.swift:686-697` — wire the two new closures.
- `ios/PatataTube/Tests/DownloadsViewTests.swift` — existing tests tap `find(button: "Cancel")`, which the menu breaks; they move to the menu label.

---

### Task 1: `PausedDownload` + `PausedDownloadStore`

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/PausedDownloadStore.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/PausedDownloadStoreTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `PausedDownload` (see fields below), `DownloadPausedError`, and
  `PausedDownloadStore` with `init(root:fileManager:)`, `entries: [PausedDownload]`,
  `contains(_ key: String) -> Bool`, `entry(_ key: String) -> PausedDownload?`,
  `insert(_ entry: PausedDownload)`, `remove(_ key: String)`, `removeAll()`.

- [ ] **Step 1: Write the failing test**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/PausedDownloadStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Paused download store")
struct PausedDownloadStoreTests {
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("paused-\(UUID().uuidString)")
    }

    private func sample(videoID: Int, versionID: Int? = nil) -> PausedDownload {
        PausedDownload(
            videoID: videoID,
            versionID: versionID,
            remoteURL: URL(string: "https://example.com/\(videoID).mp4")!,
            isHLS: false,
            streamCount: 2,
            previewURL: nil,
            showPosterKey: nil,
            showPosterURL: nil,
            progress: 0.25,
            transferredByteCount: 250,
            totalByteCount: 1_000
        )
    }

    @Test func entriesSurviveANewStoreOnTheSameRoot() {
        let root = temporaryRoot()
        var store = PausedDownloadStore(root: root)
        store.insert(sample(videoID: 7, versionID: 2))

        let reopened = PausedDownloadStore(root: root)
        #expect(reopened.entries.count == 1)
        #expect(reopened.contains("7:2"))
        #expect(reopened.entry("7:2")?.progress == 0.25)
        #expect(reopened.entry("7:2")?.streamCount == 2)
    }

    @Test func insertReplacesTheEntryForTheSameKey() {
        var store = PausedDownloadStore(root: temporaryRoot())
        store.insert(sample(videoID: 7))
        var updated = sample(videoID: 7)
        updated = PausedDownload(
            videoID: 7, versionID: nil,
            remoteURL: updated.remoteURL, isHLS: false, streamCount: 2,
            previewURL: nil, showPosterKey: nil, showPosterURL: nil,
            progress: 0.9, transferredByteCount: 900, totalByteCount: 1_000
        )
        store.insert(updated)

        #expect(store.entries.count == 1)
        #expect(store.entry("7")?.progress == 0.9)
    }

    @Test func removeAndRemoveAllClearEntriesAndPersist() {
        let root = temporaryRoot()
        var store = PausedDownloadStore(root: root)
        store.insert(sample(videoID: 1))
        store.insert(sample(videoID: 2))
        store.remove("1")
        #expect(PausedDownloadStore(root: root).contains("1") == false)
        #expect(PausedDownloadStore(root: root).contains("2"))

        store.removeAll()
        #expect(PausedDownloadStore(root: root).entries.isEmpty)
    }

    @Test func aCorruptFileLoadsAsEmpty() throws {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(
            to: root.appendingPathComponent("paused-downloads.json")
        )
        #expect(PausedDownloadStore(root: root).entries.isEmpty)
    }

    @Test func idMatchesTheCacheKeyFormat() {
        #expect(sample(videoID: 7, versionID: 2).id == "7:2")
        #expect(sample(videoID: 7).id == "7")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ios/PatataTubeKit && swift build --build-tests`
Expected: FAIL — `cannot find 'PausedDownload' in scope`.

(Build only. Per the global constraints, do not run `swift test`.)

- [ ] **Step 3: Write the implementation**

Create `ios/PatataTubeKit/Sources/PatataTubeKit/PausedDownloadStore.swift`:

```swift
import Foundation

/// Thrown by a download whose transfer was paused. Distinct from
/// `CancellationError` so callers can tell "the user paused this, its partial
/// bytes are still on disk" from "the user cancelled, everything was wiped".
public struct DownloadPausedError: Error, Equatable {
    public init() {}
}

/// A download the user paused. Carries everything needed to restart the
/// transfer, because the HLS path keeps no partial state on disk to recover
/// its parameters from.
public struct PausedDownload: Codable, Equatable, Identifiable, Sendable {
    public let videoID: Int
    public let versionID: Int?
    public let remoteURL: URL
    /// True when `remoteURL` is an HLS master playlist and resuming must go
    /// through `downloadHLS` rather than `download`.
    public let isHLS: Bool
    public let streamCount: Int
    public let previewURL: URL?
    public let showPosterKey: String?
    public let showPosterURL: URL?
    /// Progress at the moment of pausing, so the frozen row still renders.
    public let progress: Double
    public let transferredByteCount: Int64
    public let totalByteCount: Int64?

    public init(
        videoID: Int,
        versionID: Int?,
        remoteURL: URL,
        isHLS: Bool,
        streamCount: Int,
        previewURL: URL?,
        showPosterKey: String?,
        showPosterURL: URL?,
        progress: Double,
        transferredByteCount: Int64,
        totalByteCount: Int64?
    ) {
        self.videoID = videoID
        self.versionID = versionID
        self.remoteURL = remoteURL
        self.isHLS = isHLS
        self.streamCount = streamCount
        self.previewURL = previewURL
        self.showPosterKey = showPosterKey
        self.showPosterURL = showPosterURL
        self.progress = progress
        self.transferredByteCount = transferredByteCount
        self.totalByteCount = totalByteCount
    }

    /// The `CacheManager` cache key, so this store is keyed exactly like
    /// `inFlight`, `tasksByKey`, and `segmentedAttempts`.
    public var id: String { versionID.map { "\(videoID):\($0)" } ?? "\(videoID)" }
}

/// Paused downloads, persisted as `paused-downloads.json` in the cache root.
///
/// Mirrors `DownloadCompletionHistoryStore`: load in `init`, rewrite the whole
/// file on every mutation, best-effort throughout. No capacity cap — entries
/// only ever appear and disappear by explicit user action.
struct PausedDownloadStore {
    private let url: URL
    private let fileManager: FileManager
    private(set) var entries: [PausedDownload]

    init(root: URL, fileManager: FileManager = .default) {
        self.url = root.appendingPathComponent("paused-downloads.json")
        self.fileManager = fileManager
        self.entries = (try? Data(contentsOf: url)).flatMap {
            try? JSONDecoder().decode([PausedDownload].self, from: $0)
        } ?? []
    }

    func contains(_ key: String) -> Bool {
        entries.contains { $0.id == key }
    }

    func entry(_ key: String) -> PausedDownload? {
        entries.first { $0.id == key }
    }

    mutating func insert(_ entry: PausedDownload) {
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        persist()
    }

    mutating func remove(_ key: String) {
        guard contains(key) else { return }
        entries.removeAll { $0.id == key }
        persist()
    }

    mutating func removeAll() {
        entries = []
        try? fileManager.removeItem(at: url)
    }

    private func persist() {
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
```

The store is an internal `struct` (not `public final class`) precisely like
`DownloadCompletionHistoryStore`: `CacheManager` owns one as a `var` and mutates
it under its existing `lock`, so it needs no lock of its own. The test file uses
`@testable import`, which reaches internal types.

- [ ] **Step 4: Verify it compiles**

Run: `cd ios/PatataTubeKit && swift build --build-tests`
Expected: builds clean, no warnings about the new file.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/PausedDownloadStore.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/PausedDownloadStoreTests.swift
git commit -m "feat(ios): persist paused downloads in a JSON store"
```

---

### Task 2: `DownloadActivity.isPaused` and the paused/live merge

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/DownloadActivity.swift:3-25`
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift` (`activeDownloads()` at ~458, `state(for:)` at ~449, stored properties at ~167-179, `init` at ~204-242)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerPauseTests.swift` (create)

**Interfaces:**
- Consumes: `PausedDownload`, `PausedDownloadStore` (Task 1).
- Produces: `DownloadActivity.isPaused: Bool` (defaulted `false` in the initializer); `CacheManager.activeDownloads()` returning live + paused merged; `CacheManager.pausedKeys` (internal, `Set<String>`) for later tasks.

- [ ] **Step 1: Write the failing test**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerPauseTests.swift`:

```swift
import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Cache manager pause")
struct CacheManagerPauseTests {
    fileprivate func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pause-cache-\(UUID().uuidString)")
    }

    fileprivate func pausedEntry(
        videoID: Int,
        versionID: Int? = nil,
        progress: Double = 0.4
    ) -> PausedDownload {
        PausedDownload(
            videoID: videoID,
            versionID: versionID,
            remoteURL: URL(string: "https://example.com/\(videoID).mp4")!,
            isHLS: false,
            streamCount: 2,
            previewURL: nil,
            showPosterKey: nil,
            showPosterURL: nil,
            progress: progress,
            transferredByteCount: 400,
            totalByteCount: 1_000
        )
    }

    /// Seeds a paused entry on disk, then builds a manager over that root so it
    /// loads the entry at init — the "app was quit while paused" case.
    fileprivate func managerWithPausedEntry(
        _ entry: PausedDownload,
        root: URL
    ) -> CacheManager {
        var store = PausedDownloadStore(root: root)
        store.insert(entry)
        return CacheManager(
            root: root,
            configuration: .ephemeral,
            fileManager: .default
        )
    }

    @Test func pausedEntriesAppearInActiveDownloadsAsPaused() {
        let root = temporaryRoot()
        let manager = managerWithPausedEntry(pausedEntry(videoID: 7, versionID: 2), root: root)

        let activities = manager.activeDownloads()
        #expect(activities.count == 1)
        #expect(activities.first?.videoID == 7)
        #expect(activities.first?.versionID == 2)
        #expect(activities.first?.isPaused == true)
        #expect(activities.first?.progress == 0.4)
    }

    @Test func pausedEntriesDoNotMoveTheByteCounter() {
        let root = temporaryRoot()
        let manager = managerWithPausedEntry(pausedEntry(videoID: 7), root: root)
        #expect(manager.downloadedByteCount() == 0)
    }

    @Test func aPausedKeyStillReadsAsDownloading() {
        let root = temporaryRoot()
        let manager = managerWithPausedEntry(pausedEntry(videoID: 7, progress: 0.4), root: root)
        guard case .downloading(let progress) = manager.state(for: 7) else {
            Issue.record("expected .downloading, got \(manager.state(for: 7))")
            return
        }
        #expect(progress == 0.4)
    }

    @Test func aPausedEntryWhoseFileLandedIsDropped() throws {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = managerWithPausedEntry(pausedEntry(videoID: 7), root: root)
        try Data("mp4".utf8).write(to: manager.localURL(for: 7))

        #expect(manager.activeDownloads().isEmpty)
        #expect(PausedDownloadStore(root: root).contains("7") == false)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd ios/PatataTubeKit && swift build --build-tests`
Expected: FAIL — `value of type 'DownloadActivity' has no member 'isPaused'`.

- [ ] **Step 3: Add the flag**

In `DownloadActivity.swift`, add the property and a defaulted initializer
parameter (defaulted so all ~19 existing construction sites keep compiling):

```swift
public struct DownloadActivity: Equatable, Identifiable, Sendable {
    public let videoID: Int
    public let versionID: Int?
    public let progress: Double
    public let transferredByteCount: Int64
    public let totalByteCount: Int64?
    /// True for an entry restored from `PausedDownloadStore` rather than a live
    /// transfer. Paused entries never enter `inFlight`, so they contribute
    /// nothing to the speed meter.
    public let isPaused: Bool

    public init(
        videoID: Int,
        versionID: Int?,
        progress: Double,
        transferredByteCount: Int64,
        totalByteCount: Int64?,
        isPaused: Bool = false
    ) {
        self.videoID = videoID
        self.versionID = versionID
        self.progress = progress
        self.transferredByteCount = transferredByteCount
        self.totalByteCount = totalByteCount
        self.isPaused = isPaused
    }

    public var id: String { versionID.map { "\(videoID):\($0)" } ?? "\(videoID)" }
}
```

- [ ] **Step 4: Wire the store into `CacheManager`**

Add stored properties next to `completionHistory` (~line 171):

```swift
    private var pausedStore: PausedDownloadStore
    /// In-memory mirror of `pausedStore`'s keys, read under `lock` on the hot
    /// paths (`releasePermit`, `resumeInterrupted`) so they never touch the
    /// filesystem.
    private var pausedKeys: Set<String> = []
```

In the designated `init`, after `self.segmentedStore = …` (~line 232):

```swift
        self.pausedStore = PausedDownloadStore(root: self.root, fileManager: fileManager)
```

and after `super.init()` / directory creation (~line 235):

```swift
        self.pausedKeys = Set(self.pausedStore.entries.map(\.id))
```

Replace `activeDownloads()` (~line 458):

```swift
    /// Live transfers plus paused entries, sorted by key. A paused entry whose
    /// file has since landed is stale (a pause that raced a completion) — drop
    /// it here, the same staleness check `recentDownloads()` applies.
    public func activeDownloads() -> [DownloadActivity] {
        lock.withLock {
            let live = inFlight.values.map(\.activity)
            let liveKeys = Set(live.map(\.id))
            var stale: [String] = []
            var paused: [DownloadActivity] = []
            for entry in pausedStore.entries where !liveKeys.contains(entry.id) {
                let landed = fileManager.fileExists(
                    atPath: localURL(for: entry.videoID, versionId: entry.versionID).path
                )
                if landed {
                    stale.append(entry.id)
                    continue
                }
                paused.append(DownloadActivity(
                    videoID: entry.videoID,
                    versionID: entry.versionID,
                    progress: entry.progress,
                    transferredByteCount: entry.transferredByteCount,
                    totalByteCount: entry.totalByteCount,
                    isPaused: true
                ))
            }
            for key in stale {
                pausedStore.remove(key)
                pausedKeys.remove(key)
            }
            return (live + paused).sorted { $0.id < $1.id }
        }
    }
```

Extend `state(for:versionId:)` (~line 449) so a paused key reports the frozen
progress rather than `.notCached` (the grid ring freezes instead of reverting to
a download arrow, and no `CacheState` switch anywhere else changes):

```swift
        return lock.withLock {
            if let activity = inFlight[key]?.activity {
                return .downloading(activity.progress)
            }
            if let entry = pausedStore.entry(key) {
                return .downloading(entry.progress)
            }
            return .notCached
        }
```

- [ ] **Step 5: Verify it compiles**

Run: `cd ios/PatataTubeKit && swift build --build-tests`
Expected: builds clean.

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/DownloadActivity.swift \
        ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerPauseTests.swift
git commit -m "feat(ios): surface paused downloads alongside live ones"
```

---

### Task 3: Permit ownership — pause keeps its slot

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift` (`download(id:…)` ~501-529, stored properties ~171, `init` ~235)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerPauseTests.swift`

**Interfaces:**
- Consumes: `pausedKeys`, `pausedStore` (Task 2).
- Produces: `releasePermit(for key: String)`, `reservePermit(for key: String)`,
  `awaitPermit(for key: String) async`, `releasePausedPermit(for key: String)`,
  and the stored `pausedPermitKeys: Set<String>` / `pausedReservations: [String: Task<Void, Never>]`.
  Later tasks call `releasePausedPermit` when a paused entry is cancelled and
  `awaitPermit` before resuming.

- [ ] **Step 1: Write the failing test**

Append to `CacheManagerPauseTests.swift`. It needs a gate spy; `SpyGate` in
`CacheManagerConcurrencyGateTests.swift` is `private`, so declare a local one
(the two files' spies stay independent on purpose — this one counts more):

```swift
private final class PauseSpyGate: DownloadConcurrencyGating, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var acquireCount = 0
    private(set) var releaseCount = 0
    private var limit = 3

    func acquire() async { lock.withLock { acquireCount += 1 } }
    func release() { lock.withLock { releaseCount += 1 } }
    func setLimit(_ n: Int) { lock.withLock { limit = max(n, 1) } }
    var currentLimit: Int { lock.withLock { limit } }
}

extension CacheManagerPauseTests {
    @Test func aStoredPausedEntryReservesAPermitAtLaunch() async throws {
        let root = temporaryRoot()
        var store = PausedDownloadStore(root: root)
        store.insert(pausedEntry(videoID: 7))
        let spy = PauseSpyGate()
        let manager = CacheManager(
            root: root,
            configuration: .ephemeral,
            fileManager: .default,
            concurrencyGate: spy
        )
        // The reservation runs in a detached task; wait for it to be granted.
        await manager.awaitPermit(for: "7")

        #expect(spy.acquireCount == 1)
        #expect(spy.releaseCount == 0)
    }

    @Test func releasingAPausedPermitReturnsItToTheGate() async throws {
        let root = temporaryRoot()
        var store = PausedDownloadStore(root: root)
        store.insert(pausedEntry(videoID: 7))
        let spy = PauseSpyGate()
        let manager = CacheManager(
            root: root,
            configuration: .ephemeral,
            fileManager: .default,
            concurrencyGate: spy
        )
        await manager.awaitPermit(for: "7")
        manager.releasePausedPermit(for: "7")

        #expect(spy.releaseCount == 1)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd ios/PatataTubeKit && swift build --build-tests`
Expected: FAIL — `value of type 'CacheManager' has no member 'awaitPermit'`.

- [ ] **Step 3: Implement permit ownership**

Add stored properties beside `pausedKeys`:

```swift
    /// Paused keys currently holding a gate permit.
    private var pausedPermitKeys: Set<String> = []
    /// Launch-time reservations still waiting on the gate. Completing means the
    /// permit was granted (or the key stopped being paused, in which case the
    /// task released it again).
    private var pausedReservations: [String: Task<Void, Never>] = [:]
```

Extend `init` after `self.pausedKeys = …`:

```swift
        for key in self.pausedKeys {
            reservePermit(for: key)
        }
```

Add the four methods near `cancel(id:versionId:)`:

```swift
    /// Returns a finished download's permit — unless the key was paused, in
    /// which case ownership transfers to the paused-permit table and the slot
    /// stays occupied. Called from `download`'s `defer` instead of a bare
    /// `concurrencyGate.release()`.
    private func releasePermit(for key: String) {
        let handedOver = lock.withLock { () -> Bool in
            guard pausedKeys.contains(key), !pausedPermitKeys.contains(key)
            else { return false }
            pausedPermitKeys.insert(key)
            return true
        }
        DevLog.event(.download, handedOver ? "permit held for pause" : "permit released", [
            "key": key,
        ])
        if !handedOver { concurrencyGate.release() }
    }

    /// Re-acquires a permit for an entry that was paused in a previous process.
    /// Queues through the gate like any other acquirer; if the entry stops being
    /// paused before the permit is granted, it is handed straight back.
    private func reservePermit(for key: String) {
        let task = Task.detached { [weak self] in
            guard let self else { return }
            await self.concurrencyGate.acquire()
            let stillPaused = self.lock.withLock { () -> Bool in
                guard self.pausedKeys.contains(key) else { return false }
                self.pausedPermitKeys.insert(key)
                return true
            }
            if !stillPaused { self.concurrencyGate.release() }
        }
        lock.withLock { pausedReservations[key] = task }
    }

    /// Waits until this paused key's permit has actually been granted. A no-op
    /// when the permit was handed over from a live download (no reservation).
    func awaitPermit(for key: String) async {
        guard let task = lock.withLock({ pausedReservations[key] }) else { return }
        await task.value
    }

    /// Hands a paused entry's permit back to the gate. Safe to call for a key
    /// that never held one.
    func releasePausedPermit(for key: String) {
        let held = lock.withLock { pausedPermitKeys.remove(key) != nil }
        lock.withLock { pausedReservations[key] = nil }
        if held { concurrencyGate.release() }
    }
```

Change `download(id:versionId:…)`'s defer (~line 512) from
`concurrencyGate.release()` to `releasePermit(for:)`. The key has to be computed
before the `defer`:

```swift
        let key = cacheKey(videoId: id, versionId: versionId)
        await concurrencyGate.acquire()
        DevLog.event(.download, "download passed gate", ["video_id": "\(id)"])
        defer {
            DevLog.event(.download, "download releasing gate", ["video_id": "\(id)"])
            releasePermit(for: key)
        }
```

Do the same in `downloadHLS` (`CacheManager+HLS.swift:24-29`), which has the
identical acquire/`defer`-release pair. It already computes `key` above line 24,
so only the release changes:

```swift
        defer {
            DevLog.event(.download, "downloadHLS releasing gate", ["video_id": "\(id)"])
            releasePermit(for: key)
        }
```

`releasePermit` is `private`, and the extension lives in a different file, so
widen it to `internal` (drop the `private`) — same-module access is all the
extension needs.

- [ ] **Step 4: Verify it compiles**

Run: `cd ios/PatataTubeKit && swift build --build-tests`
Expected: builds clean.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift \
        ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager+HLS.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerPauseTests.swift
git commit -m "feat(ios): keep the concurrency permit while a download is paused"
```

---

### Task 4: `CacheManager.pause(id:versionId:)`

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift` (new methods near `cancel` ~645)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerPauseTests.swift`

**Interfaces:**
- Consumes: `pausedStore`, `pausedKeys`, `releasePermit` (Tasks 2-3), plus the
  existing private `segmentedAttempts`, `tasksByKey`, `preserveSegmentResumeData(_:attempt:segmentIndex:pendingTaskIdentifier:)`,
  `finishFailedSegmentedAttemptIfReady(_:)`, `cancelExternalActivity(key:)`.
- Produces: `public func pause(id: Int, versionId: Int? = nil, remote: URL, isHLS: Bool, streamCount: Int, preview: URL?, showPosterKey: String?, showPoster: URL?)`.

The pause parameters mirror what `download`/`downloadHLS` were called with,
because the store entry has to carry them for a resume in a later process. The
view layer already holds them (`VideoGridView.download(_:)` builds exactly these
values), so Task 8 passes them through.

- [ ] **Step 1: Write the failing test**

Append to `CacheManagerPauseTests.swift`:

```swift
extension CacheManagerPauseTests {
    @Test func pausingRecordsTheEntryAndKeepsThePermit() async throws {
        let root = temporaryRoot()
        let spy = PauseSpyGate()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        // Never responds: the download stays in flight while we pause it.
        MockURLProtocol.handler = { _ in
            try await Task.sleep(for: .seconds(30))
            throw URLError(.timedOut)
        }
        defer { MockURLProtocol.handler = nil }

        let manager = CacheManager(
            root: root,
            configuration: config,
            fileManager: .default,
            concurrencyGate: spy
        )
        let remote = URL(string: "https://example.com/7.mp4")!
        let download = Task { try await manager.download(id: 7, from: remote) }
        // Let the probe register the key in `inFlight`.
        try await Task.sleep(for: .milliseconds(200))

        manager.pause(
            id: 7, versionId: nil, remote: remote, isHLS: false, streamCount: 1,
            preview: nil, showPosterKey: nil, showPoster: nil
        )
        _ = try? await download.value

        #expect(PausedDownloadStore(root: root).contains("7"))
        #expect(manager.activeDownloads().first?.isPaused == true)
        // Acquired once for the download; never released, because it is paused.
        #expect(spy.acquireCount == 1)
        #expect(spy.releaseCount == 0)
    }

    @Test func pausingASegmentedDownloadKeepsItsManifest() async throws {
        let root = temporaryRoot()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let total = 4_000
        MockURLProtocol.handler = { request in
            if request.httpMethod == "HEAD" || request.value(forHTTPHeaderField: "Range") == nil {
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: [
                        "Content-Length": "\(total)",
                        "Accept-Ranges": "bytes",
                        "ETag": "\"abc\"",
                    ]
                )!
                return (response, Data())
            }
            try await Task.sleep(for: .seconds(30))
            throw URLError(.timedOut)
        }
        defer { MockURLProtocol.handler = nil }

        let manager = CacheManager(root: root, configuration: config, fileManager: .default)
        let remote = URL(string: "https://example.com/7.mp4")!
        let download = Task {
            try await manager.download(id: 7, from: remote, streamCount: 2)
        }
        try await Task.sleep(for: .milliseconds(300))

        manager.pause(
            id: 7, versionId: nil, remote: remote, isHLS: false, streamCount: 2,
            preview: nil, showPosterKey: nil, showPoster: nil
        )
        _ = try? await download.value

        let manifest = SegmentedDownloadStore(root: root, fileManager: .default)
            .manifestURL(cacheKey: "7")
        #expect(FileManager.default.fileExists(atPath: manifest.path))
    }
}
```

`SegmentedDownloadStore` is the internal type at
`SegmentedDownload.swift:148`; `manifestURL(cacheKey:)` is line 179.

- [ ] **Step 2: Run to verify it fails**

Run: `cd ios/PatataTubeKit && swift build --build-tests`
Expected: FAIL — `value of type 'CacheManager' has no member 'pause'`.

- [ ] **Step 3: Implement `pause`**

Add near `cancel(id:versionId:)`:

```swift
    /// Suspends a download, keeping every byte already on disk **and** its gate
    /// permit. Deliberately not `cancel(id:)`: that path exists to wipe resume
    /// state so a re-tap starts clean, which is the opposite of a pause.
    ///
    /// The download parameters are taken as arguments and stored, because the
    /// HLS path leaves nothing on disk to recover them from and a resume may
    /// happen in a later process.
    public func pause(
        id: Int,
        versionId: Int? = nil,
        remote: URL,
        isHLS: Bool,
        streamCount: Int,
        preview: URL? = nil,
        showPosterKey: String? = nil,
        showPoster: URL? = nil
    ) {
        let key = cacheKey(videoId: id, versionId: versionId)
        let snapshot = lock.withLock { () -> DownloadActivity? in
            guard !pausedKeys.contains(key) else { return nil }
            let activity = inFlight[key]?.activity
            pausedKeys.insert(key)
            pausedStore.insert(PausedDownload(
                videoID: id,
                versionID: versionId,
                remoteURL: remote,
                isHLS: isHLS,
                streamCount: streamCount,
                previewURL: preview,
                showPosterKey: showPosterKey,
                showPosterURL: showPoster,
                progress: activity?.progress ?? 0,
                transferredByteCount: activity?.transferredByteCount ?? 0,
                totalByteCount: activity?.totalByteCount
            ))
            inFlight[key] = nil
            return activity
        }
        DevLog.event(.download, "pause", [
            "video_id": "\(id)",
            "version_id": versionId.map(String.init) ?? "-",
            "progress": snapshot.map { String(format: "%.3f", $0.progress) } ?? "-",
            "hls": "\(isHLS)",
        ])
        pauseExternal(key: key)
        pauseSegmented(key: key)
        pausePlain(key: key)
    }

    /// HLS packaging keeps no partial state, so pausing it is a cancel; the
    /// stored entry is what makes the row survive, and resuming restarts at 0.
    private func pauseExternal(key: String) {
        guard lock.withLock({ externalActivityKeys.contains(key) }) else { return }
        cancelExternalActivity(key: key)
    }

    /// Cancels the segment tasks while producing resume data, reusing the same
    /// preservation machinery a resumable transport error goes through:
    /// `preservingResumeData` makes `finishFailedSegmentedAttemptIfReady` write
    /// the manifest back and skip `segmentedStore.remove`, so the partial parts
    /// survive for `startIncompleteSegments` to pick up.
    private func pauseSegmented(key: String) {
        guard let attempt = lock.withLock({ segmentedAttempts[key] }) else { return }
        let tasks: [(task: URLSessionDownloadTask, taskID: Int, segmentIndex: Int)] =
            lock.withLock {
                guard let current = segmentedAttempts[key],
                      current.id == attempt.id,
                      !current.terminalClaimed
                else { return [] }
                current.preservingResumeData = true
                if current.terminalError == nil {
                    current.terminalError = DownloadPausedError()
                }
                return current.taskIDs.compactMap { taskID in
                    guard let task = tasksByIdentifier[taskID],
                          let context = segmentContextByTask[taskID],
                          context.attemptID == current.id
                    else { return nil }
                    current.resumeDataPendingTaskIDs.insert(taskID)
                    return (task, taskID, context.segmentIndex)
                }
            }
        for entry in tasks {
            entry.task.cancel(byProducingResumeData: { [weak self, weak attempt] data in
                guard let self, let attempt else { return }
                self.preserveSegmentResumeData(
                    data,
                    attempt: attempt,
                    segmentIndex: entry.segmentIndex,
                    pendingTaskIdentifier: entry.taskID
                )
            })
        }
        finishFailedSegmentedAttemptIfReady(attempt)
    }

    /// The plain path (a download already running off a `{key}.resume` file):
    /// cancel producing fresh resume data and write it back over that file.
    private func pausePlain(key: String) {
        guard let task = lock.withLock({ tasksByKey[key] }) else { return }
        task.cancel(byProducingResumeData: { [weak self] data in
            guard let self, let data, !data.isEmpty else { return }
            try? self.fileManager.createDirectory(
                at: self.root, withIntermediateDirectories: true
            )
            try? data.write(to: self.resumeURL(for: key), options: .atomic)
        })
    }
```

`resumeURL(for:)`, `root`, and `fileManager` are all private members of the same
type, so no visibility changes are needed.

- [ ] **Step 4: Verify it compiles**

Run: `cd ios/PatataTubeKit && swift build --build-tests`
Expected: builds clean.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerPauseTests.swift
git commit -m "feat(ios): pause a download without discarding its partial bytes"
```

---

### Task 5: `CacheManager.resume(id:versionId:)`

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift` (`download` ~501, new `resume` below it)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerPauseTests.swift`

**Interfaces:**
- Consumes: `awaitPermit(for:)`, `releasePausedPermit(for:)` (Task 3), `pausedStore` (Task 2).
- Produces: `public func resume(id: Int, versionId: Int? = nil, bearerToken: String? = nil) async throws`, and the extracted ungated `performDownload(id:versionId:from:preview:showPosterKey:showPoster:bearerToken:streamCount:)`.

- [ ] **Step 1: Write the failing test**

Append to `CacheManagerPauseTests.swift`:

```swift
extension CacheManagerPauseTests {
    @Test func resumingClearsTheEntryAndReusesTheHeldPermit() async throws {
        let root = temporaryRoot()
        let spy = PauseSpyGate()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        defer { MockURLProtocol.handler = nil }

        var store = PausedDownloadStore(root: root)
        store.insert(pausedEntry(videoID: 7))
        let manager = CacheManager(
            root: root,
            configuration: config,
            fileManager: .default,
            concurrencyGate: spy
        )
        await manager.awaitPermit(for: "7")
        #expect(spy.acquireCount == 1)

        // The transfer itself fails (offline), but resume must still consume the
        // entry and hand the reserved permit back exactly once.
        try? await manager.resume(id: 7)

        #expect(PausedDownloadStore(root: root).contains("7") == false)
        #expect(manager.activeDownloads().isEmpty)
        #expect(spy.acquireCount == 1)   // no second acquire
        #expect(spy.releaseCount == 1)
    }

    @Test func resumingAnUnknownKeyDoesNothing() async throws {
        let manager = CacheManager(
            root: temporaryRoot(),
            configuration: .ephemeral,
            fileManager: .default
        )
        try await manager.resume(id: 999)
        #expect(manager.activeDownloads().isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd ios/PatataTubeKit && swift build --build-tests`
Expected: FAIL — `value of type 'CacheManager' has no member 'resume'`.

- [ ] **Step 3: Extract the ungated body and add `resume`**

Split the current `download(id:…)` so its post-gate body is reusable. Replace
the body after the `defer` block with a call to a new private method, and add
`resume` next to it:

```swift
    public func download(id: Int, versionId: Int? = nil, from remote: URL, preview: URL? = nil,
                         showPosterKey: String? = nil, showPoster: URL? = nil,
                         bearerToken: String? = nil, streamCount: Int = 1) async throws {
        DevLog.event(.download, "download requested", [
            "video_id": "\(id)",
            "version_id": versionId.map(String.init) ?? "-",
            "streams": "\(streamCount)",
            "state": DevLog.describe(state(for: id, versionId: versionId)),
        ])
        let key = cacheKey(videoId: id, versionId: versionId)
        await concurrencyGate.acquire()
        DevLog.event(.download, "download passed gate", ["video_id": "\(id)"])
        defer {
            DevLog.event(.download, "download releasing gate", ["video_id": "\(id)"])
            releasePermit(for: key)
        }
        try await performDownload(
            id: id, versionId: versionId, from: remote, preview: preview,
            showPosterKey: showPosterKey, showPoster: showPoster,
            bearerToken: bearerToken, streamCount: streamCount
        )
    }

    /// The transfer itself, with no gate interaction. `download` wraps it in an
    /// acquire/release; `resume` calls it directly because the permit for a
    /// paused entry is already held.
    private func performDownload(
        id: Int, versionId: Int?, from remote: URL, preview: URL?,
        showPosterKey: String?, showPoster: URL?,
        bearerToken: String?, streamCount: Int
    ) async throws {
        _ = try await downloadVideo(
            id: id,
            versionId: versionId,
            from: remote,
            bearerToken: bearerToken,
            streamCount: min(max(streamCount, 1), 4)
        )
        // Best-effort: a missing preview must not fail the cached video.
        if let preview { try? await cachePreview(id: id, from: preview, bearerToken: bearerToken) }
        // Show poster is shared across episodes: fetch once, skip when cached.
        if let showPosterKey, let showPoster, cachedShowPosterURL(for: showPosterKey) == nil {
            try? await cacheShowPoster(key: showPosterKey, from: showPoster, bearerToken: bearerToken)
        }
    }

    /// Restarts a paused download. The permit it has been holding is reused, so
    /// this never queues behind other pending downloads. Nothing calls this
    /// automatically — only the Resume menu item does.
    public func resume(id: Int, versionId: Int? = nil, bearerToken: String? = nil) async throws {
        let key = cacheKey(videoId: id, versionId: versionId)
        guard let entry = lock.withLock({ pausedStore.entry(key) }) else { return }
        await awaitPermit(for: key)
        lock.withLock {
            pausedStore.remove(key)
            pausedKeys.remove(key)
        }
        DevLog.event(.download, "resume", [
            "video_id": "\(id)",
            "version_id": versionId.map(String.init) ?? "-",
            "hls": "\(entry.isHLS)",
            "progress": String(format: "%.3f", entry.progress),
        ])
        defer {
            // The permit was reserved for the paused entry; hand it back now
            // that the transfer has ended, however it ended.
            releasePausedPermit(for: key)
        }
        if entry.isHLS {
            try await downloadHLS(
                id: id, versionId: versionId,
                masterURL: entry.remoteURL,
                preview: entry.previewURL,
                showPosterKey: entry.showPosterKey,
                showPoster: entry.showPosterURL,
                bearerToken: bearerToken,
                acquiresPermit: false
            )
        } else {
            try await performDownload(
                id: id, versionId: versionId, from: entry.remoteURL,
                preview: entry.previewURL,
                showPosterKey: entry.showPosterKey, showPoster: entry.showPosterURL,
                bearerToken: bearerToken, streamCount: entry.streamCount
            )
        }
    }
```

`downloadHLS` (`CacheManager+HLS.swift:6`) gains a final
`acquiresPermit: Bool = true` parameter. Wrap its gate lines (24-29) so both the
acquire and the `defer`'s `releasePermit(for: key)` are skipped when it is
false — `resume` already holds the permit:

```swift
        if acquiresPermit {
            await concurrencyGate.acquire()
            DevLog.event(.download, "downloadHLS passed gate", ["video_id": "\(id)"])
        }
        defer {
            guard acquiresPermit else { return }
            DevLog.event(.download, "downloadHLS releasing gate", ["video_id": "\(id)"])
            releasePermit(for: key)
        }
```

The default keeps `VideoGridView`'s existing `downloadHLS` call (line 1027)
compiling unchanged.

`resume`'s `defer` and `download`'s `releasePermit(for:)` never both fire for one
key: `resume` removes the key from `pausedKeys` before starting, so a pause
racing in mid-resume creates a *new* entry and a fresh handover.

- [ ] **Step 4: Verify it compiles**

Run: `cd ios/PatataTubeKit && swift build --build-tests`
Expected: builds clean.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift \
        ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager+HLS.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerPauseTests.swift
git commit -m "feat(ios): resume a paused download on its held permit"
```

---

### Task 6: Nothing auto-resumes; cancel and clear clean up

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift` (`resumeInterrupted` ~538-640, `cancel` ~645-696, `clearAllVideos` ~738-757)
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/VideoStore.swift:174-179`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerPauseTests.swift`

**Interfaces:**
- Consumes: `pausedKeys`, `pausedStore`, `releasePausedPermit` (Tasks 2-3).
- Produces: no new API. `cancel(id:versionId:)` now also clears a paused entry;
  `VideoStore.isCancellation` returns true for `DownloadPausedError`.

- [ ] **Step 1: Write the failing test**

Append to `CacheManagerPauseTests.swift`:

```swift
extension CacheManagerPauseTests {
    @Test func resumeInterruptedSkipsPausedKeys() async throws {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // A paused plain download leaves exactly this artifact behind.
        try Data("resume-bytes".utf8).write(to: root.appendingPathComponent("7.resume"))
        var store = PausedDownloadStore(root: root)
        store.insert(pausedEntry(videoID: 7))

        let manager = CacheManager(
            root: root, configuration: .ephemeral, fileManager: .default
        )
        #expect(manager.resumeInterrupted().isEmpty)
        #expect(manager.activeDownloads().first?.isPaused == true)
    }

    @Test func cancellingAPausedEntryClearsItAndItsPermit() async throws {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("resume-bytes".utf8).write(to: root.appendingPathComponent("7.resume"))
        var store = PausedDownloadStore(root: root)
        store.insert(pausedEntry(videoID: 7))
        let spy = PauseSpyGate()
        let manager = CacheManager(
            root: root, configuration: .ephemeral, fileManager: .default,
            concurrencyGate: spy
        )
        await manager.awaitPermit(for: "7")

        manager.cancel(id: 7)

        #expect(PausedDownloadStore(root: root).contains("7") == false)
        #expect(manager.activeDownloads().isEmpty)
        #expect(spy.releaseCount == 1)
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("7.resume").path
            ) == false
        )
    }

    @Test func clearingAllVideosDropsPausedEntries() async throws {
        let root = temporaryRoot()
        var store = PausedDownloadStore(root: root)
        store.insert(pausedEntry(videoID: 7))
        let spy = PauseSpyGate()
        let manager = CacheManager(
            root: root, configuration: .ephemeral, fileManager: .default,
            concurrencyGate: spy
        )
        await manager.awaitPermit(for: "7")

        manager.clearAllVideos()

        #expect(PausedDownloadStore(root: root).entries.isEmpty)
        #expect(manager.activeDownloads().isEmpty)
        #expect(spy.releaseCount == 1)
    }

    @Test func aPausedDownloadIsTreatedAsACancellation() {
        #expect(VideoStore.isCancellation(DownloadPausedError()))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd ios/PatataTubeKit && swift build --build-tests`
Expected: builds, then the behavior is wrong — `resumeInterrupted` restarts the
paused key. (This is the one task whose failure is behavioral rather than a
compile error; the assertions are what catch it when the user later runs the
suite.)

- [ ] **Step 3: Guard `resumeInterrupted`**

In the manifest loop's registration guard (~line 567), add `pausedKeys` to the
existing conditions:

```swift
            let registered = lock.withLock {
                guard segmentedAttempts[key] == nil,
                      tasksByKey[key] == nil,
                      probeAttempts[key] == nil,
                      inFlight[key] == nil,
                      !pausedKeys.contains(key),
                      !externalActivityKeys.contains(key)
                else { return false }
```

In the `.resume`-file loop, add it to both the early-skip check (~line 599) and
the registration guard (~line 610):

```swift
        if lock.withLock({
            tasksByKey[key] != nil
                || segmentedAttempts[key] != nil
                || probeAttempts[key] != nil
                || inFlight[key] != nil
                || pausedKeys.contains(key)
                || externalActivityKeys.contains(key)
        }) {
                continue
            }
```

```swift
            let registered = lock.withLock {
                guard tasksByKey[key] == nil,
                      segmentedAttempts[key] == nil,
                      probeAttempts[key] == nil,
                      inFlight[key] == nil,
                      !pausedKeys.contains(key),
                      !externalActivityKeys.contains(key)
                else { return false }
```

- [ ] **Step 4: Clean up in `cancel` and `clearAllVideos`**

At the top of `cancel(id:versionId:)`, right after the `DevLog.event(.cache, "cancel", …)`
call, drop the paused entry and its partial state before the existing teardown
runs (a paused key has no live attempt for that teardown to find):

```swift
        let wasPaused = lock.withLock { () -> Bool in
            guard pausedKeys.contains(key) else { return false }
            pausedStore.remove(key)
            pausedKeys.remove(key)
            return true
        }
        if wasPaused {
            releasePausedPermit(for: key)
            segmentedStore.remove(cacheKey: key)
            try? fileManager.removeItem(at: resumeURL(for: key))
            try? fileManager.removeItem(at: offlineHLSDir(for: id, versionId: versionId))
        }
```

In `clearAllVideos()`, after the `for activity in activeDownloads() { cancel(…) }`
loop — which now cancels paused entries too, since `activeDownloads()` includes
them — add a belt-and-braces clear alongside `completionHistory.clear()`:

```swift
        let strandedPermits = lock.withLock { () -> [String] in
            let keys = Array(pausedKeys)
            pausedStore.removeAll()
            pausedKeys.removeAll()
            return keys
        }
        strandedPermits.forEach { releasePausedPermit(for: $0) }
        lock.withLock { completionHistory.clear() }
```

- [ ] **Step 5: Swallow the pause error in `VideoStore`**

`VideoStore.swift:174`:

```swift
    public static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if error is DownloadPausedError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
```

This is what keeps `VideoGridView.download(_:)`'s `catch` from showing
"Download failed: DownloadPausedError()" every time the user pauses.

- [ ] **Step 6: Verify it compiles**

Run: `cd ios/PatataTubeKit && swift build --build-tests`
Expected: builds clean.

- [ ] **Step 7: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift \
        ios/PatataTubeKit/Sources/PatataTubeKit/VideoStore.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerPauseTests.swift
git commit -m "feat(ios): keep paused downloads paused across foreground and launch"
```

---

### Task 7: The three-dot menu in `DownloadsView`

**Files:**
- Modify: `ios/PatataTube/Sources/DownloadsView.swift:8, 100-113`
- Modify: `ios/PatataTube/Tests/DownloadsViewTests.swift:33-77`

**Interfaces:**
- Consumes: `DownloadActivity.isPaused` (Task 2).
- Produces: `DownloadsView.onPause: (DownloadActivity) -> Void` and
  `onResume: (DownloadActivity) -> Void`, both defaulted to `{ _ in }` so the
  four existing construction sites in tests keep compiling.

- [ ] **Step 1: Write the failing tests**

In `DownloadsViewTests.swift`, replace `activeRowShowsProgressAndCancelInvokesIdentity`
and `versionedActionsKeepTheDownloadIdentity` (the two that tap
`find(button: "Cancel")`, which no longer exists as a bare button) and add
coverage for the new items:

```swift
    @Test func theMenuCancelsWithTheDownloadIdentity() async throws {
        var cancelled: DownloadActivity.ID?
        let activity = DownloadActivity(
            videoID: 7,
            versionID: 2,
            progress: 0.5,
            transferredByteCount: 5_000,
            totalByteCount: 10_000
        )
        let sut = DownloadsView(
            active: { [activity] },
            recent: { [] },
            video: { id, _ in sampleVideo(id: id) },
            onCancel: { cancelled = $0.id },
            onPlay: { _ in }
        )
        .environmentObject(AppModel())

        try sut.inspect().find(button: "Cancel download").tap()
        #expect(cancelled == activity.id)
    }

    @Test func versionedActionsKeepTheDownloadIdentity() throws {
        let activity = DownloadActivity(
            videoID: 12,
            versionID: 99,
            progress: 0.2,
            transferredByteCount: 200,
            totalByteCount: 1_000
        )
        var cancelled: (Int, Int?)?
        let sut = DownloadsView(
            active: { [activity] },
            recent: { [] },
            video: { id, _ in sampleVideo(id: id) },
            onCancel: { cancelled = ($0.videoID, $0.versionID) },
            onPlay: { _ in }
        )
        .environmentObject(AppModel())

        try sut.inspect().find(button: "Cancel download").tap()
        #expect(cancelled?.0 == 12)
        #expect(cancelled?.1 == 99)
    }

    @Test func aLiveRowOffersPauseAndInvokesIt() throws {
        var paused: DownloadActivity.ID?
        let activity = DownloadActivity(
            videoID: 4, versionID: nil, progress: 0.3,
            transferredByteCount: 300, totalByteCount: 1_000
        )
        let sut = DownloadsView(
            active: { [activity] },
            recent: { [] },
            video: { id, _ in sampleVideo(id: id) },
            onCancel: { _ in },
            onPlay: { _ in },
            onPause: { paused = $0.id }
        )
        .environmentObject(AppModel())

        #expect((try? sut.inspect().find(button: "Resume")) == nil)
        try sut.inspect().find(button: "Pause").tap()
        #expect(paused == "4")
    }

    @Test func aPausedRowOffersResumeAndLabelsItself() throws {
        var resumed: DownloadActivity.ID?
        let activity = DownloadActivity(
            videoID: 4, versionID: nil, progress: 0.3,
            transferredByteCount: 300, totalByteCount: 1_000,
            isPaused: true
        )
        let sut = DownloadsView(
            active: { [activity] },
            recent: { [] },
            video: { id, _ in sampleVideo(id: id) },
            onCancel: { _ in },
            onPlay: { _ in },
            onResume: { resumed = $0.id }
        )
        .environmentObject(AppModel())

        #expect((try? sut.inspect().find(button: "Pause")) == nil)
        #expect(throws: Never.self) { try sut.inspect().find(text: "Paused") }
        try sut.inspect().find(button: "Resume").tap()
        #expect(resumed == "4")
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd ios/PatataTube && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination "platform=iOS Simulator,id=$(xcrun simctl list devices available | grep -m1 -o '[0-9A-F-]\{36\}')" build-for-testing`
Expected: FAIL — `extra arguments 'onPause'` / `'onResume'`.

Build only. Do not run the tests.

- [ ] **Step 3: Add the closures and the menu**

In `DownloadsView.swift`, after the `onPlay` property (line 9):

```swift
    var onPause: (DownloadActivity) -> Void = { _ in }
    var onResume: (DownloadActivity) -> Void = { _ in }
```

They are `var`s with defaults rather than `let`s so the memberwise initializer
keeps them optional, matching how `byteCount` and `didAppear` are already
declared in this view.

Replace `activeRow` (lines 100-113):

```swift
    private func activeRow(_ item: DownloadActivity) -> some View {
        let itemVideo = video(item.videoID, item.versionID)
        return HStack {
            thumbnail(itemVideo)
            VStack(alignment: .leading) {
                Text(itemVideo?.title ?? "Video \(item.videoID)")
                ProgressView(value: item.progress)
                if item.isPaused {
                    Text("Paused")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu {
                if item.isPaused {
                    Button("Resume", systemImage: "play.fill") { onResume(item) }
                } else {
                    Button("Pause", systemImage: "pause.fill") { onPause(item) }
                }
                Button("Cancel download", systemImage: "xmark.circle", role: .destructive) {
                    onCancel(item)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .logTap("download-menu", [
                "video_id": "\(item.videoID)",
                "paused": "\(item.isPaused)",
            ])
            .accessibilityLabel("Download options")
        }
        // Not `.combine`: combining children collapses the menu's own
        // accessibility element, and the menu has to stay separately tappable.
        .accessibilityElement(children: .contain)
    }
```

- [ ] **Step 4: Verify it builds**

Run: `cd ios/PatataTube && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination "platform=iOS Simulator,id=$(xcrun simctl list devices available | grep -m1 -o '[0-9A-F-]\{36\}')" build-for-testing`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTube/Sources/DownloadsView.swift \
        ios/PatataTube/Tests/DownloadsViewTests.swift
git commit -m "feat(ios): move cancel into a per-download menu with pause/resume"
```

---

### Task 8: Wire the menu to `CacheManager`

**Files:**
- Modify: `ios/PatataTube/Sources/VideoGridView.swift:685-697`
- Test: covered by Task 7's view tests plus Tasks 4-6's manager tests; this task adds no new test file.

**Interfaces:**
- Consumes: `CacheManager.pause(id:versionId:remote:isHLS:streamCount:preview:showPosterKey:showPoster:)` (Task 4), `CacheManager.resume(id:versionId:bearerToken:)` (Task 5), `DownloadsView.onPause` / `onResume` (Task 7).
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Extract the download parameters**

`pause` needs the same URL/preview/poster values `download(_:)` computes at
`VideoGridView.swift:1005-1037`. Add a helper next to `resolveImageURL` (~line
1047) that returns them for a video id, reusing `Self.downloadVideo` (the same
lookup `DownloadsView`'s `video:` closure uses):

```swift
    /// The parameters a paused entry has to remember, resolved from the loaded
    /// video. Mirrors the branch in `download(_:)` — an HLS row pauses with its
    /// master playlist URL, everything else with its stream URL.
    private func pauseParameters(
        for videoID: Int, versionID: Int?
    ) -> (remote: URL, isHLS: Bool, streamCount: Int,
          preview: URL?, posterKey: String?, poster: URL?)? {
        guard let target = Self.downloadVideo(
            id: videoID, versionID: versionID, videos: store.videos
        ) else { return nil }
        let master = model.hlsURL(for: target)
        let takesHLS = master != nil && target.hlsPath?.isEmpty == false
        guard let remote = takesHLS ? master : model.streamURL(for: target) else { return nil }
        let posterKey = target.showPreviewUrl
        return (
            remote: remote,
            isHLS: takesHLS,
            streamCount: model.downloadStreamCount,
            preview: resolveImageURL(target.previewUrl),
            posterKey: posterKey,
            poster: resolveImageURL(posterKey)
        )
    }
```

- [ ] **Step 2: Wire the closures**

Replace the `DownloadsView(…)` construction at line 686:

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
                byteCount: { model.cache.downloadedByteCount() },
                onPause: { activity in
                    guard let parameters = pauseParameters(
                        for: activity.videoID, versionID: activity.versionID
                    ) else { return }
                    model.cache.pause(
                        id: activity.videoID,
                        versionId: activity.versionID,
                        remote: parameters.remote,
                        isHLS: parameters.isHLS,
                        streamCount: parameters.streamCount,
                        preview: parameters.preview,
                        showPosterKey: parameters.posterKey,
                        showPoster: parameters.poster
                    )
                },
                onResume: { activity in
                    Task {
                        do {
                            try await model.cache.resume(
                                id: activity.videoID,
                                versionId: activity.versionID,
                                bearerToken: model.credentials.token
                            )
                        } catch {
                            guard !isCancellation(error) else { return }
                            store.errorText = "Download failed: \(error)"
                        }
                    }
                }
            )
```

Argument order matters: `byteCount` comes before `onPause`/`onResume` only if
the properties are declared in that order in `DownloadsView`. Task 7 appends
`onPause`/`onResume` after `onPlay`, i.e. **before** `byteCount`, so put them in
declaration order here — check `DownloadsView.swift` and match it, since Swift's
memberwise initializer requires it.

- [ ] **Step 3: Verify it builds**

Run: `cd ios/PatataTube && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination "platform=iOS Simulator,id=$(xcrun simctl list devices available | grep -m1 -o '[0-9A-F-]\{36\}')" build-for-testing`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add ios/PatataTube/Sources/VideoGridView.swift
git commit -m "feat(ios): wire pause/resume from the downloads menu to the cache"
```

---

### Task 9: Document the feature

**Files:**
- Modify: `CLAUDE.md` (the iOS section, after the "Download-all is bounded on the client too" bullet)

- [ ] **Step 1: Add the bullet**

```markdown
- **Downloads can be paused, and a pause outlives the process.** Each row in
  the Downloads view carries a three-dot menu holding Cancel plus Pause (or
  Resume). `CacheManager.pause` is deliberately not `cancel`: cancel wipes
  resume state so a re-tap starts clean, pause preserves it — the segmented
  path cancels its tasks `byProducingResumeData` through the same
  `preservingResumeData` machinery a resumable transport error uses, so the
  manifest and parts survive. Entries live in `paused-downloads.json`
  (`PausedDownloadStore`) in the cache root, and `resumeInterrupted()` skips
  their keys, which is the only thing stopping the next foreground from
  silently un-pausing them. A paused download **keeps its concurrency permit**:
  `download`'s `defer` hands ownership to the paused-permit table instead of
  releasing, and every stored entry re-reserves one at launch, so pausing
  everything means nothing downloads until the user acts. HLS packages have no
  partial state on disk, so pausing one restarts it from zero on resume.
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: describe pausable downloads"
```

---

## Verification

The change is covered by, but per the global constraints **do not run**:

- `cd ios/PatataTubeKit && swift test` — `PausedDownloadStoreTests`, `CacheManagerPauseTests`.
- `cd ios/PatataTube && xcodebuild … test` — `DownloadsViewTests` (the app target only builds through `xcodebuild`, so it is the one that rots silently).

What each task's build step does verify: `swift build --build-tests` for
PatataTubeKit tasks, `xcodebuild … build-for-testing` for app-target tasks.

Manual check, once the user asks for a build: start a download, open Downloads,
pause it from the menu, force-quit the app, relaunch, open Downloads — the row
is still there labeled Paused, and `log/ios.jsonl` shows a `download` record
`"permit held for pause"` with no matching `gate released`. Resume it and the
transfer continues from its byte offset rather than from zero (visible as the
progress bar picking up where it left off).
