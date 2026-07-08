# Download Progress Ring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the iOS offline-download button's indeterminate spinner with a filling ring (donut) that tracks real download percentage, and lets a tap cancel the in-flight download.

**Architecture:** `CacheManager` already computes real byte progress in `inFlight[key]` and exposes it via `state(for:) -> CacheState.downloading(Double)`. Task 1 adds a `cancel(id:versionId:)` method (Kit, TDD). Task 2 rewrites the `VideoCell` download button: a SwiftUI ring bound to `@State progress`, fed by a `.task` loop that polls `cache.state(for:)` every 150 ms (source of truth for tap / download-all / re-entry alike), plus an `onCancel` closure wired through `VideoGridView`.

**Tech Stack:** Swift 5.9+, SwiftUI, Swift Testing (`import Testing`), SwiftPM (PatataTubeKit), XcodeGen (app shell).

## Global Constraints

- No backend change — server already sends `Content-Length` on the full-file `GET /videos/{id}/stream` (main.py:424).
- No new dependencies.
- Kit logic is unit-tested with Swift Testing; the app shell (`ios/PatataTube/Sources/`) has no test target and is verified by build + manual check per `ios/README.md`.
- Ring geometry: `Circle`, 4pt stroke, `.round` cap, rotated `-90°`, 30×30 inside the existing 44×44 tap frame. Empty center (no percent text, no icon).
- Explicit user cancel restarts from scratch on next tap (plain `task.cancel()`); it does NOT persist resume data. (Resume-on-network-error stays handled by the existing `persistResumeData` path in `didCompleteWithError`.)

## File Structure

- `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift` — add `tasksByKey` map + `cancel(id:versionId:)`. (Task 1)
- `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift` — add cancel test + a pausable mock protocol. (Task 1)
- `ios/PatataTube/Sources/VideoCell.swift` — ring view, `@State progress`, poll `.task`, `onCancel` param. (Task 2)
- `ios/PatataTube/Sources/VideoGridView.swift` — pass `onCancel`. (Task 2)

---

### Task 1: `CacheManager.cancel(id:versionId:)`

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift`

**Interfaces:**
- Consumes: existing `cacheKey(videoId:versionId:)`, `inFlight`, `idByTask`, `finish`, `state(for:)`.
- Produces: `public func cancel(id: Int, versionId: Int? = nil)` — cancels the in-flight download for that key; the awaiting `download(...)` throws `URLError(.cancelled)`; `state(for:)` returns to `.notCached`.

- [ ] **Step 1: Write the failing test**

Add to `CacheManagerTests.swift`. First, at the top of the file (after the existing `MockDownloadProtocol`), add a pausable protocol that sends headers + one chunk then never finishes, so the download is genuinely in-flight when we cancel:

```swift
// Sends a response + partial body but never finishes, so a download stays
// in-flight until the task is explicitly cancelled.
private final class HangingDownloadProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Length": "1000000"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data([0x00, 0x01]))
        // Intentionally never call urlProtocolDidFinishLoading.
    }
    override func stopLoading() {}
}

