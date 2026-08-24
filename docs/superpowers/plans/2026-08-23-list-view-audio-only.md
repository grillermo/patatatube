# List-View Audio-Only Playback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In the pushed group-detail screen in list mode, tapping a row plays that video's audio only — no full-screen player — with autoplay, randomize, lock-screen controls, and a play/pause overlay on the row's thumbnail.

**Architecture:** The queue rules and the player-item source chain currently live as private methods inside `VideoPlayerView` (a SwiftUI view, so it dies with its presentation). Tasks 1–3 extract them: `QueueNavigator` into PatataTubeKit (pure, testable) and `PlaybackSource` into its own app-target file. Tasks 4–6 build `AudioQueuePlayer` — one `AVPlayer`, no `AVPlayerViewController` — owned by `AppModel` so playback survives navigation, and wire it to `VideoRow`.

**Tech Stack:** Swift 6 (`swift-tools-version: 6.0`, iOS 18+), SwiftUI, AVFoundation/AVKit, MediaPlayer (`MPNowPlayingInfoCenter`), XCTest (PatataTubeKit), swift-testing + ViewInspector (app target), XcodeGen.

**Spec:** `docs/superpowers/specs/2026-08-23-list-view-audio-only-design.md`

## Global Constraints

- **Audio mode is enabled only when `currentGroupID != nil && displayMode == .list`.** Movies list, TV episodes list, and the all-videos feed keep the full-screen player.
- **No resume positions in audio mode:** always start at 0, never call `model.positions`, never show the resume alert.
- **No video escape hatch from list mode.** "Play and sleep" becomes audio-only too.
- **One audio source at a time:** every `fullScreenCover` player presentation calls `model.audio.stop()` first.
- **Nothing in downloads, `StreamProxy`, HLS packaging, or the server changes.**
- **Autoplay/randomize come from the existing per-scope settings** — `model.autoplay(for: scope)` / `model.randomize(for: scope)`, read at fire time, never captured in a closure.
- **Test authorization for this run (granted 2026-08-23, supersedes `CLAUDE.md`'s
  "never run iOS tests unasked" for this plan only):** the user authorized ~6
  hours of unattended work and asked not to be consulted. Therefore:
  - `swift test --filter <Suite>` (PatataTubeKit) freely, per step.
  - The **simulator run** (`xcodebuild ... test`) exactly twice by plan: after
    the big refactor (Task 3, Milestone 1) and as the last testing step
    (Task 6, Milestone 2). **Re-run it as many times as needed** while fixing
    problems found at those two points — that is explicitly authorized.
  - Never the full app-target suite unfiltered; always
    `-skip-testing:PatataTubeTests/EpisodesDownloadAllViewTests` (that suite
    hangs under filtering — see `CLAUDE.md`).
  - **Do not stop to ask questions.** Make the call, note the decision in the
    commit message, and keep going. Leave anything genuinely undecidable for
    the final report rather than blocking on it.
- **New app-target files must be picked up by XcodeGen.** `ios/PatataTube/project.yml` globs `Sources/`, so no project.yml edit is needed, but `xcodegen generate` must be re-run before an Xcode build.
- **DevLog only:** never `print`. `DevLog.event` / `DevLog.error`, ids and statuses only — never tokens or response bodies.

## File Structure

| File | Responsibility |
|---|---|
| `ios/PatataTubeKit/Sources/PatataTubeKit/QueueNavigator.swift` | **Create.** Pure queue stepping: sequential and random, playable-only pool, cursor state. |
| `ios/PatataTubeKit/Tests/PatataTubeKitTests/QueueNavigatorTests.swift` | **Create.** Unit tests for the above. |
| `ios/PatataTube/Sources/PlaybackSource.swift` | **Create.** The `AVPlayerItem` source-selection chain, moved verbatim out of `VideoPlayerView`. |
| `ios/PatataTube/Sources/AudioQueuePlayer.swift` | **Create.** Headless queue player: one `AVPlayer`, `QueueNavigator`, `NowPlayingManager`, audio session. |
| `ios/PatataTube/Sources/RowAudioState.swift` | **Create.** Four-state enum describing one row's audio status. |
| `ios/PatataTube/Sources/VideoPlayerView.swift` | **Modify.** Delete the extracted methods; call `QueueNavigator` and `PlaybackSource`. No behavior change. |
| `ios/PatataTube/Sources/VideoRow.swift` | **Modify.** `audioState` parameter, thumbnail overlay, tap semantics. |
| `ios/PatataTube/Sources/VideoGridView.swift` | **Modify.** Audio-mode gate in `defaultGrid`, `stop()` before covers, sleep routing. |
| `ios/PatataTube/Sources/AppModel.swift` | **Modify.** `let audio = AudioQueuePlayer()`. |
| `ios/PatataTube/Sources/PatataTubeApp.swift` | **Modify.** Inject `model.audio` as its own environment object. |
| `ios/PatataTube/Tests/VideoRowAudioTests.swift` | **Create.** Overlay states and tap-toggle. |
| `CLAUDE.md` | **Modify.** Document the audio-only path in the iOS section. |

---

### Task 1: `QueueNavigator` in PatataTubeKit

Pure extraction target. Owns what `VideoPlayerView` today implements as `playableIndex`, `hasAnyPlayableVideo`, `playableVideoIndices`, `randomStep`, and the `playbackOrder`/`orderPosition` cursor. Nothing here imports AVFoundation — playability arrives as an injected closure, which is exactly what makes it testable.

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/QueueNavigator.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/QueueNavigatorTests.swift`

**Interfaces:**
- Consumes: `Video`, `shuffledPlaybackOrder(count:pinFirst:avoidFirst:using:)` from `PlaybackOrder.swift` (both already in the kit).
- Produces:
  ```swift
  public struct QueueNavigator {
      public init(videos: [Video], startIndex: Int, randomize: Bool,
                  isPlayable: @escaping (Video) -> Bool)
      public var currentIndex: Int { get }          // private(set)
      public var currentVideo: Video? { get }
      public var hasAnyPlayable: Bool { get }
      public var isAtQueueStart: Bool { get }
      public mutating func step(direction: Int) -> Int?   // commits; nil = nothing playable
      public mutating func peekHasNext() -> Bool          // does NOT commit
  }
  ```

- [ ] **Step 1: Write the failing test**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/QueueNavigatorTests.swift`:

```swift
import XCTest
@testable import PatataTubeKit

final class QueueNavigatorTests: XCTestCase {
    private func video(id: Int) -> Video {
        Video(id: id, url: "https://example.com/\(id)", title: "Video \(id)", platform: nil,
              sourceKey: nil, previewUrl: nil, groupID: 1, plexKind: nil,
              position: nil, status: "done", errorMsg: nil, streamPath: "/videos/\(id)/stream")
    }

    /// Playable-only pool: ids listed in `unplayable` report false.
    private func navigator(ids: [Int], startIndex: Int, randomize: Bool,
                           unplayable: Set<Int> = []) -> QueueNavigator {
        QueueNavigator(videos: ids.map(video(id:)), startIndex: startIndex,
                       randomize: randomize, isPlayable: { !unplayable.contains($0.id) })
    }

    func testSequentialStepsForwardOneAtATime() {
        var nav = navigator(ids: [1, 2, 3], startIndex: 0, randomize: false)
        XCTAssertEqual(nav.step(direction: 1), 1)
        XCTAssertEqual(nav.currentIndex, 1)
        XCTAssertEqual(nav.step(direction: 1), 2)
        XCTAssertEqual(nav.currentVideo?.id, 3)
    }

    func testSequentialStopsAtTheEndOfTheQueue() {
        var nav = navigator(ids: [1, 2], startIndex: 1, randomize: false)
        XCTAssertNil(nav.step(direction: 1))
        XCTAssertEqual(nav.currentIndex, 1, "a refused step must not move the cursor")
    }

    func testSequentialSkipsUnplayableEntries() {
        var nav = navigator(ids: [1, 2, 3], startIndex: 0, randomize: false, unplayable: [2])
        XCTAssertEqual(nav.step(direction: 1), 2)
        XCTAssertEqual(nav.currentVideo?.id, 3)
    }

    func testSequentialStepsBackwardAndReportsQueueStart() {
        var nav = navigator(ids: [1, 2, 3], startIndex: 2, randomize: false)
        XCTAssertFalse(nav.isAtQueueStart)
        XCTAssertEqual(nav.step(direction: -1), 1)
        XCTAssertEqual(nav.step(direction: -1), 0)
        XCTAssertTrue(nav.isAtQueueStart)
        XCTAssertNil(nav.step(direction: -1))
    }

    func testRandomStartsAtTheTappedVideoAndVisitsEveryPlayableOneBeforeRepeating() {
        var nav = navigator(ids: [1, 2, 3, 4], startIndex: 2, randomize: true)
        XCTAssertEqual(nav.currentVideo?.id, 3, "the tapped video plays first")
        var seen = [3]
        for _ in 0..<3 {
            guard let next = nav.step(direction: 1) else { return XCTFail("random step ran dry") }
            seen.append(nav.videos[next].id)
        }
        XCTAssertEqual(Set(seen), [1, 2, 3, 4])
    }

    func testRandomReshuffleNeverRepeatsAVideoBackToBack() {
        // 2 playable entries: the reshuffle at the wrap point must not put the
        // just-finished video first, or autoplay's loop replays it immediately.
        var nav = navigator(ids: [1, 2], startIndex: 0, randomize: true)
        var ids = [nav.currentVideo?.id]
        for _ in 0..<6 {
            guard let next = nav.step(direction: 1) else { return XCTFail("random step ran dry") }
            ids.append(nav.videos[next].id)
        }
        for (previous, current) in zip(ids, ids.dropFirst()) {
            XCTAssertNotEqual(previous, current, "back-to-back repeat in \(ids)")
        }
    }

    func testRandomExcludesUnplayableEntriesFromThePool() {
        var nav = navigator(ids: [1, 2, 3], startIndex: 0, randomize: true, unplayable: [2, 3])
        XCTAssertEqual(nav.step(direction: 1), nil, "nothing else is playable")
        XCTAssertTrue(nav.hasAnyPlayable, "video 1 is still playable")
    }

    func testRandomBackwardWalksTheCursorAndStopsAtPositionZero() {
        var nav = navigator(ids: [1, 2, 3], startIndex: 0, randomize: true)
        XCTAssertTrue(nav.isAtQueueStart)
        XCTAssertNil(nav.step(direction: -1))
        XCTAssertNotNil(nav.step(direction: 1))
        XCTAssertFalse(nav.isAtQueueStart)
        XCTAssertNotNil(nav.step(direction: -1))
        XCTAssertTrue(nav.isAtQueueStart)
    }

    func testNothingPlayableAnywhereRefusesEveryStep() {
        var nav = navigator(ids: [1, 2], startIndex: 0, randomize: false, unplayable: [1, 2])
        XCTAssertFalse(nav.hasAnyPlayable)
        XCTAssertNil(nav.step(direction: 1))
        XCTAssertFalse(nav.peekHasNext())
    }

    func testPeekDoesNotMoveTheCursor() {
        var nav = navigator(ids: [1, 2], startIndex: 0, randomize: false)
        XCTAssertTrue(nav.peekHasNext())
        XCTAssertEqual(nav.currentIndex, 0)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd ios/PatataTubeKit && swift test --filter QueueNavigatorTests
```

Expected: FAIL — `cannot find 'QueueNavigator' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ios/PatataTubeKit/Sources/PatataTubeKit/QueueNavigator.swift`:

```swift
import Foundation

/// Queue stepping for a playback session: which video comes next, sequentially
/// or randomly, skipping entries with no playable source.
///
/// Extracted from `VideoPlayerView`, where these rules lived as private methods
/// on a SwiftUI view and could not be tested. `isPlayable` is injected so this
/// type never imports AVFoundation — the caller decides what "playable" means
/// (see `PlaybackSource` in the app target).
///
/// Not `Sendable`: it stores `isPlayable`. Callers are `@MainActor`.
public struct QueueNavigator {
    public let videos: [Video]
    public let randomize: Bool
    private let isPlayable: (Video) -> Bool
    public private(set) var currentIndex: Int
    /// Random mode only: cursor state over a shuffled permutation of the
    /// playable pool, grown with a fresh shuffle whenever a forward step runs
    /// off the end. Stays empty when `randomize` is false.
    private var playbackOrder: [Int] = []
    private var orderPosition: Int = 0

    public init(videos: [Video], startIndex: Int, randomize: Bool,
                isPlayable: @escaping (Video) -> Bool) {
        self.videos = videos
        self.randomize = randomize
        self.isPlayable = isPlayable
        self.currentIndex = startIndex
        guard randomize else { return }
        let playable = playableVideoIndices
        let order = shuffledPlaybackOrder(count: playable.count,
                                          pinFirst: playable.firstIndex(of: startIndex))
        playbackOrder = order.map { playable[$0] }
        orderPosition = 0
    }

    public var currentVideo: Video? {
        videos.indices.contains(currentIndex) ? videos[currentIndex] : nil
    }

    /// Whether at least one video in the queue has a playable source. In random
    /// mode a literal end-of-list peek doesn't apply (the order reshuffles
    /// forever), so this is what decides the lock screen's "next" enabled state.
    public var hasAnyPlayable: Bool { videos.contains(where: isPlayable) }

    /// Nothing before the current item: the cursor is at random-order position
    /// 0, or no playable entry precedes it sequentially. Drives the iOS
    /// "previous restarts the current item" convention.
    public var isAtQueueStart: Bool {
        randomize ? orderPosition == 0 : playableIndex(from: currentIndex, direction: -1) == nil
    }

    /// Move to the next playable video in `direction` and return its `videos`
    /// index, or nil when there is none. **Commits** — in random mode a forward
    /// step mutates the cursor and may reshuffle, so never call it as a peek.
    public mutating func step(direction: Int) -> Int? {
        guard let next = randomize
            ? randomStep(direction: direction)
            : playableIndex(from: currentIndex, direction: direction) else { return nil }
        currentIndex = next
        return next
    }

    /// Whether a forward step would find something, without committing one.
    public mutating func peekHasNext() -> Bool {
        randomize ? hasAnyPlayable : playableIndex(from: currentIndex, direction: 1) != nil
    }

    /// Nearest queue index in `direction` with a playable source, or nil.
    private func playableIndex(from index: Int, direction: Int) -> Int? {
        var i = index + direction
        while videos.indices.contains(i) {
            if isPlayable(videos[i]) { return i }
            i += direction
        }
        return nil
    }

    /// Indices with a playable source — the pool `playbackOrder` is drawn from
    /// and reshuffled over. Excluding unplayable entries here (rather than
    /// skipping them while stepping) keeps `orderPosition == 0` an accurate
    /// "nothing before me" check.
    private var playableVideoIndices: [Int] {
        videos.indices.filter { isPlayable(videos[$0]) }
    }

    /// Random-mode step: walks `playbackOrder`'s cursor. Forward, grows the
    /// order with a fresh reshuffle over the currently playable pool — excluding
    /// the wrap point, so autoplay's loop never repeats a video back-to-back —
    /// whenever the step runs off the end.
    private mutating func randomStep(direction: Int) -> Int? {
        if direction > 0 {
            let nextPosition = orderPosition + 1
            if nextPosition >= playbackOrder.count {
                let playable = playableVideoIndices
                guard !playable.isEmpty else { return nil }
                let avoidPosition = playbackOrder.last.flatMap { playable.firstIndex(of: $0) }
                playbackOrder += shuffledPlaybackOrder(count: playable.count,
                                                       avoidFirst: avoidPosition)
                    .map { playable[$0] }
            }
            guard nextPosition < playbackOrder.count else { return nil }
            orderPosition = nextPosition
            return playbackOrder[nextPosition]
        } else {
            guard orderPosition > 0 else { return nil }
            orderPosition -= 1
            return playbackOrder[orderPosition]
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd ios/PatataTubeKit && swift test --filter QueueNavigatorTests
```

Expected: PASS, 11 tests.

Note on `testRandomExcludesUnplayableEntriesFromThePool`: with only video 1 playable, the pool has one entry, so the forward reshuffle produces `[0]` again and `nextPosition` lands past a 1-element grow — assert whichever the implementation yields, but it must never return an unplayable index. If it returns `0` (video 1 again), change the assertion to `XCTAssertEqual(nav.step(direction: 1), 0)` and add a comment that a single-entry pool legitimately repeats; do not weaken the back-to-back test, which uses two entries.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/QueueNavigator.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/QueueNavigatorTests.swift
git commit -m "feat(ios): extract queue stepping into a testable QueueNavigator"
```

---

### Task 2: `VideoPlayerView` adopts `QueueNavigator`

Behavior-preserving. The view stops owning queue state; only its call sites change.

**Files:**
- Modify: `ios/PatataTube/Sources/VideoPlayerView.swift`

**Interfaces:**
- Consumes: `QueueNavigator` from Task 1.
- Produces: nothing new. `VideoPlayerView`'s external init is unchanged.

- [ ] **Step 1: Replace the queue state with a navigator**

Delete these `@State` properties and members:

- `@State private var playbackOrder: [Int] = []`
- `@State private var orderPosition: Int = 0`
- `private func playableIndex(from:direction:)`
- `private var hasAnyPlayableVideo`
- `private var playableVideoIndices`
- `private mutating`-style `private func randomStep(direction:)`
- the `if randomize { ... }` order-seeding block at the top of `setup()`

Add in their place:

```swift
    /// Queue stepping (sequential/random, playable-only). Seeded in `setup()`
    /// so `playerItem` is available for its playability probe.
    @State private var navigator: QueueNavigator?
```

Keep `@State private var currentIndex: Int` — the view still uses it to index `videos` for rendering; it now mirrors the navigator.

- [ ] **Step 2: Seed the navigator in `setup()`**

Where the deleted `if randomize { ... }` block was (immediately before `activateAudioSession()`), insert:

```swift
        navigator = QueueNavigator(
            videos: videos, startIndex: currentIndex, randomize: randomize,
            isPlayable: { playerItem(for: $0) != nil }
        )
```

- [ ] **Step 3: Route `advance` and `handlePrevious` through it**

In `advance(by:)`, replace

```swift
        let nextIndex = randomize
            ? randomStep(direction: direction)
            : playableIndex(from: currentIndex, direction: direction)
```

with

```swift
        let nextIndex = navigator?.step(direction: direction)
```

In the same function, replace both

```swift
        nowPlaying.setNextEnabled(randomize ? hasAnyPlayableVideo : playableIndex(from: currentIndex, direction: 1) != nil)
```

occurrences (one in `advance`, one in `setup`) with

```swift
        nowPlaying.setNextEnabled(navigator?.peekHasNext() ?? false)
```

In `handlePrevious()`, replace

```swift
        let atQueueStart = randomize ? orderPosition == 0 : playableIndex(from: currentIndex, direction: -1) == nil
