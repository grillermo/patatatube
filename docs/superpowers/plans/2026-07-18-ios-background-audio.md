# iOS Background Audio Playback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Audio keeps playing when the phone locks or the app is backgrounded, with full lock-screen / Control Center controls (play, pause, scrub, title, artwork).

**Architecture:** Replace SwiftUI `VideoPlayer` with an `AVPlayerViewController` wrapped in `UIViewControllerRepresentable`. On `scenePhase == .background` the player is detached from the video layer (iOS pauses any player attached to one) and `play()` is re-issued; on `.active` it reattaches. A new `NowPlayingManager` drives `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`. `UIBackgroundModes: audio` is added to the generated Info.plist via `project.yml`.

**Tech Stack:** SwiftUI, AVKit (`AVPlayerViewController`), MediaPlayer (`MPNowPlayingInfoCenter`, `MPRemoteCommandCenter`), XcodeGen.

**Spec:** `docs/superpowers/specs/2026-07-18-ios-background-audio-design.md`

## Global Constraints

- All changes in the app target `ios/PatataTube/Sources/`; PatataTubeKit untouched.
- Swift 6 language mode (`SWIFT_VERSION: "6.0"` in project.yml) — strict concurrency. Remote-command and KVO closures are nonisolated; hop to the main actor as shown in the code (do not sprinkle `@unchecked Sendable`).
- Deployment target iOS 17.0 — two-parameter `onChange(of:)` is available.
- No PiP: `allowsPictureInPicturePlayback = false`.
- `updatesNowPlayingInfoCenter = false` on the `AVPlayerViewController` — otherwise AVKit fights `NowPlayingManager` for the lock screen.
- No automated iOS test target exists. Each task's check is a clean `xcodebuild` compile; final task is the manual on-device checklist. Do not invent a test target.
- Build command used throughout (from `ios/PatataTube/`):
  `xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`
- Behaviors that must not regress (verify in final task): pull-down-to-dismiss; cached-MP4 → HLS → MP4 source order; bearer-token `AVURLAsset`; dismiss on play-to-end; AirPlay; audio session activate/deactivate.

---

### Task 1: Background audio entitlement in project.yml

**Files:**
- Modify: `ios/PatataTube/project.yml` (target settings block, after `INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace`)

**Interfaces:**
- Produces: generated Info.plist containing `UIBackgroundModes = [audio]`. Later tasks' runtime behavior (audio surviving lock) depends on this.

- [ ] **Step 1: Add the Info.plist key**

In `ios/PatataTube/project.yml`, inside `targets.PatataTube.settings.base`, add one line after `INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace: YES`:

```yaml
        INFOPLIST_KEY_UIBackgroundModes: audio
```

- [ ] **Step 2: Regenerate the project and verify the setting landed**

```bash
cd ios/PatataTube && xcodegen generate
xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -showBuildSettings 2>/dev/null | grep UIBackgroundModes
```

Expected output contains: `INFOPLIST_KEY_UIBackgroundModes = audio`

If the grep is empty, XcodeGen dropped the key — stop and report; do not work around it with a manual Info.plist without checking in.

- [ ] **Step 3: Verify it reaches the built Info.plist**

```bash
xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3
APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/PatataTube-*/Build/Products/*-iphonesimulator/PatataTube.app | head -1)
plutil -p "$APP/Info.plist" | grep -A2 UIBackgroundModes
```

Expected: build succeeds; plutil output shows `"UIBackgroundModes" => [ 0 => "audio" ]`

- [ ] **Step 4: Commit**

```bash
git add ios/PatataTube/project.yml
git commit -m "feat(ios): declare audio background mode"
```

(`project.pbxproj` is generated; commit it too if the repo tracks it — check `git status`.)

---

### Task 2: NowPlayingManager

