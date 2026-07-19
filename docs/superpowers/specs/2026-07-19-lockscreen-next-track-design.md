# Lock-Screen Next/Previous Track + Auto-Play — Design

**Date:** 2026-07-19
**Status:** Approved

## Goal

While a video plays with the phone locked, the lock-screen next button starts the
next video's audio. Previous button works too. A new auto-play setting makes
videos advance automatically when one ends, both locked and unlocked.

## Current state

- `NowPlayingManager` registers play/pause/toggle/seek remote commands only.
- `VideoPlayerView` receives a single `Video`; it has no knowledge of the list
  it was launched from. Presented via `fullScreenCover(item: $playing)` in
  `VideoGridView`.
- On `AVPlayerItemDidPlayToEndTime` the player dismisses.

## Design (Approach A — playlist passed into the player view)

The player keeps its single-`AVPlayer` architecture. Track changes are
`replaceCurrentItem(with:)` on the existing player, so background audio and the
active `.playback` audio session carry over. The `fullScreenCover` stays alive
while the phone is locked, so the SwiftUI view can service remote commands.

### 1. Auto-play setting

- `SettingsView` gains a "Auto-play next video" `Toggle` bound to
  `@AppStorage("autoPlayNext")`, default **off**.
- When **on**: a video ending advances to the next video (foreground and
  locked). When **off**: current behavior — dismiss on end.

### 2. Queue source

- `VideoGridView` passes the currently visible filtered/sorted list (the exact
  array the grid renders) plus the tapped index into `VideoPlayerView`.
- The queue is a snapshot at tap time; later grid refreshes don't mutate it.
- Same mechanism covers episode playback since episodes launch through the same
  cover.

### 3. VideoPlayerView

- Signature becomes `VideoPlayerView(videos: [Video], startIndex: Int)`
  (single-video callers pass `[video], 0`).
- `@State currentIndex`. `advance(by: Int)`:
  - Bounds-check; out of range → stop (pause; dismiss if foreground).
  - Build the new `AVPlayerItem` with the existing per-video source logic
    (cached MP4 → HLS → direct MP4), `replaceCurrentItem(with:)`, `play()`.
  - Re-register the play-to-end observer for the new item (it is bound to
    `player.currentItem`).
  - Push new title via `NowPlayingManager.updateTitle`, reload artwork.
- Play-to-end handler: `autoPlayNext ? advance(by: 1) : dismiss()`.
- Previous follows the iOS convention: elapsed > 3 s → seek to 0;
  otherwise `advance(by: -1)` (at index 0 → seek to 0).

### 4. NowPlayingManager

- Register `nextTrackCommand` and `previousTrackCommand`; expose `onNext` /
  `onPrevious` closures the view sets before `attach`.
- Enable/disable the commands based on queue position
  (`isEnabled` on the commands) so the lock screen greys them out at the ends.
- New `updateTitle(_ title: String)` to refresh `MPMediaItemPropertyTitle`
  without re-attaching; artwork continues through `setArtwork`.
- The seek/time-jump observer must re-bind when the current item is replaced
  (observe with `object: nil` filtered by player, or re-add per item).

## Error handling

- A video in the queue with no playable source (no cache, no URLs): skip it and
  continue to the following one; if none remain, stop.
- Artwork load failures stay best-effort (existing behavior).

## Testing

No iOS test target exists. Manual checklist (add to `ios/README.md`):

1. Play from grid, lock phone → next button plays next video's audio; title
   updates on lock screen.
2. Previous within first 3 s → prior video; after 3 s → restarts current.
3. Last video + next → playback stops.
4. Auto-play ON: video ends (foreground) → next starts full-screen; (locked) →
   next audio starts.
5. Auto-play OFF: video ends → player dismisses (current behavior).
6. Filtered grid (e.g. "children"): queue respects the filter.

## Out of scope

- App-level playback controller / mini-player.
- Reflecting grid refreshes into an active queue.
- Gapless preloading of the next item.
