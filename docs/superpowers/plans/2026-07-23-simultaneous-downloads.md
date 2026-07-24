# Simultaneous Downloads Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a user-configurable cap (default 3) on how many videos download at once, enforced globally with a FIFO queue, distinct from the existing per-video multiplex setting.

**Architecture:** A FIFO counting async-semaphore (`DownloadConcurrencyGate`) lives in `CacheManager` (PatataTubeKit), injected like the existing `cancellationFence`. `CacheManager.download(...)` acquires a slot on entry and releases it via `defer`. A new app-side `SimultaneousDownloadSettings` (UserDefaults) drives an `AppModel.downloadConcurrency` value, surfaced as a `SettingsView` stepper, pushed to the gate via `cache.setMaxConcurrentDownloads(_:)`. `downloadAll()` fans out concurrently so the cap does real work.

**Tech Stack:** Swift 5, SwiftUI, swift-testing (`import Testing`), ViewInspector (SettingsView tests), XcodeGen. Kit is a local SwiftPM package (`swift build`).

## Global Constraints

- New setting: key `simultaneousDownloadCount`, default `3`, allowed range `1...4`.
- Existing setting `downloadStreamCount` (streams per video, 1–4, default 2) is untouched.
- No new `CacheState` case. Queued downloads reuse the existing 0% progress ring.
- Gate must release the slot on success, thrown error, and cancellation.
- Lowering the limit never cancels/preempts in-flight downloads; only throttles new starts.
- Follow existing DI pattern: gate is injected into `CacheManager` exactly like `cancellationFence` (protocol + concrete + default arg on the designated init).
- `resumeInterrupted` stays ungated (out of scope).

---

### Task 1: DownloadConcurrencyGate (PatataTubeKit)

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/DownloadConcurrencyGate.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/DownloadConcurrencyGateTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `protocol DownloadConcurrencyGating: Sendable` with:
    - `func acquire() async`
    - `func release()`
    - `func setLimit(_ n: Int)`
    - `var currentLimit: Int { get }`
  - `final class DownloadConcurrencyGate: DownloadConcurrencyGating, @unchecked Sendable`, `init(limit: Int)`.

- [ ] **Step 1: Write the failing tests**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/DownloadConcurrencyGateTests.swift`:

```swift
import Foundation
import Testing
@testable import PatataTubeKit

private actor Recorder {
    private(set) var order: [Int] = []
    private(set) var active = 0
    private(set) var maxActive = 0

    func enter(_ id: Int) {
        active += 1
        maxActive = max(maxActive, active)
        order.append(id)
    }

    func leave() { active -= 1 }
}

@Suite("Download concurrency gate")
struct DownloadConcurrencyGateTests {

    @Test
    func capsConcurrentHolders() async {
        let gate = DownloadConcurrencyGate(limit: 2)
        let recorder = Recorder()

        await withTaskGroup(of: Void.self) { group in
            for id in 0..<6 {
                group.addTask {
                    await gate.acquire()
                    await recorder.enter(id)
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    await recorder.leave()
                    gate.release()
                }
            }
        }

        #expect(await recorder.maxActive == 2)
    }

    @Test
    func releaseWithoutWaitersFreesSlot() async {
        let gate = DownloadConcurrencyGate(limit: 1)
        await gate.acquire()
        gate.release()
        // Second acquire must not deadlock now the slot is free.
        await gate.acquire()
        gate.release()
    }

    @Test
    func resumesWaitersInFIFOOrder() async {
        let gate = DownloadConcurrencyGate(limit: 1)
        let recorder = Recorder()

        await gate.acquire() // hold the only permit

        var tasks: [Task<Void, Never>] = []
        for id in 0..<3 {
            tasks.append(Task {
                await gate.acquire()
                await recorder.enter(id)
                gate.release()
            })
            // Stagger so each waiter enqueues before the next is spawned.
            try? await Task.sleep(nanoseconds: 15_000_000)
        }

        gate.release() // wake the chain
        for task in tasks { await task.value }

        #expect(await recorder.order == [0, 1, 2])
    }

    @Test
    func raisingLimitWakesQueuedWaiters() async {
        let gate = DownloadConcurrencyGate(limit: 1)
        await gate.acquire() // holds the single permit

        let started = Recorder()
        let waiter = Task {
            await gate.acquire()
            await started.enter(99)
            gate.release()
        }
        try? await Task.sleep(nanoseconds: 15_000_000)
        #expect(await started.order.isEmpty) // still blocked

        gate.setLimit(2) // frees a slot for the waiter
        await waiter.value
        #expect(await started.order == [99])
        gate.release()
    }

