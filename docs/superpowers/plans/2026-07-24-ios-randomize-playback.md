# Randomize Playback Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Randomize" toggle to the iOS app's overflow menu that makes "next video" (manual skip and autoplay-on-end) pick from a shuffled, no-immediate-repeat order per classification, instead of the fixed server order.

**Architecture:** A pure, unit-testable shuffle function (`shuffledPlaybackOrder`) lives in `PatataTubeKit`. `VideoPlayerView` (the App target, no test target — verify by build + manual test) owns the mutable cursor state (`playbackOrder`/`orderPosition`) and calls the pure function to build/grow the order. `AppModel` gets a per-classification `[String: Bool]` toggle state, surfaced via a new `Toggle` in `VideoGridView`'s existing overflow `Menu`.

**Tech Stack:** Swift 6, SwiftUI, XCTest (`PatataTubeKitTests`), SPM (`swift build`/`swift test` in `ios/PatataTubeKit`).

## Global Constraints

- Non-random behavior must be byte-for-byte unchanged (existing sequential `playableIndex` math untouched when `randomize == false`).
- Toggle state is per-classification, session-only (matches existing `autoplay`'s lifetime — a plain `@Published`, not persisted to `UserDefaults`/`AppStorage`).
- Shuffle position/order is not persisted across app relaunch — only the on/off toggle state is remembered (per the approved spec).
- Exhaustion + autoplay off → dismiss/stop exactly as today (no reshuffle-and-continue); this falls out for free because `bindPlayToEnd()` only calls `advance(by:)` when `playbackEndAction` returns `.advance`, which requires `autoplay == true`.
- Manual next (`nowPlaying.onNext`, the lock-screen/Control-Center "next" command — there is no in-app skip button) reshuffles-and-continues even when autoplay is off, since it always routes through `advance(by:)` directly.
- No changes to `PlaybackEndAction`/`playbackEndAction(...)` — its existing tests (`PlaybackEndActionTests.swift`) must keep passing unmodified.

---

### Task 1: Pure shuffle function in PatataTubeKit

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/PlaybackOrder.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/PlaybackOrderTests.swift`

**Interfaces:**
- Produces: `public func shuffledPlaybackOrder<G: RandomNumberGenerator>(count: Int, pinFirst: Int? = nil, avoidFirst: Int? = nil, using rng: inout G) -> [Int]` and a convenience `public func shuffledPlaybackOrder(count: Int, pinFirst: Int? = nil, avoidFirst: Int? = nil) -> [Int]` (uses `SystemRandomNumberGenerator` internally). Both return a permutation of `0..<count`.

- [ ] **Step 1: Write the failing tests**

```swift
// ios/PatataTubeKit/Tests/PatataTubeKitTests/PlaybackOrderTests.swift
import XCTest
@testable import PatataTubeKit

/// Deterministic RNG so shuffle tests aren't flaky: a tiny fixed-seed LCG.
private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

final class PlaybackOrderTests: XCTestCase {
    func testZeroCountReturnsEmpty() {
        var rng = SeededRNG(seed: 1)
        XCTAssertEqual(shuffledPlaybackOrder(count: 0, using: &rng), [])
    }

    func testSingleCountReturnsSingleElement() {
        var rng = SeededRNG(seed: 1)
        XCTAssertEqual(shuffledPlaybackOrder(count: 1, using: &rng), [0])
    }

    func testResultIsAlwaysAPermutationOfTheFullRange() {
        var rng = SeededRNG(seed: 42)
        let order = shuffledPlaybackOrder(count: 10, using: &rng)
        XCTAssertEqual(order.sorted(), Array(0..<10))
    }

    func testPinFirstForcesThatIndexToTheFront() {
        for seed: UInt64 in [1, 2, 3, 4, 5] {
            var rng = SeededRNG(seed: seed)
            let order = shuffledPlaybackOrder(count: 8, pinFirst: 5, using: &rng)
            XCTAssertEqual(order.first, 5)
            XCTAssertEqual(order.sorted(), Array(0..<8))
        }
    }

    func testAvoidFirstNeverLandsAtTheFrontWhenMoreThanOneElement() {
        for seed: UInt64 in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10] {
            var rng = SeededRNG(seed: seed)
            let order = shuffledPlaybackOrder(count: 6, avoidFirst: 3, using: &rng)
            XCTAssertNotEqual(order.first, 3)
            XCTAssertEqual(order.sorted(), Array(0..<6))
        }
    }

    func testAvoidFirstIsIgnoredWhenOnlyOneElement() {
        var rng = SeededRNG(seed: 1)
        XCTAssertEqual(shuffledPlaybackOrder(count: 1, avoidFirst: 0, using: &rng), [0])
    }

    func testPinFirstTakesPrecedenceOverAvoidFirst() {
        var rng = SeededRNG(seed: 1)
        let order = shuffledPlaybackOrder(count: 5, pinFirst: 2, avoidFirst: 2, using: &rng)
        XCTAssertEqual(order.first, 2)
    }

    func testConvenienceOverloadProducesAValidPermutation() {
        let order = shuffledPlaybackOrder(count: 7)
        XCTAssertEqual(order.sorted(), Array(0..<7))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios/PatataTubeKit && swift test --filter PlaybackOrderTests`
Expected: FAIL — `shuffledPlaybackOrder` not defined (compile error).

- [ ] **Step 3: Implement**

```swift
// ios/PatataTubeKit/Sources/PatataTubeKit/PlaybackOrder.swift
import Foundation

/// A permutation of `0..<count`, for `VideoPlayerView`'s randomize mode.
///
/// `pinFirst` forces that index to the front — used when building the
/// initial order so the tapped video plays first. `avoidFirst` prevents
/// that index from landing first — used when reshuffling after the
/// sequence is exhausted, so autoplay's loop never repeats the
/// just-finished video back-to-back. At most one of the two matters per
/// call (`pinFirst` wins if both are passed); neither applies when
/// `count <= 1`, since there is no alternative front position.
public func shuffledPlaybackOrder<G: RandomNumberGenerator>(
    count: Int,
    pinFirst: Int? = nil,
    avoidFirst: Int? = nil,
    using rng: inout G
) -> [Int] {
    guard count > 0 else { return [] }
    var order = Array(0..<count).shuffled(using: &rng)
    if let pinFirst, let at = order.firstIndex(of: pinFirst) {
        order.remove(at: at)
        order.insert(pinFirst, at: 0)
    } else if count > 1, let avoidFirst, order.first == avoidFirst {
        order.swapAt(0, 1)
    }
    return order
}

/// Convenience overload using the system RNG (production call sites).
public func shuffledPlaybackOrder(
    count: Int,
    pinFirst: Int? = nil,
    avoidFirst: Int? = nil
) -> [Int] {
    var rng = SystemRandomNumberGenerator()
    return shuffledPlaybackOrder(count: count, pinFirst: pinFirst, avoidFirst: avoidFirst, using: &rng)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios/PatataTubeKit && swift test --filter PlaybackOrderTests`
Expected: PASS (8 tests).

- [ ] **Step 5: Run the full Kit test suite to check for regressions**

Run: `cd ios/PatataTubeKit && swift test`
Expected: PASS, all existing suites (`PlaybackQueueTests`, `PlaybackEndActionTests`, etc.) unaffected.

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/PlaybackOrder.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/PlaybackOrderTests.swift
git commit -m "feat(ios): add pure shuffledPlaybackOrder for randomize mode"
```

---

### Task 2: Per-classification randomize toggle in the menu

**Files:**
- Modify: `ios/PatataTube/Sources/AppModel.swift` (near line 23, alongside `autoplay`)
- Modify: `ios/PatataTube/Sources/VideoGridView.swift` (menu block ~line 155-198; `play`/`startPlayback` ~line 241-283; `fullScreenCover` ~line 202-205)

**Interfaces:**
- Consumes: nothing new from Task 1 yet (this task is pure state/UI wiring).
- Produces: `AppModel.randomize(for classification: String?) -> Bool` and `AppModel.randomizeBinding(for classification: String?) -> Binding<Bool>`, consumed by Task 3's `VideoPlayerView(randomize:)` parameter.

No automated test target exists for the App target (per `ios/README.md`); this task is verified by a successful build and by the manual test checklist added in Task 3's Step 6.

- [ ] **Step 1: Add the per-classification state to `AppModel`**

Open `ios/PatataTube/Sources/AppModel.swift`. Immediately after the existing `autoplay` line:

```swift
    @Published var autoplay: Bool = false
```

add:

```swift
    /// Keyed by classification (`store.filter`, `"all"` for the unfiltered
    /// tab). Session-only, same lifetime as `autoplay` — not persisted
    /// across relaunch.
    @Published var randomizeByClassification: [String: Bool] = [:]

    func randomize(for classification: String?) -> Bool {
        randomizeByClassification[classification ?? "all"] ?? false
    }

    func randomizeBinding(for classification: String?) -> Binding<Bool> {
        Binding(
            get: { self.randomize(for: classification) },
            set: { self.randomizeByClassification[classification ?? "all"] = $0 }
        )
    }
```

`AppModel.swift` already `import SwiftUI` (required for `@Published`/`ObservableObject`); confirm `Binding` resolves — it's part of SwiftUI, no new import needed.

- [ ] **Step 2: Add the toggle to the overflow menu**

In `ios/PatataTube/Sources/VideoGridView.swift`, inside the `Menu { ... }` block, immediately after the existing Autoplay toggle:

```swift
                        Toggle(isOn: $model.autoplay) {
                            Label("Autoplay", systemImage: "play.circle")
                        }
```

add:

```swift
                        Toggle(isOn: model.randomizeBinding(for: store.filter)) {
                            Label("Randomize", systemImage: "shuffle")
                        }
```

The toggle is now live in the menu and its state is readable via
`model.randomize(for: store.filter)`, but nothing consumes it yet — that
wiring (`VideoPlayerView`'s new `randomize:` init parameter and the
`fullScreenCover` call site) happens in Task 3, once the parameter exists
to pass it to. This task's build must succeed on its own before moving on.

- [ ] **Step 3: Build**

Run: `cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS Simulator' build`
Expected: `** BUILD SUCCEEDED **`. If `xcodebuild` isn't set up for this environment, open the project in Xcode (`open PatataTube.xcodeproj`) and build with Cmd+B instead.

- [ ] **Step 4: Commit**

```bash
git add ios/PatataTube/Sources/AppModel.swift ios/PatataTube/Sources/VideoGridView.swift
git commit -m "feat(ios): add per-classification randomize toggle to overflow menu"
```

---

### Task 3: Wire randomize into VideoPlayerView's advance logic

**Files:**
- Modify: `ios/PatataTube/Sources/VideoPlayerView.swift`
- Modify: `ios/README.md` (manual test checklist)

**Interfaces:**
- Consumes: `shuffledPlaybackOrder(count:pinFirst:avoidFirst:)` from Task 1; `AppModel.randomize(for:)` indirectly via the new `randomize` init parameter wired in Task 2, Step 3.
- Produces: `VideoPlayerView.init(videos:startIndex:sleepMode:randomize:)` (Task 2's call site already expects this signature).

No automated test target exists for `VideoPlayerView`'s SwiftUI/AVKit code (per `ios/README.md` — "no automated iOS test target exists yet"); this task is TDD'd at the pure-function boundary (Task 1) and verified here by build + manual walkthrough.

- [ ] **Step 1: Add `randomize` to the view's state**

In `ios/PatataTube/Sources/VideoPlayerView.swift`, the struct's stored properties (~line 7-22) currently start:

```swift
struct VideoPlayerView: View {
    let videos: [Video]
    let startIndex: Int
    /// Play-and-sleep: play only this item, then black out so the device can lock.
    let sleepMode: Bool
    @State private var currentIndex: Int
    @StateObject private var orientationLock: OrientationLockCoordinator
    @StateObject private var orientationControlVisibility = OrientationControlVisibility()

    init(videos: [Video], startIndex: Int, sleepMode: Bool = false) {
        self.videos = videos
        self.startIndex = startIndex
        self.sleepMode = sleepMode
        _currentIndex = State(initialValue: startIndex)
        _orientationLock = StateObject(wrappedValue: OrientationLockCoordinator())
    }
```

Replace with:

```swift
struct VideoPlayerView: View {
    let videos: [Video]
    let startIndex: Int
    /// Play-and-sleep: play only this item, then black out so the device can lock.
    let sleepMode: Bool
    /// When true, "next" (manual skip and autoplay-on-end) draws from a
    /// shuffled, no-immediate-repeat order instead of the sequential list.
    let randomize: Bool
    @State private var currentIndex: Int
    /// Random-mode only: cursor state over a shuffled permutation of
    /// `videos.indices`, grown with a fresh shuffle whenever it's exhausted
    /// going forward. Unused (stays empty) when `randomize` is false.
    @State private var playbackOrder: [Int] = []
    @State private var orderPosition: Int = 0
    @StateObject private var orientationLock: OrientationLockCoordinator
    @StateObject private var orientationControlVisibility = OrientationControlVisibility()

    init(videos: [Video], startIndex: Int, sleepMode: Bool = false, randomize: Bool = false) {
        self.videos = videos
        self.startIndex = startIndex
        self.sleepMode = sleepMode
        self.randomize = randomize
        _currentIndex = State(initialValue: startIndex)
        _orientationLock = StateObject(wrappedValue: OrientationLockCoordinator())
    }
```

- [ ] **Step 2: Wire the call site in `VideoGridView`**

In `ios/PatataTube/Sources/VideoGridView.swift`, the `fullScreenCover` (~line 202-205) currently reads:

```swift
            .fullScreenCover(item: $playing) { request in
                VideoPlayerView(videos: request.videos, startIndex: request.startIndex,
                                sleepMode: request.sleepMode)
            }
```

Change to:

```swift
            .fullScreenCover(item: $playing) { request in
                VideoPlayerView(videos: request.videos, startIndex: request.startIndex,
                                sleepMode: request.sleepMode, randomize: model.randomize(for: store.filter))
            }
```

- [ ] **Step 3: Import PatataTubeKit's shuffle function and seed the order in `setup()`**

The file already has `import PatataTubeKit` (line 4). In `setup()` (~line 141-161), immediately after the existing `guard videos.indices.contains(currentIndex) else { dismiss(); return }` guard:

```swift
    private func setup() async {
        // Defensive: a malformed presentation must dismiss, not trap on videos[currentIndex].
        guard videos.indices.contains(currentIndex) else {
            dismiss()
            return
        }
```

add, right after that guard block:

```swift
        if randomize {
            playbackOrder = shuffledPlaybackOrder(count: videos.count, pinFirst: currentIndex)
            orderPosition = 0
        }
```

- [ ] **Step 4: Add the random-mode step helper and a playability check**

Immediately after `playableIndex(from:direction:)` (~line 253-261):

```swift
    /// Nearest queue index in `direction` with a playable source, or nil.
    private func playableIndex(from index: Int, direction: Int) -> Int? {
        var i = index + direction
        while videos.indices.contains(i) {
            if playerItem(for: videos[i]) != nil { return i }
            i += direction
        }
        return nil
    }
```

add:

```swift
    /// Whether at least one video in the queue currently has a playable
    /// source — used to decide the lock-screen "next" enabled state in
    /// random mode, where a literal end-of-list peek doesn't apply (the
    /// order reshuffles forever).
    private var hasAnyPlayableVideo: Bool {
        videos.contains { playerItem(for: $0) != nil }
    }

    /// Random-mode step: walks `playbackOrder`'s cursor in `direction`,
    /// skipping unplayable entries, growing the order with a fresh reshuffle
    /// (excluding the wrap point, so autoplay's loop never repeats a video
    /// back-to-back) whenever a forward step runs off the end. Returns the
    /// resulting `videos` index, or nil if nothing playable was found — a
    /// bounded attempt count guards against spinning forever when nothing
    /// in the queue is playable. Advancing forward commits the step (mutates
    /// `orderPosition`/`playbackOrder`); this must only be called when the
    /// caller intends to actually move, never as a peek.
    private func randomStep(direction: Int) -> Int? {
        guard !videos.isEmpty else { return nil }
        if direction > 0 {
            var position = orderPosition
            var attempts = 0
            while attempts < videos.count * 2 {
                let nextPosition = position + 1
                if nextPosition >= playbackOrder.count {
                    playbackOrder += shuffledPlaybackOrder(count: videos.count, avoidFirst: playbackOrder.last)
                }
                position = nextPosition
                let candidate = playbackOrder[position]
                if playerItem(for: videos[candidate]) != nil {
                    orderPosition = position
                    return candidate
                }
                attempts += 1
            }
            return nil
        } else {
            var position = orderPosition
            while position > 0 {
                position -= 1
                let candidate = playbackOrder[position]
                if playerItem(for: videos[candidate]) != nil {
                    orderPosition = position
                    return candidate
                }
            }
            return nil
        }
    }
```

- [ ] **Step 5: Branch `advance(by:)`, `handlePrevious()`, and the two `setNextEnabled` call sites on `randomize`**

Current `advance(by:)` (~line 263-280):

```swift
    /// Switch to the nearest playable video in `direction`; stop at queue ends.
    private func advance(by direction: Int) {
        guard let player else { return }
        guard let nextIndex = playableIndex(from: currentIndex, direction: direction),
              let item = playerItem(for: videos[nextIndex]) else {
            player.pause()
            if UIApplication.shared.applicationState == .active { dismiss() }
            return
        }
        currentIndex = nextIndex
        player.replaceCurrentItem(with: item)
        Task { await applyAudioSelection(item: item, lang: videos[nextIndex].audioLang) }
        bindPlayToEnd()
        playWhenReady(item: item, on: player)
        nowPlaying.updateTitle(title(of: video))
        nowPlaying.setNextEnabled(playableIndex(from: currentIndex, direction: 1) != nil)
        Task { await loadArtwork(for: player) }
    }
```

Replace with:

```swift
    /// Switch to the nearest playable video in `direction`; stop at queue
    /// ends (sequential mode) or when nothing playable remains at all
    /// (random mode — otherwise it loops forever via reshuffling).
    private func advance(by direction: Int) {
        guard let player else { return }
        let nextIndex = randomize
            ? randomStep(direction: direction)
            : playableIndex(from: currentIndex, direction: direction)
        guard let nextIndex, let item = playerItem(for: videos[nextIndex]) else {
            player.pause()
            if UIApplication.shared.applicationState == .active { dismiss() }
            return
        }
        currentIndex = nextIndex
        player.replaceCurrentItem(with: item)
        Task { await applyAudioSelection(item: item, lang: videos[nextIndex].audioLang) }
        bindPlayToEnd()
        playWhenReady(item: item, on: player)
        nowPlaying.updateTitle(title(of: video))
        nowPlaying.setNextEnabled(randomize ? hasAnyPlayableVideo : playableIndex(from: currentIndex, direction: 1) != nil)
        Task { await loadArtwork(for: player) }
    }
```

Current `handlePrevious()` (~line 284-291):

```swift
    /// iOS convention: >3s in (or already at the queue start) restarts the
    /// current video; otherwise go back one video.
    private func handlePrevious() {
        guard let player else { return }
        if player.currentTime().seconds > 3 || playableIndex(from: currentIndex, direction: -1) == nil {
            player.seek(to: .zero)
        } else {
            advance(by: -1)
        }
    }
```

Replace with:

```swift
    /// iOS convention: >3s in (or already at the queue start) restarts the
    /// current video; otherwise go back one video. In random mode "queue
    /// start" means the cursor is at position 0 of `playbackOrder`.
    private func handlePrevious() {
        guard let player else { return }
        let atQueueStart = randomize ? orderPosition == 0 : playableIndex(from: currentIndex, direction: -1) == nil
        if player.currentTime().seconds > 3 || atQueueStart {
            player.seek(to: .zero)
        } else {
            advance(by: -1)
        }
    }
```

Current `setup()`'s `setNextEnabled` call (~line 158):

```swift
        nowPlaying.setNextEnabled(playableIndex(from: currentIndex, direction: 1) != nil)
```

Replace with:

```swift
        nowPlaying.setNextEnabled(randomize ? hasAnyPlayableVideo : playableIndex(from: currentIndex, direction: 1) != nil)
```

- [ ] **Step 6: Build**

Run: `cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS Simulator' build`
Expected: `** BUILD SUCCEEDED **`. If `xcodebuild` isn't set up for this environment, open the project in Xcode (`open PatataTube.xcodeproj`) and build with Cmd+B instead — either way, confirm zero errors before continuing.

- [ ] **Step 7: Manual test checklist**

Add to `ios/README.md`'s "### Playback" section, after the existing autoplay/dismiss bullet:

```markdown
- Randomize toggle (overflow menu) — per classification tab, works with or without autoplay: "next" (Control Center) and autoplay-on-end pick from a shuffled order instead of the fixed list; the same video doesn't repeat back-to-back when the shuffle loops; toggling it off on a tab reverts that tab's "next" to sequential order immediately (state remembered per tab while the app stays open)
```

Then manually verify on-device or in Simulator:
1. Open a classification tab with several videos, enable Randomize in the overflow menu.
2. Play a video, let it finish with autoplay on — confirm the next video is not necessarily the adjacent one in the grid, and isn't the same video that just finished.
3. Let autoplay loop through the whole tab's videos (or use Control Center's "next" repeatedly) — confirm it keeps going past the end of the list (reshuffles) instead of dismissing.
4. Turn autoplay off, let a video finish with Randomize still on — confirm it dismisses/stops (does not auto-continue), matching non-random behavior.
5. With autoplay off, use Control Center's "next" — confirm it still jumps to a random next video (manual skip works regardless of autoplay).
6. Switch to a different classification tab — confirm its Randomize toggle is independent (e.g. off there while on in the first tab).
7. Turn Randomize off on a tab already mid-playback in a fresh player session — confirm next open of the player uses sequential order again.

- [ ] **Step 8: Commit**

```bash
git add ios/PatataTube/Sources/VideoPlayerView.swift ios/README.md
git commit -m "feat(ios): randomize advance order in VideoPlayerView"
```
