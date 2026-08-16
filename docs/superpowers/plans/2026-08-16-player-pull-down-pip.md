# Pull Down for Picture in Picture — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pulling down inside the video player sends the video to Picture in Picture and returns to the grid, instead of dismissing playback.

**Architecture:** `AVPlayerViewController` has no public API to start PiP, so the gesture fires AVKit's own PiP button, found by walking the controller's view hierarchy. AVKit then owns the floating window; our SwiftUI `fullScreenCover` dismisses itself from the `didStartPictureInPicture` delegate callback, with `VideoPlayerView.onDisappear` skipping the teardown steps that would kill playback. A `PiPCoordinator` on `AppModel` outlives the cover and re-presents the player when PiP's restore button is tapped.

**Tech Stack:** Swift 6, SwiftUI, AVKit/AVFoundation, XcodeGen, swift-testing + ViewInspector (`PatataTubeTests`, `xcodebuild`-only target).

**Spec:** `docs/superpowers/specs/2026-08-16-player-pull-down-pip-design.md`

## Global Constraints

- **Never run the iOS tests.** Neither `swift test` nor `xcodebuild ... test`. Per `CLAUDE.md`, they take many minutes and are the user's call. Write the tests, build the test target with `build-for-testing` to prove it compiles, and stop there.
- **`PatataTubeTests` only ever builds through `xcodebuild`** and rots silently otherwise. Every task touching `ios/PatataTube/Sources/` must finish with a successful `build-for-testing`.
- **Destinations:** `build`/`build-for-testing` need a concrete simulator udid from `xcrun simctl list devices available`. `generic/platform=iOS Simulator` is rejected by anything test-related; named destinations (`name=iPad Pro 13-inch (M4)`) fail on this machine.
- **No `print`.** Instrumentation goes through `DevLog.event` / `DevLog.error`, whose arguments are `@autoclosure` and compiled out without the `DEVLOG` condition. Records carry ids and statuses only — never tokens, never response bodies.
- **Do not add ViewInspector tests that inspect `VideoPlayerView`.** ViewInspector 0.10.3 segfaults the whole test process injecting `AppModel` into it (see the disabled test at `PlayerViewControllerTests.swift:92`). Test pure functions and `UIView` trees instead.
- **Existing gesture geometry is preserved verbatim:** 20pt minimum distance, downward + vertically-dominant to engage, 150pt to commit.
- **`Info.plist` needs no change** — `UIBackgroundModes` already contains `audio` (`Info.plist:88-91`), which is what PiP requires.

---

### Task 1: Spike — does PiP survive our cover being dismissed?

Throwaway. The entire design rests on an assumption the SDK headers do not settle: that AVKit's PiP keeps running after *our* `fullScreenCover` is dismissed, given AVKit is no longer dismissing its own presentation. This task answers that and captures the real view-hierarchy identifiers Task 2 needs. **Nothing here is kept.**

**Files:**
- Modify (temporarily): `ios/PatataTube/Sources/PlayerViewController.swift`
- Modify (temporarily): `ios/PatataTube/Sources/VideoPlayerView.swift`

- [ ] **Step 1: Branch so the throwaway is trivially discardable**

```bash
git checkout -b spike/pip-survives-dismissal
```

- [ ] **Step 2: Enable PiP and dump the view tree**

In `PlayerViewController.makePlayerViewController`, change `controller.allowsPictureInPicturePlayback = false` to `true`, and add a temporary dump inside `SceneReportingPlayerViewController.viewDidAppear`, after the existing body:

```swift
// SPIKE ONLY — delete before merging.
DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
    guard let root = self?.view else { return }
    var queue: [(UIView, Int)] = [(root, 0)]
    while !queue.isEmpty {
        let (view, depth) = queue.removeFirst()
        if view is UIControl {
            NSLog("SPIKE control depth=%d class=%@ id=%@ label=%@",
                  depth, String(describing: type(of: view)),
                  view.accessibilityIdentifier ?? "nil",
                  view.accessibilityLabel ?? "nil")
        }
        queue.append(contentsOf: view.subviews.map { ($0, depth + 1) })
    }
}
```

`NSLog` rather than `DevLog` because this code is deleted within the hour and its output must land in the Xcode console without the `DEVLOG` condition.

- [ ] **Step 3: Build and run on a simulator, then read the dump**

```bash
cd ios/PatataTube && xcodegen generate
open PatataTube.xcodeproj
```

Run, play any video, tap once to reveal the transport controls. Read the `SPIKE control` lines in the Xcode console.

**Record verbatim, in the findings comment of Step 6: the class name and `accessibilityIdentifier` of the PiP button.** Task 2's matcher is written against these exact strings. If no control looks like PiP, PiP is not being offered — check that the simulator supports it (`AVPictureInPictureController.isPictureInPictureSupported()`); iPad simulators do, some iPhone ones do not.

- [ ] **Step 4: Fire the button and dismiss the cover**

Temporarily replace the body of `pullDownToDismiss`'s `.onEnded` in `VideoPlayerView.swift:190-197` with:

```swift
.onEnded { value in
    guard value.translation.height > 150 else {
        withAnimation(.spring()) { dragOffset = 0 }
        return
    }
    // SPIKE ONLY — delete before merging.
    NotificationCenter.default.post(name: Notification.Name("SpikeStartPiP"), object: nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { dismiss() }
}
```

and in `SceneReportingPlayerViewController.viewDidAppear`, observe it and send the action:

```swift
// SPIKE ONLY — delete before merging.
NotificationCenter.default.addObserver(
    forName: Notification.Name("SpikeStartPiP"), object: nil, queue: .main
) { [weak self] _ in
    guard let root = self?.view else { return }
    var queue: [UIView] = [root]
    while !queue.isEmpty {
        let view = queue.removeFirst()
        if let control = view as? UIControl,
           (control.accessibilityIdentifier ?? "").localizedCaseInsensitiveContains("picture") {
            NSLog("SPIKE firing %@", String(describing: type(of: control)))
            control.sendActions(for: .touchUpInside)
            return
        }
        queue.append(contentsOf: view.subviews)
    }
    NSLog("SPIKE no PiP button found")
}
```

