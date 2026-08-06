# Download Button Tap-to-Delete Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the cached-state download button a two-tap destructive control that arms a red delete X, then removes the locally cached file for that version.

**Architecture:** Add an orthogonal `isArmed` flag (plus an `armGeneration` counter) to the existing `@Observable` `DownloadButtonState`. The `.cached` render becomes a `Button`: first tap arms (red X), second tap deletes and resets to `.notCached`. A view `.task(id:)` keyed on the arm generation owns a 3-second auto-revert using the injected `Clock`, mirroring the existing `poll` pattern. A new `onDeleteCache` closure is threaded through the three call sites to `cache.removeCached(id:versionId:)`.

**Tech Stack:** Swift 6, SwiftUI, `@Observable`, `swift-clocks` (`TestClock`), `ViewInspector`, `swift-testing`. App unit-test target `PatataTubeTests`.

## Global Constraints

- New callback is named `onDeleteCache` — MUST NOT reuse `VideoCell.onDelete`, which already deletes the whole server-side video (`store.delete`).
- Deletion targets the button's chosen version: `cache.removeCached(id:versionId:)`, NOT `removeAllCached`.
- Arm/delete UI is reachable ONLY from `.cached`. `.downloading`, `.notCached`, `.loading` renders are unchanged.
- Auto-revert timeout is 3 seconds, driven by the injected `Clock` (never `Task.sleep` with a literal), so `TestClock` can drive it.
- Tests run via the `PatataTubeTests` target (Xcode), not `swift build`. `DownloadButtonState`/`DownloadButton` live in `PatataTube/Sources`, tests in `PatataTube/Tests/DownloadButtonTests.swift`.
- Run the iOS test suite with:
  `cd ios/PatataTube && xcodegen generate && xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 15'`
  (use whatever simulator name is installed; adjust `-destination` if needed).

---

### Task 1: Arm/disarm state on `DownloadButtonState`

**Files:**
- Modify: `ios/PatataTube/Sources/DownloadButton.swift` (the `DownloadButtonState` class, lines ~13-117)
- Test: `ios/PatataTube/Tests/DownloadButtonTests.swift` (`DownloadButtonStateTests` suite, lines ~8-60)

**Interfaces:**
- Consumes: existing `effectiveState: CacheState`, `reset(to:)`, `observe(_:)`.
- Produces:
  - `var isArmed: Bool` (private(set))
  - `var armGeneration: Int` (private(set))
  - `var showsArmedDelete: Bool` — `true` only when `isArmed && effectiveState == .cached`
  - `func arm()` — sets `isArmed = true`, increments `armGeneration`
  - `func disarm()` — sets `isArmed = false`
  - `reset(to:)` and `observe(_:)` clear `isArmed` whenever the resulting state is not `.cached`.

- [ ] **Step 1: Write the failing tests**

Add to the `DownloadButtonStateTests` suite in `DownloadButtonTests.swift`:

```swift
    @Test func armingRequiresCachedAndTogglesDeletePrompt() {
        let state = DownloadButtonState()
        state.reset(to: .cached)
        #expect(!state.showsArmedDelete)

        state.arm()
        #expect(state.isArmed)
        #expect(state.showsArmedDelete)

        state.disarm()
        #expect(!state.isArmed)
        #expect(!state.showsArmedDelete)
    }

    @Test func armGenerationAdvancesOnEachArm() {
        let state = DownloadButtonState()
        state.reset(to: .cached)
        let first = state.armGeneration
        state.arm()
        state.arm()
        #expect(state.armGeneration == first + 2)
    }

    @Test func leavingCachedClearsArmedState() {
        let state = DownloadButtonState()
        state.reset(to: .cached)
        state.arm()
        #expect(state.isArmed)

        state.observe(.notCached)
        #expect(!state.isArmed)
        #expect(!state.showsArmedDelete)

        state.reset(to: .cached)
        state.arm()
        state.reset(to: .downloading(0.3))
        #expect(!state.isArmed)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run the test suite (see Global Constraints command).
Expected: FAIL — `value of type 'DownloadButtonState' has no member 'arm'/'isArmed'/'armGeneration'/'showsArmedDelete'`.

- [ ] **Step 3: Add the arm/disarm implementation**

In the `DownloadButtonState` class add the stored properties near `progress`/`activeAttemptID`:

```swift
    private(set) var isArmed: Bool = false
    private(set) var armGeneration: Int = 0