**Files:**
- Create: `ios/PatataTube/Sources/NowPlayingManager.swift`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces (used by Task 4's `VideoPlayerView`):
  - `@MainActor final class NowPlayingManager`
  - `func attach(player: AVPlayer, title: String)`
  - `func setArtwork(_ image: UIImage)`
  - `func detach()`

- [ ] **Step 1: Create the file**

```swift
// ios/PatataTube/Sources/NowPlayingManager.swift
import Foundation
import AVFoundation
import MediaPlayer
import UIKit

/// Lock-screen / Control Center integration for a single AVPlayer.
/// Attach when the player screen appears, detach on dismiss.
/// Elapsed time is pushed only on rate changes and seeks — iOS extrapolates
/// the lock-screen progress bar from elapsed + rate in between.
@MainActor
final class NowPlayingManager {
    private weak var player: AVPlayer?
    private var rateObservation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?
    private var seekObserver: NSObjectProtocol?
    private var targets: [(MPRemoteCommand, Any)] = []

    /// nonisolated so `@State private var nowPlaying = NowPlayingManager()` can
    /// initialize it — SwiftUI property default values run in a nonisolated context.
    nonisolated init() {}

    func attach(player: AVPlayer, title: String) {
        self.player = player
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        rateObservation = player.observe(\.rate) { [weak self] _, _ in
            Task { @MainActor in self?.pushDynamicInfo() }
        }
        // Duration becomes known once the item is ready to play.
        statusObservation = player.observe(\.currentItem?.status) { [weak self] _, _ in
            Task { @MainActor in self?.pushDynamicInfo() }
        }
        seekObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.timeJumpedNotification,
            object: player.currentItem, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.pushDynamicInfo() }
        }
        registerCommands()
    }

    /// Best-effort: called only when the thumbnail download succeeds.
    func setArtwork(_ image: UIImage) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func detach() {
        for (command, target) in targets { command.removeTarget(target) }
        targets = []
        rateObservation = nil
        statusObservation = nil
        if let seekObserver { NotificationCenter.default.removeObserver(seekObserver) }
        seekObserver = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        player = nil
    }

    private func pushDynamicInfo() {
        guard let player, let item = player.currentItem else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        let duration = item.duration.seconds
        if duration.isFinite {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime().seconds
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.rate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()
        add(center.playCommand) { player, _ in
            player.play()
            return .success
        }
        add(center.pauseCommand) { player, _ in
            player.pause()
            return .success
        }
        add(center.togglePlayPauseCommand) { player, _ in
            player.rate == 0 ? player.play() : player.pause()
            return .success
        }
        add(center.changePlaybackPositionCommand) { player, event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            player.seek(to: CMTime(seconds: event.positionTime, preferredTimescale: 600))
            return .success
        }
    }

    /// Remote-command handlers arrive on the main thread but the closure type is
    /// nonisolated under Swift 6; assumeIsolated bridges without a hop.
    private func add(
        _ command: MPRemoteCommand,
        handler: @escaping @MainActor (AVPlayer, MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        let target = command.addTarget { [weak self] event in
            MainActor.assumeIsolated {
                guard let player = self?.player else { return .commandFailed }
                return handler(player, event)
            }
        }
        targets.append((command, target))
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

```bash
cd ios/PatataTube && xcodegen generate
xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`. If Swift 6 concurrency errors appear in the KVO or addTarget closures, fix by keeping the `Task { @MainActor in ... }` / `MainActor.assumeIsolated` patterns shown above — do not mark the class `@unchecked Sendable`.

- [ ] **Step 3: Commit**

```bash
git add ios/PatataTube/Sources/NowPlayingManager.swift
git commit -m "feat(ios): add NowPlayingManager for lock screen controls"
```

---

### Task 3: PlayerViewController representable

**Files:**
- Create: `ios/PatataTube/Sources/PlayerViewController.swift`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces (used by Task 4): `struct PlayerViewController: UIViewControllerRepresentable` with init `PlayerViewController(player: AVPlayer, attached: Bool)`. When `attached` is false the controller's `player` is set to nil (video layer released, audio keeps running); when true it is (re)attached.

- [ ] **Step 1: Create the file**

```swift
// ios/PatataTube/Sources/PlayerViewController.swift
import SwiftUI
import AVKit

/// AVPlayerViewController wrapper. iOS pauses any player attached to a video
/// layer when the app backgrounds, so `attached` lets the parent detach the
/// player (audio continues) and reattach on foreground.
struct PlayerViewController: UIViewControllerRepresentable {
    let player: AVPlayer
    let attached: Bool

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = false
        // NowPlayingManager owns the lock screen; stop AVKit competing for it.
        controller.updatesNowPlayingInfoCenter = false
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if attached {
            if controller.player !== player { controller.player = player }
        } else if controller.player != nil {
            controller.player = nil
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

```bash
cd ios/PatataTube && xcodegen generate
xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add ios/PatataTube/Sources/PlayerViewController.swift
git commit -m "feat(ios): add AVPlayerViewController representable with detachable player"
```

---

### Task 4: Rewrite VideoPlayerView

**Files:**
- Modify: `ios/PatataTube/Sources/VideoPlayerView.swift` (full rewrite)

**Interfaces:**
- Consumes: `PlayerViewController(player:attached:)` from Task 3; `NowPlayingManager.attach(player:title:)`, `.setArtwork(_:)`, `.detach()` from Task 2; existing `AppModel.streamURL(for:)`, `.hlsURL(for:)`, `model.cache.state(for:versionId:)`, `model.cache.localURL(for:versionId:)`, `model.api.imageData(path:)`, `model.credentials.token`.
- Produces: same public shape as today — `VideoPlayerView(video:)` with `AppModel` environment object. No caller changes.

- [ ] **Step 1: Replace the file contents**

```swift
// ios/PatataTube/Sources/VideoPlayerView.swift
import SwiftUI
import AVKit
import PatataTubeKit

struct VideoPlayerView: View {
    let video: Video
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var player: AVPlayer?
    @State private var nowPlaying = NowPlayingManager()
    /// false while backgrounded: player detached from the video layer so audio continues.
    @State private var attached = true
    /// Live vertical drag offset for the pull-down-to-dismiss gesture.
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea().opacity(backdropOpacity)
            if let player {
                PlayerViewController(player: player, attached: attached)
                    .ignoresSafeArea()
                    .onAppear { player.play() }
                    .offset(y: dragOffset)
                    .scaleEffect(dragScale)
            } else {
                ProgressView().tint(.white)
            }
        }
        .simultaneousGesture(pullDownToDismiss)
        .task { await setup() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                attached = false
                player?.play()   // keep audio rolling without the video layer
            case .active:
                attached = true
            default:
                break
            }
        }
        .onDisappear {
            player?.pause()
            nowPlaying.detach()
            deactivateAudioSession()
        }
    }

    /// Vertical-only drag; horizontal moves (scrubbing) and taps fall through to AVKit controls.
    private var pullDownToDismiss: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                let dy = value.translation.height
                let dx = value.translation.width
                // Only engage on a downward, vertically-dominant drag.
                guard dy > 0, abs(dy) > abs(dx) else { return }
                dragOffset = dy
            }
            .onEnded { value in
                if value.translation.height > 150 {
                    dismiss()
                } else {
                    withAnimation(.spring()) { dragOffset = 0 }
                }
            }
    }

    private var dragScale: CGFloat { max(1 - dragOffset / 1000, 0.85) }
    private var backdropOpacity: Double { max(1 - dragOffset / 400, 0.4) }

    private func setup() async {
        activateAudioSession()
        let player: AVPlayer
        if model.cache.state(for: video.id, versionId: video.chosenVersionId) == .cached {
            // Offline MP4 wins: instant, no network. (HLS offline is a later phase.)
            player = AVPlayer(url: model.cache.localURL(for: video.id, versionId: video.chosenVersionId))
        } else if let hlsURL = model.hlsURL(for: video) {
            // Remote HLS exposes native subtitle tracks in the AVKit controls.
            player = AVPlayer(playerItem: AVPlayerItem(asset: authedAsset(url: hlsURL)))
        } else if let url = model.streamURL(for: video) {
            // Direct MP4 fallback for rows without an HLS package.
            player = AVPlayer(playerItem: AVPlayerItem(asset: authedAsset(url: url)))
        } else {
            return
        }
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        self.player = player
        nowPlaying.attach(player: player, title: video.title ?? video.sourceFilename ?? "PatataTube")
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem, queue: .main
        ) { _ in
            Task { @MainActor in dismiss() }
        }
        await loadArtwork()
    }

    /// Best-effort lock-screen artwork; controls work without it.
    private func loadArtwork() async {
        guard let path = video.previewUrl,
              let data = try? await model.api.imageData(path: path),
              let image = UIImage(data: data) else { return }
        nowPlaying.setArtwork(image)
    }

    /// AVURLAsset carrying the bearer token; AVPlayer reuses these headers for
    /// the HLS playlist, segment, and subtitle sub-requests on the same asset.
    private func authedAsset(url: URL) -> AVURLAsset {
        var options: [String: Any] = [:]
        if let token = model.credentials.token {
            options["AVURLAssetHTTPHeaderFieldsKey"] = ["Authorization": "Bearer \(token)"]
        }
        return AVURLAsset(url: url, options: options)
    }

    /// A `.playback` session is what lets audio continue in the background and
    /// AVPlayer send full video (not just audio) over AirPlay.
    private func activateAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            // Non-fatal — leave local playback running.
        }
    }

    /// Release the session on dismiss so other apps' audio can resume.
    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // Non-fatal.
        }
    }
}
```

Notes for the implementer:
- The play-to-end observer now wraps `dismiss()` in `Task { @MainActor in ... }` because the notification closure is nonisolated under Swift 6 (the old file predates the rewrite; keep this form).
- Do not re-add `VideoPlayer` from AVKit; the representable replaces it.
- `.task { await setup() }` replaces the old sync `setup()`; the artwork fetch is the only await inside.

- [ ] **Step 2: Build to verify it compiles**

```bash
cd ios/PatataTube && xcodegen generate
xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add ios/PatataTube/Sources/VideoPlayerView.swift
git commit -m "feat(ios): rewrite player around AVPlayerViewController for background audio"
```

---

### Task 5: Manual test checklist + on-device verification

**Files:**
- Modify: `ios/README.md` (append to the manual test checklist section)

**Interfaces:**
- Consumes: the complete feature from Tasks 1–4.
- Produces: updated manual checklist; verified feature.

- [ ] **Step 1: Append to the manual checklist in `ios/README.md`**

Find the existing manual test checklist section and append:

```markdown
### Background audio
- [ ] Play a video, lock the phone → audio continues; lock screen shows title, artwork, and controls
- [ ] Play/pause and scrub from the lock screen and Control Center
- [ ] Switch apps mid-playback → audio continues
- [ ] Return to the app → video resumes in sync with audio
- [ ] Video ends while locked → playback stops and lock screen controls clear
- [ ] Pull-down-to-dismiss still works; AVKit tap/scrub controls still work
- [ ] AirPlay still works (full video on the external screen)
```

- [ ] **Step 2: Run the checklist on a device**

Simulator cannot exercise the lock screen properly — this needs a real iPhone/iPad. Build and run from Xcode (`cd ios/PatataTube && xcodegen generate && open PatataTube.xcodeproj`), then walk every new checklist item plus the no-regression list from Global Constraints. Report any failure instead of marking done.

- [ ] **Step 3: Commit**

```bash
git add ios/README.md
git commit -m "docs(ios): add background audio to manual test checklist"
```