If Step 3 showed the identifier is nil or does not contain "picture", match on whatever it actually showed instead.

The 0.5s delay before `dismiss()` is deliberate: it lets PiP start before the cover tears down, which is the friendliest possible version of the question. If PiP does not survive even with the delay, it will not survive without one.

- [ ] **Step 5: Answer the question**

Run, play a video, pull down. Observe:

1. **Does a floating PiP window appear?** If no → the button-firing approach is dead.
2. **Does it keep playing after the cover dismisses and the grid reappears?** If no → approach B is dead.
3. Note whether audio survives when video does not — that distinguishes "AVKit tore down PiP" from "`onDisappear` paused the player", which Task 3 fixes.

**If PiP does not survive:** stop. Do not work around it. Report to the user that approach B is dead and the window-level `AVPlayerLayer` host (approach A in the spec) is the only route, and re-plan. Case 3 above is the one exception — a player merely paused by `onDisappear` is expected at this stage and does not condemn the approach.

- [ ] **Step 6: Discard the spike, keep the findings**

```bash
git checkout main
git branch -D spike/pip-survives-dismissal
```

Then append the findings to the spec and commit:

```bash
cat >> docs/superpowers/specs/2026-08-16-player-pull-down-pip-design.md <<'EOF'

## Spike findings (2026-08-16)

- PiP survives our cover's dismissal: <yes/no>
- PiP button class: <exact class name from the dump>
- PiP button accessibilityIdentifier: <exact string, or "nil">
- Notes: <anything surprising>
EOF
git add docs/superpowers/specs/2026-08-16-player-pull-down-pip-design.md
git commit -m "docs: record PiP spike findings"
```

---

### Task 2: The PiP button finder

**Files:**
- Create: `ios/PatataTube/Sources/PictureInPictureButtonFinder.swift`
- Test: `ios/PatataTube/Tests/PictureInPictureButtonFinderTests.swift`
- Modify: `ios/PatataTube/Sources/PlayerViewController.swift:78`

**Interfaces:**
- Consumes: the exact identifier string recorded by Task 1.
- Produces: `func pictureInPictureButton(in root: UIView) -> UIControl?` — a free function, `@MainActor`, breadth-first, returns the first match or nil.

- [ ] **Step 1: Write the failing tests**

Create `ios/PatataTube/Tests/PictureInPictureButtonFinderTests.swift`:

```swift
import AVKit
import Testing
import UIKit
@testable import PatataTube

@Suite("Picture in Picture button finder")
@MainActor
struct PictureInPictureButtonFinderTests {
    /// Builds root -> child -> grandchild, with `target` installed at `depth`.
    private func tree(installing target: UIView?, atDepth depth: Int) -> UIView {
        let root = UIView()
        var current = root
        for level in 1...3 {
            let next = UIView()
            current.addSubview(next)
            if level == depth, let target { next.addSubview(target) }
            current = next
        }
        return root
    }

    private func pipButton() -> UIControl {
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = PictureInPictureButtonIdentifier
        return button
    }

    @Test func findsTheButtonNestedDeepInTheTree() {
        let target = pipButton()
        #expect(pictureInPictureButton(in: tree(installing: target, atDepth: 3)) === target)
    }

    @Test func returnsNilWhenNoControlMatches() {
        let decoy = UIButton(type: .system)
        decoy.accessibilityIdentifier = "SomeOtherButton"
        #expect(pictureInPictureButton(in: tree(installing: decoy, atDepth: 2)) == nil)
    }

    @Test func ignoresPlainViewsCarryingTheIdentifier() {
        // Only a UIControl can be sent .touchUpInside; a label must not match.
        let impostor = UILabel()
        impostor.accessibilityIdentifier = PictureInPictureButtonIdentifier
        #expect(pictureInPictureButton(in: tree(installing: impostor, atDepth: 2)) == nil)
    }

    @Test func prefersTheShallowestMatch() {
        // Breadth-first, so a nested duplicate never shadows the real one.
        let shallow = pipButton()
        let deep = pipButton()
        let root = UIView()
        let branch = UIView()
        root.addSubview(branch)
        branch.addSubview(deep)
        root.addSubview(shallow)
        #expect(pictureInPictureButton(in: root) === shallow)
    }

    /// The canary. Everything above tests our walk against a tree we built;
    /// only this one fails when Apple moves the button, which is the whole
    /// risk of this approach.
    @Test func findsTheButtonInARealPlayerViewController() throws {
        try #require(AVPictureInPictureController.isPictureInPictureSupported())
        let controller = AVPlayerViewController()
        controller.allowsPictureInPicturePlayback = true
        controller.player = AVPlayer()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        controller.view.layoutIfNeeded()
        #expect(pictureInPictureButton(in: controller.view) != nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Do **not** run them — see Global Constraints. Instead prove they fail to *compile* against the missing symbol, which is the same signal here:

```bash
cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube \
  -destination "platform=iOS Simulator,id=$(xcrun simctl list devices available | grep -m1 -o '[0-9A-F-]\{36\}')" \
  build-for-testing 2>&1 | tail -20
```

Expected: FAIL, `cannot find 'pictureInPictureButton' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ios/PatataTube/Sources/PictureInPictureButtonFinder.swift`:

```swift
import UIKit

/// AVKit's identifier for the PiP button in `AVPlayerViewController`'s control
/// bar, captured from the running control hierarchy (see the spike findings in
/// the design doc). Undocumented, hence the canary test in
/// `PictureInPictureButtonFinderTests` that reads a real controller's tree.
let PictureInPictureButtonIdentifier = "<exact string recorded in Task 1>"