```

with

```swift
        let atQueueStart = navigator?.isAtQueueStart ?? true
```

- [ ] **Step 4: Build and confirm nothing else referenced the deleted members**

```bash
cd ios/PatataTube && xcodegen generate
xcodebuild -project ios/PatataTube/PatataTube.xcodeproj -scheme PatataTube \
  -destination "generic/platform=iOS Simulator" build
```

Expected: BUILD SUCCEEDED. Any `cannot find 'playableIndex'` error points at a call site missed in Step 3 — fix it the same way.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTube/Sources/VideoPlayerView.swift ios/PatataTube/PatataTube.xcodeproj
git commit -m "refactor(ios): VideoPlayerView steps its queue through QueueNavigator"
```

---

### Task 3: `PlaybackSource` extraction — Milestone 1

Moves the source-selection chain out of the view so `AudioQueuePlayer` can share it instead of copying it. **Move the body verbatim** — this chain and its DevLog metadata are the app's main playback diagnostic, and paraphrasing it loses information.

**Files:**
- Create: `ios/PatataTube/Sources/PlaybackSource.swift`
- Modify: `ios/PatataTube/Sources/VideoPlayerView.swift`

**Interfaces:**
- Consumes: `AppModel` (`cache`, `streamProxy`, `streamURL(for:)`, `hlsURL(for:)`, `proxiedHLSURL(for:)`, `proxiedMP4URL(for:)`, `offlineHLSURL(for:)`).
- Produces:
  ```swift
  @MainActor enum PlaybackSource {
      static func item(for video: Video, model: AppModel, log: Bool = true)
          -> (item: AVPlayerItem, source: String)?
      static func authedAsset(url: URL, model: AppModel) -> AVURLAsset
  }
  ```

- [ ] **Step 1: Create the file with the moved chain**

Create `ios/PatataTube/Sources/PlaybackSource.swift`:

```swift
// ios/PatataTube/Sources/PlaybackSource.swift
import AVFoundation
import PatataTubeKit

/// Which URL a video actually plays from, and an `AVPlayerItem` over it.
///
/// Extracted from `VideoPlayerView` so the full-screen player and
/// `AudioQueuePlayer` share one chain. Playback failures that only happen
/// sometimes are usually a wrong branch — a `cached` state over a file that is
/// missing or half written, say — so the branch and the on-disk facts behind it
/// are recorded together, before AVFoundation ever sees the URL.
///
/// Most callers only ask *whether* a video is playable, sweeping a queue for
/// the next candidate. Those probes pass `log: false` — one source line per
/// candidate would bury the one that actually got played.
@MainActor
enum PlaybackSource {
    static func item(for video: Video, model: AppModel, log: Bool = true)
        -> (item: AVPlayerItem, source: String)? {
        // MOVE the entire body of VideoPlayerView.playerItemWithSource(for:log:)
        // here verbatim, with two mechanical substitutions:
        //   * every `model.` reference keeps working (model is now a parameter)
        //   * `authedAsset(url:)` becomes `authedAsset(url:model:)`
        // Do not restructure the branch order, drop a branch, or trim the
        // DevLog `meta` dictionary — each field is there for a past bug.
    }

    /// One asset carrying the bearer header, so AVFoundation authenticates the
    /// HLS playlist, segment, and subtitle sub-requests on the same asset.
    static func authedAsset(url: URL, model: AppModel) -> AVURLAsset {
        // MOVE the body of VideoPlayerView.authedAsset(url:) here verbatim.
    }

    /// Playability probe for `QueueNavigator`: a video has a source or it doesn't.
    static func isPlayable(_ video: Video, model: AppModel) -> Bool {
        item(for: video, model: model, log: false) != nil
    }

    private static func fileSize(at url: URL) -> String {
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int64 else { return "-" }
        return "\(size)"
    }
}
```

- [ ] **Step 2: Point `VideoPlayerView` at it**

In `VideoPlayerView.swift`, delete `playerItemWithSource(for:log:)`, `playerItem(for:)`, `authedAsset(url:)`, and the `static func fileSize(at:)` helper, then add thin shims so the ~6 existing call sites don't each need editing:

```swift
    private func playerItem(for video: Video) -> AVPlayerItem? {
        PlaybackSource.item(for: video, model: model, log: false)?.item
    }

    private func playerItemWithSource(for video: Video) -> (item: AVPlayerItem, source: String)? {
        PlaybackSource.item(for: video, model: model)
    }
```

- [ ] **Step 3: Build**

```bash
cd ios/PatataTube && xcodegen generate
xcodebuild -project ios/PatataTube/PatataTube.xcodeproj -scheme PatataTube \
  -destination "generic/platform=iOS Simulator" build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Milestone 1 — the first simulator run**

The big refactor is done, so this is the first of the two authorized simulator runs. Run it without asking:

```bash
cd ios/PatataTube && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube \
  -destination "platform=iOS Simulator,id=$(xcrun simctl list devices available | grep -m1 -o '[0-9A-F-]\{36\}')" \
  test -skip-testing:PatataTubeTests/EpisodesDownloadAllViewTests
```

Expected: the suite passes as it did before this branch. `VideoPlayerResumeTests`, `PlayerViewControllerTests` and `VideoGridViewTests` are the ones that cover this refactor. A failure here is a real regression — fix it and re-run this command as often as needed; do not proceed to Task 4 until it's green. Per `CLAUDE.md`, re-run a single failure filtered before treating it as a regression: a full run surfaces pre-existing flakes (e.g. in `VideoStoreTests`).

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTube/Sources/PlaybackSource.swift \
        ios/PatataTube/Sources/VideoPlayerView.swift ios/PatataTube/PatataTube.xcodeproj
git commit -m "refactor(ios): move the player-item source chain into PlaybackSource"
```

---

### Task 4: `RowAudioState` and the `VideoRow` overlay

The row stays dumb: plain values and closures, no `AppModel`, consistent with the rest of the file. `audioState` defaults to `.idle` so `moviesGrid` and any other call site keep compiling untouched.

**Files:**
- Create: `ios/PatataTube/Sources/RowAudioState.swift`
- Modify: `ios/PatataTube/Sources/VideoRow.swift`
- Test: `ios/PatataTube/Tests/VideoRowAudioTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum RowAudioState: Equatable { case idle, loading, playing, paused }
  extension RowAudioState { var overlaySystemImage: String? { get } }
  // VideoRow gains: var audioState: RowAudioState = .idle
  ```

