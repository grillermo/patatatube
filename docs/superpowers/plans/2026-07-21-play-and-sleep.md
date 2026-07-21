# Play-and-Sleep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Children's videos get a bottom-right corner play+moon button that plays just that video and shows an undismissable-by-toddler black "sleep" overlay when it ends, letting the iPad auto-lock.

**Architecture:** A `sleepMode` flag originates at a new triangular corner button on `VideoCell` (children's videos only), travels through `VideoGridView.play` → `PlaybackQueue` → `VideoPlayerView`. `playbackEndAction` in PatataTubeKit gains a `sleepMode` parameter and a `.sleep` case; on `.sleep` the player pauses and shows a full-screen black overlay dismissed only by a 3-second long-press. Once playback pauses, AVPlayer stops holding the display awake, so the iPad locks after the system auto-lock interval.

**Tech Stack:** Swift / SwiftUI / AVKit. Logic in the SwiftPM package `ios/PatataTubeKit` (tested with `swift test`); UI in the XcodeGen app `ios/PatataTube` (no automated test target — build + manual checklist).

## Global Constraints

- Sleep mode ignores the autoplay setting entirely: `.sleep` wins over `.advance`.
- The corner button renders only when `video.classification == "children"` and `video.status == "done"`.
- The sleep overlay ignores taps; only a 3-second long-press dismisses it (returns to grid).
- Existing behavior for normal play (tap anywhere else on the cell) must not change.
- Kit changes must keep `swift build` and `swift test` green in `ios/PatataTubeKit`.
- App file style: follow existing comment density and patterns in `ios/PatataTube/Sources/`.

---

### Task 1: PatataTubeKit — `.sleep` case in `playbackEndAction`

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/PlaybackEndAction.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/PlaybackEndActionTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `PlaybackEndAction.sleep` case; new signature `public func playbackEndAction(autoplay: Bool, isForeground: Bool, sleepMode: Bool = false) -> PlaybackEndAction`. The default `sleepMode: Bool = false` keeps every existing call site compiling unchanged. Task 4 calls it with `sleepMode:`.

- [ ] **Step 1: Write the failing tests**

Append to `ios/PatataTubeKit/Tests/PatataTubeKitTests/PlaybackEndActionTests.swift`, inside the existing `PlaybackEndActionTests` class:

```swift
    func testSleepModeWinsOverAutoplay() {
        XCTAssertEqual(playbackEndAction(autoplay: true, isForeground: true, sleepMode: true), .sleep)
    }

    func testSleepModeWinsWhenBackgrounded() {
        XCTAssertEqual(playbackEndAction(autoplay: false, isForeground: false, sleepMode: true), .sleep)
    }

    func testSleepModeOffKeepsExistingBehavior() {
        XCTAssertEqual(playbackEndAction(autoplay: false, isForeground: true, sleepMode: false), .dismiss)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios/PatataTubeKit && swift test --filter PlaybackEndActionTests`
Expected: compile FAILURE — `extra argument 'sleepMode' in call` / no `.sleep` member.

- [ ] **Step 3: Implement**

Replace the contents of `ios/PatataTubeKit/Sources/PatataTubeKit/PlaybackEndAction.swift` with:

```swift
import Foundation

/// What the player does when the current item plays to the end.
public enum PlaybackEndAction: Equatable, Sendable {
    /// Play the next playable video in the queue.
    case advance
    /// Close the player.
    case dismiss
    /// Pause and leave the player mounted (nothing dismisses while backgrounded).
    case stop
    /// Pause and show the black sleep overlay so the device can auto-lock.
    case sleep
}

/// Sleep mode overrides everything: the whole point is that playback ends there.
/// Otherwise the autoplay flag governs both foreground and background: with
/// autoplay on a finished video always rolls into the next one; with it off
/// playback ends where it is — dismissing when the user is looking, pausing
/// when they are not.
public func playbackEndAction(autoplay: Bool, isForeground: Bool, sleepMode: Bool = false) -> PlaybackEndAction {
    if sleepMode { return .sleep }
    if autoplay { return .advance }
    return isForeground ? .dismiss : .stop
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios/PatataTubeKit && swift test --filter PlaybackEndActionTests`
Expected: PASS, 7 tests (4 existing + 3 new).

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/PlaybackEndAction.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/PlaybackEndActionTests.swift
git commit -m "feat(ios): add .sleep playback end action for play-and-sleep mode"
```

---

### Task 2: PatataTubeKit — `sleepMode` on `PlaybackQueue`

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/PlaybackQueue.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/PlaybackQueueTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `public let sleepMode: Bool` on `PlaybackQueue`; init becomes `public init(video: Video, queueSnapshot: [Video], sleepMode: Bool = false)`. Default keeps existing call sites compiling. Tasks 3–4 construct it with `sleepMode: true` and read `request.sleepMode`.

- [ ] **Step 1: Write the failing test**

Append to `ios/PatataTubeKit/Tests/PatataTubeKitTests/PlaybackQueueTests.swift`, inside the existing `PlaybackQueueTests` class (it already has a private `video(id:title:)` fixture helper — use it):

```swift
    func testSleepModeDefaultsFalseAndIsCarried() {
        let tapped = video(id: 4)
        XCTAssertFalse(PlaybackQueue(video: tapped, queueSnapshot: []).sleepMode)
        XCTAssertTrue(PlaybackQueue(video: tapped, queueSnapshot: [], sleepMode: true).sleepMode)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter PlaybackQueueTests`
Expected: compile FAILURE — `extra argument 'sleepMode'` / no member `sleepMode`.

- [ ] **Step 3: Implement**

In `ios/PatataTubeKit/Sources/PatataTubeKit/PlaybackQueue.swift`:

Add the stored property after `public let startIndex: Int`:

```swift
    /// When true the player plays only this item and ends in the sleep overlay.
    public let sleepMode: Bool
```

Change the init signature and add the assignment as the first line of the body:

```swift
    public init(video: Video, queueSnapshot: [Video], sleepMode: Bool = false) {
        self.sleepMode = sleepMode
```

(rest of the init body unchanged).

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios/PatataTubeKit && swift test`
Expected: PASS, full suite green.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/PlaybackQueue.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/PlaybackQueueTests.swift
git commit -m "feat(ios): carry sleepMode on PlaybackQueue"
```

---

### Task 3: App — corner play+moon button on `VideoCell`, wired through `VideoGridView.play`

**Files:**
- Modify: `ios/PatataTube/Sources/VideoCell.swift`
- Modify: `ios/PatataTube/Sources/VideoGridView.swift` (the `VideoCell(...)` call around line 90, and `play`/`startPlayback` around lines 219–254)

**Interfaces:**
- Consumes: `PlaybackQueue(video:queueSnapshot:sleepMode:)` from Task 2.
- Produces: `VideoCell` gains `let onPlaySleep: () -> Void` (declared directly after `let onPlay: () -> Void`). `VideoGridView` gains `sleepMode: Bool = false` parameters on `play(_:)`, `play(_:queueSnapshot:)`, and `startPlayback(_:queueSnapshot:)`. Task 4 reads `request.sleepMode` from the `playing` state these produce.

- [ ] **Step 1: Add the triangle shape and corner button to `VideoCell.swift`**

Add at the bottom of the file (after `VideoInfoView`):

```swift
/// Right triangle filling the bottom-right half of its frame — both the visual
/// wedge and the hit area of the play-and-sleep corner button.
struct BottomRightTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
```

In the `VideoCell` struct:

Add the callback after `let onPlay: () -> Void`:

```swift
    /// Children-only corner button: play this one video, then sleep-lock.
    let onPlaySleep: () -> Void
```

Add a computed property next to `isPoster`:

```swift
    /// Play-and-sleep only makes sense on playable children's videos.
    private var showsSleepButton: Bool {
        video.classification == "children" && video.status == "done"
    }
```

Attach the corner button as an overlay on the thumbnail `Button` — i.e. on the `Button(action: onPlay) { ... }.buttonStyle(.plain)` chain, after `.buttonStyle(.plain)`:

```swift
            .overlay(alignment: .bottomTrailing) {
                if showsSleepButton {
                    Button(action: onPlaySleep) {
                        ZStack(alignment: .bottomTrailing) {
                            BottomRightTriangle().fill(.black.opacity(0.55))
                            HStack(spacing: 2) {
                                Image(systemName: "play.fill")
                                Image(systemName: "moon.fill")
                            }
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.trailing, 8)
                            .padding(.bottom, 6)
                        }
                        .frame(width: 64, height: 64)
                        .contentShape(BottomRightTriangle())
                    }
                    .buttonStyle(.plain)
                }
            }
```

(The inner `Button` sits above the outer play button, so taps inside the triangle go to play-and-sleep and taps anywhere else on the thumbnail keep playing normally. `contentShape(BottomRightTriangle())` limits the hit area to the wedge itself.)

- [ ] **Step 2: Thread `sleepMode` through `VideoGridView`**

In `ios/PatataTube/Sources/VideoGridView.swift`, change the three private funcs (currently around lines 219–254):

```swift
    private func play(_ video: Video, sleepMode: Bool = false) {
        let queueSnapshot = filteredVideos
        play(video, queueSnapshot: queueSnapshot, sleepMode: sleepMode)
    }

    private func play(_ video: Video, queueSnapshot: [Video], sleepMode: Bool = false) {
        // Already downloaded to device: play the local file directly, no network.
        // ensureReady() would hit /prepare and fail offline (-1009) even though
        // the cached MP4 is ready to play. VideoPlayerView plays from cache too.
        if model.cache.state(for: video.id, versionId: video.chosenVersionId) == .cached {
            startPlayback(video, queueSnapshot: queueSnapshot, sleepMode: sleepMode)
            return
        }
        guard video.isLibrary, video.status != "done" else {
            startPlayback(video, queueSnapshot: queueSnapshot, sleepMode: sleepMode)
            return
        }
        preparing = true
        Task {
            defer { preparing = false }
            do {
                startPlayback(
                    try await store.ensureReady(id: video.id),
                    queueSnapshot: queueSnapshot,
                    sleepMode: sleepMode
                )
            } catch {
                store.errorText = String(describing: error)
            }
        }
    }

    /// Starts playback from the tap-time queue snapshot. `video` may be the
    /// ensureReady-updated copy, so it replaces its stale row in the snapshot.
    private func startPlayback(_ video: Video, queueSnapshot: [Video], sleepMode: Bool = false) {
        playing = PlaybackQueue(video: video, queueSnapshot: queueSnapshot, sleepMode: sleepMode)
    }
```

In the `VideoCell(...)` construction (around line 90), add directly after `onPlay: { play(video) },`:

```swift
                                onPlaySleep: { play(video, sleepMode: true) },
```

- [ ] **Step 3: Build the app to verify it compiles**

Run:
```bash
cd ios/PatataTube && xcodegen generate && xcodebuild build -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS Simulator' -quiet
```
(If the scheme name differs, list schemes with `xcodebuild -list -project PatataTube.xcodeproj` and use the app scheme.)
Expected: `BUILD SUCCEEDED`. Note: `ShowsView`/`MovieDetailView` call `play($0)` / `play(video, queueSnapshot:)` without `sleepMode` — the defaulted parameter keeps them compiling.

- [ ] **Step 4: Commit**

```bash
git add ios/PatataTube/Sources/VideoCell.swift ios/PatataTube/Sources/VideoGridView.swift
git commit -m "feat(ios): play-and-sleep corner button on children's video cells"
```

---

### Task 4: App — sleep overlay in `VideoPlayerView`

**Files:**
- Modify: `ios/PatataTube/Sources/VideoPlayerView.swift`
- Modify: `ios/PatataTube/Sources/VideoGridView.swift` (the `fullScreenCover` around line 170)

**Interfaces:**
- Consumes: `PlaybackEndAction.sleep` and `playbackEndAction(autoplay:isForeground:sleepMode:)` from Task 1; `PlaybackQueue.sleepMode` from Task 2.
- Produces: `VideoPlayerView.init(videos:startIndex:sleepMode:)` with `sleepMode` defaulting to `false`.

- [ ] **Step 1: Add `sleepMode` to `VideoPlayerView`**

In `ios/PatataTube/Sources/VideoPlayerView.swift`:

Add a stored property after `let startIndex: Int` and extend the init:

```swift
    /// Play-and-sleep: play only this item, then black out so the device can lock.
    let sleepMode: Bool
```

```swift
    init(videos: [Video], startIndex: Int, sleepMode: Bool = false) {
        self.videos = videos
        self.startIndex = startIndex
        self.sleepMode = sleepMode
        _currentIndex = State(initialValue: startIndex)
    }
```

Add state next to the other `@State` vars:

```swift
    /// Set when sleep-mode playback finishes; only a 3s long-press clears it.
    @State private var showingSleepOverlay = false
```

- [ ] **Step 2: Handle `.sleep` at end of playback**

In `bindPlayToEnd()`, pass the flag and add the case:

```swift
                switch playbackEndAction(
                    autoplay: model.autoplay,
                    isForeground: UIApplication.shared.applicationState == .active,
                    sleepMode: sleepMode
                ) {
                case .advance:
                    advance(by: 1)
                case .dismiss:
                    dismiss()
                case .stop:
                    player?.pause()
                case .sleep:
                    player?.pause()
                    showingSleepOverlay = true
                }
```

- [ ] **Step 3: Render the overlay and block the dismiss gesture**

In `body`, add the overlay as the last child of the outer `ZStack` (after the `if let player { ... } else { ... }` block) so it covers the AVKit controls:

```swift
            if showingSleepOverlay {
                // Sleep overlay: swallow every touch so a child can't tap back
                // into the app; a paused player releases the idle timer, so the
                // device auto-locks on the system schedule. Parents escape with
                // a 3-second long-press.
                Color.black.ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onLongPressGesture(minimumDuration: 3) { dismiss() }
            }
```

In `pullDownToDismiss`'s `.onChanged`, add the guard so a drag can't reveal the player behind the overlay:

```swift
                guard !showingSleepOverlay else { return }
```

(first line of the closure, before the existing translation logic) — and the same guard as the first line of `.onEnded`.

- [ ] **Step 4: Pass the flag from the cover**

In `ios/PatataTube/Sources/VideoGridView.swift`, change the `fullScreenCover`:

```swift
            .fullScreenCover(item: $playing) { request in
                VideoPlayerView(videos: request.videos, startIndex: request.startIndex,
                                sleepMode: request.sleepMode)
            }
```

- [ ] **Step 5: Build**

Run:
```bash
cd ios/PatataTube && xcodegen generate && xcodebuild build -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS Simulator' -quiet
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTube/Sources/VideoPlayerView.swift ios/PatataTube/Sources/VideoGridView.swift
git commit -m "feat(ios): sleep overlay when play-and-sleep video ends"
```

---

### Task 5: Manual verification on device/simulator

No automated iOS UI tests exist (see `ios/README.md`). Verify by hand:

- [ ] **Step 1: Run the app in an iPad simulator (or device) against the server**

Checklist:
1. Grid: children's videos with status `done` show the dark bottom-right wedge with play+moon; adults/education/tv/movies cells and non-`done` children's rows do not.
2. Tap the wedge → video plays full screen. Tap elsewhere on the thumbnail → normal playback (autoplay behavior unchanged).
3. With autoplay ON, let a play-and-sleep video finish → screen goes black, no next video starts.
4. On the black overlay: single taps and swipes do nothing (no player controls appear, pull-down doesn't dismiss).
5. Press and hold ~3s anywhere on the black overlay → returns to the grid.
6. (Device only) Leave the overlay untouched → device auto-locks after the system auto-lock interval.

- [ ] **Step 2: Update `ios/README.md` manual test checklist**

Append the play-and-sleep items above to the existing manual test checklist section in `ios/README.md`, matching its formatting.

- [ ] **Step 3: Commit**

```bash
git add ios/README.md
git commit -m "docs(ios): add play-and-sleep manual test checklist"
```