/// Finds AVKit's own PiP button so a gesture can fire it. `AVPlayerViewController`
/// exposes no public way to start Picture in Picture, and
/// `AVPictureInPictureController` can only be built from an `AVPlayerLayer`,
/// which the controller does not hand out.
///
/// Breadth-first on purpose: the shallowest match is the visible control bar's
/// button, and a nested duplicate can never shadow it.
@MainActor
func pictureInPictureButton(in root: UIView) -> UIControl? {
    var queue: [UIView] = [root]
    while !queue.isEmpty {
        let view = queue.removeFirst()
        if let control = view as? UIControl,
           control.accessibilityIdentifier == PictureInPictureButtonIdentifier {
            return control
        }
        queue.append(contentsOf: view.subviews)
    }
    return nil
}
```

Replace `<exact string recorded in Task 1>` with the identifier from the spike findings. If Task 1 recorded the identifier as nil, match on the button's image instead — swap the condition for:

```swift
        if let button = view as? UIButton,
           let image = button.image(for: .normal),
           image.isEqual(AVPictureInPictureController.pictureInPictureButtonStartImage) {
            return button
        }
```

and add `import AVKit`. Prefer the identifier when one exists; it is the more stable of the two signals.

- [ ] **Step 4: Enable PiP on the controller**

In `ios/PatataTube/Sources/PlayerViewController.swift:78`:

```swift
        controller.allowsPictureInPicturePlayback = true
```

Without this AVKit never renders the button and the finder always returns nil.

- [ ] **Step 5: Verify it compiles**

```bash
cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube \
  -destination "platform=iOS Simulator,id=$(xcrun simctl list devices available | grep -m1 -o '[0-9A-F-]\{36\}')" \
  build-for-testing 2>&1 | tail -5
```

Expected: `** TEST BUILD SUCCEEDED **`. (The tests themselves are the user's to run.)

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTube/Sources/PictureInPictureButtonFinder.swift \
        ios/PatataTube/Tests/PictureInPictureButtonFinderTests.swift \
        ios/PatataTube/Sources/PlayerViewController.swift
git commit -m "feat(ios): locate AVKit's Picture in Picture button"
```

---

### Task 3: The teardown gate

`VideoPlayerView.onDisappear` (`:157-177`) tears down unconditionally today. When the cover dismisses *because* PiP started, three of those steps kill the thing we just started. This task makes the decision an explicit, testable value before any caller depends on it.

**Files:**
- Modify: `ios/PatataTube/Sources/VideoPlayerView.swift:157-177`
- Test: `ios/PatataTube/Tests/VideoPlayerTeardownTests.swift`

**Interfaces:**
- Produces: `VideoPlayerView.TeardownPlan` with `static func plan(handingOffToPiP: Bool) -> TeardownPlan` and four `Bool` properties: `pausesPlayer`, `deactivatesAudioSession`, `detachesNowPlaying`, `removesPositionObserver`.

- [ ] **Step 1: Write the failing test**

Create `ios/PatataTube/Tests/VideoPlayerTeardownTests.swift`:

```swift
import Testing
@testable import PatataTube

@Suite("Player teardown plan")
struct VideoPlayerTeardownTests {
    @Test func ordinaryDismissalTearsEverythingDown() {
        let plan = VideoPlayerView.TeardownPlan.plan(handingOffToPiP: false)
        #expect(plan.pausesPlayer)
        #expect(plan.deactivatesAudioSession)
        #expect(plan.detachesNowPlaying)
        #expect(plan.removesPositionObserver)
    }

    /// Each of these would kill the floating window we just handed the player
    /// to: pausing stops it, deactivating the session silences it, detaching
    /// now-playing surrenders the lock screen mid-playback.
    @Test func handingOffToPiPKeepsPlaybackAlive() {
        let plan = VideoPlayerView.TeardownPlan.plan(handingOffToPiP: true)
        #expect(!plan.pausesPlayer)
        #expect(!plan.deactivatesAudioSession)
        #expect(!plan.detachesNowPlaying)
        // Position reporting continues while the video plays in PiP.
        #expect(!plan.removesPositionObserver)
    }
}
```

- [ ] **Step 2: Verify it fails to build**

```bash
cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube \
  -destination "platform=iOS Simulator,id=$(xcrun simctl list devices available | grep -m1 -o '[0-9A-F-]\{36\}')" \
  build-for-testing 2>&1 | tail -20
```

Expected: FAIL, `type 'VideoPlayerView' has no member 'TeardownPlan'`.

- [ ] **Step 3: Add the type**

In `ios/PatataTube/Sources/VideoPlayerView.swift`, next to the existing `Self.canContinueSetup` helper (same pure-static-function pattern, same reason — it is testable without a view):

```swift
    /// What `onDisappear` should actually do. A dismissal caused by PiP
    /// starting must leave the player, the audio session and the lock-screen
    /// info alone: AVKit is still playing the video in its floating window.
    struct TeardownPlan: Equatable {
        let pausesPlayer: Bool
        let deactivatesAudioSession: Bool
        let detachesNowPlaying: Bool
        let removesPositionObserver: Bool

        static func plan(handingOffToPiP: Bool) -> TeardownPlan {
            TeardownPlan(
                pausesPlayer: !handingOffToPiP,
                deactivatesAudioSession: !handingOffToPiP,
                detachesNowPlaying: !handingOffToPiP,
                removesPositionObserver: !handingOffToPiP
            )
        }
    }
```

- [ ] **Step 4: Apply the plan in `onDisappear`**

Add the state that records the handoff, near `hasDisappeared` (`:76`):

```swift
    /// Set when the cover is dismissing because PiP took over playback, so
    /// `onDisappear` hands off instead of tearing down.
    @State private var handingOffToPiP = false
```

Then rewrite the `.onDisappear` body (`:157-177`), keeping every existing call and gating only the four:

```swift
        .onDisappear {
            let plan = TeardownPlan.plan(handingOffToPiP: handingOffToPiP)
            hasDisappeared = true
            orientationControlVisibility.hide()
            horizontalLock.endPlayerSession()
            reportPosition()
            pauseTransitionObserver?.invalidate()
            pauseTransitionObserver = nil
            if plan.pausesPlayer { player?.pause() }
            removePlayToEndObserver()
            readyObserver?.invalidate()
            readyObserver = nil
            readyTimeoutTask?.cancel()
            readyTimeoutTask = nil
            if plan.removesPositionObserver {
                if let positionObserver { player?.removeTimeObserver(positionObserver) }
                positionObserver = nil
            }
            if plan.detachesNowPlaying { nowPlaying.detach() }
            if plan.deactivatesAudioSession { deactivateAudioSession() }
            playbackProbe.detach()
            DevLog.event(.nav, "player dismissed", [
                "video_id": "\(video.id)", "inst": instanceID,
                "pip_handoff": "\(handingOffToPiP)",
            ])
            DevLog.flush()
        }
```

Note `pauseTransitionObserver` is invalidated in both cases — it exists to catch foreground/remote-control pauses on *this* screen, and the screen is going away either way.

- [ ] **Step 5: Verify it compiles**

```bash
cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube \
  -destination "platform=iOS Simulator,id=$(xcrun simctl list devices available | grep -m1 -o '[0-9A-F-]\{36\}')" \
  build-for-testing 2>&1 | tail -5
```

Expected: `** TEST BUILD SUCCEEDED **`. Nothing sets `handingOffToPiP` yet, so behavior is unchanged — that is correct for this task.

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTube/Sources/VideoPlayerView.swift ios/PatataTube/Tests/VideoPlayerTeardownTests.swift
git commit -m "feat(ios): make player teardown skippable for a PiP handoff"
```

---

### Task 4: The PiP coordinator

Something must outlive the `fullScreenCover` to hold the player and know how to restore it. It lives on `AppModel` for the same reason `restorationGate` does (`AppModel.swift:19-25`): the grid's view state is rebuilt on every cover dismissal.

**Files:**
- Create: `ios/PatataTube/Sources/PiPCoordinator.swift`
- Modify: `ios/PatataTube/Sources/AppModel.swift`
- Test: `ios/PatataTube/Tests/PiPCoordinatorTests.swift`

**Interfaces:**
- Consumes: `PlaybackQueue` (PatataTubeKit), `AVPlayer`.
- Produces:
  - `@MainActor final class PiPCoordinator: ObservableObject`
  - `@Published private(set) var isActive: Bool`
  - `var onRestore: ((PlaybackQueue) -> Void)?`
  - `func didStart(player: AVPlayer, queue: PlaybackQueue)`
  - `func restore() -> Bool`
  - `func didStop()`
  - `AppModel.pip: PiPCoordinator`

- [ ] **Step 1: Write the failing test**

Create `ios/PatataTube/Tests/PiPCoordinatorTests.swift`:

```swift
import AVFoundation
import PatataTubeKit
import Testing
@testable import PatataTube

private let sampleVideo = Video(
    id: 7,
    url: "/videos/7",
    title: "Video 7",
    platform: nil,
    sourceKey: nil,
    previewUrl: nil,
    groupID: nil,
    plexKind: .movies,
    position: 1,
    status: "done",
    errorMsg: nil,
    streamPath: "/videos/7/stream"
)

private func sampleQueue(startSecs: Double = 42) -> PlaybackQueue {
    PlaybackQueue(video: sampleVideo, queueSnapshot: [sampleVideo], startSecs: startSecs)
}

@Suite("PiP coordinator")
@MainActor
struct PiPCoordinatorTests {
    @Test func startsInactiveAndBecomesActiveOnStart() {
        let sut = PiPCoordinator()
        #expect(!sut.isActive)
        sut.didStart(player: AVPlayer(), queue: sampleQueue())
        #expect(sut.isActive)
    }

    @Test func restoreRepresentsTheStoredQueueAndGoesInactive() {
        let sut = PiPCoordinator()
        var restored: PlaybackQueue?
        sut.onRestore = { restored = $0 }
        sut.didStart(player: AVPlayer(), queue: sampleQueue(startSecs: 42))

        #expect(sut.restore())
        #expect(restored?.startSecs == 42)
        #expect(restored?.id == sampleVideo.id)
        #expect(!sut.isActive)
    }

    /// A restore with nothing stored must report failure, so the delegate can
    /// answer AVKit's completion handler with `false` rather than lying.
    @Test func restoreWithoutAnActiveSessionFails() {
        let sut = PiPCoordinator()
        sut.onRestore = { _ in Issue.record("restored with no session") }
        #expect(!sut.restore())
    }

    /// Closing the PiP window with its X: no restore, so the coordinator must
    /// let go of the player it has been keeping alive.
    @Test func stoppingReleasesTheRetainedPlayer() {
        let sut = PiPCoordinator()
        sut.didStart(player: AVPlayer(), queue: sampleQueue())
        sut.didStop()
        #expect(!sut.isActive)
        #expect(sut.retainedPlayer == nil)
    }

    @Test func stoppingAfterARestoreIsHarmless() {
        // AVKit reports didStop after a restore too; it must not double-clear
        // or re-fire onRestore.
        let sut = PiPCoordinator()
        var restores = 0
        sut.onRestore = { _ in restores += 1 }
        sut.didStart(player: AVPlayer(), queue: sampleQueue())
        _ = sut.restore()
        sut.didStop()
        #expect(restores == 1)
        #expect(!sut.isActive)
    }
}
```

- [ ] **Step 2: Verify it fails to build**

```bash
cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube \
  -destination "platform=iOS Simulator,id=$(xcrun simctl list devices available | grep -m1 -o '[0-9A-F-]\{36\}')" \
  build-for-testing 2>&1 | tail -20
```

Expected: FAIL, `cannot find 'PiPCoordinator' in scope`.

- [ ] **Step 3: Write the coordinator**

Create `ios/PatataTube/Sources/PiPCoordinator.swift`:

```swift
import AVFoundation
import Combine
import PatataTubeKit

