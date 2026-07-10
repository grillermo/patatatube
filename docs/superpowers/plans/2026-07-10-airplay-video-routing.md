# AirPlay Full-Video Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make casting a playing video to Apple TV route full video + audio (not audio-only) from the stock AirPlay icon.

**Architecture:** iOS-only change in `VideoPlayerView.swift`. Activate a `.playback` `AVAudioSession` when the player appears and set explicit external-playback flags on the `AVPlayer` — the missing audio session is what degrades AirPlay to audio-only. Auth, HLS, and the stock AVKit AirPlay icon are untouched.

**Tech Stack:** SwiftUI, AVKit / AVFoundation (`AVPlayer`, `AVAudioSession`), XcodeGen target.

## Global Constraints

- No automated iOS test target exists — verification is **manual on a real device against a real Apple TV** (per `ios/README.md`).
- No server changes, no `PatataTubeKit` changes, no new files.
- Keep the stock AVKit AirPlay icon — do NOT add an `AVRoutePickerView`.
- Keep header-based auth (`AVURLAssetHTTPHeaderFieldsKey`) and the HLS path as-is.
- `AVAudioSession` calls throw — every call site wraps in `do/catch` and swallows errors (local playback must still work if session config fails).

---

### Task 1: Route full video to Apple TV via audio session + external-playback flags

**Files:**
- Modify: `ios/PatataTube/Sources/VideoPlayerView.swift`

**Interfaces:**
- Consumes: existing `setup()` (called from `.task`), existing `player` `@State`, existing `onDisappear` pausing the player.
- Produces: new private helpers `activateAudioSession()` and `deactivateAudioSession()`; no external API surface (view-internal only).

- [ ] **Step 1: Confirm current behavior baseline (manual)**

Build + run on device, play a video, tap the AirPlay icon in the player controls, select the Apple TV.
Expected (pre-fix): audio plays on the Apple TV, video stays on the iPad. Record this so the fix is provably a change.

- [ ] **Step 2: Add the audio-session helpers**

`import AVKit` already covers `AVAudioSession` (AVFoundation). Add these two private methods to `VideoPlayerView` (place them next to `authedAsset`):

```swift
/// A `.playback` session is what lets AVPlayer send full video (not just audio)
/// over AirPlay. Errors are non-fatal: local playback still works without it.
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
```

- [ ] **Step 3: Set explicit external-playback flags in `setup()`**

In `setup()`, after `self.player = player` (line ~68) and before the `NotificationCenter` observer, insert:

```swift
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
```

- [ ] **Step 4: Activate the session in `setup()`**

At the very start of `setup()` (before the `let player: AVPlayer` line), insert:

```swift
        activateAudioSession()
```

- [ ] **Step 5: Deactivate the session on disappear**

Change the existing `.onDisappear { player?.pause() }` (line ~29) to:

```swift
        .onDisappear {
            player?.pause()
            deactivateAudioSession()
        }
```

- [ ] **Step 6: Build**

Run:
```bash
cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS' build
```
Expected: build succeeds (BUILD SUCCEEDED). Fix any compile errors before proceeding.

- [ ] **Step 7: Verify — cached MP4 path (manual, on device + Apple TV)**

Pick a video that is already downloaded/cached (`file://` local URL path in `setup()`). Play it, tap the AirPlay icon, select the Apple TV.
Expected (post-fix): **video AND audio** play on the Apple TV; the iPad shows the AirPlay/external-playback state.

- [ ] **Step 8: Verify — remote HLS path (manual)**

Pick a non-cached video that has an HLS package (`hlsURL` branch). Play, AirPlay to Apple TV.
Expected: **video AND audio** on the Apple TV. If this path casts audio-only or errors while the MP4 path works, STOP and escalate to the spec's Approach B fallback (server m3u8 `?token=` rewrite) — do not hack it in the client.

- [ ] **Step 9: Verify — disengage + lifecycle (manual)**

Turn AirPlay off mid-playback → playback returns to the iPad cleanly. Pull-down-to-dismiss and end-of-video auto-dismiss still work. Background the app and return → no crash, audio/video state sane.

- [ ] **Step 10: Commit**

```bash
git add ios/PatataTube/Sources/VideoPlayerView.swift
git commit -m "feat(ios): route full video to Apple TV via playback audio session

Activate a .playback AVAudioSession and set explicit external-playback
flags so AirPlay sends video+audio instead of audio-only.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

- **Spec coverage:** audio session (Steps 2,4) ✓; external-playback flags (Step 3) ✓; lifecycle deactivate (Steps 2,5) ✓; auth/HLS unchanged ✓; stock icon (no AVRoutePickerView added) ✓; manual verify both paths (Steps 7–8) ✓; Approach B fallback referenced (Step 8) ✓.
- **Placeholders:** none — all code shown verbatim.
- **Type consistency:** helper names `activateAudioSession()` / `deactivateAudioSession()` used consistently across Steps 2, 4, 5.