    @Test
    func loweringLimitThrottlesNewStarts() async {
        let gate = DownloadConcurrencyGate(limit: 2)
        await gate.acquire()
        await gate.acquire() // 2 active
        gate.setLimit(1)

        let started = Recorder()
        let waiter = Task {
            await gate.acquire()
            await started.enter(1)
            gate.release()
        }
        try? await Task.sleep(nanoseconds: 15_000_000)
        #expect(await started.order.isEmpty) // 2 active > new limit 1, blocked

        gate.release() // active drops to 1, still == limit, waiter stays blocked
        try? await Task.sleep(nanoseconds: 15_000_000)
        #expect(await started.order.isEmpty)

        gate.release() // active drops to 0 < limit, waiter proceeds
        await waiter.value
        #expect(await started.order == [1])
    }

    @Test
    func currentLimitReflectsSetLimit() {
        let gate = DownloadConcurrencyGate(limit: 3)
        #expect(gate.currentLimit == 3)
        gate.setLimit(1)
        #expect(gate.currentLimit == 1)
        gate.setLimit(0) // clamped to >= 1
        #expect(gate.currentLimit == 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios/PatataTubeKit && swift test --filter DownloadConcurrencyGateTests`
Expected: FAIL — `cannot find 'DownloadConcurrencyGate' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ios/PatataTubeKit/Sources/PatataTubeKit/DownloadConcurrencyGate.swift`:

```swift
import Foundation

/// Caps how many downloads run at once, queueing the rest FIFO. Injected into
/// `CacheManager` so tests can substitute a spy (mirrors `cancellationFence`).
protocol DownloadConcurrencyGating: Sendable {
    func acquire() async
    func release()
    func setLimit(_ n: Int)
    var currentLimit: Int { get }
}

/// FIFO counting semaphore. `acquire` suspends when no permit is free; `release`
/// hands a freed permit to the oldest waiter, or credits it back if none wait.
final class DownloadConcurrencyGate: DownloadConcurrencyGating, @unchecked Sendable {
    private let lock = NSLock()
    private var limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(limit, 1)
    }

    var currentLimit: Int {
        lock.withLock { limit }
    }

    func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let granted: Bool = lock.withLock {
                if active < limit {
                    active += 1
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if granted { continuation.resume() }
        }
    }

    func release() {
        let next: CheckedContinuation<Void, Never>? = lock.withLock {
            if waiters.isEmpty {
                active = max(active - 1, 0)
                return nil
            }
            // Hand the permit straight to the next waiter: active stays level
            // (one holder left, one entered).
            return waiters.removeFirst()
        }
        next?.resume()
    }

    func setLimit(_ n: Int) {
        let newLimit = max(n, 1)
        let toWake: [CheckedContinuation<Void, Never>] = lock.withLock {
            limit = newLimit
            var woken: [CheckedContinuation<Void, Never>] = []
            while active < limit, !waiters.isEmpty {
                active += 1
                woken.append(waiters.removeFirst())
            }
            return woken
        }
        toWake.forEach { $0.resume() }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios/PatataTubeKit && swift test --filter DownloadConcurrencyGateTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/grillermo/c/patatatube
git add ios/PatataTubeKit/Sources/PatataTubeKit/DownloadConcurrencyGate.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/DownloadConcurrencyGateTests.swift
git commit -m "feat(kit): FIFO download concurrency gate"
```

---

### Task 2: Wire the gate into CacheManager

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift` (init signatures ~165-208; `download(...)` ~270-286)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerConcurrencyGateTests.swift` (create)

**Interfaces:**
- Consumes: `DownloadConcurrencyGating`, `DownloadConcurrencyGate` (Task 1).
- Produces:
  - `CacheManager` designated init gains `concurrencyGate: any DownloadConcurrencyGating = DownloadConcurrencyGate(limit: 3)`.
  - `public func setMaxConcurrentDownloads(_ n: Int)` → `gate.setLimit(n)`.
  - `public var maxConcurrentDownloads: Int` → `gate.currentLimit`.
  - `download(...)` acquires a slot at entry, releases via `defer`.

- [ ] **Step 1: Write the failing test**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerConcurrencyGateTests.swift`:

```swift
import Foundation
import Testing
@testable import PatataTubeKit

private final class SpyGate: DownloadConcurrencyGating, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var acquireCount = 0
    private(set) var releaseCount = 0
    private(set) var limit = 3

    func acquire() async { lock.withLock { acquireCount += 1 } }
    func release() { lock.withLock { releaseCount += 1 } }
    func setLimit(_ n: Int) { lock.withLock { limit = max(n, 1) } }
    var currentLimit: Int { lock.withLock { limit } }
}

@Suite("CacheManager concurrency gate", .serialized)
struct CacheManagerConcurrencyGateTests {
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("gate-cache-\(UUID().uuidString)")
    }

