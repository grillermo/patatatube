# Player Buffer-Readiness Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the AVKit player mounting before its item can play, so the first tap on a streamed video never shows a crossed-out play button.

**Architecture:** Gate the `PlayerViewController` mount behind a new `itemReady` flag. Keep showing `ProgressView` until the current `AVPlayerItem` reports `isPlaybackLikelyToKeepUp == true` (enough bytes buffered), then mount and `play()`. A KVO observer drives the flip; a timeout task falls through to play anyway on a dead network. Same gate applies on queue `advance()`.

**Tech Stack:** SwiftUI, AVKit/AVFoundation, Swift concurrency (`Task`), NSKeyValueObservation.

## Global Constraints

- Target file: `ios/PatataTube/Sources/VideoPlayerView.swift` (app shell target, XcodeGen).
- No iOS automated test target exists — verification is Xcode compile + the manual checklist in `ios/README.md`. Do NOT invent a test target.
- `swift build` in `ios/PatataTubeKit` does NOT cover this file (app target, not the Kit package). It only confirms the logic package still builds.
- Readiness signal: `AVPlayerItem.isPlaybackLikelyToKeepUp` (per product decision — "enough bytes to actually play", not just decodable).
- No hard minimum-spinner floor — buffer-only (per product decision).
- Timeout fallback: ~12 seconds, then mount + play regardless (AVKit shows its own buffering/error state).
- Every KVO/timeout callback MUST guard `self.player === player` so a stale observer from a dismissed or advanced player can't mutate state.

---

### Task 1: Add readiness state and the `playWhenReady` helper, gate the initial mount

**Files:**
- Modify: `ios/PatataTube/Sources/VideoPlayerView.swift`

**Interfaces:**
- Consumes: existing `@State private var player: AVPlayer?`, `setup()`, `PlayerViewController(player:attached:resumeAfterDetaching:)`.
- Produces: `@State private var itemReady: Bool`, `@State private var readyObserver: NSKeyValueObservation?`, `@State private var readyTimeoutTask: Task<Void, Never>?`, and `private func playWhenReady(item: AVPlayerItem, on player: AVPlayer)`. Task 2 relies on `playWhenReady` and `itemReady`.

- [ ] **Step 1: Add the three state properties**

Insert after the existing `@State private var player: AVPlayer?` (currently line 25):

```swift
    @State private var player: AVPlayer?
    /// Gates mounting the player UI: false until the current item has buffered
    /// enough to play, so we never surface AVKit's crossed-out play button.
    @State private var itemReady = false
    /// KVO on the current item's isPlaybackLikelyToKeepUp; flips itemReady true.
    @State private var readyObserver: NSKeyValueObservation?
    /// Fallback: mount + play even if buffering never reports ready (dead network).
    @State private var readyTimeoutTask: Task<Void, Never>?
```

- [ ] **Step 2: Gate the mount on `itemReady`**

Replace the body's player branch (currently lines 40–52). Remove `.onAppear { player.play() }` — play now comes from readiness:

```swift
            if let player, itemReady {
                PlayerViewController(
                    player: player,
                    attached: attached,
                    resumeAfterDetaching: resumeAfterDetaching
                )
                    .ignoresSafeArea()
                    .offset(y: dragOffset)
                    .scaleEffect(dragScale)
            } else {
                ProgressView().tint(.white)
            }
```

- [ ] **Step 3: Add the `playWhenReady` helper**

Insert immediately after `setup()` (after its closing brace, currently line 129). This is the single entry point both `setup()` and `advance()` use:

```swift
    /// Show a spinner until `item` has buffered enough to play, then mount the
    /// player and start. Cancels any prior observer/timeout so requeueing is safe.
    /// A ~12s timeout mounts anyway so a dead network still surfaces AVKit's UI.
    private func playWhenReady(item: AVPlayerItem, on player: AVPlayer) {
        readyObserver?.invalidate()
        readyTimeoutTask?.cancel()
        itemReady = false

        let markReady = {
            guard self.player === player, !self.itemReady else { return }
            self.itemReady = true
            player.play()
            self.readyObserver?.invalidate()
            self.readyObserver = nil
            self.readyTimeoutTask?.cancel()
            self.readyTimeoutTask = nil
        }

        // Already buffered (e.g. cached local file): mount without a flash.
        if item.isPlaybackLikelyToKeepUp {
            markReady()
            return
        }

        readyObserver = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { _, change in
            guard change.newValue == true else { return }
            Task { @MainActor in markReady() }
        }

        readyTimeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            markReady()
        }
    }
```

