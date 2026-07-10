# AirPlay Full-Video Routing to Apple TV — Design

**Date:** 2026-07-10
**Status:** Approved (design)
**Scope:** iOS app only (`ios/PatataTube/Sources/VideoPlayerView.swift`)

## Problem

Playing a video in the iPad app and casting to Apple TV routes **audio only** — video
stays on the device. The user wants full video + audio on the Apple TV, driven from a
convenient AirPlay icon in the player controls.

## Findings

- The player is SwiftUI `VideoPlayer(player:)` in `VideoPlayerView.swift`. AVKit's stock
  controls **already render an AirPlay icon** — no custom button needed.
- No `AVAudioSession` configuration exists anywhere in the app.
- No `allowsExternalPlayback` / external-playback config anywhere.
- Auth: player uses a Bearer-header-authed `AVURLAsset`
  (`AVURLAssetHTTPHeaderFieldsKey`). The server's `/videos/{id}/stream` and
  `/videos/{id}/hls/{asset}` endpoints also accept a `?token=` query fallback.
- HLS playlists (`hls.py`) reference child URLs **relatively** (`video.m3u8`,
  `segment_*.m4s`), so a query-param token would not propagate to segments — only header
  auth carries across HLS sub-requests today.

## Diagnosis

Audio reaches the Apple TV, so the receiver **is** getting the media — auth is not the
blocker (Apple forwards `AVURLAssetHTTPHeaderFieldsKey` to AirPlay receivers for HLS).
Audio-only while video stays local is the classic signature of **no active
`AVAudioSession`**. Without a `.playback` session, AVPlayer's external route degrades to
audio-only.

## Approach (chosen: A — minimal, iOS-only)

Fix routing in `VideoPlayerView.swift`. Keep the stock AirPlay icon, keep header auth,
keep HLS. Rejected: B (server m3u8 token rewrite — YAGNI, held as fallback), C (MP4-only
casting — regresses native subtitles).

## Changes (all in `VideoPlayerView.swift`)

1. **Audio session** — new private helper that configures the shared `AVAudioSession`:
   `category = .playback`, `mode = .moviePlayback`, then `setActive(true)`. This is the
   piece that flips AirPlay from audio-only to video+audio. Wrap in do/catch; swallow
   errors (local playback still works if the session call fails).

2. **Player flags** — in `setup()`, right after building `player`:
   - `player.allowsExternalPlayback = true` (explicit even though it defaults true)
   - `player.usesExternalPlaybackWhileExternalScreenIsActive = true`

3. **Lifecycle**:
   - Activate the audio session in `setup()` (runs from the existing `.task`).
   - In `onDisappear`: pause (exists today) + deactivate the session with
     `.notifyOthersOnDeactivation` so other apps' audio resumes. do/catch, swallow errors.

4. **Auth unchanged** — header-authed `AVURLAsset` + HLS path stay as-is.

## Testing / Verification

No automated iOS test target exists (see `ios/README.md`, manual checklist). Verify on a
**real device against a real Apple TV**, both player paths:

- Cached MP4 (`file://` local URL) → tap AirPlay icon → confirm **video** on the TV.
- Remote HLS → tap AirPlay icon → confirm **video** on the TV.
- Disengage AirPlay → playback returns to device cleanly.
- Background/return, and end-of-video dismiss, behave normally.

## Risk / Fallback

If HLS casts audio-only or errors on some tvOS versions (header not forwarded by the
receiver), fall back to **Approach B**: rewrite served `.m3u8` playlists on the fly to
append `?token=` to each child URI so HLS is self-authenticating for the receiver. Not
built now — documented contingency only.

## Non-goals

- No custom `AVRoutePickerView` overlay (stock icon chosen).
- No server changes.
- No HLS offline / subtitle-over-AirPlay work.