/// Owns what survives the player's `fullScreenCover` while AVKit plays the
/// video in its floating window: a strong reference to the `AVPlayer` (the
/// cover's `@State` copy dies with the view) and the queue needed to rebuild
/// the full-screen player when PiP's restore button is tapped.
///
/// Lives on `AppModel` rather than in the grid's view state for the same
/// reason `restorationGate` does — SwiftUI rebuilds the grid on every cover
/// dismissal, and this must outlive that.
@MainActor
final class PiPCoordinator: ObservableObject {
    @Published private(set) var isActive = false
    /// Kept alive only for the duration of the PiP session.
    private(set) var retainedPlayer: AVPlayer?
    private var queue: PlaybackQueue?
    /// Set by the grid: re-presents the player for the given queue.
    var onRestore: ((PlaybackQueue) -> Void)?

    func didStart(player: AVPlayer, queue: PlaybackQueue) {
        retainedPlayer = player
        self.queue = queue
        isActive = true
        DevLog.event(.play, "pip started", ["video_id": "\(queue.id)"])
    }

    /// Re-presents the full-screen player. Returns false when there is no
    /// session to restore, so the caller can answer AVKit honestly instead of
    /// reporting a restoration that never happened.
    func restore() -> Bool {
        guard let queue else { return false }
        DevLog.event(.nav, "pip restore", [
            "video_id": "\(queue.id)", "start_secs": "\(Int(queue.startSecs))",
        ])
        clear()
        onRestore?(queue)
        return true
    }

    /// PiP ended without a restore — the user closed the floating window.
    func didStop() {
        guard isActive else { return }
        DevLog.event(.play, "pip stopped", ["video_id": "\(queue?.id ?? -1)"])
        retainedPlayer?.pause()
        clear()
    }

    private func clear() {
        retainedPlayer = nil
        queue = nil
        isActive = false
    }
}
```

`didStop` is guarded on `isActive` because AVKit reports it after a restore as well; the guard is what makes the two orderings equivalent.

- [ ] **Step 4: Hang it off AppModel**

In `ios/PatataTube/Sources/AppModel.swift`, next to `restorationGate` (`:25`):

```swift
    /// Survives the player's cover so PiP can outlive it. See PiPCoordinator.
    let pip = PiPCoordinator()
```

- [ ] **Step 5: Verify it compiles**

```bash
cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube \
  -destination "platform=iOS Simulator,id=$(xcrun simctl list devices available | grep -m1 -o '[0-9A-F-]\{36\}')" \
  build-for-testing 2>&1 | tail -5
```

Expected: `** TEST BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTube/Sources/PiPCoordinator.swift ios/PatataTube/Sources/AppModel.swift \
        ios/PatataTube/Tests/PiPCoordinatorTests.swift
git commit -m "feat(ios): add a PiP coordinator that outlives the player cover"
```

---

### Task 5: Fire PiP from the representable

`VideoPlayerView` has no handle on the `UIViewController`'s view, so starting PiP goes through a token bump — the same idiom `revealControlsToken` already uses (`PlayerViewController.swift:55-58, 89-95`). AVKit's delegate callbacks are wired here too.

**Files:**
- Modify: `ios/PatataTube/Sources/PlayerViewController.swift`
- Test: `ios/PatataTube/Tests/PlayerViewControllerTests.swift`

**Interfaces:**
- Consumes: `pictureInPictureButton(in:)` (Task 2).
- Produces, on `PlayerViewController`: `let startPiPToken: Int`, `let onPiPStartFailed: () -> Void`, `let onPiPStarted: () -> Void`, `let onPiPStopped: () -> Void`, `let onPiPRestore: () -> Bool`. On `Coordinator`: `var lastPiPToken: Int`, and `AVPlayerViewControllerDelegate` conformance.

- [ ] **Step 1: Write the failing test**

Append to `ios/PatataTube/Tests/PlayerViewControllerTests.swift`, inside the existing `PlayerViewControllerTests` suite:

```swift
    @Test func controllerAllowsPictureInPictureAndDelegatesToItsCoordinator() {
        let sut = PlayerViewController(
            player: AVPlayer(), attached: true, resumeAfterDetaching: false,
            revealControlsToken: 0, startPiPToken: 0,
            onPlayerTap: {}, onSceneAvailable: { _ in },
            onPiPStartFailed: {}, onPiPStarted: {}, onPiPStopped: {},
            onPiPRestore: { true }
        )
        let coordinator = sut.makeCoordinator()
        let controller = sut.makePlayerViewController(coordinator: coordinator)

        #expect(controller.allowsPictureInPicturePlayback)
        #expect(controller.delegate === coordinator)
        // AVKit cannot dismiss our SwiftUI cover, so we must dismiss it
        // ourselves from didStart -- never let AVKit try.
        #expect(!coordinator.playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(controller))
    }

    @Test func delegateCallbacksForwardToTheirClosures() {
        var started = 0, stopped = 0, failed = 0, restores = 0
        let sut = PlayerViewController(
            player: AVPlayer(), attached: true, resumeAfterDetaching: false,
            revealControlsToken: 0, startPiPToken: 0,
            onPlayerTap: {}, onSceneAvailable: { _ in },
            onPiPStartFailed: { failed += 1 }, onPiPStarted: { started += 1 },
            onPiPStopped: { stopped += 1 }, onPiPRestore: { restores += 1; return true }
        )
        let coordinator = sut.makeCoordinator()
        let controller = sut.makePlayerViewController(coordinator: coordinator)

        coordinator.playerViewControllerDidStartPictureInPicture(controller)
        coordinator.playerViewControllerDidStopPictureInPicture(controller)
        coordinator.playerViewController(
            controller,
            failedToStartPictureInPictureWithError: NSError(domain: "test", code: 1)
        )
        var restored: Bool?
        coordinator.playerViewController(controller) { restored = $0 }

        #expect(started == 1)
        #expect(stopped == 1)
        #expect(failed == 1)
        #expect(restores == 1)
        #expect(restored == true)
    }

    /// A start that finds no button must fail immediately, so the gesture
    /// falls back to a plain dismiss instead of doing nothing.
    @Test func startingPiPOnAControllerWithoutBoundButtonReportsFailure() {
        var failed = 0
        let coordinator = PlayerViewController.Coordinator(
            onPlayerTap: {}, onPiPStartFailed: { failed += 1 },
            onPiPStarted: {}, onPiPStopped: {}, onPiPRestore: { true }
        )
        // A bare view has no AVKit control bar, so the finder returns nil.
        coordinator.startPictureInPicture(in: UIView())
        #expect(failed == 1)
    }