- [ ] **Step 4: Call `playWhenReady` from `setup()`**

In `setup()`, insert the call right after `self.player = player` (currently line 121):

```swift
        self.player = player
        playWhenReady(item: item, on: player)
        Task { await applyAudioSelection(item: item, lang: video.audioLang) }
```

- [ ] **Step 5: Verify the Kit package still builds**

Run: `cd ios/PatataTubeKit && swift build`
Expected: `Build complete!` (confirms no shared-logic regression; this file is not in this package).

- [ ] **Step 6: Verify the app compiles**

Run: `cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS' build`
Expected: `** BUILD SUCCEEDED **`
(If `xcodebuild`/simulator is unavailable in this environment, open `PatataTube.xcodeproj` in Xcode and confirm `VideoPlayerView.swift` compiles with no errors.)

- [ ] **Step 7: Commit**

```bash
git add ios/PatataTube/Sources/VideoPlayerView.swift
git commit -m "fix(ios): gate player mount on buffer readiness"
```

---

### Task 2: Gate queue `advance()` and clean up on disappear

**Files:**
- Modify: `ios/PatataTube/Sources/VideoPlayerView.swift`

**Interfaces:**
- Consumes: `playWhenReady(item:on:)`, `itemReady`, `readyObserver`, `readyTimeoutTask` from Task 1.
- Produces: none (final state).

- [ ] **Step 1: Route `advance()` through `playWhenReady`**

In `advance(by:)`, replace the immediate `player.play()` (currently line 208) so the next item buffers before mounting. The block currently reads:

```swift
        currentIndex = nextIndex
        player.replaceCurrentItem(with: item)
        Task { await applyAudioSelection(item: item, lang: videos[nextIndex].audioLang) }
        bindPlayToEnd()
        player.play()
        nowPlaying.updateTitle(title(of: video))
```

Change it to:

```swift
        currentIndex = nextIndex
        player.replaceCurrentItem(with: item)
        Task { await applyAudioSelection(item: item, lang: videos[nextIndex].audioLang) }
        bindPlayToEnd()
        playWhenReady(item: item, on: player)
        nowPlaying.updateTitle(title(of: video))
```

- [ ] **Step 2: Tear down observer + timeout on disappear**

In `.onDisappear` (currently lines 78–83), add cleanup so a dismissed view leaves nothing observing:

```swift
        .onDisappear {
            player?.pause()
            removePlayToEndObserver()
            readyObserver?.invalidate()
            readyObserver = nil
            readyTimeoutTask?.cancel()
            readyTimeoutTask = nil
            nowPlaying.detach()
            deactivateAudioSession()
        }
```

- [ ] **Step 3: Verify the Kit package still builds**

Run: `cd ios/PatataTubeKit && swift build`
Expected: `Build complete!`

- [ ] **Step 4: Verify the app compiles**

Run: `cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS' build`
Expected: `** BUILD SUCCEEDED **` (or Xcode compile, per Task 1 Step 6).

- [ ] **Step 5: Manual verification**

On device/simulator against a live server:
1. Tap a non-cached streamed video (e.g. "The Jungle Book"). Expected: spinner, then playback starts — no crossed-out play icon, no need to dismiss and re-tap.
2. Let it autoplay to the next queue item (or tap Next on the lock screen). Expected: brief spinner while the next item buffers, then it plays.
3. Tap a cached (offline-downloaded) video. Expected: near-instant playback, no visible spinner flash.
4. (Optional) Enable Airplane Mode, tap a non-cached video. Expected: spinner for ~12s, then AVKit's own buffering/error UI appears (not an infinite silent spinner).

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTube/Sources/VideoPlayerView.swift
git commit -m "fix(ios): apply buffer-readiness gate to queue advance and clean up observers"
```

---

## Self-Review

- **Spec coverage:** Initial-play race (Task 1) ✓. `advance()` re-gate — explicitly requested (Task 2 Step 1) ✓. Cached instant-path (Task 1 Step 3, early `isPlaybackLikelyToKeepUp` check) ✓. Timeout fallback (Task 1 Step 3) ✓. Observer cleanup (Task 2 Step 2) ✓. No hard 1s floor — buffer-only ✓.
- **Placeholder scan:** none — all code shown in full.
- **Type consistency:** `playWhenReady(item:on:)`, `itemReady`, `readyObserver`, `readyTimeoutTask` referenced identically across Tasks 1 and 2. `markReady` guards `self.player === player` in every path.
- **Background/foreground detach:** `attached`/`resumeAfterDetaching` logic untouched — orthogonal to the readiness gate.
