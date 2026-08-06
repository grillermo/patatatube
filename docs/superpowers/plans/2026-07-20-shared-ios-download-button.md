# Shared iOS Download Button Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the three iOS download-button implementations with one thoroughly tested control that gives episode rows the same progress, cancellation, retry, and stale-completion behavior as `MovieDetailView`.

**Architecture:** A shared `DownloadButton` owns the reference rendering, polling, async attempt tracking, and cancellation interaction. An internal observable state machine contains all transitions and accepts cache, download, cancellation, identity, refresh-token, and clock dependencies; `MovieDetailView`, `VideoCell`, and `EpisodesView` only adapt their video data to that interface.

**Tech Stack:** Swift 6.0, SwiftUI, Observation, PatataTubeKit, XcodeGen 2.45.4, Swift Testing, ViewInspector 0.10.3, swift-clocks 1.1.0, Xcode 26.3 / iOS 26.3 simulator.

## Global Constraints

- Deployment target remains iOS 17.0.
- `MovieDetailView` is the behavioral and visual reference: a 30x30 ring inside a 44x44 tap target, a 4-point round stroke, and a `-90` degree rotation.
- All three existing surfaces use the same `DownloadButton` type and identical 44x44 presentation.
- `MovieCell` remains a control-free poster link.
- `CacheManager` remains the sole owner of download tasks, cached files, progress, explicit cancellation, and resume data; do not change it.
- Network interruption remains resumable through `CacheManager`; explicit ring cancellation follows the current restart-from-scratch contract.
- `VideoGridView.download(_:)` remains the sole owner of preparation and user-visible download errors.
- A stale async completion must not overwrite a cancel, retry, identity change, or refresh-token reset.
- ViewInspector 0.10.3 is linked only to `PatataTubeTests`; it must not ship in the application target.
- swift-clocks 1.1.0 supplies the production continuous clock and deterministic test clock.
- Every shell command is prefixed with `rtk` per the repository instructions.

## File Structure

- `ios/PatataTube/Sources/DownloadButton.swift` — download identity, observable state machine, polling loop, shared rendering, and interaction.
- `ios/PatataTube/Tests/DownloadButtonTests.swift` — state-transition, rendering, interaction, polling, and lifecycle tests.
- `ios/PatataTube/project.yml` — Clocks and ViewInspector packages, app dependency, unit-test target, and scheme test action.
- `ios/PatataTube/Sources/MovieDetailView.swift` — replace the reference's local implementation with the shared control and retain immediate delete-cache refresh.
- `ios/PatataTube/Sources/VideoCell.swift` — replace its duplicate implementation with the shared control.
- `ios/PatataTube/Sources/EpisodesView.swift` — use the shared control and separate play/download tap targets.
- `ios/PatataTube/Sources/ShowsView.swift` — propagate the async download result.
- `ios/PatataTube/Sources/VideoGridView.swift` — pass the existing async download function through the show path.
- `ios/README.md` — document automated tests and manual parity checks.

---

### Task 1: Test target and download state machine

**Files:**
- Modify: `ios/PatataTube/project.yml:6-63`
- Create: `ios/PatataTube/Sources/DownloadButton.swift`
- Create: `ios/PatataTube/Tests/DownloadButtonTests.swift`

**Interfaces:**
- Consumes: `PatataTubeKit.CacheState`.
- Produces: `DownloadButtonIdentity(videoID:versionID:audioLanguage:)` and `@MainActor DownloadButtonState` with `effectiveState`, `clampedProgress`, `begin(attemptID:)`, `finish(attemptID:succeeded:)`, `cancel()`, `reset(to:)`, and `observe(_:)`.

- [ ] **Step 1: Configure the packages and unit-test target**

Add these remote packages after `Capture` in `ios/PatataTube/project.yml`:

```yaml
  Clocks:
    url: https://github.com/pointfreeco/swift-clocks.git
    from: "1.1.0"
  ViewInspector:
    url: https://github.com/nalexn/ViewInspector.git
    from: "0.10.3"
```

Add Clocks to the existing `PatataTube` dependencies:

```yaml
      - package: Clocks
```

Add this target after the complete `PatataTube` application target:

```yaml
  PatataTubeTests:
    type: bundle.unit-test
    platform: iOS
    deploymentTarget: "17.0"
    sources:
      - Tests
    dependencies:
      - target: PatataTube
      - package: Clocks
      - package: ViewInspector
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.patatube.tests
        GENERATE_INFOPLIST_FILE: YES
        SWIFT_VERSION: "6.0"
```