```

Note: the two existing tests construct `PlayerViewController` with the old argument list and must be updated to the new one in Step 3, or they will not compile.

- [ ] **Step 2: Verify it fails to build**

```bash
cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube \
  -destination "platform=iOS Simulator,id=$(xcrun simctl list devices available | grep -m1 -o '[0-9A-F-]\{36\}')" \
  build-for-testing 2>&1 | tail -20
```

Expected: FAIL, `extra arguments at positions ... in call`.

- [ ] **Step 3: Extend the representable**

In `ios/PatataTube/Sources/PlayerViewController.swift`, add the new stored properties after `revealControlsToken` (`:58`):

```swift
    /// Every increment asks AVKit to enter Picture in Picture. Same idiom as
    /// `revealControlsToken`: the view has no handle on the UIViewController,
    /// so the request travels as a value change.
    let startPiPToken: Int
    let onPiPStartFailed: () -> Void
    let onPiPStarted: () -> Void
    let onPiPStopped: () -> Void
    /// Returns whether the full-screen player was actually re-presented.
    let onPiPRestore: () -> Bool
```

Update `makeCoordinator`:

```swift
    func makeCoordinator() -> Coordinator {
        Coordinator(
            onPlayerTap: onPlayerTap, onPiPStartFailed: onPiPStartFailed,
            onPiPStarted: onPiPStarted, onPiPStopped: onPiPStopped,
            onPiPRestore: onPiPRestore
        )
    }
```

In `makeUIViewController`, seed the token alongside the existing reveal-token seed so a mount never fires a stale request:

```swift
        context.coordinator.lastPiPToken = startPiPToken
```

In `makePlayerViewController`, set the delegate (the `allowsPictureInPicturePlayback = true` line landed in Task 2):

```swift
        controller.delegate = coordinator
```

In `updateUIViewController`, forward the closures and act on a bump — before the `attached` handling, so a detach never races the start:

```swift
        context.coordinator.onPiPStartFailed = onPiPStartFailed
        context.coordinator.onPiPStarted = onPiPStarted
        context.coordinator.onPiPStopped = onPiPStopped
        context.coordinator.onPiPRestore = onPiPRestore
        if context.coordinator.lastPiPToken != startPiPToken {
            context.coordinator.lastPiPToken = startPiPToken
            context.coordinator.startPictureInPicture(in: controller.view)
        }
```

Extend the `Coordinator`:

```swift
    final class Coordinator: NSObject, UIGestureRecognizerDelegate, AVPlayerViewControllerDelegate {
        var onPlayerTap: () -> Void
        var onPiPStartFailed: () -> Void
        var onPiPStarted: () -> Void
        var onPiPStopped: () -> Void
        var onPiPRestore: () -> Bool
        /// Last `revealControlsToken` acted on, so one bump reveals once.
        var lastRevealToken = 0
        /// Same, for `startPiPToken`.
        var lastPiPToken = 0

        init(
            onPlayerTap: @escaping () -> Void,
            onPiPStartFailed: @escaping () -> Void,
            onPiPStarted: @escaping () -> Void,
            onPiPStopped: @escaping () -> Void,
            onPiPRestore: @escaping () -> Bool
        ) {
            self.onPlayerTap = onPlayerTap
            self.onPiPStartFailed = onPiPStartFailed
            self.onPiPStarted = onPiPStarted
            self.onPiPStopped = onPiPStopped
            self.onPiPRestore = onPiPRestore
        }

        /// `AVPlayerViewController` exposes no way to start PiP, so this fires
        /// its own button. When the button is gone — an unsupported device, or
        /// an AVKit reshuffle — the caller is told at once so the gesture can
        /// fall back to dismissing.
        @MainActor
        func startPictureInPicture(in view: UIView) {
            guard AVPictureInPictureController.isPictureInPictureSupported(),
                  let button = pictureInPictureButton(in: view) else {
                DevLog.event(.play, "pip start unavailable", [:])
                onPiPStartFailed()
                return
            }
            button.sendActions(for: .touchUpInside)
        }

        @objc func tapped() { onPlayerTap() }

        func makeTapRecognizer() -> UITapGestureRecognizer {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(tapped))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            return recognizer
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }

        // MARK: AVPlayerViewControllerDelegate

        /// AVKit can only dismiss its own presentation, and ours is a SwiftUI
        /// `fullScreenCover` it knows nothing about. We dismiss it in
        /// `didStart` instead.
        func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(
            _ playerViewController: AVPlayerViewController
        ) -> Bool { false }

        func playerViewControllerDidStartPictureInPicture(
            _ playerViewController: AVPlayerViewController
        ) { onPiPStarted() }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            failedToStartPictureInPictureWithError error: Error
        ) {
            DevLog.error(.play, "pip start failed", ["code": "\((error as NSError).code)"])
            onPiPStartFailed()
        }

        func playerViewControllerDidStopPictureInPicture(
            _ playerViewController: AVPlayerViewController
        ) { onPiPStopped() }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
                @escaping (Bool) -> Void
        ) {
            completionHandler(onPiPRestore())
        }
    }
```

The `DevLog.error` call logs only an error code — never a message body, per the instrumentation rules in `CLAUDE.md`.

- [ ] **Step 4: Fix the two pre-existing tests**

`installedControllerHasExactlyOneNonCancellingSimultaneousTapRecognizer` and any other call site constructing `PlayerViewController` need the new arguments:

```swift
            revealControlsToken: 0, startPiPToken: 0,
            onPlayerTap: {}, onSceneAvailable: { _ in },
            onPiPStartFailed: {}, onPiPStarted: {}, onPiPStopped: {},
            onPiPRestore: { true }