```

Add the derived flag next to `effectiveState`:

```swift
    var showsArmedDelete: Bool {
        isArmed && effectiveState == .cached
    }
```

Add the two methods (e.g. after `observe`):

```swift
    func arm() {
        isArmed = true
        armGeneration += 1
    }

    func disarm() {
        isArmed = false
    }
```

Clear armed when leaving `.cached`. In `reset(to:)`, after `observe(cacheState)` add:

```swift
        if cacheState != .cached { isArmed = false }
```

In `observe(_:)`, at the top of the method (before the switch) add:

```swift
        if cacheState != .cached { isArmed = false }
```

- [ ] **Step 4: Run tests to verify they pass**

Run the test suite.
Expected: PASS for the three new tests; the existing `DownloadButtonStateTests` still pass.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTube/Sources/DownloadButton.swift ios/PatataTube/Tests/DownloadButtonTests.swift
git commit -m "feat(ios): add arm/disarm state to download button"
```

---

### Task 2: Cached button renders arm → delete, with auto-revert

**Files:**
- Modify: `ios/PatataTube/Sources/DownloadButton.swift` (the `DownloadButton` view: init lines ~135-151, `control` `.cached` case lines ~164-170, `body` lines ~153-159)
- Test: `ios/PatataTube/Tests/DownloadButtonTests.swift` (`makeDownloadButton` helper ~112-127, `DownloadButtonViewTests` suite ~129-247)

**Interfaces:**
- Consumes: `DownloadButtonState.arm()`, `.disarm()`, `.showsArmedDelete`, `.armGeneration`, `.reset(to:)` from Task 1.
- Produces: `DownloadButton` gains `let onDeleteCache: () -> Void`, added to the memberwise usage and the explicit `init`.

- [ ] **Step 1: Update the existing cached-render test (it will otherwise break)**

The current test asserts `.cached` is an `Image`. It now becomes a `Button`. In `rendersAccessibleIdleActiveAndCachedStates` replace the final block (lines ~144-146):

```swift
        state.reset(to: .cached)
        control = try sut.inspect().find(ViewType.Button.self)
        #expect(try control.accessibilityLabel().string() == "Downloaded")
```

- [ ] **Step 2: Add `onDeleteCache` to the test helper**

In `makeDownloadButton` add a parameter and pass it through:

```swift
private func makeDownloadButton(
    state: DownloadButtonState,
    cache: CacheStateSource = CacheStateSource(.notCached),
    refreshToken: Int = 0,
    onDownload: @escaping () async -> Bool = { false },
    onCancel: @escaping () -> Void = {},
    onDeleteCache: @escaping () -> Void = {}
) -> DownloadButton {
    DownloadButton(
        identity: DownloadButtonIdentity(videoID: 7, versionID: 3, audioLanguage: "eng"),
        refreshToken: refreshToken,
        currentCacheState: { cache.read() },
        onDownload: onDownload,
        onCancel: onCancel,
        onDeleteCache: onDeleteCache,
        state: state
    )
}
```

- [ ] **Step 3: Write the failing behavior tests**

Add to the `DownloadButtonViewTests` suite:

```swift
    @Test func tappingCachedArmsDeletePrompt() throws {
        let state = DownloadButtonState(initialCacheState: .cached)
        let sut = makeDownloadButton(state: state)

        var control = try sut.inspect().find(ViewType.Button.self)
        #expect(try control.accessibilityLabel().string() == "Downloaded")

        try control.tap()
        #expect(state.showsArmedDelete)

        control = try sut.inspect().find(ViewType.Button.self)
        #expect(try control.accessibilityLabel().string() == "Delete download")
    }

    @Test func tappingArmedDeletesCacheAndReturnsToDownload() throws {
        let state = DownloadButtonState(initialCacheState: .cached)
        var deleteCount = 0
        let sut = makeDownloadButton(state: state, onDeleteCache: { deleteCount += 1 })

        state.arm()
        try sut.inspect().find(ViewType.Button.self).tap()

        #expect(deleteCount == 1)
        #expect(state.effectiveState == .notCached)
        #expect(!state.isArmed)

        let control = try sut.inspect().find(ViewType.Button.self)
        #expect(try control.accessibilityLabel().string() == "Download")
    }

    @Test func armedStateAutoRevertsAfterTimeout() async {
        let state = DownloadButtonState(initialCacheState: .cached)
        let clock = TestClock()
        let sut = makeDownloadButton(state: state, cache: CacheStateSource(.cached))
            .environment(\.continuousClock, clock)

        ViewHosting.host(view: sut)
        state.arm()
        await eventually("View never observed armed state") { state.isArmed }

        await clock.advance(by: .seconds(3))
        await eventually("Armed state never auto-reverted") { !state.isArmed }

        ViewHosting.expel()
    }
```

