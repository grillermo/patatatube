# Lock-Screen Next/Previous Track + Auto-Advance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lock-screen next/previous buttons switch to the adjacent video in the list the user tapped from, and videos auto-advance when one ends while the phone is locked/backgrounded.

**Architecture:** The player keeps its single-`AVPlayer` design; track changes are `replaceCurrentItem(with:)` so the active `.playback` audio session and background audio carry over. `VideoPlayerView` receives a queue snapshot (the grid's visible filtered list) instead of one video. `NowPlayingManager` gains next/previous remote commands that call closures the view provides.

**Tech Stack:** SwiftUI, AVFoundation/AVKit, MediaPlayer (MPRemoteCommandCenter / MPNowPlayingInfoCenter). No new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-19-lockscreen-next-track-design.md`

## Global Constraints

- No settings UI for auto-play. Locked/backgrounded → always auto-advance on video end; foreground → keep the current dismiss-on-end behavior.
- Previous follows the iOS convention: elapsed > 3 s → seek to 0; otherwise go to the prior video; at the start of the queue → seek to 0.
- Queue is a snapshot at tap time; grid refreshes don't mutate it.
- Videos with no playable source (not cached, no HLS/MP4 URL, or an unprepared library row) are skipped when advancing; if none remain, playback stops.
- No iOS test target exists (project convention). Every task verifies with a compile of the app target; manual verification steps land in `ios/README.md` (Task 4).
- `docs/` is gitignored; plan/spec commits use `git add -f`. Source commits under `ios/` are normal.

**Build command used by every task** (expected output `** BUILD SUCCEEDED **`):

```bash
cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

---

### Task 1: NowPlayingManager — next/previous remote commands

**Files:**
- Modify: `ios/PatataTube/Sources/NowPlayingManager.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces (used by Task 2):
  - `var onNext: (() -> Void)?` — set before `attach`; called on the lock-screen next button.
  - `var onPrevious: (() -> Void)?` — same for previous.
  - `func updateTitle(_ title: String)` — pushes a new track title, drops the previous track's artwork, refreshes elapsed/duration.
  - `func setNextEnabled(_ enabled: Bool)` — greys out the next button at the end of the queue.

- [ ] **Step 1: Add the closures and new remote actions**

In `NowPlayingManager.swift`, extend the private enum and add the closure properties right below `private weak var player: AVPlayer?`:

```swift
    private enum RemoteAction: Sendable {
        case play
        case pause
        case togglePlayPause
        case seek(TimeInterval)
        case next
        case previous
    }

    private weak var player: AVPlayer?
    /// Set by the owning view before `attach`; drive queue navigation.
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
```

In `registerCommands()`, after the `togglePlayPauseCommand` line, add:

```swift
        add(center.nextTrackCommand, action: .next)
        add(center.previousTrackCommand, action: .previous)
```

In `handle(_:)`, the `guard let player` currently blocks all actions; next/previous don't need the player. Replace the method body:

```swift
    private func handle(_ action: RemoteAction) {
        switch action {
        case .next:
            onNext?()
            return
        case .previous:
            onPrevious?()
            return
        default:
            break
        }
        guard let player else { return }
        switch action {
        case .play:
            player.play()
        case .pause:
            player.pause()
        case .togglePlayPause:
            player.rate == 0 ? player.play() : player.pause()
        case .seek(let positionTime):
            player.seek(to: CMTime(seconds: positionTime, preferredTimescale: 600))
        case .next, .previous:
            break
        }
    }
```

- [ ] **Step 2: Add `updateTitle` and `setNextEnabled`**

Below `setArtwork`, add:

```swift
    /// Push the new track's title on a queue change and drop the previous
    /// track's artwork so the lock screen never shows a stale thumbnail.
    func updateTitle(_ title: String) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyArtwork] = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        pushDynamicInfo()
    }

    func setNextEnabled(_ enabled: Bool) {
        MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = enabled
    }
```

- [ ] **Step 3: Make the seek observer survive item replacement**

The `timeJumpedNotification` observer in `attach` is bound to `object: player.currentItem`, which goes stale after `replaceCurrentItem`. Replace the `seekObserver = …` block in `attach` with an unbound observer filtered by the player's current item:

```swift
        seekObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.timeJumpedNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            let item = notification.object as? AVPlayerItem
            Task { @MainActor in
                guard let self, let item, item === self.player?.currentItem else { return }
                self.pushDynamicInfo()
            }
        }
```

Also in `detach()`, clear the closures so a dismissed player can't be navigated:

```swift
        onNext = nil
        onPrevious = nil
```

(add these two lines right before `player = nil`).

Note: `statusObservation` observes `\.currentItem?.status` through the *player*, so it already follows replaced items — leave it alone.

- [ ] **Step 4: Compile**

Run the build command from Global Constraints. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTube/Sources/NowPlayingManager.swift
git commit -m "feat(ios): next/previous remote commands in NowPlayingManager"
```

