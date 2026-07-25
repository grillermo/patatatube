# Randomize playback toggle

## Problem

Playback advance (manual next + autoplay-on-end) walks the classification's
video list strictly in server order. No way to get shuffled playback per
classification.

## Design

### Toggle

`VideoGridView.swift` overflow menu (`ellipsis.circle`, ~line 155-198) gains
a second `Toggle`, next to the existing Autoplay toggle:

```swift
Toggle(isOn: randomizeBinding) {
    Label("Randomize", systemImage: "shuffle")
}
```

`randomizeBinding` reads/writes `AppModel.randomizeByClassification[model.filter]`,
so each classification (children/adults/education/entertainment) remembers
its own on/off state independently, same lifetime as `autoplay` today
(session-only `@Published`, not persisted across relaunch).

```swift
// AppModel
@Published var randomizeByClassification: [String: Bool] = [:]

func randomize(for classification: String) -> Bool {
    randomizeByClassification[classification] ?? false
}
```

Works with or without autoplay — it only changes *which* video "next" points
to, not whether advance happens automatically.

### Queue

`PlaybackQueue` (PatataTubeKit) gains a precomputed `playbackOrder: [Int]`
(indices into `videos`), built once when the queue is created in
`VideoGridView.play(_:queueSnapshot:)`:

- Randomize off: `playbackOrder` = identity sequence `0..<videos.count`
  (today's behavior, unchanged, zero regression risk).
- Randomize on: Fisher-Yates shuffle of all indices, with `startIndex`
  (the tapped video) moved to the front — tapping a specific video still
  plays that video first, shuffle governs everything after it.

### Advance

`VideoPlayerView.advance(by:)` / `playableIndex(from:direction:)` currently
step `index ± 1` over the flat `videos` array. Change to move a cursor over
`playbackOrder` instead, skipping unplayable entries as today.

- **Forward, cursor has room**: move to next position in `playbackOrder`.
- **Forward, cursor exhausted** (played through the whole shuffled order):
  reshuffle the full playable pool, excluding the just-finished video from
  the front (no immediate back-to-back repeat), append as the new tail of
  `playbackOrder`, and continue advancing into it. This applies identically
  whether "forward" was triggered by the manual next button or by
  `PlaybackEndAction.advance` (autoplay-on-end) — both call `advance(by:)`.
  Net effect with autoplay on: an infinite shuffled loop per classification.
- **Forward, exhausted, autoplay off**: unaffected by this change —
  `playbackEndAction(autoplay: false, ...)` already returns `.dismiss`/`.stop`
  before `advance(by:)` would be called, so playback still stops at the end
  of the (shuffled) queue exactly like it stops today at the end of the
  sequential queue. No reshuffle happens in this case.
- **Backward**: steps the cursor back through already-visited history in
  `playbackOrder`. No reshuffle on back.

Non-random mode's math is unchanged (`playbackOrder` is just identity), so
existing sequential behavior/tests aren't touched.

### Out of scope

- No persistence of toggle state or shuffle position across app relaunch.
- No changes to `PlaybackEndAction`'s decision logic (`.advance`/`.dismiss`/
  `.stop`/`.sleep`) — randomize only changes what "advance" advances *to*.
