# List-view audio-only playback

**Date:** 2026-08-23
**Status:** approved, ready for an implementation plan

## Goal

In the pushed **group detail** screen, when it is in **list mode**, tapping a
row plays that video's **audio only** — no full-screen player is presented, and
the user keeps browsing. Autoplay advances to the next row's audio; randomize
picks randomly. The row's thumbnail carries a play/pause overlay, and tapping
the row again toggles playback.

Nothing about downloads, `StreamProxy`, HLS packaging, or the server changes.

## Decisions

| Question | Decision |
|---|---|
| Where it applies | Group detail only (`currentGroupID != nil && displayMode == .list`). Movies list, TV episodes and the all-videos feed keep the full-screen player. |
| Lifetime | Audio survives grid switches, back navigation, tab changes and backgrounding. It stops only on pause, queue end, or a full-screen player starting. |
| Resume positions | Not honored, not written. Audio always starts at 0; no resume alert, no `PlaybackPositionReporter`. |
| Lock screen | Full Now Playing: title, artwork, play/pause, next/previous. |
| Queue | The group's currently filtered/searched list. Autoplay and randomize read the existing per-scope `model.autoplay(for:)` / `model.randomize(for:)` — same switches as the video player. |
| Not-ready rows | Unchanged: `ensureReady`/`/prepare` runs, then audio starts. Unplayable rows are skipped during autoplay. |
| Video escape hatch | **None.** "Play and sleep" also becomes audio-only. To watch, leave list mode. |
| Concurrency | Any full-screen player presentation stops audio first. One source at a time. |

## Architecture

The queue rules, the source-selection chain, the audio session, and the
NowPlaying wiring currently live as ~800 lines of **private methods inside
`VideoPlayerView`**, a SwiftUI view. Audio-only needs almost exactly that logic
minus `AVPlayerViewController`, and it must outlive the view. So: extract the
shared core, then build the audio player on top.

### New: `PatataTubeKit/Sources/PatataTubeKit/QueueNavigator.swift`

Pure and testable. Takes `[Video]` plus an injected `isPlayable: (Video) -> Bool`
and owns what today are `playableIndex`, `hasAnyPlayableVideo`,
`playableVideoIndices`, `randomStep`, and the `playbackOrder` / `orderPosition`
cursor. Sequential-vs-random stepping, the reshuffle that avoids a back-to-back
repeat, and the "at queue start" rule behind *previous* all move here unchanged.
It already depends on `PlaybackOrder.shuffledPlaybackOrder`, which lives in the
kit — this is the missing half of that file.

### New: `ios/PatataTube/Sources/PlaybackSource.swift`

App-target, because it needs `AppModel`'s `cache`, `streamProxy` and URL
builders. Holds today's `playerItemWithSource` verbatim — the
`local_mp4 → offline_hls → proxy_hls → direct_hls → proxy_mp4 → direct_mp4`
chain, its `log:` flag, and its DevLog `source -> x` line with all of its
diagnostic metadata.

```swift
static func item(for video: Video, model: AppModel, log: Bool = true)
    -> (item: AVPlayerItem, source: String)?
```

This is the subtlest code in the app and the last thing that should exist
twice; duplicating it means audio silently plays from the wrong source the
first time one copy gains a fallback.

### New: `ios/PatataTube/Sources/AudioQueuePlayer.swift`

`@MainActor final class AudioQueuePlayer: ObservableObject`, owned by
`AppModel` as `let audio = AudioQueuePlayer()`. That ownership is what makes
"keeps playing everywhere" true.

Holds one `AVPlayer` (no `AVPlayerViewController`, no PiP, no view), a
`QueueNavigator`, and a `NowPlayingManager` whose `onNext`/`onPrevious` drive
the navigator. Same `.playback` / `.moviePlayback` session activate on start
and deactivate on stop. An `AVPlayer` over a video asset simply renders no
frames when nothing displays it — there is no audio-only asset to build.

- Published: `currentID: Int?`, `isPlaying: Bool`, `isLoading: Bool`.
- API: `start(queue:startIndex:scope:sleepMode:)`, `toggle()`, `stop()`.
- Autoplay/randomize read `model.autoplay(for: scope)` / `model.randomize(for: scope)`
  **at fire time**, not captured — matching `bindPlayToEnd`'s existing reason.
- Item end goes through the same `playbackEndAction` decision, so sleep mode
  plays one item and then runs the black-screen Shortcut.
- No position recording of any kind.

### Changed: `VideoPlayerView`

Loses ~150 lines to the two extractions and keeps every behavior. This is the
regression surface, and `PatataTubeTests` is what guards it.

### Changed: `VideoRow`

Gains one value parameter, `audioState: RowAudioState` (`.idle`, `.loading`,
`.playing`, `.paused`) — a plain enum in the app target next to `VideoRow`,
since it describes a row, not playback. Stays dumb — plain values and closures, no `AppModel`,
consistent with the rest of the row. The thumbnail keeps rendering and gains a
dimmed overlay carrying `play.fill` / `pause.fill`; `.idle` draws nothing,
`.loading` a small spinner. Tapping the row body starts playback when `.idle`
and calls `toggle()` otherwise. The ellipsis menu is unchanged except that
"Play and sleep" routes to audio.

### Changed: `VideoGridView`

`defaultGrid` picks the audio tap handler when
`currentGroupID != nil && displayMode == .list`, and passes each row its
`audioState` from an observed `model.audio`. Every `fullScreenCover`
presentation calls `model.audio.stop()` first.

## Error handling

- Queue exhausted with autoplay off → pause, clear `currentID`, deactivate the
  session. Nothing is presented, so nothing is dismissed.
- No playable source anywhere in the queue → stop and clear, same path.
- `ensureReady` failure → existing behavior (`store.errorText`), row returns to
  `.idle`.

## Testing

Cadence agreed with the user, and narrower than the default in `CLAUDE.md`:

- **Per step:** `cd ios/PatataTubeKit && swift test --filter QueueNavigatorTests`.
  Seconds, filter works reliably here. New coverage for rules that have never
  been unit-testable: random reshuffle avoiding back-to-back repeats,
  unplayable entries excluded from the pool, previous-at-queue-start,
  sequential end-of-queue.
- **At milestones only:** the app target, skipping the suite that hangs —
  `xcodebuild ... test -skip-testing:PatataTubeTests/EpisodesDownloadAllViewTests`.
  New `VideoRowTests` cover the four overlay states and the tap-toggle.

Never run either without asking first.

## Milestones

1. **Extraction lands.** `QueueNavigator` + `PlaybackSource` are out of
   `VideoPlayerView`; video playback behaves identically. Stop, run the app
   target, confirm.
2. **Audio-only works** in the group list: rows, queue, autoplay, randomize,
   lock screen. Stop, run the app target, confirm.
