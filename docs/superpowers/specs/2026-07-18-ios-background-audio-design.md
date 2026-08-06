# iOS Background Audio Playback — Design

Date: 2026-07-18
Status: Approved

## Goal

Audio from a playing video continues when the phone locks or the user switches
apps, with full lock-screen / Control Center controls (play, pause, scrub,
title, artwork). No Picture-in-Picture in this phase.

## Approach

Full rewrite of the player screen around `AVPlayerViewController` (chosen over
keeping SwiftUI `VideoPlayer` with a detach trick). Rationale: full control over
the player layer attachment, and a natural path to PiP later.

## Components

All changes live in the app target (`ios/PatataTube/Sources/`). PatataTubeKit is
untouched.

### 1. `PlayerViewController.swift` (new)

`UIViewControllerRepresentable` wrapping `AVPlayerViewController`.

- Takes the `AVPlayer` and exposes it to AVKit's native controls.
- Coordinator retains the `AVPlayerViewController` so the parent view can
  detach/reattach the player across scene phases.
- `allowsPictureInPicturePlayback` left at default; PiP not wired up (no
  background-auto-start), explicitly out of scope.

### 2. `NowPlayingManager.swift` (new, ~80 lines)

Owns lock-screen integration. Attached to exactly one `AVPlayer` at a time.

- `MPNowPlayingInfoCenter`: title (`video.title`), duration, elapsed time,
  playback rate. Updated on rate changes and seeks (not every time-observer
  tick). Artwork: best-effort thumbnail download through the existing authed
  image path; on failure, controls work without artwork.
- `MPRemoteCommandCenter`: play, pause, togglePlayPause,
  changePlaybackPosition (scrub). Commands drive the `AVPlayer` directly.
- Torn down (info cleared, command targets removed) when the player screen is
  dismissed or the video ends.

### 3. `VideoPlayerView.swift` (rewrite)

Same public shape (`video`, `AppModel` env object). Swaps `VideoPlayer` for the
representable and adds `@Environment(\.scenePhase)`.

Background continuation mechanism (Apple guidance): iOS pauses any player
attached to a video layer when the app backgrounds. On
`scenePhase == .background`: set `playerViewController.player = nil`, then
`player.play()`. On `.active`: reattach the player. The `AVPlayer` lives in
SwiftUI state and is never deallocated while the screen is open.

### 4. `project.yml`

Add `INFOPLIST_KEY_UIBackgroundModes: audio` to target settings; regenerate
`project.pbxproj` with `xcodegen generate`.

## Behaviors that must not regress

- Pull-down-to-dismiss gesture (`simultaneousGesture` over the representable;
  AVKit taps/scrubs must still fall through) — verify on device.
- Source selection order: cached local MP4 → remote HLS → direct MP4.
- Bearer-token `AVURLAsset` headers for HLS playlist/segment/subtitle requests.
- Dismiss on `AVPlayerItemDidPlayToEndTime`; also clears Now Playing info.
- AirPlay (`allowsExternalPlayback` + full video over external screen).
- Audio session: `.playback` / `.moviePlayback` activated on setup, deactivated
  with `.notifyOthersOnDeactivation` on dismiss.

## Error handling

- Artwork fetch failure: skip artwork, keep controls.
- Audio session activation/deactivation errors: non-fatal, as today.
- Interruption (phone call): default iOS behavior — playback pauses; user
  resumes from lock screen.

## Testing

No automated iOS test target exists. `swift build` on PatataTubeKit must still
pass (unaffected). Add to the manual checklist in `ios/README.md`:

1. Play video, lock phone → audio continues; lock screen shows title/controls.
2. Play/pause and scrub from lock screen and Control Center.
3. Switch apps mid-playback → audio continues.
4. Return to app → video resumes in sync.
5. Video ends while locked → playback stops, lock screen controls clear.
6. Pull-down-to-dismiss still works; AVKit tap/scrub controls still work.
7. AirPlay still works.