Add the test action to the existing `PatataTube` scheme:

```yaml
    test:
      targets:
        - PatataTubeTests
```

- [ ] **Step 2: Write failing state-machine tests**

Create `ios/PatataTube/Tests/DownloadButtonTests.swift` with:

```swift
import Clocks
import PatataTubeKit
import SwiftUI
import Testing
import ViewInspector
@testable import PatataTube

@Suite("Download button state", .serialized)
@MainActor
struct DownloadButtonStateTests {
    @Test func observedCacheStateDrivesIdleRenderingAndClampsProgress() {
        let state = DownloadButtonState()
        #expect(state.effectiveState == .notCached)

        state.observe(.downloading(-0.25))
        #expect(state.effectiveState == .downloading(-0.25))
        #expect(state.clampedProgress == 0)

        state.observe(.downloading(1.25))
        #expect(state.effectiveState == .downloading(1.25))
        #expect(state.clampedProgress == 1)

        state.observe(.cached)
        #expect(state.effectiveState == .cached)
        #expect(state.clampedProgress == 1)
    }

    @Test func currentAttemptAppliesSuccessAndFailure() {
        let state = DownloadButtonState()
        let successID = UUID()

        state.begin(attemptID: successID)
        #expect(state.effectiveState == .downloading(0))
        state.finish(attemptID: successID, succeeded: true)
        #expect(state.effectiveState == .cached)

        state.reset(to: .notCached)
        let failureID = UUID()
        state.begin(attemptID: failureID)
        state.finish(attemptID: failureID, succeeded: false)
        #expect(state.effectiveState == .notCached)
    }

    @Test func staleCompletionCannotOverwriteCancelRetryOrReset() {
        let state = DownloadButtonState()
        let cancelledID = UUID()
        let retryID = UUID()

        state.begin(attemptID: cancelledID)
        state.cancel()
        state.begin(attemptID: retryID)
        state.finish(attemptID: cancelledID, succeeded: false)
        #expect(state.activeAttemptID == retryID)
        #expect(state.effectiveState == .downloading(0))

        state.reset(to: .downloading(0.4))
        state.finish(attemptID: retryID, succeeded: true)
        #expect(state.effectiveState == .downloading(0.4))
    }
}
```

- [ ] **Step 3: Generate the project and prove the tests fail for the missing state machine**

Run from `ios/PatataTube`:

```bash
rtk xcodegen generate
rtk xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3' -only-testing:PatataTubeTests/DownloadButtonStateTests
```

Expected: project generation succeeds; test compilation fails with `cannot find 'DownloadButtonState' in scope`.

- [ ] **Step 4: Implement the minimal state machine**

Create `ios/PatataTube/Sources/DownloadButton.swift` with:

```swift
import Foundation
import Observation
import PatataTubeKit

struct DownloadButtonIdentity: Hashable, Sendable {
    let videoID: Int
    let versionID: Int?
    let audioLanguage: String?
}

@MainActor
@Observable
final class DownloadButtonState {
    enum Phase: Equatable {
        case idle
        case loading
        case done
    }

    private(set) var phase: Phase = .idle
    private(set) var observedCacheState: CacheState?
    private(set) var progress: Double = 0
    private(set) var activeAttemptID: UUID?

    init(initialCacheState: CacheState = .notCached) {
        observe(initialCacheState)
    }

    var effectiveState: CacheState {
        let observedState = observedCacheState ?? .notCached
        switch phase {
        case .loading:
            if case .downloading = observedState { return observedState }
            return .downloading(progress)
        case .done:
            return .cached
        case .idle:
            return observedState
        }
    }

    var clampedProgress: Double {
        let value: Double
        if case .downloading(let progress) = effectiveState {
            value = progress
        } else {
            value = self.progress
        }
        return min(max(value, 0), 1)
    }

    var isDownloading: Bool {
        if case .downloading = effectiveState { return true }
        return false
    }

    @discardableResult
    func begin(attemptID: UUID = UUID()) -> UUID {
        activeAttemptID = attemptID
        phase = .loading
        observedCacheState = .downloading(0)
        progress = 0
        return attemptID
    }

    func finish(attemptID: UUID, succeeded: Bool) {
        guard activeAttemptID == attemptID else { return }
        activeAttemptID = nil
        phase = succeeded ? .done : .idle
        observedCacheState = succeeded ? .cached : .notCached
        progress = succeeded ? 1 : 0
    }

    func cancel() {
        activeAttemptID = nil
        phase = .idle
        observedCacheState = .notCached
        progress = 0
    }

    func reset(to cacheState: CacheState) {
        activeAttemptID = nil
        phase = .idle
        observedCacheState = nil
        progress = 0
        observe(cacheState)
    }

    func observe(_ cacheState: CacheState) {
        observedCacheState = cacheState
        switch cacheState {
        case .downloading(let progress):
            self.progress = progress
        case .cached:
            progress = 1
        case .notCached:
            if phase == .idle { progress = 0 }
        }
    }
}
```

