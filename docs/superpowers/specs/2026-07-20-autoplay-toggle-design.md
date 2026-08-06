# Autoplay toggle — design

Date: 2026-07-20
Status: approved, ready for planning

## Goal

Add an autoplay switch to the iOS app. When on, a finished video automatically starts the next
video in the same queue, in list order. When off, playback stops at the end of a video.

The switch appears in two toolbars — `EpisodesView` and `VideoGridView` — and both read and write
the same state, so flipping one flips the other.

## Existing behavior this replaces

`VideoPlayerView.bindPlayToEnd()` observes `AVPlayerItemDidPlayToEndTime` and today decides by
application state alone:

- foreground → `dismiss()`
- backgrounded/locked → `advance(by: 1)`

The queue machinery already exists and is reused unchanged: `PlaybackQueue` (videos + start index,
snapshotted at tap time), `advance(by:)`, and `playableIndex(from:direction:)` which skips entries
with no playable source.

## Decisions

| Question | Decision |
|---|---|
| State scope | Global, session-only. Resets to off on relaunch. No `AppStorage`. |
| End of queue with autoplay on | Dismiss the player (existing `advance()` fallback). |
| Toggle UI | SwiftUI `Toggle` with `.switch` style, labeled with a custom autoplay icon. |
| Reach | Toggle visible in both `EpisodesView` and `VideoGridView`; shared state. |
| Background behavior | The flag governs both foreground and background. Autoplay off + locked now stops at the end instead of advancing. |

## Architecture

### State

`AppModel` (already an `@EnvironmentObject` in `EpisodesView`, `VideoGridView`, and
`VideoPlayerView`) gains:

```swift
@Published var autoplay: Bool = false
```

Session-only by construction — nothing persists it. No new environment injection, no new plumbing
through `PlaybackQueue`. Passing the flag through `PlaybackQueue` was rejected: that value is
snapshotted at tap time, so toggling mid-playback would not take effect.

### End-of-playback decision

The decision moves out of the SwiftUI view into a pure function in `PatataTubeKit`, so it is
testable without a running player. New file `PlaybackEndAction.swift`:

```swift
public enum PlaybackEndAction: Equatable {
    case advance   // play the next playable video in the queue
    case dismiss   // close the player
    case stop      // pause, leave the player mounted
}

public func playbackEndAction(autoplay: Bool, isForeground: Bool) -> PlaybackEndAction
```

| autoplay | foreground | action |
|---|---|---|
| on | yes | `.advance` |
| on | no | `.advance` |
| off | yes | `.dismiss` |
| off | no | `.stop` |

`bindPlayToEnd()` calls this instead of its inline `applicationState == .active` check. It keeps
reading `UIApplication.shared.applicationState` and `model.autoplay` *at fire time* — a
closure-captured value would be frozen at bind time, which is why the current code reads
`applicationState` inside the closure.

`advance(by:)` is unchanged. Its existing queue-end fallback (pause, then dismiss if foreground)
gives the approved "dismiss at end of queue" behavior for free.

### Toolbar UI

Icon asset, generated once with `rsvg-convert` (librsvg, `/opt/homebrew/bin`) from a
user-supplied SVG — a circular-arrow-with-play glyph, `16 16` viewBox, single black `path` — and
committed:

```
rsvg-convert -w 24 -h 24 autoplay.svg -o autoplay.png
rsvg-convert -w 48 -h 48 autoplay.svg -o autoplay@2x.png
rsvg-convert -w 72 -h 72 autoplay.svg -o autoplay@3x.png
```

Output goes to `ios/PatataTube/Sources/Assets.xcassets/Autoplay.imageset/`, with
`"template-rendering-intent": "template"` in `Contents.json` so the glyph tints with the control
(accent when on, secondary when off) and reads correctly in dark mode. The source SVG is kept
alongside the PNGs for regeneration.

Shared view, new file `ios/PatataTube/Sources/AutoplayToggle.swift`:

```swift
struct AutoplayToggle: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Toggle(isOn: $model.autoplay) {
            Image("Autoplay").renderingMode(.template)
        }
        .toggleStyle(.switch)
        .accessibilityLabel("Autoplay")
    }
}
```

Placement:

- `EpisodesView` — a new `ToolbarItem(placement: .topBarTrailing)` declared *before* the existing
  download-all item, so the switch sits to its left.
- `VideoGridView` — the same item appended to its existing `.topBarTrailing` group (cell size −/+,
  refresh, upload).

## Edges

- Lock-screen next/previous buttons (`NowPlayingManager.onNext` / `onPrevious`) keep working
  regardless of the flag. Autoplay governs only *automatic* end-of-item behavior.
- `.stop` (off + backgrounded) pauses and leaves the player mounted. Returning to the app shows the
  paused end frame; the user dismisses manually. Nothing dismisses while backgrounded.
- Queue end + autoplay on + backgrounded: `advance()` pauses without dismissing, as today.
- Videos with no playable source are already skipped by `playableIndex`; autoplay inherits that.

## Testing

**`PatataTubeKit/Tests/PatataTubeKitTests/PlaybackEndActionTests.swift`** — the four-row truth
table above. Pure function, no SwiftUI, no player.

**`PatataTube/Tests/EpisodesViewTests.swift`** — follows the existing ViewInspector pattern: the
toolbar contains the toggle, and flipping it sets `model.autoplay`.

No equivalent `VideoGridView` inspector test. That view needs a live `VideoStore` and network
fixtures, and the toggle under test is the same shared subview — the cost outweighs the signal.

**Manual checklist**, added to `ios/README.md`:

- autoplay on → an episode ends → the next one starts, in list order
- autoplay on → the last episode ends → the player dismisses
- autoplay off → an episode ends → the player dismisses
- autoplay off + locked screen → audio stops at the end of the video
- flipping the switch in `EpisodesView` shows it flipped in `VideoGridView`

## Files touched

| File | Change |
|---|---|
| `ios/PatataTube/Sources/AppModel.swift` | `@Published var autoplay` |
| `ios/PatataTubeKit/Sources/PatataTubeKit/PlaybackEndAction.swift` | new — enum + pure function |
| `ios/PatataTube/Sources/VideoPlayerView.swift` | `bindPlayToEnd()` calls `playbackEndAction` |
| `ios/PatataTube/Sources/AutoplayToggle.swift` | new — shared toolbar control |
| `ios/PatataTube/Sources/EpisodesView.swift` | +1 toolbar item |
| `ios/PatataTube/Sources/VideoGridView.swift` | +1 toolbar item |
| `ios/PatataTube/Sources/Assets.xcassets/Autoplay.imageset/` | new — SVG + 3 PNGs + `Contents.json` |
| `ios/PatataTubeKit/Tests/PatataTubeKitTests/PlaybackEndActionTests.swift` | new |
| `ios/PatataTube/Tests/EpisodesViewTests.swift` | + toggle tests |
| `ios/README.md` | + manual checklist entries |

Run `cd ios/PatataTube && xcodegen generate` after adding the new source files and the imageset.