    @Test
    func downloadAcquiresAndReleasesEvenOnFailure() async {
        let spy = SpyGate()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        defer { MockURLProtocol.handler = nil }

        let manager = CacheManager(
            root: temporaryRoot(),
            configuration: config,
            fileManager: .default,
            concurrencyGate: spy
        )

        // The download fails (probe errors out), but the slot must be released.
        try? await manager.download(
            id: 1,
            from: URL(string: "https://example.com/v.mp4")!
        )

        #expect(spy.acquireCount == 1)
        #expect(spy.releaseCount == 1)
    }

    @Test
    func setMaxConcurrentDownloadsForwardsToGate() {
        let spy = SpyGate()
        let manager = CacheManager(
            root: temporaryRoot(),
            configuration: .ephemeral,
            fileManager: .default,
            concurrencyGate: spy
        )
        manager.setMaxConcurrentDownloads(2)
        #expect(spy.currentLimit == 2)
        #expect(manager.maxConcurrentDownloads == 2)
    }
}
```

Note: `MockURLProtocol` already exists at `ios/PatataTubeKit/Tests/PatataTubeKitTests/MockURLProtocol.swift`. Read it first to confirm the `handler` API shape; if it differs, adapt the failure-injection lines (the goal is only that the probe request errors out).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter CacheManagerConcurrencyGateTests`
Expected: FAIL — extra `concurrencyGate:` argument / no `setMaxConcurrentDownloads` member.

- [ ] **Step 3: Modify CacheManager**

In `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift`:

Add a stored property beside `cancellationFence` (near line 152):

```swift
    private let concurrencyGate: any DownloadConcurrencyGating
```

Update the designated `init` (the one taking `cancellationFence`, ~line 177) to accept and store the gate:

```swift
    init(
        root: URL?,
        configuration: URLSessionConfiguration,
        fileManager: FileManager,
        now: @escaping @Sendable () -> Date = Date.init,
        cancellationFence: any CacheManagerCancellationFencing =
            CacheManagerCancellationFence(),
        concurrencyGate: any DownloadConcurrencyGating =
            DownloadConcurrencyGate(limit: 3)
    ) {
        self.fileManager = fileManager
        self.now = now
        self.cancellationFence = cancellationFence
        self.concurrencyGate = concurrencyGate
        // ... rest unchanged
```

(The `convenience init` at ~line 165 does not pass `concurrencyGate`; the default applies, so leave it as-is.)

Add the two public members (e.g. right after the convenience/designated inits, before `localURL`):

```swift
    /// Sets the global cap on how many videos download at once.
    public func setMaxConcurrentDownloads(_ n: Int) {
        concurrencyGate.setLimit(n)
    }

    /// Current global simultaneous-download cap.
    public var maxConcurrentDownloads: Int {
        concurrencyGate.currentLimit
    }
```

Gate the public `download(...)` (~line 270). Add the two lines at the very top of the method body, before the `_ = try await downloadVideo(...)` call:

