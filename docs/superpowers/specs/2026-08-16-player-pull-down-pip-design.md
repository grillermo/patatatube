# Pull down for Picture in Picture — design

Date: 2026-08-16
Status: approved, ready for implementation planning

## Problem

Pulling down inside `VideoPlayerView` dismisses the player
(`VideoPlayerView.swift:181`, `pullDownToDismiss`). Leaving the video means
losing it: there is no way to keep watching while browsing the grid, adding to
a group, or using the web bridge.

The gesture should instead send the video to Picture in Picture, the way
YouTube and Safari do — the video keeps playing in a floating window and the
app returns to whatever was underneath.

## Goal

A downward pull past the existing threshold starts PiP and returns the user to
the grid, with playback uninterrupted. The full-screen player remains
reachable via the PiP window's restore button.

## Decisions taken

Recorded because each had a cheaper alternative that was considered and rejected:

- **Dismiss gets its own affordance.** With pull-down repurposed, the player
  has no exit — AVKit shows no close button when embedded inline in a
  `fullScreenCover`. A close button is added to the existing overlay rather
  than overloading the same drag with two thresholds or adding a second
  (swipe-up) gesture.
- **PiP is started by firing AVKit's own button, not by hosting our own
  `AVPictureInPictureController`.** Verified against the SDK headers on this
  machine: `AVPlayerViewController.h` exposes only
  `allowsPictureInPicturePlayback`, `canStartPictureInPictureAutomaticallyFromInline`
  (background-only), and delegate callbacks — **there is no public method to
  start PiP programmatically**, and `AVPictureInPictureController` can only be
  constructed from an `AVPlayerLayer`, which `AVPlayerViewController` does not
  expose. The alternative (a window-level `AVPlayerLayer` host owning the
  player, all public API) was rejected as too much machinery; the cost is a
  dependency on AVKit's private view hierarchy, mitigated by the fallback and
  the tests below.
- **PiP keeps playing when the app is backgrounded.** No explicit teardown on
  `scenePhase == .background` — that is both less code and what PiP is for.
- **Restore rebuilds the player rather than threading a live one back.**
  Sub-second re-buffer, no ownership plumbing through the `fullScreenCover`.

## Gesture behavior

`pullDownToPiP` replaces `pullDownToDismiss` with its geometry unchanged: 20pt
minimum distance, engages only on a downward, vertically-dominant drag, commits
past 150pt, and keeps the existing `dragScale` / `backdropOpacity` rubber-band
feedback. Horizontal moves (AVKit scrubbing) and taps still fall through.

On commit it asks the coordinator to start PiP. **The gesture is never a dead
end:** if PiP cannot start, it falls back to `dismiss()` — today's behavior.
Three cases route to the fallback:

1. `AVPictureInPictureController.isPictureInPictureSupported()` is false.
2. The PiP button cannot be located in the view hierarchy.
3. AVKit reports `playerViewController(_:failedToStartPictureInPictureWithError:)`.

Case 3 arrives asynchronously, after the gesture has ended, so the fallback
dismiss is invoked from the delegate callback rather than inline.

## Starting PiP

`allowsPictureInPicturePlayback` flips from `false` to `true`
(`PlayerViewController.swift:78`).

The starter is a free function over a `UIView`, deliberately isolated from
`AVPlayerViewController` so it is unit-testable:

```swift
func pictureInPictureButton(in root: UIView) -> UIControl?
```

It breadth-first walks the subview tree for a `UIControl` matching AVKit's PiP
button, then the caller sends `.touchUpInside`. Matching is by
`accessibilityIdentifier` and, failing that, by the button's image compared
against `AVPictureInPictureController.pictureInPictureButtonStartImage` — a
documented class property, so at least one of the two signals is public API.

## Surviving the cover dismissal

AVKit auto-dismisses *its own* presentation when PiP starts, but cannot dismiss
a SwiftUI `fullScreenCover`. So `PlayerViewController.Coordinator` adopts
`AVPlayerViewControllerDelegate`:

- `playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart` → `false`
- `playerViewControllerDidStartPictureInPicture` → set `pipActive`, then dismiss
  the cover ourselves.

Dismissing runs `VideoPlayerView.onDisappear` (`:157-177`), which today tears
down unconditionally — `player?.pause()`, `deactivateAudioSession()`,
`nowPlaying.detach()`, observer removal — all of which would kill PiP. It gains
a handoff branch gated on `pipActive`:

| Step | Normal dismiss | Handoff to PiP |
|---|---|---|
| `reportPosition()` | yes | yes |
| `horizontalLock.endPlayerSession()` | yes | yes |
| `playbackProbe.detach()`, ready observers | yes | yes |
| `player?.pause()` | yes | **no** |
| `deactivateAudioSession()` | yes | **no** |
| `nowPlaying.detach()` | yes | **no** |
| position time observer removed | yes | **no** (keeps reporting during PiP) |

