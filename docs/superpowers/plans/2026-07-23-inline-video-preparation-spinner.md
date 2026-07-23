# Inline Video Preparation Spinner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` (recommended) or
> `superpowers:executing-plans` to implement this plan task-by-task.

**Goal:** Replace the blocking iOS MP4-preparation overlay with a buffering-style
spinner in every matching download button, regardless of whether Play or
Download initiated preparation.

**Architecture:** `VideoGridView` owns one observable
`VideoPreparationTracker`, injects it into the SwiftUI environment, and routes
all `ensureReady` work through it. `DownloadButton` observes the tracker by
video ID and gives its indeterminate preparation spinner precedence over the
existing idle, cache-download progress, and cached states.

**Tech Stack:** Swift 6, SwiftUI, Observation, Swift Testing, ViewInspector,
XcodeGen, XCTest/xcodebuild.

## Global Constraints

- Keep the iOS 17.0 deployment target and existing dependencies.
- Use native SwiftUI `ProgressView`, matching `VideoPlayerView` buffering.
- Preserve the existing 44-by-44 download-control footprint.
- Preserve the determinate cache-download progress ring and cached/delete states.
- Preserve the existing error banner and cache cancellation behavior.
- Do not add conversion percentages, retry UI, or server changes.
- Keep unrelated controls and navigation interactive during preparation.

---

### Task 1: Add the shared per-video preparation tracker

**Files:**

- Create: `ios/PatataTube/Sources/VideoPreparationTracker.swift`
- Create: `ios/PatataTube/Tests/VideoPreparationTrackerTests.swift`
- Regenerate: `ios/PatataTube/PatataTube.xcodeproj/project.pbxproj`

**Interfaces:**

- Produces:
  `@MainActor @Observable final class VideoPreparationTracker`
- Produces:
  `func isPreparing(videoID: Int) -> Bool`
- Produces:
  `func begin(videoID: Int)`
- Produces:
  `func end(videoID: Int)`
- Produces:
  `func track<T>(videoID: Int, operation: () async throws -> T) async rethrows -> T`
- Produces:
  `func trackIfIdle<T>(videoID: Int, operation: () async throws -> T) async rethrows -> T?`

- [ ] **Step 1: Write failing tracker tests**

Create `VideoPreparationTrackerTests.swift` with coverage for independent video
IDs, balanced reference counts, cleanup after errors, and atomic duplicate
suppression:

```swift
import Testing
@testable import PatataTube

@Suite("Video preparation tracker", .serialized)
@MainActor
struct VideoPreparationTrackerTests {
    private enum ExpectedError: Error {
        case failed
    }

    @Test func tracksIndependentVideosAndBalancedOperations() {
        let tracker = VideoPreparationTracker()

        tracker.begin(videoID: 1)
        tracker.begin(videoID: 1)
        tracker.begin(videoID: 2)

        #expect(tracker.isPreparing(videoID: 1))
        #expect(tracker.isPreparing(videoID: 2))

        tracker.end(videoID: 1)
        #expect(tracker.isPreparing(videoID: 1))

        tracker.end(videoID: 1)
        tracker.end(videoID: 2)
        #expect(!tracker.isPreparing(videoID: 1))
        #expect(!tracker.isPreparing(videoID: 2))
    }

    @Test func trackClearsPreparationAfterFailure() async {
        let tracker = VideoPreparationTracker()

        do {
            try await tracker.track(videoID: 7) {
                #expect(tracker.isPreparing(videoID: 7))
                throw ExpectedError.failed
            }
            Issue.record("Expected preparation to throw")
        } catch ExpectedError.failed {
            #expect(!tracker.isPreparing(videoID: 7))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func trackIfIdleSuppressesASecondOperation() async {
        let tracker = VideoPreparationTracker()
        tracker.begin(videoID: 9)
        var operationCount = 0

        let result = await tracker.trackIfIdle(videoID: 9) {
            operationCount += 1
            return 42
        }

        #expect(result == nil)
        #expect(operationCount == 0)
        tracker.end(videoID: 9)
    }
}
```

- [ ] **Step 2: Regenerate the project and verify the tests fail**