- [ ] **Step 1: Write the failing test**

Create `ios/PatataTube/Tests/VideoRowAudioTests.swift`:

```swift
import PatataTubeKit
import SwiftUI
import Testing
@testable import PatataTube

@Suite("Video row audio overlay", .serialized)
@MainActor
struct VideoRowAudioTests {
    @Test func idleDrawsNoOverlayGlyph() {
        #expect(RowAudioState.idle.overlaySystemImage == nil)
    }

    @Test func playingDrawsPauseAndPausedDrawsPlay() {
        // The glyph is the *action* the next tap performs, not the current state.
        #expect(RowAudioState.playing.overlaySystemImage == "pause.fill")
        #expect(RowAudioState.paused.overlaySystemImage == "play.fill")
    }

    @Test func loadingDrawsNoGlyphBecauseItShowsASpinner() {
        #expect(RowAudioState.loading.overlaySystemImage == nil)
    }

    @Test func rowRendersWithEveryAudioState() throws {
        for state in [RowAudioState.idle, .loading, .playing, .paused] {
            let row = VideoRow(
                video: Self.video, cacheState: .notCached,
                currentCacheState: { .notCached }, groups: [],
                audioState: state,
                onPlay: {}, onPlaySleep: {}, onDownload: { true }, onCancel: {},
                onDeleteCache: {}, onSetGroup: { _ in }, onPromote: { _ in },
                onChooseVersion: { _ in }, onDelete: {}
            )
            #expect(row.audioState == state)
        }
    }

    static let video = Video(
        id: 42, url: "/videos/42", title: "Video 42", platform: nil, sourceKey: nil,
        previewUrl: nil, groupID: 1, plexKind: nil, position: nil, status: "done",
        errorMsg: nil, streamPath: "/videos/42/stream"
    )
}
```

Note: this deliberately does **not** use ViewInspector to reach inside the row. `CLAUDE.md` records that inspecting a large SwiftUI view segfaults the whole test process, and no `withKnownIssue` absorbs that. The glyph decision is tested on the enum, where it's pure.

- [ ] **Step 2: Note why this test isn't run yet**

The app target only builds tests through `xcodebuild`, and simulator runs are budgeted to the two milestones. Skip running it here — it would fail to compile (`cannot find type 'RowAudioState'`), which Step 3 fixes — and let the Milestone 2 run in Task 6 be its first execution. Do not add a third scheduled simulator run for this.

- [ ] **Step 3: Create the enum**

Create `ios/PatataTube/Sources/RowAudioState.swift`:

```swift
// ios/PatataTube/Sources/RowAudioState.swift
import Foundation

/// One list row's audio status, as the row needs to draw it.
///
/// Deliberately a row-shaped type, not a playback-shaped one: `VideoRow` takes
/// plain values and closures and never sees `AppModel` or `AudioQueuePlayer`.
enum RowAudioState: Equatable {
    /// Not the current audio item — the thumbnail draws bare.
    case idle
    /// Tapped, but the source isn't resolved yet (`/prepare`, conversion).
    case loading
    case playing
    case paused

    /// The glyph the overlay shows: the action the next tap performs, so a
    /// playing row offers pause. `nil` where there is no glyph — `.idle` draws
    /// nothing at all, `.loading` draws a spinner instead.
    var overlaySystemImage: String? {
        switch self {
        case .idle, .loading: return nil
        case .playing: return "pause.fill"
        case .paused: return "play.fill"
        }
    }
}
```

- [ ] **Step 4: Add the parameter and the overlay to `VideoRow`**

In `VideoRow.swift`, add the property after `let groups: [VideoGroup]`:

```swift
    /// Audio-only playback status for this row. `.idle` everywhere except the
    /// group-detail list, whose rows play audio instead of presenting a player.
    var audioState: RowAudioState = .idle
```

Then replace the `thumbnail` computed property with:

```swift
    /// Fixed 78x44 box for both aspect ratios, so titles line up across feeds.
    /// Plex posters are 2:3 and letterbox inside it rather than centre-cropping.
    /// In audio mode the thumbnail keeps rendering and takes a dimmed overlay
    /// carrying the play/pause glyph — the row's only playback control.
    private var thumbnail: some View {
        ZStack {
            Rectangle().fill(.black)
            if video.previewUrl != nil || cachedPreviewURL != nil {
                Rectangle().fill(.clear)
                    .overlay {
                        AuthedImage(path: video.previewUrl, localFileURL: cachedPreviewURL,
                                    fill: !video.isPlexItem,
                                    onNetworkLoad: onPreviewLoaded)
                    }
                    .clipped()
            }
            audioOverlay
        }
        .frame(width: Self.thumbWidth, height: Self.thumbHeight)
        .clipped()
        .cornerRadius(4)
    }

    @ViewBuilder private var audioOverlay: some View {
        switch audioState {
        case .idle:
            EmptyView()
        case .loading:
            Color.black.opacity(0.45)
            ProgressView().tint(.white).scaleEffect(0.7)
        case .playing, .paused:
            Color.black.opacity(0.45)
            Image(systemName: audioState.overlaySystemImage ?? "play.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(radius: 2)
        }
    }
```

`onPlay` keeps its name and its `logTap`; `VideoGridView` decides in Task 6 whether it starts audio or presents a player, so nothing else in this file changes.

- [ ] **Step 5: Build**

```bash
cd ios/PatataTube && xcodegen generate
xcodebuild -project ios/PatataTube/PatataTube.xcodeproj -scheme PatataTube \
  -destination "generic/platform=iOS Simulator" build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTube/Sources/RowAudioState.swift ios/PatataTube/Sources/VideoRow.swift \
        ios/PatataTube/Tests/VideoRowAudioTests.swift ios/PatataTube/PatataTube.xcodeproj
git commit -m "feat(ios): VideoRow draws an audio play/pause overlay on its thumbnail"
```

---

### Task 5: `AudioQueuePlayer`

One `AVPlayer`, no view. Owned by `AppModel` for the same reason `pip` is: it outlives every presentation.

**Files:**
- Create: `ios/PatataTube/Sources/AudioQueuePlayer.swift`
- Modify: `ios/PatataTube/Sources/AppModel.swift`