- [ ] **Step 5: Run the focused tests and confirm they pass**

Run from `ios/PatataTube`:

```bash
rtk xcodegen generate
rtk xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3' -only-testing:PatataTubeTests/DownloadButtonStateTests
```

Expected: `** TEST SUCCEEDED **`; all three state tests pass.

- [ ] **Step 6: Commit the test infrastructure and state machine**

Run from the repository root:

```bash
rtk git add ios/PatataTube/project.yml ios/PatataTube/Sources/DownloadButton.swift ios/PatataTube/Tests/DownloadButtonTests.swift
rtk git commit -m "test(ios): cover shared download button state"
```

---

### Task 2: Shared SwiftUI button, interaction, and deterministic polling

**Files:**
- Modify: `ios/PatataTube/Sources/DownloadButton.swift`
- Modify: `ios/PatataTube/Tests/DownloadButtonTests.swift`

**Interfaces:**
- Consumes: Task 1's `DownloadButtonIdentity` and `DownloadButtonState`; Clocks' `continuousClock` environment value and `TestClock`; ViewInspector.
- Produces: `DownloadButton.init(identity:refreshToken:currentCacheState:onDownload:onCancel:state:)` and `DownloadButtonState.poll(currentCacheState:clock:)`.

- [ ] **Step 1: Add failing tests for rendering, taps, stale completion, polling, and lifecycle**

Append these helpers and suites to `ios/PatataTube/Tests/DownloadButtonTests.swift`:

```swift
@MainActor
private final class CacheStateSource {
    var value: CacheState
    private(set) var readCount = 0

    init(_ value: CacheState) {
        self.value = value
    }

    func read() -> CacheState {
        readCount += 1
        return value
    }
}

private actor DownloadGate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var bufferedResult: Bool?

    func wait() async -> Bool {
        if let bufferedResult {
            self.bufferedResult = nil
            return bufferedResult
        }
        return await withCheckedContinuation { continuation = $0 }
    }

    func finish(_ result: Bool) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: result)
        } else {
            bufferedResult = result
        }
    }
}

@MainActor
private func eventually(
    _ message: String,
    condition: @escaping @MainActor () -> Bool
) async {
    for _ in 0..<100 {
        if condition() { return }
        await Task.yield()
    }
    Issue.record(message)
}

@MainActor
private func makeDownloadButton(
    state: DownloadButtonState,
    cache: CacheStateSource = CacheStateSource(.notCached),
    refreshToken: Int = 0,
    onDownload: @escaping () async -> Bool = { false },
    onCancel: @escaping () -> Void = {}
) -> DownloadButton {
    DownloadButton(
        identity: DownloadButtonIdentity(videoID: 7, versionID: 3, audioLanguage: "eng"),
        refreshToken: refreshToken,
        currentCacheState: { cache.read() },
        onDownload: onDownload,
        onCancel: onCancel,
        state: state
    )
}

@Suite("Download button view", .serialized)
@MainActor
struct DownloadButtonViewTests {
    @Test func rendersAccessibleIdleActiveAndCachedStates() throws {
        let state = DownloadButtonState()
        let sut = makeDownloadButton(state: state)

        var control = try sut.inspect().find(ViewType.Button.self)
        #expect(try control.accessibilityLabel().string() == "Download")

        state.observe(.downloading(1.4))
        control = try sut.inspect().find(ViewType.Button.self)
        #expect(try control.accessibilityLabel().string() == "Cancel download")
        #expect(try control.accessibilityValue().string() == "100%")

        state.reset(to: .cached)
        let image = try sut.inspect().find(ViewType.Image.self)
        #expect(try image.accessibilityLabel().string() == "Downloaded")
    }

    @Test func tappingDownloadShowsLoadingThenAppliesSuccess() async throws {
        let state = DownloadButtonState()
        let gate = DownloadGate()
        let sut = makeDownloadButton(state: state, onDownload: { await gate.wait() })

        try sut.inspect().find(ViewType.Button.self).tap()
        await eventually("Download tap never entered loading") {
            state.effectiveState == .downloading(0)
        }

        await gate.finish(true)
        await eventually("Successful completion never showed cached") {
            state.effectiveState == .cached
        }
    }

    @Test func tappingDownloadReturnsToIdleOnFailure() async throws {
        let state = DownloadButtonState()
        let gate = DownloadGate()
        let sut = makeDownloadButton(state: state, onDownload: { await gate.wait() })

        try sut.inspect().find(ViewType.Button.self).tap()
        await eventually("Download tap never entered loading") { state.isDownloading }
        await gate.finish(false)
        await eventually("Failed completion never returned to idle") {
            state.effectiveState == .notCached
        }
    }

    @Test func tappingRingInvalidatesAttemptBeforeCallingCancel() throws {
        let state = DownloadButtonState(initialCacheState: .downloading(0.35))
        var cancelCount = 0
        var attemptWasInvalidated = false
        let sut = makeDownloadButton(state: state, onCancel: {
            cancelCount += 1
            attemptWasInvalidated = state.activeAttemptID == nil
        })

        state.begin()
        state.observe(.downloading(0.35))
        try sut.inspect().find(ViewType.Button.self).tap()

        #expect(cancelCount == 1)
        #expect(attemptWasInvalidated)
        #expect(state.effectiveState == .notCached)
    }

    @Test func pollingUsesActiveAndInactiveIntervals() async {
        let state = DownloadButtonState()
        let source = CacheStateSource(.downloading(0.25))
        let clock = TestClock()
        let polling = Task {
            await state.poll(currentCacheState: { source.read() }, clock: clock)
        }
        await eventually("Initial cache state was not read") { source.readCount == 1 }

        await clock.advance(by: .milliseconds(149))
        #expect(source.readCount == 1)
        await clock.advance(by: .milliseconds(1))
        await eventually("Active 150 ms poll did not fire") { source.readCount == 2 }

        source.value = .notCached
        await clock.advance(by: .milliseconds(150))
        await eventually("Transition to inactive state was not observed") {
            source.readCount == 3
        }
        await clock.advance(by: .milliseconds(499))
        #expect(source.readCount == 3)
        await clock.advance(by: .milliseconds(1))
        await eventually("Inactive 500 ms poll did not fire") { source.readCount == 4 }

        polling.cancel()
        await clock.run()
    }

    @Test func removingHostedViewStopsPollingWithoutCancellingDownload() async {
        let state = DownloadButtonState()
        let source = CacheStateSource(.downloading(0.2))
        let clock = TestClock()
        var cancelCount = 0
        let sut = makeDownloadButton(
            state: state,
            cache: source,
            onCancel: { cancelCount += 1 }
        )
        .environment(\.continuousClock, clock)

        ViewHosting.host(view: sut)
        await eventually("Hosted view never started polling") { source.readCount > 0 }
        ViewHosting.expel()
        await Task.yield()
        let readsAfterExpel = source.readCount
        await clock.advance(by: .seconds(1))
        await Task.yield()

        #expect(source.readCount == readsAfterExpel)
        #expect(cancelCount == 0)
    }
}
```

- [ ] **Step 2: Run the focused tests and verify the shared view API is missing**

Run from `ios/PatataTube`:

```bash
rtk xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3' -only-testing:PatataTubeTests/DownloadButtonViewTests
```

Expected: FAIL with missing `DownloadButton`, missing `DownloadButtonState.poll`, and missing Clocks environment usage.

- [ ] **Step 3: Implement the shared view and polling loop**

Replace `ios/PatataTube/Sources/DownloadButton.swift` with this complete file. The state machine is unchanged except for the added `poll` method:

```swift
import Clocks
import Foundation
import Observation
import PatataTubeKit
import SwiftUI

struct DownloadButtonIdentity: Hashable, Sendable {
    let videoID: Int
    let versionID: Int?
    let audioLanguage: String?
}

@MainActor
@Observable
final class DownloadButtonState {
    enum Phase: Equatable {
        case idle
        case loading
        case done
    }

    private(set) var phase: Phase = .idle
    private(set) var observedCacheState: CacheState?
    private(set) var progress: Double = 0
    private(set) var activeAttemptID: UUID?

    init(initialCacheState: CacheState = .notCached) {
        observe(initialCacheState)
    }

    var effectiveState: CacheState {
        let observedState = observedCacheState ?? .notCached
        switch phase {
        case .loading:
            if case .downloading = observedState { return observedState }
            return .downloading(progress)
        case .done:
            return .cached
        case .idle:
            return observedState
        }
    }

    var clampedProgress: Double {
        let value: Double
        if case .downloading(let progress) = effectiveState {
            value = progress
        } else {
            value = self.progress
        }
        return min(max(value, 0), 1)
    }

    var isDownloading: Bool {
        if case .downloading = effectiveState { return true }
        return false
    }

    @discardableResult
    func begin(attemptID: UUID = UUID()) -> UUID {
        activeAttemptID = attemptID
        phase = .loading
        observedCacheState = .downloading(0)
        progress = 0
        return attemptID
    }

    func finish(attemptID: UUID, succeeded: Bool) {
        guard activeAttemptID == attemptID else { return }
        activeAttemptID = nil
        phase = succeeded ? .done : .idle
        observedCacheState = succeeded ? .cached : .notCached
        progress = succeeded ? 1 : 0
    }

    func cancel() {
        activeAttemptID = nil
        phase = .idle
        observedCacheState = .notCached
        progress = 0
    }

    func reset(to cacheState: CacheState) {
        activeAttemptID = nil
        phase = .idle
        observedCacheState = nil
        progress = 0
        observe(cacheState)
    }

    func observe(_ cacheState: CacheState) {
        observedCacheState = cacheState
        switch cacheState {
        case .downloading(let progress):
            self.progress = progress
        case .cached:
            progress = 1
        case .notCached:
            if phase == .idle { progress = 0 }
        }
    }

    func poll(
        currentCacheState: @escaping () -> CacheState,
        clock: any Clock<Duration>
    ) async {
        while !Task.isCancelled {
            observe(currentCacheState())
            let interval: Duration = isDownloading ? .milliseconds(150) : .milliseconds(500)
            do {
                try await clock.sleep(for: interval)
            } catch {
                return
            }
        }
    }
}

@MainActor
struct DownloadButton: View {
    let identity: DownloadButtonIdentity
    var refreshToken: Int = 0
    let currentCacheState: () -> CacheState
    let onDownload: () async -> Bool
    let onCancel: () -> Void

    @Environment(\.continuousClock) private var clock
    @State private var state: DownloadButtonState

    private struct ObservationID: Hashable {
        let identity: DownloadButtonIdentity
        let refreshToken: Int
    }

    init(
        identity: DownloadButtonIdentity,
        refreshToken: Int = 0,
        currentCacheState: @escaping () -> CacheState,
        onDownload: @escaping () async -> Bool,
        onCancel: @escaping () -> Void,
        state: DownloadButtonState? = nil
    ) {
        self.identity = identity
        self.refreshToken = refreshToken
        self.currentCacheState = currentCacheState
        self.onDownload = onDownload
        self.onCancel = onCancel
        _state = State(initialValue: state ?? DownloadButtonState(
            initialCacheState: currentCacheState()
        ))
    }

    var body: some View {
        control
            .task(id: ObservationID(identity: identity, refreshToken: refreshToken)) {
                state.reset(to: currentCacheState())
                await state.poll(currentCacheState: currentCacheState, clock: clock)
            }
    }

    @ViewBuilder
    private var control: some View {
        switch state.effectiveState {
        case .cached:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 30))
                .frame(width: 44, height: 44)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Downloaded")

        case .downloading:
            Button {
                withAnimation { state.cancel() }
                onCancel()
            } label: {
                ZStack {
                    Circle()
                        .stroke(Color.gray.opacity(0.25), lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: state.clampedProgress)
                        .stroke(
                            Color.accentColor,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.15), value: state.clampedProgress)
                }
                .frame(width: 30, height: 30)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel download")
            .accessibilityValue("\(Int(state.clampedProgress * 100))%")

        case .notCached:
            Button {
                Task { @MainActor in
                    let attemptID = withAnimation { state.begin() }
                    let succeeded = await onDownload()
                    withAnimation {
                        state.finish(attemptID: attemptID, succeeded: succeeded)
                    }
                }
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 30))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Download")
        }
    }
}
```

- [ ] **Step 4: Run both download-button suites**

Run from `ios/PatataTube`:

```bash
rtk xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3' -only-testing:PatataTubeTests/DownloadButtonStateTests -only-testing:PatataTubeTests/DownloadButtonViewTests
```

Expected: `** TEST SUCCEEDED **`; state, rendering, interaction, polling, and lifecycle tests all pass without wall-clock sleeps.