Run:

```bash
cd ios/PatataTube
rtk xcodegen generate
rtk test xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' \
  -only-testing:PatataTubeTests/VideoPreparationTrackerTests
```

Expected: build failure because `VideoPreparationTracker` does not exist.

- [ ] **Step 3: Implement the minimal observable tracker**

Create `VideoPreparationTracker.swift`:

```swift
import Observation

@MainActor
@Observable
final class VideoPreparationTracker {
    private var activeCounts: [Int: Int] = [:]

    func isPreparing(videoID: Int) -> Bool {
        activeCounts[videoID, default: 0] > 0
    }

    func begin(videoID: Int) {
        activeCounts[videoID, default: 0] += 1
    }

    func end(videoID: Int) {
        guard let count = activeCounts[videoID] else { return }
        if count <= 1 {
            activeCounts.removeValue(forKey: videoID)
        } else {
            activeCounts[videoID] = count - 1
        }
    }

    func track<T>(
        videoID: Int,
        operation: () async throws -> T
    ) async rethrows -> T {
        begin(videoID: videoID)
        defer { end(videoID: videoID) }
        return try await operation()
    }

    func trackIfIdle<T>(
        videoID: Int,
        operation: () async throws -> T
    ) async rethrows -> T? {
        guard !isPreparing(videoID: videoID) else { return nil }
        return try await track(videoID: videoID, operation: operation)
    }
}
```

- [ ] **Step 4: Run the focused tests**

Run the Step 2 `xcodebuild test` command again.

Expected: `VideoPreparationTrackerTests` passes.

- [ ] **Step 5: Commit the tracker**

```bash
rtk git add ios/PatataTube/Sources/VideoPreparationTracker.swift \
  ios/PatataTube/Tests/VideoPreparationTrackerTests.swift \
  ios/PatataTube/PatataTube.xcodeproj/project.pbxproj
rtk git commit -m "feat(ios): track video preparation by id"
```

### Task 2: Render preparation in the shared download button

**Files:**

- Modify: `ios/PatataTube/Sources/DownloadButton.swift`
- Modify: `ios/PatataTube/Tests/DownloadButtonTests.swift`

**Interfaces:**

- Consumes: `VideoPreparationTracker` from Task 1 through SwiftUI environment.
- Preserves: all existing `DownloadButton` initializer parameters.
- Produces: a 44-by-44 indeterminate `ProgressView` with accessibility label
  `Preparing video` when the tracker contains `identity.videoID`.

- [ ] **Step 1: Inject a tracker in the download-button test fixture**

Change the test helper to accept a tracker and wrap the button in its
environment. Keep all existing call sites valid by supplying a default:

```swift
@MainActor
private func makeDownloadButton(
    state: DownloadButtonState,
    cache: CacheStateSource = CacheStateSource(.notCached),
    refreshToken: Int = 0,
    tracker: VideoPreparationTracker = VideoPreparationTracker(),
    onDownload: @escaping () async -> Bool = { false },
    onCancel: @escaping () -> Void = {},
    onDeleteCache: @escaping () -> Void = {}
) -> some View {
    DownloadButton(
        identity: DownloadButtonIdentity(
            videoID: 7,
            versionID: 3,
            audioLanguage: "eng"
        ),
        refreshToken: refreshToken,
        currentCacheState: { cache.read() },
        onDownload: onDownload,
        onCancel: onCancel,
        onDeleteCache: onDeleteCache,
        state: state
    )
    .environment(tracker)
}
```

- [ ] **Step 2: Write failing rendering and isolation tests**

Add these cases to `DownloadButtonViewTests`:

```swift
@Test func matchingPreparationReplacesControlWithBufferingSpinner() throws {
    let tracker = VideoPreparationTracker()
    let sut = makeDownloadButton(
        state: DownloadButtonState(),
        tracker: tracker
    )

    tracker.begin(videoID: 7)

    let spinner = try sut.inspect().find(ViewType.ProgressView.self)
    #expect(try spinner.accessibilityLabel().string() == "Preparing video")
    #expect(try spinner.fixedWidth() == 44)
    #expect(try spinner.fixedHeight() == 44)
    #expect((try? sut.inspect().find(ViewType.Button.self)) == nil)
}

@Test func preparationForAnotherVideoDoesNotReplaceControl() throws {
    let tracker = VideoPreparationTracker()
    let sut = makeDownloadButton(
        state: DownloadButtonState(),
        tracker: tracker
    )

    tracker.begin(videoID: 99)

    let button = try sut.inspect().find(ViewType.Button.self)
    #expect(try button.accessibilityLabel().string() == "Download")
}

@Test func completedPreparationRevealsCacheDownloadProgress() throws {
    let tracker = VideoPreparationTracker()
    let state = DownloadButtonState(initialCacheState: .downloading(0.35))
    let sut = makeDownloadButton(state: state, tracker: tracker)

    tracker.begin(videoID: 7)
    #expect((try? sut.inspect().find(ViewType.ProgressView.self)) != nil)

    tracker.end(videoID: 7)
    let button = try sut.inspect().find(ViewType.Button.self)
    #expect(try button.accessibilityLabel().string() == "Cancel download")
    #expect(try button.accessibilityValue().string() == "35%")
}

@Test func failedPreparationRestoresIdleDownloadControl() throws {
    let tracker = VideoPreparationTracker()
    let state = DownloadButtonState()
    let attemptID = state.begin()
    let sut = makeDownloadButton(state: state, tracker: tracker)

    tracker.begin(videoID: 7)
    #expect((try? sut.inspect().find(ViewType.ProgressView.self)) != nil)

    tracker.end(videoID: 7)
    state.finish(attemptID: attemptID, succeeded: false)
    let button = try sut.inspect().find(ViewType.Button.self)
    #expect(try button.accessibilityLabel().string() == "Download")
}
```

- [ ] **Step 3: Run the focused tests and verify failure**

Run:

```bash
cd ios/PatataTube
rtk test xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' \
  -only-testing:PatataTubeTests/DownloadButtonViewTests
```

Expected: failure because `DownloadButton` does not read the preparation
tracker and still renders a button.

- [ ] **Step 4: Add the preparation rendering branch**

In `DownloadButton`, read the environment tracker:

```swift
@Environment(VideoPreparationTracker.self)
private var preparationTracker
```

Rename the existing `control` property to `cacheControl` without changing its
switch body. Then add this new `control` property so preparation takes
precedence:

```swift
@ViewBuilder
private var control: some View {
    if preparationTracker.isPreparing(videoID: identity.videoID) {
        ProgressView()
            .frame(width: 44, height: 44)
            .accessibilityLabel("Preparing video")
    } else {
        cacheControl
    }
}
```

The spinner is not wrapped in a `Button`, so it cannot start, cancel, or delete
a download while preparation is active.

- [ ] **Step 5: Run all download-button tests**

Run:

```bash
cd ios/PatataTube
rtk test xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' \
  -only-testing:PatataTubeTests/DownloadButtonStateTests \
  -only-testing:PatataTubeTests/DownloadButtonViewTests
```

Expected: all existing and new download-button tests pass.

- [ ] **Step 6: Commit the button behavior**

```bash
rtk git add ios/PatataTube/Sources/DownloadButton.swift \
  ios/PatataTube/Tests/DownloadButtonTests.swift
rtk git commit -m "feat(ios): show preparation spinner in download button"
```

### Task 3: Route play and download preparation through the tracker

**Files:**

- Modify: `ios/PatataTube/Sources/VideoGridView.swift`
- Modify: `ios/README.md`

**Interfaces:**

- Consumes: `VideoPreparationTracker.track(videoID:operation:)` for downloads.
- Consumes: `VideoPreparationTracker.trackIfIdle(videoID:operation:)` for Play,
  preventing repeat Play requests for the same video.
- Provides: `.environment(preparationTracker)` to all descendants, including
  grid cells, movie details, shows, and episode rows.
- Removes: `VideoGridView.preparing` and the blocking “Preparing…” overlay.

- [ ] **Step 1: Add the owned tracker and inject it into the hierarchy**

Replace:

```swift
@State private var preparing = false
```

with:

```swift
@State private var preparationTracker = VideoPreparationTracker()
```