**Interfaces:**
- Consumes: `QueueNavigator` (Task 1), `PlaybackSource` (Task 3), `NowPlayingManager`, `playbackEndAction(autoplay:isForeground:sleepMode:)` from PatataTubeKit.
- Produces:
  ```swift
  @MainActor final class AudioQueuePlayer: ObservableObject {
      @Published private(set) var currentID: Int?
      @Published private(set) var isPlaying: Bool
      @Published private(set) var isLoading: Bool
      func state(for videoID: Int) -> RowAudioState
      func start(videos: [Video], startIndex: Int, scope: String?, sleepMode: Bool, model: AppModel)
      func markLoading(id: Int?)
      func toggle()
      func stop()
  }
  // AppModel gains: let audio = AudioQueuePlayer()
  ```

- [ ] **Step 1: Create the player**

Create `ios/PatataTube/Sources/AudioQueuePlayer.swift`:

```swift
// ios/PatataTube/Sources/AudioQueuePlayer.swift
import AVFoundation
import Combine
import PatataTubeKit
import UIKit

/// Audio-only queue playback for the group-detail list: the same assets the
/// full-screen player uses, with nothing displaying them.
///
/// Lives on `AppModel` (like `pip`) because playback has to survive switching to
/// grid, navigating back, changing tabs, and backgrounding — the list row that
/// started it is gone from the hierarchy long before the queue ends. An
/// `AVPlayer` over a video asset simply renders no frames when no layer is
/// attached, so there is no audio-only asset to build.
///
/// Positions are deliberately not involved: audio always starts at 0 and never
/// writes to `PlaybackPositionReporter`.
@MainActor
final class AudioQueuePlayer: ObservableObject {
    /// The video whose audio is loaded, or nil when nothing is playing.
    @Published private(set) var currentID: Int?
    @Published private(set) var isPlaying: Bool = false
    /// A tap whose source isn't resolved yet (`/prepare`, conversion). Keyed by
    /// id rather than a flag, so a second tap elsewhere moves the spinner.
    @Published private(set) var loadingID: Int?

    private var player: AVPlayer?
    private var navigator: QueueNavigator?
    private var scope: String?
    private var sleepAfterCurrent = false
    private weak var model: AppModel?
    private let nowPlaying = NowPlayingManager()
    private var playToEndObserver: NSObjectProtocol?
    private var rateObservation: NSKeyValueObservation?

    /// How a given row should draw itself.
    func state(for videoID: Int) -> RowAudioState {
        if loadingID == videoID { return .loading }
        guard currentID == videoID else { return .idle }
        return isPlaying ? .playing : .paused
    }

    /// Marks a row as waiting on `ensureReady`. Pass nil to clear.
    func markLoading(id: Int?) { loadingID = id }

    /// Start (or restart) the queue at `startIndex`. Any previous audio and any
    /// pending loading marker are dropped first.
    func start(videos: [Video], startIndex: Int, scope: String?,
               sleepMode: Bool, model: AppModel) {
        stop()
        guard videos.indices.contains(startIndex) else { return }
        self.model = model
        self.scope = scope
        self.sleepAfterCurrent = sleepMode
        navigator = QueueNavigator(
            videos: videos, startIndex: startIndex, randomize: model.randomize(for: scope),
            isPlayable: { [weak model] video in
                guard let model else { return false }
                return PlaybackSource.isPlayable(video, model: model)
            }
        )
        DevLog.event(.play, "audio start", [
            "video_id": "\(videos[startIndex].id)",
            "count": "\(videos.count)",
            "scope": scope ?? "-",
            "sleep": "\(sleepMode)",
        ])
        Task {
            await model.streamProxy.ensureRunning()
            guard let video = navigator?.currentVideo,
                  let (item, source) = PlaybackSource.item(for: video, model: model) else {
                DevLog.event(.play, "audio start found no source", [:])
                stop()
                return
            }
            activateAudioSession()
            let player = AVPlayer(playerItem: item)
            player.allowsExternalPlayback = true
            self.player = player
            currentID = video.id
            loadingID = nil
            observe(player: player)
            bindPlayToEnd()
            nowPlaying.onNext = { [weak self] in self?.advance(by: 1) }
            nowPlaying.onPrevious = { [weak self] in self?.handlePrevious() }
            nowPlaying.attach(player: player, title: video.title ?? video.url)
            nowPlaying.setNextEnabled(navigator?.peekHasNext() ?? false)
            DevLog.event(.play, "audio source -> \(source)", ["video_id": "\(video.id)"])
            player.play()
        }
    }

    /// Row tap on the current item, and the lock screen's play/pause.
    func toggle() {
        guard let player else { return }
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
    }

    /// Tear everything down: pause, drop observers, clear Now Playing, release
    /// the audio session so other apps resume.
    func stop() {
        if let playToEndObserver {
            NotificationCenter.default.removeObserver(playToEndObserver)
            self.playToEndObserver = nil
        }
        rateObservation = nil
        player?.pause()
        player = nil
        navigator = nil
        currentID = nil
        loadingID = nil
        isPlaying = false
        sleepAfterCurrent = false
        nowPlaying.detach()
        deactivateAudioSession()
    }

    private func observe(player: AVPlayer) {
        rateObservation = player.observe(\.timeControlStatus) { [weak self] observed, _ in
            Task { @MainActor in
                guard let self, self.player === observed else { return }
                self.isPlaying = observed.timeControlStatus != .paused
            }
        }
        isPlaying = player.timeControlStatus != .paused
    }

    /// `model.autoplay` is read at fire time — a closure-captured copy would go
    /// stale the moment the user flips the toolbar switch mid-queue.
    private func bindPlayToEnd() {
        if let playToEndObserver {
            NotificationCenter.default.removeObserver(playToEndObserver)
        }
        playToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player?.currentItem, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let model = self.model else { return }
                switch playbackEndAction(
                    autoplay: model.autoplay(for: self.scope),
                    isForeground: UIApplication.shared.applicationState == .active,
                    sleepMode: self.sleepAfterCurrent
                ) {
                case .advance:
                    self.advance(by: 1)
                case .sleep:
                    self.stop()
                    self.runBlackScreenShortcut()
                // Nothing is presented, so there is nothing to dismiss: both
                // non-advancing outcomes end playback where it is.
                case .dismiss, .stop:
                    self.stop()
                }
            }
        }
    }

    private func advance(by direction: Int) {
        guard let player, let model, navigator != nil else { return }
        guard let nextIndex = navigator?.step(direction: direction),
              let video = navigator?.currentVideo,
              let (item, source) = PlaybackSource.item(for: video, model: model) else {
            DevLog.event(.play, "audio advance found nothing playable", [
                "direction": "\(direction)",
            ])
            stop()
            return
        }
        _ = nextIndex
        currentID = video.id
        player.replaceCurrentItem(with: item)
        bindPlayToEnd()
        nowPlaying.updateTitle(video.title ?? video.url)
        nowPlaying.setNextEnabled(navigator?.peekHasNext() ?? false)
        DevLog.event(.play, "audio advance -> \(source)", ["video_id": "\(video.id)"])
        player.play()
    }

    /// iOS convention: >3s in (or already at the queue start) restarts the
    /// current item; otherwise go back one.
    private func handlePrevious() {
        guard let player else { return }
        if player.currentTime().seconds > 3 || navigator?.isAtQueueStart != false {
            player.seek(to: .zero)
        } else {
            advance(by: -1)
        }
    }

    /// Sleep end-action: hand off to the user's "black-screen" iOS Shortcut,
    /// the same URL the full-screen player opens.
    private func runBlackScreenShortcut() {
        // COPY the body of VideoPlayerView.runBlackScreenShortcut() verbatim —
        // it is a few lines building a shortcuts:// URL and calling
        // UIApplication.shared.open. Read it before writing this.
    }

    private func activateAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            // Non-fatal — leave local playback running.
        }
    }

    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance()
                .setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // Non-fatal.
        }
    }
}
```