```

`VideoPlayerView.swift`'s construction of `PlayerViewController` (`:102-109`) also needs the new arguments to compile; wire them properly in Task 6. For now pass placeholders that preserve today's behavior:

```swift
                    startPiPToken: 0,
                    onPiPStartFailed: {},
                    onPiPStarted: {},
                    onPiPStopped: {},
                    onPiPRestore: { false }
```

- [ ] **Step 5: Verify it compiles**

```bash
cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube \
  -destination "platform=iOS Simulator,id=$(xcrun simctl list devices available | grep -m1 -o '[0-9A-F-]\{36\}')" \
  build-for-testing 2>&1 | tail -5
```

Expected: `** TEST BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTube/Sources/PlayerViewController.swift \
        ios/PatataTube/Sources/VideoPlayerView.swift \
        ios/PatataTube/Tests/PlayerViewControllerTests.swift
git commit -m "feat(ios): start PiP by firing AVKit's button on a token bump"
```

---

### Task 6: The gesture, and restoring the player

The last task connects everything: the gesture asks for PiP, the coordinator holds the session, the grid re-presents.

**Files:**
- Modify: `ios/PatataTube/Sources/VideoPlayerView.swift:180-201`
- Modify: `ios/PatataTube/Sources/VideoGridView.swift`
- Test: `ios/PatataTube/Tests/VideoPlayerPullDownTests.swift`

**Interfaces:**
- Consumes: `PiPCoordinator` (Task 4), `PlayerViewController`'s PiP closures (Task 5), `VideoPlayerView.TeardownPlan` (Task 3).
- Produces: `VideoPlayerView.engagesPullDown(translation:)` and `VideoPlayerView.commitsPullDown(translation:)`, both `static`, both pure.

- [ ] **Step 1: Write the failing test**

Create `ios/PatataTube/Tests/VideoPlayerPullDownTests.swift`. This mirrors `VideoGridViewTests.dismissesOnlyForDominantHorizontalFlicksPastThreshold`, which tests the sibling gesture the same way:

```swift
import SwiftUI
import Testing
@testable import PatataTube

@Suite("Player pull-down gesture")
struct VideoPlayerPullDownTests {
    @Test func engagesOnlyOnDownwardVerticallyDominantDrags() {
        // Downward and vertical: the gesture.
        #expect(VideoPlayerView.engagesPullDown(translation: CGSize(width: 5, height: 60)))
        // Upward: not ours.
        #expect(!VideoPlayerView.engagesPullDown(translation: CGSize(width: 0, height: -60)))
        // Horizontally dominant: AVKit is scrubbing, leave it alone.
        #expect(!VideoPlayerView.engagesPullDown(translation: CGSize(width: 90, height: 40)))
        // Exactly diagonal is not vertically dominant.
        #expect(!VideoPlayerView.engagesPullDown(translation: CGSize(width: 50, height: 50)))
    }

    @Test func commitsOnlyPastOneHundredFiftyPoints() {
        #expect(!VideoPlayerView.commitsPullDown(translation: CGSize(width: 0, height: 150)))
        #expect(VideoPlayerView.commitsPullDown(translation: CGSize(width: 0, height: 151)))
        #expect(!VideoPlayerView.commitsPullDown(translation: CGSize(width: 0, height: -400)))
    }
}
```

- [ ] **Step 2: Verify it fails to build**

```bash
cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube \
  -destination "platform=iOS Simulator,id=$(xcrun simctl list devices available | grep -m1 -o '[0-9A-F-]\{36\}')" \
  build-for-testing 2>&1 | tail -20
```

Expected: FAIL, `type 'VideoPlayerView' has no member 'engagesPullDown'`.

- [ ] **Step 3: Rewrite the gesture**

In `ios/PatataTube/Sources/VideoPlayerView.swift`, add the token state next to `handingOffToPiP` (added in Task 3):

```swift
    /// Bumped to ask AVKit for Picture in Picture; see PlayerViewController.
    @State private var startPiPToken = 0
```

Replace `pullDownToDismiss` and its comment (`:180-198`) with:

```swift
    /// Vertical-only drag; horizontal moves (scrubbing) and taps fall through
    /// to AVKit controls. Past the threshold the video goes to Picture in
    /// Picture rather than being dismissed — and if PiP cannot start, it is
    /// dismissed after all, so the gesture is never a dead end.
    private var pullDownToPiP: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard Self.engagesPullDown(translation: value.translation) else { return }
                dragOffset = value.translation.height
            }
            .onEnded { value in
                guard Self.commitsPullDown(translation: value.translation) else {
                    withAnimation(.spring()) { dragOffset = 0 }
                    return
                }
                DevLog.event(.nav, "pull-down pip", [
                    "video_id": "\(video.id)", "inst": instanceID,
                    "translation": "\(value.translation.height)",
                ])
                startPiPToken += 1
            }
    }

    /// Downward and vertically dominant — anything else belongs to AVKit.
    static func engagesPullDown(translation: CGSize) -> Bool {
        translation.height > 0 && abs(translation.height) > abs(translation.width)
    }

    static func commitsPullDown(translation: CGSize) -> Bool {
        translation.height > 150
    }
```

Update the `.simultaneousGesture(pullDownToDismiss)` attachment (`:134`) to `.simultaneousGesture(pullDownToPiP)`.

- [ ] **Step 4: Wire the representable's PiP closures**

Replace the placeholders added in Task 5 (`VideoPlayerView.swift:102-109`) with the real thing:

```swift
                PlayerViewController(
                    player: player,
                    attached: attached,
                    resumeAfterDetaching: resumeAfterDetaching,
                    revealControlsToken: revealControlsToken,
                    startPiPToken: startPiPToken,
                    onPlayerTap: { orientationControlVisibility.reveal() },
                    onSceneAvailable: { horizontalLock.beginPlayerSession(in: $0) },
                    onPiPStartFailed: {
                        // PiP is unavailable — behave exactly as this gesture
                        // did before it meant PiP.
                        dragOffset = 0
                        dismiss()
                    },
                    onPiPStarted: {
                        guard let player else { return }
                        handingOffToPiP = true
                        model.pip.didStart(player: player, queue: currentQueueSnapshot())
                        dismiss()
                    },
                    onPiPStopped: { model.pip.didStop() },
                    onPiPRestore: { model.pip.restore() }
                )