Apply the environment to the `NavigationStack` after its existing modifiers:

```swift
.environment(preparationTracker)
```

This one injection must cover `VideoCell`, `MovieDetailView`, `ShowsView`, and
the pushed `EpisodesView`; do not add per-view Boolean plumbing.

- [ ] **Step 2: Remove the blocking overlay**

Delete the complete overlay whose condition is `if preparing`, including the
dimmed full-screen color and the “Preparing…” text. Keep the existing error
banner overlay unchanged.

- [ ] **Step 3: Route playback preparation through duplicate-safe tracking**

In the unprepared-library branch of `play`, replace the `preparing` mutations
and direct `ensureReady` call with:

```swift
Task {
    do {
        guard let readyVideo = try await preparationTracker.trackIfIdle(
            videoID: video.id,
            operation: {
                try await store.ensureReady(id: video.id)
            }
        ) else {
            return
        }
        startPlayback(
            readyVideo,
            queueSnapshot: queueSnapshot,
            sleepMode: sleepMode
        )
    } catch {
        store.errorText = String(describing: error)
    }
}
```

Keep the cached-file and already-ready fast paths before this branch unchanged,
so they never show the preparation spinner.

- [ ] **Step 4: Route download preparation through balanced tracking**

In `download(_:)`, replace the `preparing` mutations and direct `ensureReady`
call with:

```swift
if video.isLibrary, video.status != "done" {
    do {
        target = try await preparationTracker.track(videoID: video.id) {
            try await store.ensureReady(id: video.id)
        }
    } catch {
        store.errorText = String(describing: error)
        return false
    }
}
```

Leave URL resolution, poster caching, cache progress, cancellation, and final
success/failure handling unchanged. When `track` returns, the shared button
automatically falls back to the existing determinate cache-download ring.

- [ ] **Step 5: Update the manual acceptance checklist**

Replace the stale blocking-overlay assertions in `ios/README.md` with:

```markdown
- [ ] Playing an unprepared mkv episode leaves navigation responsive, replaces
  that episode's download button with a spinner, ignores a second Play tap for
  the same episode, then opens playback after conversion.
- [ ] Download an unprepared episode: its download button first shows the
  buffering-style spinner, then the existing 44×44 determinate progress ring
  and green checkmark; airplane-mode playback works from cache.
- [ ] Play from a movie detail page works for an unconverted library movie
  while the matching download button shows a spinner and no blocking overlay
  appears.
```

Retain the surrounding manual checks.

- [ ] **Step 6: Build and run the complete iOS unit suite**

Run:

```bash
cd ios/PatataTube
rtk test xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1'
```

Expected: `** TEST SUCCEEDED **` with all `PatataTubeTests` passing. There must
be no compile error from missing tracker environment injection.

- [ ] **Step 7: Inspect the final diff for stale preparation UI**

Run:

```bash
rtk rg -n 'Preparing…|@State private var preparing|if preparing' \
  ios/PatataTube/Sources
rtk git diff --check
rtk git diff --stat
```

Expected: the source search has no matches; `git diff --check` reports no
whitespace errors; the diff is limited to the tracker, shared button,
`VideoGridView`, tests, generated project membership, and README checklist.

- [ ] **Step 8: Commit the integration**

```bash
rtk git add ios/PatataTube/Sources/VideoGridView.swift ios/README.md
rtk git commit -m "feat(ios): make video preparation nonblocking"
```

### Task 4: Final verification

**Files:**

- Verify only; no planned source changes.

**Interfaces:**

- Verifies the complete behavior defined by the approved design.

- [ ] **Step 1: Run focused regression tests once more**

```bash
cd ios/PatataTube
rtk test xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' \
  -only-testing:PatataTubeTests/VideoPreparationTrackerTests \
  -only-testing:PatataTubeTests/DownloadButtonViewTests
```

Expected: all focused tests pass.

- [ ] **Step 2: Confirm repository state and commit history**

```bash
rtk git status --short
rtk git log -4 --oneline
```

Expected: no uncommitted implementation changes, and the three feature commits
from Tasks 1–3 appear above the design and plan commits.