- [ ] **Step 2: Confirm `NowPlayingManager.detach()` exists**

```bash
grep -n "func detach\|func updateTitle\|func setNextEnabled" ios/PatataTube/Sources/NowPlayingManager.swift
```

If `detach()` is absent, add it beside `attach`, mirroring what `VideoPlayerView` does on dismiss (invalidate the observations, remove the notification observer and the `MPRemoteCommand` targets, set `MPNowPlayingInfoCenter.default().nowPlayingInfo = nil`). Do not change `attach`.

- [ ] **Step 3: Own it from `AppModel`**

In `AppModel.swift`, immediately after the `pip` property:

```swift
    /// Audio-only playback for the group-detail list. Lives here, like `pip`,
    /// because it must survive the list view that started it.
    let audio = AudioQueuePlayer()
```

- [ ] **Step 4: Build**

```bash
cd ios/PatataTube && xcodegen generate
xcodebuild -project ios/PatataTube/PatataTube.xcodeproj -scheme PatataTube \
  -destination "generic/platform=iOS Simulator" build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTube/Sources/AudioQueuePlayer.swift ios/PatataTube/Sources/AppModel.swift \
        ios/PatataTube/Sources/NowPlayingManager.swift ios/PatataTube/PatataTube.xcodeproj
git commit -m "feat(ios): add AudioQueuePlayer for headless queue playback"
```

---

### Task 6: Wire it into `VideoGridView` — Milestone 2

**Files:**
- Modify: `ios/PatataTube/Sources/VideoGridView.swift`

**Interfaces:**
- Consumes: `model.audio` (Task 5), `VideoRow.audioState` (Task 4).
- Produces: no new API.

- [ ] **Step 1: Add the audio-mode gate**

Near `currentGroupID` (around line 878), add:

```swift
    /// Group detail in list mode plays audio only: the row is the transport,
    /// and no player is presented. Deliberately no video escape hatch — leave
    /// list mode to watch something.
    private var audioOnlyMode: Bool {
        currentGroupID != nil && displayMode == .list
    }
```

- [ ] **Step 2: Inject the player so rows redraw**

A nested `ObservableObject` does **not** republish through its parent: rows observing `model` alone would never redraw when `isPlaying` flips, and the glyph would freeze. The app already solves this for `model.store` by injecting it separately — follow that precedent exactly.

In `PatataTubeApp.swift`, beside line 88's `.environmentObject(model.store)`:

```swift
                    .environmentObject(model.audio)
```

In `VideoGridView.swift`, beside its other environment objects:

```swift
    /// Injected separately from `model` because nested ObservableObjects don't
    /// republish through their parent — same reason `model.store` is.
    @EnvironmentObject private var audio: AudioQueuePlayer
```

Any other view that renders `VideoRow` outside this environment would now crash on a missing environment object; there is none today (`defaultGrid` is the only `VideoRow` call site, and `RootTabView` builds every grid under the app root), but confirm with:

```bash
grep -rn "VideoRow(" ios/PatataTube/Sources ios/PatataTube/Tests
```

Test-only constructions are fine — Task 4's test builds the row directly and never renders it into a hierarchy.

- [ ] **Step 3: Feed each row its state and its tap**

In `defaultGrid`'s `VideoRow(...)` call, add `audioState:` after `groups:` and swap the two play closures:

```swift
                            groups: groups.groups,
                            audioState: audioOnlyMode ? audio.state(for: videoId) : .idle,
                            onPlay: {
                                if audioOnlyMode { toggleAudio(video) }
                                else { play(video, caller: "grid-row") }
                            },
                            onPlaySleep: {
                                if audioOnlyMode { startAudio(video, sleepMode: true) }
                                else { play(video, sleepMode: true, caller: "grid-row-sleep") }
                            },
```

- [ ] **Step 4: Add the two audio entry points**

Next to `play(_:sleepMode:caller:)` (around line 934):

```swift
    /// Row tap in audio mode: the current item toggles, anything else starts.
    private func toggleAudio(_ video: Video) {
        if model.audio.currentID == video.id {
            model.audio.toggle()
        } else {
            startAudio(video)
        }
    }

    /// Start audio for `video` with the on-screen list as its queue. Mirrors
    /// `play`'s readiness handling — a library row that isn't converted still
    /// needs `/prepare` first — but ends in audio instead of a presentation.
    private func startAudio(_ video: Video, sleepMode: Bool = false) {
        let queueSnapshot = filteredVideos
        DevLog.event(.nav, "audio requested", ["video_id": "\(video.id)"])
        let begin: (Video) -> Void = { ready in
            let index = queueSnapshot.firstIndex(where: { $0.id == ready.id }) ?? 0
            let queue = queueSnapshot.isEmpty ? [ready] : queueSnapshot
            model.audio.start(videos: queue, startIndex: index, scope: playbackScope,
                              sleepMode: sleepMode, model: model)
        }
        if model.cache.state(for: video.id, versionId: video.chosenVersionId) == .cached
            || !(video.isLibrary && video.status != "done") {
            begin(video)
            return
        }
        if model.cache.state(for: video.id, versionId: video.chosenVersionId) == .notCached {
            pendingAutoDownloads.add(video.id)
        }
        model.audio.markLoading(id: video.id)
        Task {
            do {
                guard let readyVideo = try await preparationTracker.trackIfIdle(
                    videoID: video.id,
                    operation: { try await store.ensureReady(id: video.id) }
                ) else {
                    model.audio.markLoading(id: nil)
                    return
                }
                autoDownloadIfPending(readyVideo)
                begin(readyVideo)
            } catch {
                pendingAutoDownloads.remove(video.id)
                model.audio.markLoading(id: nil)
                store.errorText = String(describing: error)
            }
        }
    }
```