---

### Task 2: VideoPlayerView — queue, advance, auto-advance when backgrounded

**Files:**
- Modify: `ios/PatataTube/Sources/VideoPlayerView.swift`

**Interfaces:**
- Consumes (from Task 1): `NowPlayingManager.onNext`, `.onPrevious`, `.updateTitle(_:)`, `.setNextEnabled(_:)`.
- Produces (used by Task 3): `VideoPlayerView(videos: [Video], startIndex: Int)` — new initializer. `videos` must be non-empty and `startIndex` a valid index.

- [ ] **Step 1: Replace the single-video property with a queue**

At the top of `VideoPlayerView`, replace `let video: Video` with:

```swift
    let videos: [Video]
    let startIndex: Int
    @State private var currentIndex: Int

    init(videos: [Video], startIndex: Int) {
        self.videos = videos
        self.startIndex = startIndex
        _currentIndex = State(initialValue: startIndex)
    }

    private var video: Video { videos[currentIndex] }
```

The computed `video` keeps every existing reference (`setup`, `loadArtwork`) compiling unchanged. Add `import UIKit` under the existing imports (`UIApplication` is used in Step 4).

- [ ] **Step 2: Extract per-video item construction**

In `setup()`, the three-way source selection currently builds an `AVPlayer` per branch. Replace the whole `let player: AVPlayer` selection block (from `let player: AVPlayer` through the final `else { return }`) with:

```swift
        guard let item = playerItem(for: video) else { return }
        let player = AVPlayer(playerItem: item)
```

and add the factored-out builder as a new method (below `setup()`):

```swift
    /// AVPlayerItem for a queue entry, or nil when it has no playable source
    /// (skipped during queue navigation). Order matches the original logic:
    /// cached MP4 → remote HLS → direct MP4.
    private func playerItem(for video: Video) -> AVPlayerItem? {
        if model.cache.state(for: video.id, versionId: video.chosenVersionId) == .cached {
            // Offline MP4 wins: instant, no network. (HLS offline is a later phase.)
            return AVPlayerItem(url: model.cache.localURL(for: video.id, versionId: video.chosenVersionId))
        }
        // Library rows that haven't been converted server-side have no streamable file yet.
        if video.isLibrary && video.status != "done" { return nil }
        if let hlsURL = model.hlsURL(for: video) {
            // Remote HLS exposes native subtitle tracks in the AVKit controls.
            return AVPlayerItem(asset: authedAsset(url: hlsURL))
        }
        if let url = model.streamURL(for: video) {
            // Direct MP4 fallback for rows without an HLS package.
            return AVPlayerItem(asset: authedAsset(url: url))
        }
        return nil
    }
```

- [ ] **Step 3: Wire remote commands and title helper in `setup()`**

Still in `setup()`, after `self.player = player` replace the `nowPlaying.attach(...)` line with:

```swift
        nowPlaying.onNext = { advance(by: 1) }
        nowPlaying.onPrevious = { handlePrevious() }
        nowPlaying.attach(player: player, title: title(of: video))
        nowPlaying.setNextEnabled(playableIndex(from: currentIndex, direction: 1) != nil)
```

and add the tiny helper (near `playerItem(for:)`):

```swift
    private func title(of video: Video) -> String {
        video.title ?? video.sourceFilename ?? "PatataTube"
    }
```

- [ ] **Step 4: Play-to-end → auto-advance when backgrounded**

Replace the `removePlayToEndObserver()` call plus the `playToEndObserver = NotificationCenter…` block in `setup()` with a single call:

```swift
        bindPlayToEnd()
```

and add the method (near `removePlayToEndObserver()`), which re-binds to the player's *current* item so it must be called again after every `replaceCurrentItem`:

```swift
    /// Rebind end-of-item handling to the current item. Foreground keeps the
    /// dismiss-on-end behavior; locked/backgrounded always auto-advances.
    /// `applicationState` is read at fire time — a closure-captured scenePhase
    /// would be frozen at bind time.
    private func bindPlayToEnd() {
        removePlayToEndObserver()
        playToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player?.currentItem, queue: .main
        ) { _ in
            Task { @MainActor in
                if UIApplication.shared.applicationState == .active {
                    dismiss()
                } else {
                    advance(by: 1)
                }
            }
        }
    }
```

- [ ] **Step 5: Queue navigation**

Add below `bindPlayToEnd()`:

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
        bindPlayToEnd()
        player.play()
        nowPlaying.updateTitle(title(of: video))
        nowPlaying.setNextEnabled(playableIndex(from: currentIndex, direction: 1) != nil)
        Task { await loadArtwork(for: player) }
    }

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