```swift
    public func download(id: Int, versionId: Int? = nil, from remote: URL, preview: URL? = nil,
                         showPosterKey: String? = nil, showPoster: URL? = nil,
                         bearerToken: String? = nil, streamCount: Int = 1) async throws {
        await concurrencyGate.acquire()
        defer { concurrencyGate.release() }
        _ = try await downloadVideo(
            id: id,
            versionId: versionId,
            from: remote,
            bearerToken: bearerToken,
            streamCount: min(max(streamCount, 1), 4)
        )
        // ... rest unchanged (preview/poster best-effort)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios/PatataTubeKit && swift test --filter CacheManagerConcurrencyGateTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Run the whole Kit suite (guard against regressions)**

Run: `cd ios/PatataTubeKit && swift test`
Expected: PASS (all existing tests still green).

- [ ] **Step 6: Commit**

```bash
cd /Users/grillermo/c/patatatube
git add ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerConcurrencyGateTests.swift
git commit -m "feat(kit): gate CacheManager.download on concurrency limit"
```

---

### Task 3: SimultaneousDownloadSettings (app)

**Files:**
- Create: `ios/PatataTube/Sources/SimultaneousDownloadSettings.swift`
- Test: `ios/PatataTube/Tests/SimultaneousDownloadSettingsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `struct SimultaneousDownloadSettings` with `static let key = "simultaneousDownloadCount"`, `static let defaultCount = 3`, `static let allowedCounts = 1...4`, `init(defaults:)`, `load() -> Int`, `save(_ count: Int)`.

- [ ] **Step 1: Write the failing test**

Create `ios/PatataTube/Tests/SimultaneousDownloadSettingsTests.swift`:

```swift
import Foundation
import Testing
import PatataTubeKit
@testable import PatataTube

@Suite("Simultaneous download settings", .serialized)
@MainActor
struct SimultaneousDownloadSettingsTests {
    private func defaults() throws -> UserDefaults {
        let name = "SimultaneousDownloadSettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test
    func defaultsToThreeAndClampsStoredValues() throws {
        let defaults = try defaults()
        let settings = SimultaneousDownloadSettings(defaults: defaults)

        #expect(settings.load() == 3)

        defaults.set(-10, forKey: SimultaneousDownloadSettings.key)
        #expect(settings.load() == 1)

        defaults.set(99, forKey: SimultaneousDownloadSettings.key)
        #expect(settings.load() == 4)
    }

    @Test
    func saveClampsBeforePersisting() throws {
        let defaults = try defaults()
        let settings = SimultaneousDownloadSettings(defaults: defaults)

        settings.save(99)
        #expect(settings.load() == 4)

        settings.save(0)
        #expect(settings.load() == 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/PatataTube && xcodegen generate` then build/test the `PatataTube` scheme (see note below).
Expected: FAIL — `cannot find 'SimultaneousDownloadSettings'`.

Test-run note: the app target has no `swift test`. Run its tests via Xcode or:
`cd ios/PatataTube && xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPad (10th generation)' -only-testing:PatataTubeTests/SimultaneousDownloadSettingsTests` (adjust the simulator name to one installed locally: `xcrun simctl list devices available`). New files must be added to `project.yml`/regenerated so XcodeGen picks them up (both source and test files under existing globbed folders are picked up automatically — confirm the folders `Sources/` and `Tests/` are globbed in `project.yml`).

- [ ] **Step 3: Write the implementation**

Create `ios/PatataTube/Sources/SimultaneousDownloadSettings.swift`:

```swift
import Foundation

/// How many videos download at once (global cap). Distinct from
/// `DownloadStreamSettings` (streams *within* one video).
struct SimultaneousDownloadSettings {
    static let key = "simultaneousDownloadCount"
    static let defaultCount = 3
    static let allowedCounts = 1...4

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> Int {
        guard defaults.object(forKey: Self.key) != nil else {
            return Self.defaultCount
        }
        return min(
            max(defaults.integer(forKey: Self.key), Self.allowedCounts.lowerBound),
            Self.allowedCounts.upperBound
        )
    }

    func save(_ count: Int) {
        let clamped = min(
            max(count, Self.allowedCounts.lowerBound),
            Self.allowedCounts.upperBound
        )
        defaults.set(clamped, forKey: Self.key)
    }
}
```

- [ ] **Step 4: Regenerate + run tests to verify they pass**