- [ ] **Step 5: Commit the shared control**

Run from the repository root:

```bash
rtk git add ios/PatataTube/Sources/DownloadButton.swift ios/PatataTube/Tests/DownloadButtonTests.swift
rtk git commit -m "feat(ios): add shared tested download button"
```

---

### Task 3: Migrate MovieDetailView and VideoCell

**Files:**
- Modify: `ios/PatataTube/Sources/MovieDetailView.swift:18-25,64-74,115-151,154-251,259-271`
- Modify: `ios/PatataTube/Sources/VideoCell.swift:24-32,75-77,116-235`

**Interfaces:**
- Consumes: `DownloadButton` from Task 2.
- Produces: movie detail and generic grid cells that delegate all download state/rendering to the shared control; `MovieDetailView` also produces an incrementing refresh token after cache deletion.

- [ ] **Step 1: Replace MovieDetailView's local state with a refresh token**

Delete `downloadPhase`, `progress`, `observedCacheState`, `activeDownloadID`, and the private `DownloadPhase` enum at lines 18-25. Add:

```swift
    /// Forces the shared button to reread cache state after an explicit delete.
    @State private var downloadRefreshToken = 0
```

- [ ] **Step 2: Replace the movie-detail button call site**

Replace `downloadButton` at line 73 with:

```swift
                    DownloadButton(
                        identity: DownloadButtonIdentity(
                            videoID: currentVideo.id,
                            versionID: currentVideo.chosenVersionId,
                            audioLanguage: currentVideo.audioLang
                        ),
                        refreshToken: downloadRefreshToken,
                        currentCacheState: {
                            model.cache.state(
                                for: currentVideo.id,
                                versionId: currentVideo.chosenVersionId
                            )
                        },
                        onDownload: { await onDownload(currentVideo) },
                        onCancel: {
                            model.cache.cancel(
                                id: currentVideo.id,
                                versionId: currentVideo.chosenVersionId
                            )
                        }
                    )
```

- [ ] **Step 3: Preserve the immediate Delete cached reset**

Replace the delete action body at lines 118-127 with:

```swift
                    Button(role: .destructive) {
                        model.cache.removeAllCached(id: currentVideo.id)
                        withAnimation { downloadRefreshToken &+= 1 }
                    } label: {
                        Label("Delete cached", systemImage: "trash")
                    }
```

Delete the root `.task(id:)` and both download-state `.onChange` blocks at lines 137-151. Delete `cacheState`, `effectiveState`, `downloadPollKey`, `clampedProgress`, `downloadButton`, `pollCacheState`, and `updateObservedCacheState` at lines 154-251 and 259-271. Keep `audioLabel(for:)` unchanged.

- [ ] **Step 4: Replace VideoCell's duplicate state and renderer**

Delete `downloadPhase`, `progress`, `observedCacheState`, and the private `DownloadPhase` enum at lines 26-32.

Replace `downloadButton` at line 76 with:

```swift
                DownloadButton(
                    identity: DownloadButtonIdentity(
                        videoID: video.id,
                        versionID: video.chosenVersionId,
                        audioLanguage: video.audioLang
                    ),
                    currentCacheState: currentCacheState,
                    onDownload: onDownload,
                    onCancel: onCancel
                )
```

Change the information-sheet construction at lines 116-119 to read its existing input independently:

```swift
        .sheet(isPresented: $showingInfo) {
            VideoInfoView(video: video, cacheState: cacheState,
                          cachedPreviewURL: cachedPreviewURL, localFileURL: localFileURL)
        }
```

Delete the root `.task` and `.onChange` modifiers at lines 120-130. Delete `effectiveState`, `downloadPollKey`, `clampedProgress`, `downloadButton`, `pollCacheState`, and `updateObservedCacheState` at lines 133-235. Leave `VideoInfoView` unchanged.

- [ ] **Step 5: Build and run the shared-button tests after both migrations**

Run from `ios/PatataTube`:

```bash
rtk xcodegen generate
rtk xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3' -only-testing:PatataTubeTests
```

Expected: `** TEST SUCCEEDED **`; the app target compiles with no remaining private download renderer in either migrated view.

- [ ] **Step 6: Confirm duplication is gone from the migrated files**

Run from the repository root:

```bash
rtk grep -n 'DownloadPhase|pollCacheState|clampedProgress|activeDownloadID|private var downloadButton' ios/PatataTube/Sources/MovieDetailView.swift ios/PatataTube/Sources/VideoCell.swift
```

Expected: zero matches.