- [ ] **Step 6: Guard stale artwork loads**

A slow artwork download started for video N must not land after advancing to N+1 (`setArtwork` only checks player identity, and the player is now reused across tracks). In `loadArtwork(for:)`, capture the index and add it to both guards:

```swift
    /// Best-effort lock-screen artwork; controls work without it.
    private func loadArtwork(for expectedPlayer: AVPlayer) async {
        let index = currentIndex
        guard !Task.isCancelled,
              self.player === expectedPlayer,
              let path = video.previewUrl,
              let data = try? await model.api.imageData(path: path),
              !Task.isCancelled,
              self.player === expectedPlayer,
              currentIndex == index else { return }
        nowPlaying.setArtwork(data, for: expectedPlayer)
    }
```

- [ ] **Step 7: Compile**

Run the build command from Global Constraints. Expected: `** BUILD SUCCEEDED **`. (Task 3 hasn't updated the call site yet — if `VideoGridView.swift` fails on `VideoPlayerView(video:)`, that one error is expected; every other file must compile. Otherwise fix before committing.)

- [ ] **Step 8: Commit**

```bash
git add ios/PatataTube/Sources/VideoPlayerView.swift
git commit -m "feat(ios): queue navigation + auto-advance in VideoPlayerView"
```

---

### Task 3: VideoGridView — snapshot the visible list as the queue

**Files:**
- Modify: `ios/PatataTube/Sources/VideoGridView.swift`

**Interfaces:**
- Consumes (from Task 2): `VideoPlayerView(videos: [Video], startIndex: Int)`.
- Produces: nothing downstream.

- [ ] **Step 1: Add the queue state**

Below `@State private var playing: Video?` add:

```swift
    /// Snapshot of the visible list taken when playback starts; the lock-screen
    /// next/previous queue. Grid refreshes don't mutate an active queue.
    @State private var playQueue: [Video] = []
```

- [ ] **Step 2: Route all playback starts through one snapshot point**

Replace `play(_:)` with:

```swift
    private func play(_ video: Video) {
        // Already downloaded to device: play the local file directly, no network.
        // ensureReady() would hit /prepare and fail offline (-1009) even though
        // the cached MP4 is ready to play. VideoPlayerView plays from cache too.
        if model.cache.state(for: video.id, versionId: video.chosenVersionId) == .cached {
            startPlayback(video)
            return
        }
        guard video.isLibrary, video.status != "done" else {
            startPlayback(video)
            return
        }
        preparing = true
        Task {
            defer { preparing = false }
            do {
                startPlayback(try await store.ensureReady(id: video.id))
            } catch {
                store.errorText = String(describing: error)
            }
        }
    }

    /// Snapshot the visible list as the playback queue. `video` may be the
    /// ensureReady-updated copy, so it replaces its stale row in the snapshot.
    private func startPlayback(_ video: Video) {
        var queue = filteredVideos
        if let index = queue.firstIndex(where: { $0.id == video.id }) {
            queue[index] = video
        } else {
            queue = [video]
        }
        playQueue = queue
        playing = video
    }
```

- [ ] **Step 3: Pass the queue into the player**

Replace the `fullScreenCover` block:

```swift
            .fullScreenCover(item: $playing) { video in
                VideoPlayerView(
                    videos: playQueue,
                    startIndex: playQueue.firstIndex(where: { $0.id == video.id }) ?? 0
                )
            }
```

- [ ] **Step 4: Compile**

Run the build command from Global Constraints. Expected: `** BUILD SUCCEEDED **` with zero errors anywhere (this closes the Task 2 call-site gap).

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTube/Sources/VideoGridView.swift
git commit -m "feat(ios): pass visible-list queue snapshot into the player"
```

---

### Task 4: Manual test checklist in ios/README.md

**Files:**
- Modify: `ios/README.md` (append to the existing manual test checklist section)

**Interfaces:** none.

- [ ] **Step 1: Append the checklist**

Open `ios/README.md`, find the manual test checklist, and append:

```markdown
### Lock-screen next/previous + auto-advance

1. Play a video from the grid, lock the phone → lock-screen **next** starts the
   next video's audio; the title updates on the lock screen.
2. Lock-screen **previous** within the first 3 s → prior video; after 3 s →
   restarts the current one. On the first video it restarts.
3. On the last video, **next** stops playback (button greyed out).
4. Locked: a video ending auto-advances to the next one.
5. Foreground: a video ending dismisses the player (unchanged behavior).
6. With a classification tab or search active, the queue respects that filter.
7. Unplayable rows (unconverted library items) are skipped when advancing.
```

- [ ] **Step 2: Final full build**

Run the build command from Global Constraints. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add ios/README.md
git commit -m "docs(ios): manual test checklist for lock-screen queue controls"
```