Run: `cd ios/PatataTube && xcodegen generate`
Then run the `SimultaneousDownloadSettingsTests` (Xcode or the `xcodebuild test -only-testing:` command above).
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/grillermo/c/patatatube
git add ios/PatataTube/Sources/SimultaneousDownloadSettings.swift ios/PatataTube/Tests/SimultaneousDownloadSettingsTests.swift ios/PatataTube/PatataTube.xcodeproj/project.pbxproj
git commit -m "feat(ios): SimultaneousDownloadSettings (default 3)"
```

---

### Task 4: Wire AppModel to the setting and the gate

**Files:**
- Modify: `ios/PatataTube/Sources/AppModel.swift` (properties ~11-23; init ~24-40; `saveSettings()` ~39-47)
- Test: `ios/PatataTube/Tests/SimultaneousDownloadSettingsTests.swift` (append a test)

**Interfaces:**
- Consumes: `SimultaneousDownloadSettings` (Task 3); `CacheManager.setMaxConcurrentDownloads`, `CacheManager.maxConcurrentDownloads` (Task 2).
- Produces: `AppModel.downloadConcurrency: Int` (`@Published`); designated init gains `simultaneousSettings: SimultaneousDownloadSettings = SimultaneousDownloadSettings()`.

- [ ] **Step 1: Write the failing test**

Append to `ios/PatataTube/Tests/SimultaneousDownloadSettingsTests.swift` (inside the suite):

```swift
    @Test
    func appModelSavesAndPushesConcurrencyToCache() throws {
        let defaults = try defaults()
        let settings = SimultaneousDownloadSettings(defaults: defaults)
        let cache = CacheManager(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("concurrency-cache-\(UUID().uuidString)")
        )
        let model = AppModel(
            credentials: InMemoryCredentialStore(),
            cache: cache,
            simultaneousSettings: settings
        )

        // Loaded default is pushed to the cache on init.
        #expect(model.downloadConcurrency == 3)
        #expect(cache.maxConcurrentDownloads == 3)

        model.downloadConcurrency = 2
        model.saveSettings()

        #expect(settings.load() == 2)
        #expect(cache.maxConcurrentDownloads == 2)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run the suite (Xcode or `xcodebuild test -only-testing:PatataTubeTests/SimultaneousDownloadSettingsTests`).
Expected: FAIL — no `simultaneousSettings:` argument / no `downloadConcurrency` member.

- [ ] **Step 3: Modify AppModel**

In `ios/PatataTube/Sources/AppModel.swift`:

Add a stored settings property beside `downloadSettings`:

```swift
    private let downloadSettings: DownloadStreamSettings
    private let simultaneousSettings: SimultaneousDownloadSettings
```

Add the published value beside `downloadStreamCount`:

```swift
    @Published var downloadStreamCount: Int
    @Published var downloadConcurrency: Int
```

Update the init signature and body:

```swift
    init(
        credentials: CredentialStore = KeychainCredentialStore(),
        cache: CacheManager = CacheManager(),
        downloadSettings: DownloadStreamSettings = DownloadStreamSettings(),
        simultaneousSettings: SimultaneousDownloadSettings = SimultaneousDownloadSettings()
    ) {
        let api = APIClient(store: credentials)
        self.credentials = credentials
        self.cache = cache
        self.api = api
        self.store = VideoStore(api: api, cache: VideoListCache())
        self.downloadSettings = downloadSettings
        self.simultaneousSettings = simultaneousSettings
        self.downloadStreamCount = downloadSettings.load()
        self.downloadConcurrency = simultaneousSettings.load()
        self.baseURLText = credentials.baseURL?.absoluteString ?? ""
        self.tokenText = credentials.token ?? ""
        cache.setMaxConcurrentDownloads(self.downloadConcurrency)
    }
```

Update `saveSettings()`:

```swift
    func saveSettings() {
        credentials.baseURL = URL(string: baseURLText.trimmingCharacters(in: .whitespaces))
        credentials.token = tokenText.isEmpty ? nil : tokenText
        downloadStreamCount = min(
            max(downloadStreamCount, DownloadStreamSettings.allowedCounts.lowerBound),
            DownloadStreamSettings.allowedCounts.upperBound
        )
        downloadSettings.save(downloadStreamCount)
        downloadConcurrency = min(
            max(downloadConcurrency, SimultaneousDownloadSettings.allowedCounts.lowerBound),
            SimultaneousDownloadSettings.allowedCounts.upperBound
        )
        simultaneousSettings.save(downloadConcurrency)
        cache.setMaxConcurrentDownloads(downloadConcurrency)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run the suite.
Expected: PASS (3 tests total in the file).

- [ ] **Step 5: Commit**

```bash
cd /Users/grillermo/c/patatatube
git add ios/PatataTube/Sources/AppModel.swift ios/PatataTube/Tests/SimultaneousDownloadSettingsTests.swift
git commit -m "feat(ios): AppModel drives simultaneous-download cap"
```

---

### Task 5: SettingsView stepper

**Files:**
- Modify: `ios/PatataTube/Sources/SettingsView.swift` (the `Section("Downloads")` block, ~39-49)
- Test: `ios/PatataTube/Tests/SettingsViewTests.swift` (append a test)

**Interfaces:**
- Consumes: `AppModel.downloadConcurrency` (Task 4); `SimultaneousDownloadSettings.allowedCounts` / `.key` (Task 3).
- Produces: nothing new.

- [ ] **Step 1: Write the failing test**

Append to `ios/PatataTube/Tests/SettingsViewTests.swift` (inside the suite):

```swift
    @Test
    func showsTheSelectedSimultaneousDownloads() throws {
        let defaults = try #require(
            UserDefaults(suiteName: "SettingsViewTests-\(UUID().uuidString)")
        )
        defaults.set(2, forKey: SimultaneousDownloadSettings.key)
        let model = AppModel(
            credentials: InMemoryCredentialStore(),
            cache: CacheManager(
                root: FileManager.default.temporaryDirectory
                    .appendingPathComponent("settings-cache-\(UUID().uuidString)")
            ),
            simultaneousSettings: SimultaneousDownloadSettings(defaults: defaults)
        )
        let sut = SettingsView().environmentObject(model)

        let content = try sut.inspect().find(text: "Simultaneous downloads")
        #expect(try content.string() == "Simultaneous downloads")
        #expect(try sut.inspect().find(text: "2").string() == "2")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run the `SettingsViewTests` suite.
Expected: FAIL — no view contains text "Simultaneous downloads".

- [ ] **Step 3: Add the stepper**

In `ios/PatataTube/Sources/SettingsView.swift`, extend the `Section("Downloads")` so it holds both steppers:

```swift
                Section("Downloads") {
                    Stepper(
                        value: $model.downloadStreamCount,
                        in: DownloadStreamSettings.allowedCounts
                    ) {
                        LabeledContent(
                            "Streams per video",
                            value: "\(model.downloadStreamCount)"
                        )
                    }
                    Stepper(
                        value: $model.downloadConcurrency,
                        in: SimultaneousDownloadSettings.allowedCounts
                    ) {
                        LabeledContent(
                            "Simultaneous downloads",
                            value: "\(model.downloadConcurrency)"
                        )
                    }
                }
```

- [ ] **Step 4: Run tests to verify they pass**

Run the `SettingsViewTests` suite.
Expected: PASS (both stream and simultaneous tests green).

- [ ] **Step 5: Commit**

```bash
cd /Users/grillermo/c/patatatube
git add ios/PatataTube/Sources/SettingsView.swift ios/PatataTube/Tests/SettingsViewTests.swift
git commit -m "feat(ios): Settings stepper for simultaneous downloads"
```

---

### Task 6: Fan out bulk downloads

**Files:**
- Modify: `ios/PatataTube/Sources/VideoGridView.swift` (`downloadAll()`, ~327-333)
- Modify: `ios/PatataTube/Sources/SettingsView.swift` ("Cache all videos" button, ~52-64)

**Interfaces:**
- Consumes: the gate wiring from Tasks 2 & 4 (bounds real concurrency).
- Produces: nothing new. Behavior change only.

This task has no unit test (concurrent UI fan-out is not unit-testable here without heavy scaffolding). Verification is: the whole Kit suite + the app test suites stay green, and the app builds. The gate (Task 1/2) already has direct concurrency tests.

- [ ] **Step 1: Fan out `downloadAll()`**

In `ios/PatataTube/Sources/VideoGridView.swift`, replace:

```swift
    private func downloadAll() async {
        downloadingAll = true
        defer { downloadingAll = false }
        for video in store.videos where model.cache.state(for: video.id, versionId: video.chosenVersionId) == .notCached {
            await download(video)
        }
    }
```

with:

```swift
    private func downloadAll() async {
        downloadingAll = true
        defer { downloadingAll = false }
        // Snapshot the not-cached targets, then let them run concurrently — the
        // CacheManager gate bounds how many actually download at once.
        let targets = store.videos.filter {
            model.cache.state(for: $0.id, versionId: $0.chosenVersionId) == .notCached
        }
        await withTaskGroup(of: Void.self) { group in
            for video in targets {
                group.addTask { await download(video) }
            }
        }
    }
```

- [ ] **Step 2: Fan out "Cache all videos"**

In `ios/PatataTube/Sources/SettingsView.swift`, replace the button's `Task { for video in ... }` body:

```swift
                    Button("Cache all videos") {
                        Task {
                            for video in model.store.videos {
                                if let url = model.streamURL(for: video) {
                                    let preview = video.previewUrl.flatMap(URL.init(string:))
                                try? await model.cache.download(id: video.id, versionId: video.chosenVersionId, from: url, preview: preview,
                                                                bearerToken: model.credentials.token,
                                                                streamCount: model.downloadStreamCount)
                                }
                            }
                        }
                    }
```

with:

```swift
                    Button("Cache all videos") {
                        Task {
                            await withTaskGroup(of: Void.self) { group in
                                for video in model.store.videos {
                                    guard let url = model.streamURL(for: video) else { continue }
                                    let preview = video.previewUrl.flatMap(URL.init(string:))
                                    let versionId = video.chosenVersionId
                                    let id = video.id
                                    let streamCount = model.downloadStreamCount
                                    let token = model.credentials.token
                                    group.addTask {
                                        try? await model.cache.download(
                                            id: id, versionId: versionId, from: url,
                                            preview: preview, bearerToken: token,
                                            streamCount: streamCount
                                        )
                                    }
                                }
                            }
                        }
                    }
```

(Binding the values into locals before `group.addTask` keeps the `@Sendable` closure off `model`'s main-actor-isolated stored properties at capture time; `model.cache.download` is an `async` call the child task awaits.)

- [ ] **Step 3: Regenerate, build, run the full suites**

```bash
cd ios/PatataTube && xcodegen generate
```
Then build the app and run the app test suite (Xcode or `xcodebuild test ... -scheme PatataTube`). Also:
```bash
cd ios/PatataTubeKit && swift test
```
Expected: builds clean; all Kit + app tests PASS.

- [ ] **Step 4: Manual smoke (per `ios/README.md` checklist)**

With a reachable server: set "Simultaneous downloads" to 2, tap "Download all" on a filter with ≥4 not-cached videos, confirm at most two show active progress rings at once while the rest sit at 0% until slots free.

- [ ] **Step 5: Commit**

```bash
cd /Users/grillermo/c/patatatube
git add ios/PatataTube/Sources/VideoGridView.swift ios/PatataTube/Sources/SettingsView.swift ios/PatataTube/PatataTube.xcodeproj/project.pbxproj
git commit -m "feat(ios): fan out bulk downloads under the concurrency cap"
```

---

## Self-Review

**Spec coverage:**
- Setting storage (`SimultaneousDownloadSettings`, key/default/range) → Task 3. ✓
- AppModel load/save/push-to-gate → Task 4. ✓
- Gate (FIFO, cap, release-on-throw/cancel, setLimit raise/lower) → Task 1. ✓
- Gate default 3 at construction → Task 2 (`DownloadConcurrencyGate(limit: 3)` default). ✓
- CacheManager `setMaxConcurrentDownloads` + `download` acquire/defer → Task 2. ✓
- SettingsView stepper, no new CacheState → Task 5. ✓
- `downloadAll()` + "Cache all" fan-out → Task 6. ✓
- Tests: gate FIFO/cap/release/limit-change (Task 1), settings load/save/clamp (Task 3), CacheManager honors setMaxConcurrentDownloads (Task 2). ✓
- Known limit: `resumeInterrupted` ungated → documented, no task (out of scope). ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases"; every code step shows full code. ✓

**Type consistency:** `DownloadConcurrencyGating` (acquire/release/setLimit/currentLimit), `DownloadConcurrencyGate(limit:)`, `setMaxConcurrentDownloads(_:)`, `maxConcurrentDownloads`, `downloadConcurrency`, `SimultaneousDownloadSettings` (key/defaultCount/allowedCounts) — used identically across Tasks 1→6. ✓

**Assumptions flagged for the implementer:**
- `MockURLProtocol.handler` shape (Task 2) — read the existing file and adapt the failure-injection line if the API differs.
- `Video` must be `Sendable` for the TaskGroup captures in Task 6; the codebase already treats it as such. If the compiler objects, capture the already-extracted scalar locals only (Task 6 Step 2 already does this).
- `project.yml` is assumed to glob `Sources/` and `Tests/`; confirm new files are picked up after `xcodegen generate`.