```

Add the snapshot helper next to `reportPosition()`:

```swift
    /// The queue as it stands right now, so PiP can rebuild this exact player
    /// — same items, same position — when its restore button is tapped.
    private func currentQueueSnapshot() -> PlaybackQueue {
        PlaybackQueue(
            video: video,
            queueSnapshot: videos,
            sleepMode: sleepAfterCurrent,
            startSecs: player?.currentTime().seconds ?? 0
        )
    }
```

`player?.currentTime().seconds` can be NaN before the first item loads; guard it:

```swift
            startSecs: (player?.currentTime().seconds).flatMap { $0.isFinite ? $0 : nil } ?? 0
```

- [ ] **Step 5: Re-present on restore**

In `ios/PatataTube/Sources/VideoGridView.swift`, in the existing `.onAppear` that starts `jobsStore` (`:420`), claim the restore hook:

```swift
            model.pip.onRestore = { restored in
                DevLog.event(.nav, "pip restore presenting", ["video_id": "\(restored.id)"])
                playing = restored
            }
```

This assigns on every grid appearance, which is correct: the most recently appeared grid is the one that should own the presentation, and `PiPCoordinator` holds a single closure, so no duplicates accumulate.

Take care with the re-presentation guard documented at `VideoGridView.swift:755` — the `.task` that restores a saved session re-runs on every cover dismissal and is gated by `restorationGate` for exactly this reason. Setting `playing` here is the same call `begin` makes (`:1030`), so it takes the identical path and needs no new gate.

- [ ] **Step 6: Verify it compiles**

```bash
cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube \
  -destination "platform=iOS Simulator,id=$(xcrun simctl list devices available | grep -m1 -o '[0-9A-F-]\{36\}')" \
  build-for-testing 2>&1 | tail -5
```

Expected: `** TEST BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add ios/PatataTube/Sources/VideoPlayerView.swift ios/PatataTube/Sources/VideoGridView.swift \
        ios/PatataTube/Tests/VideoPlayerPullDownTests.swift
git commit -m "feat(ios): pull down to send the video to Picture in Picture"
```

- [ ] **Step 8: Manual verification on a device or simulator**

The unit tests cover the pure decisions; none of them prove PiP works. Run the app and check, reading `log/ios.jsonl` alongside:

1. Pull down → floating window appears, grid returns, **video keeps playing**.
2. Tap the PiP window's restore button → full-screen player reopens at the same position.
3. Close the PiP window with its X → playback ends, no orphaned audio.
4. AVKit's own close control still dismisses the player, as before.
5. Background the app during PiP → the float keeps playing.
6. A Plex HLS item with a non-default audio or subtitle track → PiP keeps the chosen track.
7. Short pull (under 150pt) → springs back, nothing happens.
8. Horizontal drag → still scrubs.

```bash
grep -E '"(pull-down pip|pip started|pip restore|pip stopped|pip start)' log/ios.jsonl | tail -20
```

- [ ] **Step 9: Update CLAUDE.md**

The iOS section documents player behavior that this changes. Add to the iOS bullet list, after the "Resume positions live on the server" bullet:

```markdown
- **Pull down in the player sends the video to Picture in Picture**, it does
  not dismiss. `AVPlayerViewController` has no public API to start PiP, so
  `pictureInPictureButton(in:)` finds AVKit's own button and fires it —
  undocumented, and guarded by a canary test that reads a real controller's
  view tree. AVKit cannot dismiss our `fullScreenCover`, so the coordinator
  dismisses it from `didStartPictureInPicture`, and `VideoPlayerView`'s
  `TeardownPlan` skips the pause, the audio-session teardown and the
  now-playing detach that would otherwise kill the floating window.
  `PiPCoordinator` (on `AppModel`, like `restorationGate`) outlives the cover
  and re-presents the player on PiP's restore button. If PiP cannot start the
  gesture falls back to dismissing, which is what it always did.
```

```bash
git add CLAUDE.md && git commit -m "docs: describe pull-down-to-PiP in the iOS section"
```

---

## Self-Review

**Spec coverage:** Gesture behavior → Task 6. Starting PiP (`allowsPictureInPicturePlayback`, the finder) → Tasks 2 and 5. Surviving the cover dismissal (delegate, teardown table, coordinator) → Tasks 3, 4, 5. Restore and close → Tasks 4 and 6. The three fallback cases → unsupported and button-not-found in Task 5's `startPictureInPicture`, async failure via the delegate in Task 5, both routed to `onPiPStartFailed` → `dismiss()` in Task 6. Implementation order (spike first) → Task 1. Testing section → each task's test step, plus Task 6 Step 8's manual list.

**Placeholders:** One deliberate, unavoidable placeholder: `PictureInPictureButtonIdentifier`'s value in Task 2 Step 3, which cannot be known before Task 1 measures it. The plan says exactly where the value comes from and gives the image-comparison fallback if no identifier exists.

**Type consistency:** `pictureInPictureButton(in:)` (Task 2) is called in Task 5's `startPictureInPicture(in:)`. `TeardownPlan.plan(handingOffToPiP:)` (Task 3) is driven by the `handingOffToPiP` state set in Task 6. `PiPCoordinator.didStart(player:queue:)`/`restore()`/`didStop()` (Task 4) match the closures wired in Task 6 — `restore()` returns `Bool`, and `onPiPRestore: () -> Bool` feeds AVKit's completion handler in Task 5. `startPiPToken`/`lastPiPToken` are consistent across Tasks 5 and 6.