- [ ] **Step 4: Run tests to verify they fail**

Run the test suite.
Expected: FAIL — `onDeleteCache` missing from `DownloadButton.init`; cached case still renders an `Image`, so the new tests can't find/behave on a `Button`.

- [ ] **Step 5: Add the `onDeleteCache` property and init parameter**

In the `DownloadButton` struct, next to `let onCancel: () -> Void`:

```swift
    let onDeleteCache: () -> Void
```

Update the explicit `init` signature and body — add the parameter after `onCancel` and assign it:

```swift
    init(
        identity: DownloadButtonIdentity,
        refreshToken: Int = 0,
        currentCacheState: @escaping () -> CacheState,
        onDownload: @escaping () async -> Bool,
        onCancel: @escaping () -> Void,
        onDeleteCache: @escaping () -> Void,
        state: DownloadButtonState? = nil
    ) {
        self.identity = identity
        self.refreshToken = refreshToken
        self.currentCacheState = currentCacheState
        self.onDownload = onDownload
        self.onCancel = onCancel
        self.onDeleteCache = onDeleteCache
        _state = State(initialValue: state ?? DownloadButtonState(
            initialCacheState: currentCacheState()
        ))
    }
```

- [ ] **Step 6: Replace the `.cached` render with the arm/delete button**

In `control`, replace the entire `.cached` case (lines ~164-170) with:

```swift
        case .cached:
            Button {
                if state.showsArmedDelete {
                    onDeleteCache()
                    withAnimation { state.reset(to: .notCached) }
                } else {
                    withAnimation { state.arm() }
                }
            } label: {
                Image(systemName: state.showsArmedDelete ? "x.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(state.showsArmedDelete ? .red : .green)
                    .font(.system(size: 30))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .transition(.scale.combined(with: .opacity))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state.showsArmedDelete ? "Delete download" : "Downloaded")
```

- [ ] **Step 7: Add the auto-revert task to `body`**

Replace `body` (lines ~153-159) with a second `.task` that disarms after the timeout, keyed on the arm generation so re-arming restarts it:

```swift
    var body: some View {
        control
            .task(id: ObservationID(identity: identity, refreshToken: refreshToken)) {
                state.reset(to: currentCacheState())
                await state.poll(currentCacheState: currentCacheState, clock: clock)
            }
            .task(id: state.armGeneration) {
                guard state.isArmed else { return }
                do {
                    try await clock.sleep(for: .seconds(3))
                } catch {
                    return
                }
                withAnimation { state.disarm() }
            }
    }
```

- [ ] **Step 8: Run tests to verify they pass**

Run the test suite.
Expected: PASS — all `DownloadButtonViewTests` including the three new ones and the updated cached-render assertion.

- [ ] **Step 9: Commit**

```bash
git add ios/PatataTube/Sources/DownloadButton.swift ios/PatataTube/Tests/DownloadButtonTests.swift
git commit -m "feat(ios): cached download button arms then deletes local file"
```

---

### Task 3: Wire `onDeleteCache` at the three call sites

**Files:**
- Modify: `ios/PatataTube/Sources/VideoCell.swift` (props ~18-22, `DownloadButton(` ~94-103)
- Modify: `ios/PatataTube/Sources/VideoGridView.swift` (`VideoCell(` ~90-104)
- Modify: `ios/PatataTube/Sources/MovieDetailView.swift` (`DownloadButton(` ~67-87)
- Modify: `ios/PatataTube/Sources/EpisodesView.swift` (`DownloadButton(` ~172-188)

**Interfaces:**
- Consumes: `DownloadButton.onDeleteCache` from Task 2; `CacheManager.removeCached(id:versionId:)` (existing, `CacheManager.swift:132`).
- Produces: `VideoCell` gains `let onDeleteCache: () -> Void`.

This is a compile-only wiring task (no new unit test — the leaf closures just call an already-tested `removeCached`). The deliverable is a clean build + green suite.

- [ ] **Step 1: Add the `onDeleteCache` prop to `VideoCell`**

In `VideoCell.swift`, after `let onCancel: () -> Void` (line ~19) add:

```swift
    let onDeleteCache: () -> Void
```

- [ ] **Step 2: Pass it into `VideoCell`'s `DownloadButton`**

In `VideoCell.swift`, in the `DownloadButton(` call (~94-103) add the argument after `onCancel: onCancel`:

```swift
                DownloadButton(
                    identity: DownloadButtonIdentity(
                        videoID: video.id,
                        versionID: video.chosenVersionId,
                        audioLanguage: video.audioLang
                    ),
                    currentCacheState: currentCacheState,
                    onDownload: onDownload,
                    onCancel: onCancel,
                    onDeleteCache: onDeleteCache
                )
```

- [ ] **Step 3: Provide the closure from `VideoGridView`**

In `VideoGridView.swift`, in the `VideoCell(` construction (~90-104) add after `onDelete: { Task { await store.delete(id: video.id) } }`:

```swift
                                onDeleteCache: { cache.removeCached(id: videoId, versionId: versionId) }
```

(`cache`, `videoId`, `versionId` are the locals already bound at lines ~87-89.)

- [ ] **Step 4: Provide the closure in `MovieDetailView`**

In `MovieDetailView.swift`, in the `DownloadButton(` call (~67-87) add after the `onCancel` closure:

```swift
                        onDeleteCache: {
                            model.cache.removeCached(
                                id: currentVideo.id,
                                versionId: currentVideo.chosenVersionId
                            )
                        }
```

- [ ] **Step 5: Provide the closure in `EpisodesView`**

In `EpisodesView.swift`, in the `DownloadButton(` call (~172-188) add after the `onCancel` closure:

```swift
                onDeleteCache: {
                    model.cache.removeCached(
                        id: episode.id,
                        versionId: episode.chosenVersionId
                    )
                }
```

- [ ] **Step 6: Regenerate project, build, and run the suite**

```bash
cd ios/PatataTube && xcodegen generate
xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 15'
```

Expected: BUILD SUCCEEDED; all tests pass. Fix any missing-argument compile errors in `VideoGridViewTests.swift` / `EpisodesViewTests.swift` if they construct `VideoCell` directly — add `onDeleteCache: {}` there too.

- [ ] **Step 7: Commit**

```bash
git add ios/PatataTube/Sources/VideoCell.swift ios/PatataTube/Sources/VideoGridView.swift ios/PatataTube/Sources/MovieDetailView.swift ios/PatataTube/Sources/EpisodesView.swift ios/PatataTube/Tests
git commit -m "feat(ios): wire cache-delete callback through video views"
```

---

### Task 4: Document the manual test step

**Files:**
- Modify: `ios/README.md` (manual test checklist section)

- [ ] **Step 1: Add a checklist line**

Find the manual test checklist in `ios/README.md` and add:

```markdown
- [ ] Cached video: tap the green checkmark → it turns into a red X; tap again → the local file is deleted and the button returns to the download arrow. Wait ~3s after arming without a second tap → it reverts to the green checkmark.
```

- [ ] **Step 2: Commit**

```bash
git add ios/README.md
git commit -m "docs(ios): manual test step for download button tap-to-delete"
```

---

## Self-Review

**Spec coverage:**
- Cached becomes tappable, first tap → red X → Task 2 Step 6. ✓
- 3s auto-revert → Task 2 Step 7 + test Step 3. ✓
- Second tap deletes + returns to download icon → Task 2 Step 6 + test. ✓
- Leaving view / external removal clears armed → Task 1 (`reset`/`observe` guards) + tests. ✓
- New `onDeleteCache` callback wired at 3 sites, `removeCached` specific version → Task 3. ✓
- Cached-only scope (downloading/notCached untouched) → only `.cached` case changed. ✓
- Tests via injected clock → Task 2 Step 3 `armedStateAutoRevertsAfterTimeout`. ✓
- README manual step → Task 4. ✓

**Placeholder scan:** none — every code step shows full code.

**Type consistency:** `arm()`, `disarm()`, `isArmed`, `armGeneration`, `showsArmedDelete`, `onDeleteCache`, `removeCached(id:versionId:)` used identically across Tasks 1-3. `onDeleteCache` deliberately distinct from the pre-existing `VideoCell.onDelete`.

**Risk noted:** `VideoGridViewTests.swift` / `EpisodesViewTests.swift` may construct `VideoCell` directly and need the new `onDeleteCache:` argument — handled in Task 3 Step 6.