- [ ] **Step 5: Stop audio whenever a full-screen player starts**

In `startPlayback` (the function `play` funnels into, which sets `playing`), add as its first line:

```swift
        model.audio.stop()
```

Read the function first and place it before the `playing = ...` assignment. This is the "one source at a time" constraint; a grid cell tapped after switching out of list mode must not play over the audio.

- [ ] **Step 6: Build**

```bash
cd ios/PatataTube && xcodegen generate
xcodebuild -project ios/PatataTube/PatataTube.xcodeproj -scheme PatataTube \
  -destination "generic/platform=iOS Simulator" build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Milestone 2 — the final simulator run**

```bash
cd ios/PatataTube && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube \
  -destination "platform=iOS Simulator,id=$(xcrun simctl list devices available | grep -m1 -o '[0-9A-F-]\{36\}')" \
  test -skip-testing:PatataTubeTests/EpisodesDownloadAllViewTests
```

Expected: PASS, including the new `VideoRowAudioTests`. Per `CLAUDE.md`, re-run a failing test filtered before calling it a regression — a full run shows pre-existing flakes (e.g. in `VideoStoreTests`). Fix and re-run this command until green; that iteration is authorized.

- [ ] **Step 8: Manual check in the Simulator**

Open a group, pinch down to list mode, and verify: tap a row → audio plays, no player appears, thumbnail shows a pause glyph; tap again → pauses, glyph becomes play; let an item end with autoplay on → the next row's glyph moves; toggle randomize → advancing jumps around; lock the device → title and next/previous work; switch to grid and tap a card → audio stops and video takes over. `log/ios.jsonl` should carry `audio start` / `audio advance -> <source>` records:

```bash
jq -c 'select(.msg | startswith("audio"))' log/ios.jsonl | tail -20
```

- [ ] **Step 9: Commit**

```bash
git add ios/PatataTube/Sources/VideoGridView.swift ios/PatataTube/Sources/PatataTubeApp.swift \
        ios/PatataTube/PatataTube.xcodeproj
git commit -m "feat(ios): group-detail list plays audio only"
```

---

### Task 7: Document it

`CLAUDE.md` is how the next session learns this exists; the audio path is invisible from the code's surface (a player with no view).

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add the subsection**

In the `### iOS` section, after the "Download-all is bounded on the client too" bullet, add:

```markdown
- **The group-detail list plays audio, not video.** In a pushed group
  (`currentGroupID != nil`) at list size (`GridDisplayMode.list`), tapping a row
  starts `AppModel.audio` (`AudioQueuePlayer`) instead of presenting
  `VideoPlayerView`: one `AVPlayer` with nothing displaying it, so only sound
  comes out. It lives on `AppModel` like `pip` because playback outlives the
  list — grid switch, back, tab change and backgrounding all keep it running;
  only pause, an exhausted queue, or a full-screen player starting stops it
  (`startPlayback` calls `audio.stop()` first). Autoplay and randomize read the
  same per-scope toggles as the video player. **Audio never touches resume
  positions** — always starts at 0, never reports. The row's thumbnail carries
  the transport (dimmed overlay, `play.fill`/`pause.fill`); a download in
  flight is still only visible in the row's menu. There is deliberately no way
  to reach video from list mode — "Play and sleep" is audio too — so watching
  means leaving list mode. Queue stepping is shared with the video player via
  `QueueNavigator` (PatataTubeKit) and source selection via `PlaybackSource`;
  both were extracted out of `VideoPlayerView` for exactly that reason, so a
  new playback fallback belongs in `PlaybackSource`, not in one of the callers.
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: describe list-view audio-only playback"
```

---

## Working Agreement For This Run

The user granted ~6 hours of unattended execution on 2026-08-23 and asked not
to be consulted. Concretely:

- **No check-in gates.** Neither milestone stops for permission; both run.
- **Two scheduled simulator runs** — Task 3 Step 4 and Task 6 Step 7 — plus
  however many re-runs fixing their failures requires.
- **Judgment calls are yours.** Where this plan offers a shape to confirm
  against real behavior (Task 1 Step 4's single-entry pool, Task 6 Step 2's
  environment injection), pick what compiles and behaves correctly, and record
  the decision in the commit message.
- **Commit per task**, so an interrupted run leaves a clean history.
- **Report at the end**, not during: what landed, what the two simulator runs
  said, and anything left undone with the reason.

## Self-Review

**Spec coverage:** group-detail-only gate → Task 6 Step 1; lifetime across navigation → Task 5 (AppModel ownership); no resume positions → Task 5 (no `positions` call anywhere); full Now Playing → Task 5 Step 1; queue = filtered list with existing toggles → Task 6 Step 4 (`filteredVideos`, `playbackScope`); not-ready rows keep `ensureReady` → Task 6 Step 4; no escape hatch, sleep is audio → Task 6 Step 3; audio stops for video → Task 6 Step 5; `QueueNavigator` → Tasks 1–2; `PlaybackSource` → Task 3; row overlay states → Task 4; test cadence and `-skip-testing` → Global Constraints, Tasks 3 and 6; milestones → Tasks 3 and 6.

**Known soft spots for the executor:**
- Task 3's two moved bodies and Task 5's `runBlackScreenShortcut` say "move/copy verbatim" rather than reproducing 90 lines of code that must not drift. Read the original before writing.
- Task 6 Step 2 (injecting `model.audio` as its own environment object) is the one piece no unit test covers — a wrong shape here compiles fine and simply freezes the glyph. Verify with the manual check in Step 8.
- Task 1 Step 4 flags the single-playable-entry case as an assertion to confirm against real behavior rather than guess.