The gate is expressed as a pure function alongside the existing
`Self.canContinueSetup`, so it is testable without a view.

A `PiPCoordinator` (`ObservableObject`, owned by `AppModel` so it outlives the
cover) holds while PiP is active: a strong `AVPlayer` reference, the
`PlaybackQueue` snapshot needed to restore, and the active flag the grid reads.

## Restore and close

- **Restore button** → `playerViewController(_:restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:)`
  sets `playing` to a fresh `PlaybackQueue` carrying the same videos and index
  with `startSecs` = the player's current time, reusing the existing
  re-presentation path at `VideoGridView.swift:823`. Calls the completion
  handler with `true`.
- **PiP window's X** → `playerViewControllerDidStopPictureInPicture` without a
  preceding restore: run the teardown `onDisappear` skipped — pause, release
  the player, `deactivateAudioSession()`, `nowPlaying.detach()` — and clear the
  coordinator.

## Close button

A third control in `HorizontalLockOverlay`'s `VStack`
(`HorizontalLockOverlay.swift:48`): `xmark` in the same 44pt
`.black.opacity(0.55)` circle, placed above the lock and moon icons, driven by
a new `onClose: () -> Void`, accessibility label "Close player". It inherits
the overlay's 4-second auto-hide, so the same tap that reveals the lock and
sleep controls reveals it.

## Files

New:

- `ios/PatataTube/Sources/PiPCoordinator.swift` — active flag, retained player,
  queue snapshot, restore/stop handling.

Edited:

- `ios/PatataTube/Sources/PlayerViewController.swift` — `allowsPictureInPicturePlayback = true`,
  the button finder, `AVPlayerViewControllerDelegate` conformance on `Coordinator`.
- `ios/PatataTube/Sources/VideoPlayerView.swift` — `pullDownToPiP` and its
  fallback, the `onDisappear` handoff gate, wiring `onClose`.
- `ios/PatataTube/Sources/HorizontalLockOverlay.swift` — the close button.
- `ios/PatataTube/Sources/AppModel.swift` — owns the `PiPCoordinator`.
- `ios/PatataTube/Sources/VideoGridView.swift` — re-presentation on restore.
- `ios/PatataTube/Tests/PlayerViewControllerTests.swift`,
  `HorizontalLockOverlayTests.swift` — see below.

Untouched: the backend, PatataTubeKit, `Info.plist` (`UIBackgroundModes`
already contains `audio`, which is what PiP requires).

## Implementation order

**Step one is a throwaway spike, before anything else is built.** The whole
approach rests on one assumption the headers do not settle: that AVKit's PiP
keeps running after *our* cover is dismissed, given AVKit is no longer
dismissing its own presentation. Flip the flag, fire the button, dismiss the
cover, and watch whether the float survives. If it does not, this design is
dead and the window-level `AVPlayerLayer` host is the only route — stop and
re-plan rather than working around it.

Only after the spike answers yes: the button finder and its tests, the
`onDisappear` gate, the coordinator, restore, then the close button.

## Testing

New unit tests in `PatataTubeTests` (the `xcodebuild`-only target):

- `pictureInPictureButton(in:)` against a synthetic view tree (found nested,
  absent, first match wins) **and** against a real `AVPlayerViewController`
  with `allowsPictureInPicturePlayback = true`, so an OS change that moves the
  button fails a test instead of silently disabling the gesture.
- The `onDisappear` teardown gate: `pipActive` true keeps the player, audio
  session, and now-playing alive; false tears everything down as today.
- The gesture's commit decision (threshold, downward-only,
  vertical-dominance) as a pure function, in the style of
  `VideoGridViewTests.dismissesOnlyForDominantHorizontalFlicksPastThreshold`.
- `HorizontalLockOverlayTests`: the close button exists, is hidden with the
  rest of the overlay, and invokes `onClose`.

Note that `PatataTubeTests` only ever builds through `xcodebuild`, so it rots
silently — this change touches `ios/PatataTube/Sources/`, so that target must
be built. Per CLAUDE.md, tests are run only when the user asks.

Manual checks: pull down starts PiP and returns to the grid with video playing;
restore reopens the player at the right time; the PiP X ends playback cleanly;
the close button dismisses without PiP; backgrounding during PiP keeps the
float alive; PiP during a Plex HLS stream with a chosen audio/subtitle track;
the fallback path (simulator without PiP support) still dismisses.

## Verification

```bash
cd ios/PatataTube && xcodegen generate
xcodebuild -project PatataTube.xcodeproj -scheme PatataTube \
  -destination "platform=iOS Simulator,id=$(xcrun simctl list devices available | grep -m1 -o '[0-9A-F-]\{36\}')" build
```