- [ ] **Step 7: Commit the existing-surface migration**

Run from the repository root:

```bash
rtk git add ios/PatataTube/Sources/MovieDetailView.swift ios/PatataTube/Sources/VideoCell.swift
rtk git commit -m "refactor(ios): centralize existing download controls"
```

---

### Task 4: Give episode rows the shared async download control

**Files:**
- Modify: `ios/PatataTube/Sources/EpisodesView.swift:6-53`
- Modify: `ios/PatataTube/Sources/ShowsView.swift:6-36`
- Modify: `ios/PatataTube/Sources/VideoGridView.swift:59-64`

**Interfaces:**
- Consumes: `DownloadButton`; `VideoGridView.download(_:) async -> Bool`.
- Produces: `EpisodesView.onDownload` and `ShowsView.onDownload` as `(Video) async -> Bool`; episode play and download as separate sibling buttons.

- [ ] **Step 1: Change the show/episode closure contract and observe the expected compile failure**

In both `EpisodesView.swift` and `ShowsView.swift`, replace:

```swift
    let onDownload: (Video) -> Void
```

with:

```swift
    let onDownload: (Video) async -> Bool
```

Run from `ios/PatataTube`:

```bash
rtk xcodebuild build -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL in `VideoGridView` because the current show closure creates a `Task` and returns `Void` instead of returning `Bool` asynchronously.

- [ ] **Step 2: Replace the episode row with separate play and download controls**

Replace `EpisodesView.row(for:)` with:

```swift
    private func row(for episode: Video) -> some View {
        HStack(spacing: 12) {
            Button {
                onPlay(episode, show.episodes)
            } label: {
                HStack(spacing: 12) {
                    AuthedImage(
                        path: episode.previewUrl,
                        localFileURL: model.cache.cachedPreviewURL(for: episode.id)
                    )
                    .frame(width: 120, height: 68)
                    .background(.secondary.opacity(0.2))
                    .cornerRadius(6)
                    .clipped()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("E\(episode.episode ?? 0) — \(episode.title ?? "Untitled")")
                            .font(.subheadline)
                        if let summary = episode.summary {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play episode")

            DownloadButton(
                identity: DownloadButtonIdentity(
                    videoID: episode.id,
                    versionID: episode.chosenVersionId,
                    audioLanguage: episode.audioLang
                ),
                currentCacheState: {
                    model.cache.state(
                        for: episode.id,
                        versionId: episode.chosenVersionId
                    )
                },
                onDownload: { await onDownload(episode) },
                onCancel: {
                    model.cache.cancel(
                        id: episode.id,
                        versionId: episode.chosenVersionId
                    )
                }
            )
        }
    }
```

This removes the parent `.onTapGesture`; tapping Download or Cancel can no longer bubble into playback because play is a separate sibling `Button`.

- [ ] **Step 3: Pass the async result through VideoGridView**

Replace the `ShowsView` construction at lines 59-64 of `VideoGridView.swift` with:

```swift
                    ShowsView(
                        videos: filteredVideos,
                        onPlay: { video, queue in
                            play(video, queueSnapshot: queue)
                        },
                        onDownload: { await download($0) }
                    )
```

- [ ] **Step 4: Regenerate and run all app tests**

Run from `ios/PatataTube`:

```bash
rtk xcodegen generate
rtk xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3'
```

Expected: `** TEST SUCCEEDED **`; the application and `PatataTubeTests` compile, and all shared-button tests pass.

- [ ] **Step 5: Confirm every existing download surface uses the shared type**

Run from the repository root:

```bash
rtk grep -n 'DownloadButton(' ios/PatataTube/Sources/MovieDetailView.swift ios/PatataTube/Sources/VideoCell.swift ios/PatataTube/Sources/EpisodesView.swift
rtk grep -n 'ProgressView(value:|private var downloadButton|DownloadPhase' ios/PatataTube/Sources/MovieDetailView.swift ios/PatataTube/Sources/VideoCell.swift ios/PatataTube/Sources/EpisodesView.swift
```

Expected: the first command reports one `DownloadButton` use in each file; the second command reports zero matches.

- [ ] **Step 6: Commit episode parity**

Run from the repository root:

```bash
rtk git add ios/PatataTube/Sources/EpisodesView.swift ios/PatataTube/Sources/ShowsView.swift ios/PatataTube/Sources/VideoGridView.swift
rtk git commit -m "feat(ios): add full download controls to episodes"
```

---

### Task 5: Manual guide and final verification

**Files:**
- Modify: `ios/README.md:94-124,162-165`

**Interfaces:**
- Consumes: all implementation tasks and the existing `PatataTubeKit` test suite.
- Produces: current automated-test instructions and a manual checklist covering parity, cancellation, resume, tap isolation, version/audio reset, and delete-cache refresh.

- [ ] **Step 1: Update the Plex download checklist**

Replace the existing download/version bullets around lines 115 and 122-124 with:

```markdown
- [ ] Download an unprepared episode: Preparing… appears, then the episode row
      shows the same 44×44 progress ring and green checkmark as a VideoCell and
      MovieDetailView; airplane-mode playback works from cache.
- [ ] Start one download from each surface (VideoCell, MovieDetailView, and an
      episode row): every visible matching control tracks live progress and
      finishes as a green checkmark.
- [ ] Tap each active progress ring: only the matching download is cancelled,
      its control immediately returns to the arrow, and no playback begins.
- [ ] After a network interruption, restore connectivity and tap Download:
      progress resumes through CacheManager rather than restarting.
- [ ] Cancel and immediately retry the same item: the new attempt continues to
      show progress and an old cancellation completion never resets it.
- [ ] Switch version or audio language during an attempt: the control resets to
      the newly selected identity; switching back rediscovers the old identity's
      live or completed cache state.
- [ ] Delete a cached movie from MovieDetailView: the green checkmark changes to
      the download arrow immediately, without waiting for a poll.
```

- [ ] **Step 2: Replace the obsolete no-test-target note**

Replace line 164 with:

```markdown
- `PatataTubeTests` covers the shared download button's state, rendering,
  interaction, polling, and task cancellation. Run it from `ios/PatataTube`
  with `xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3'`.
```

Keep the following `PatataTubeKit` note, since cache behavior remains tested in the standalone package.

- [ ] **Step 3: Run the complete iOS app test suite from a freshly generated project**

Run from `ios/PatataTube`:

```bash
rtk xcodegen generate
rtk xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3'
```

Expected: `** TEST SUCCEEDED **` with every `PatataTubeTests` test passing.

- [ ] **Step 4: Run the complete PatataTubeKit suite**

Run from `ios/PatataTubeKit`:

```bash
rtk swift test
```

Expected: all existing `CacheManagerTests`, including cancellation and immediate same-key retry isolation, pass.

- [ ] **Step 5: Build the unsigned app for a generic iOS destination**

Run from `ios/PatataTube`:

```bash
rtk xcodebuild build -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

Expected: `** BUILD SUCCEEDED **` with no Swift concurrency warnings introduced by the shared control.

- [ ] **Step 6: Perform the new manual checklist against a large video**

Run the app against a configured PatataTube server and execute every new bullet from Step 1. Record any failure with the surface, selected version/audio language, whether the download was locally started or externally discovered, and the visible accessibility state (`Download`, `Cancel download`, or `Downloaded`).

- [ ] **Step 7: Review the final diff and commit the guide**

Run from the repository root:

```bash
rtk git diff --check
rtk git diff --stat
rtk git status --short
rtk git add ios/README.md
rtk git commit -m "docs(ios): expand download button verification"
```

Expected: only the intended source, test, XcodeGen, and README changes are present; generated `PatataTube.xcodeproj` and package-resolution files remain ignored.

---

## Self-Review

**Spec coverage:**

- One shared 44x44 control across all three existing surfaces: Tasks 2-4.
- MovieCell unchanged: no task touches it.
- Live external progress and adaptive 150/500 ms polling: Task 2.
- Success, failure, progress clamp, cancellation, retry, and stale completion: Tasks 1-2.
- Video/version/audio identity reset and refresh-token reset: Tasks 1-3.
- Immediate MovieDetailView delete-cache refresh: Task 3.
- Episode async completion and play/download tap isolation: Task 4.
- View disappearance stops observation without cancelling the download: Task 2.
- Test-only ViewInspector and deterministic Clocks dependency: Tasks 1-2.
- Existing CacheManager behavior and tests remain unchanged: Task 5.
- Manual parity and resume coverage: Task 5.

**Placeholder scan:** Clear. Every code-changing step includes exact code, exact paths, commands, and expected results.

**Type consistency:** `DownloadButtonIdentity`, `DownloadButtonState`, `DownloadButton`, `refreshToken: Int`, `currentCacheState: () -> CacheState`, `onDownload: () async -> Bool`, and `onCancel: () -> Void` are used consistently across all tasks and call sites.