private func hangingDownloadConfig() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [HangingDownloadProtocol.self]
    return config
}
```

Then add the test method inside `struct CacheManagerTests`:

```swift
@Test func cancelThrowsAndReturnsToNotCached() async {
    let root = tempRoot()
    let manager = CacheManager(root: root, configuration: hangingDownloadConfig())

    let task = Task {
        try await manager.download(id: 21, from: URL(string: "https://srv.test/videos/21/stream")!)
    }

    // Let the download start and register as in-flight before cancelling.
    while manager.state(for: 21) == .notCached { await Task.yield() }

    manager.cancel(id: 21)

    await #expect(throws: Error.self) { try await task.value }
    #expect(manager.state(for: 21) == .notCached)
    #expect(!FileManager.default.fileExists(atPath: manager.localURL(for: 21).path))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter cancelThrowsAndReturnsToNotCached`
Expected: FAIL — compile error `value of type 'CacheManager' has no member 'cancel'`.

- [ ] **Step 3: Write minimal implementation**

In `CacheManager.swift`, add the task map to the stored properties (next to `idByTask`, around line 16):

```swift
    private var tasksByKey: [String: URLSessionDownloadTask] = [:]
```

In `downloadVideo(id:versionId:from:bearerToken:)`, register the task inside the existing `lock.withLock` block (the one that sets `inFlight[key] = 0`):

```swift
            lock.withLock {
                inFlight[key] = 0
                continuations[key] = continuation
                idByTask[task.taskIdentifier] = key
                tasksByKey[key] = task
            }
```

In `finish(key:taskIdentifier:result:)`, clear it inside the existing `lock.withLock` block:

```swift
        let continuation = lock.withLock {
            inFlight[key] = nil
            idByTask[taskIdentifier] = nil
            completedResults[taskIdentifier] = nil
            tasksByKey[key] = nil
            return continuations.removeValue(forKey: key)
        }
```

Add the public method (place it after `download(...)`, before the delegate callbacks):

```swift
    /// Cancels an in-flight download for this id/version. The awaiting
    /// `download` call throws; `state(for:)` returns to `.notCached`.
    /// Explicit cancel restarts from scratch — it does not persist resume data.
    public func cancel(id: Int, versionId: Int? = nil) {
        let key = cacheKey(videoId: id, versionId: versionId)
        let task = lock.withLock { tasksByKey[key] }
        task?.cancel()
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios/PatataTubeKit && swift test --filter cancelThrowsAndReturnsToNotCached`
Expected: PASS.

- [ ] **Step 5: Run the full Kit suite to check nothing regressed**

Run: `cd ios/PatataTubeKit && swift test`
Expected: PASS (all existing CacheManager/APIClient/VideoStore tests still green).

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift
git commit -m "feat(ios): add CacheManager.cancel for in-flight downloads"
```

---

### Task 2: VideoCell filling ring + progress poll + cancel wiring

**Files:**
- Modify: `ios/PatataTube/Sources/VideoCell.swift`
- Modify: `ios/PatataTube/Sources/VideoGridView.swift:37-49`

**Interfaces:**
- Consumes: `CacheManager.cancel(id:versionId:)` (Task 1); existing `CacheState` enum; existing `effectiveState` computed property.
- Produces: `VideoCell` gains `let onCancel: () -> Void`.

- [ ] **Step 1: Add the `onCancel` property and progress state to `VideoCell`**

In `VideoCell.swift`, add the closure alongside the other `on…` lets (after `onDelete`, around line 18):

```swift
    let onCancel: () -> Void
```

Add progress state next to `downloadPhase` (around line 22):

```swift
    /// Live download fraction (0…1), polled from the cache while downloading.
    @State private var progress: Double = 0
```

- [ ] **Step 2: Replace the `.downloading` branch with the ring**

In `downloadButton` (around lines 112-114), replace:

```swift
        case .downloading:
            ProgressView().controlSize(.regular)
                .frame(width: 44, height: 44)
```

with:

```swift
        case .downloading:
            Button(action: onCancel) {
                ZStack {
                    Circle()
                        .stroke(Color.gray.opacity(0.25), lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.accentColor,
                                style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.15), value: progress)
                }
                .frame(width: 30, height: 30)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
```

- [ ] **Step 3: Add the poll `.task` that feeds `progress`**

Attach to the root `VStack` in `body`, next to the existing `.onChange(of:)` modifier (around line 91). The `.task(id:)` restarts whenever `effectiveState` changes, so it starts when a download begins and self-cancels when it ends:

```swift
        .task(id: effectiveState) {
            while !Task.isCancelled {
                guard case .downloading(let p) = effectiveState else { break }
                progress = p
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
```

`effectiveState` is `Equatable` (it returns `CacheState`, which conforms), so it is a valid `.task(id:)` key.

- [ ] **Step 4: Pass `onCancel` from `VideoGridView`**

In `VideoGridView.swift`, in the `VideoCell(...)` call (lines 37-49), add after the `onDownload:` line:

```swift
                        onCancel: { model.cache.cancel(id: video.id, versionId: video.chosenVersionId) },
```

- [ ] **Step 5: Build the Kit**

Run: `cd ios/PatataTubeKit && swift build`
Expected: `Build complete!` — confirms `cancel` compiles for the app to call.

- [ ] **Step 6: Regenerate the Xcode project and build the app**

Run:
```bash
cd ios/PatataTube && xcodegen generate
xcodebuild -project PatataTube.xcodeproj -scheme PatataTube \
  -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO
```
Expected: `** BUILD SUCCEEDED **`. (If no iOS SDK/simulator is available in the environment, note it and rely on `swift build` + manual device check instead.)

- [ ] **Step 7: Manual visual check (per `ios/README.md`)**

Run the app on a device/simulator against a live server. Verify:
- Tapping a video's download button shows a ring that fills 0→100% (empty center), then snaps to the green checkmark.
- Tapping the ring mid-download reverts it to the down-arrow; tapping again restarts and it fills from 0.
- "Download all" animates rings on every visible uncached cell.
- Leaving and re-entering the grid mid-download shows the ring resuming from its current fill.

- [ ] **Step 8: Commit**

```bash
git add ios/PatataTube/Sources/VideoCell.swift ios/PatataTube/Sources/VideoGridView.swift
git commit -m "feat(ios): filling download ring with tap-to-cancel"
```

---

## Self-Review

**Spec coverage:**
- Ring view (empty center, geometry) → Task 2 Steps 2. ✓
- Progress feeding via poll of `cache.state(for:)` → Task 2 Step 3. ✓
- Cancel path (`CacheManager.cancel`) → Task 1. ✓
- Wiring (`onCancel` through `VideoGridView`) → Task 2 Steps 1, 4. ✓
- Local phase reconciliation (`.loading` → `.downloading(0)`, poll overwrites) → unchanged; `effectiveState` still maps `.loading`; poll reads it. ✓
- Testing: Kit unit test for cancel (Task 1); ring UI manual (Task 2 Step 7). ✓
- No backend change / no deps → Global Constraints. ✓

**Deviation from spec (intentional):** The design doc said explicit cancel persists resume data. This plan uses plain `task.cancel()` (no resume on explicit cancel) — simpler, and a mock URLProtocol cannot produce resume data to unit-test the alternative. Resume-on-network-error is unaffected. Restart-from-scratch on re-tap is the accepted behavior.

**Placeholder scan:** none.

**Type consistency:** `onCancel: () -> Void`, `cancel(id:versionId:)`, `progress: Double`, `effectiveState: CacheState` used consistently across both tasks.
