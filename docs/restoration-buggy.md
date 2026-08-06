# iOS: episodes back-button requires ~4 taps after pull-down dismiss

Status: **root-caused and fixed** (2026-08-02). Fix:
`docs/superpowers/plans/2026-08-02-restoration-task-reentry-fix.md`.
Ship a clean build (`./deploy patch`) to take the AltStore source off the
instrumented release.

## Symptom

1. Play a TV show episode from `EpisodesView`.
2. Pull down on the video to dismiss the player (not the system back-swipe —
   the custom `pullDownToDismiss` gesture in `VideoPlayerView.swift`).
3. Back on the episodes list, tap the nav-bar back button to return to the
   shows list.
4. The tap doesn't pop the stack the first time. It takes **~4 taps** before
   the app actually navigates back to the shows list.

Contrast: quitting the app while an episode plays and relaunching restores
correctly to the same episode (the boot-restore path, `initialLoad()` in
`VideoGridView.swift`, works fine). The bug is specific to the
dismiss-then-back sequence within a single running session.

## Relevant code

- `ios/PatataTube/Sources/VideoGridView.swift`
  - `path: [Route]` — the `NavigationStack`'s explicit path (root-first,
    required for restoration).
  - `RestorationTracking` (`ViewModifier`, ~line 25) — six `onChange` save
    triggers pulled out of `body` for type-checker budget reasons. Includes
    the `path` and `playing` onChange handlers.
  - `destination(for:)` (~line 440) — resolves a `.show(title)` route against
    `ShowGroup.group(filteredVideos)` **at render time**. If the title
    doesn't resolve, it silently renders nothing (no path mutation).
- `ios/PatataTube/Sources/EpisodesView.swift` — the pushed screen; owns its
  own scroll-anchor debounce state.
- `ios/PatataTube/Sources/VideoPlayerView.swift`
  - `pullDownToDismiss` (~line 161) — custom drag gesture, calls
    `dismiss()` past 150pt of downward translation.
  - `onDisappear` (~line 137) — teardown + `DevLog.event(.nav, "player dismissed", …)`.
- `ios/PatataTubeKit/Sources/PatataTubeKit/RestorationStore.swift` — plain
  `UserDefaults` wrapper, **not** `@Observable`/published. Ruled out as a
  source of unwanted re-renders (mutating it doesn't trigger SwiftUI updates
  elsewhere).

## Hypotheses considered

1. ~~`RestorationStore.mutate` on `path`/`playing` change re-publishes state
   that some other view reads and reapplies, fighting the `NavigationStack`
   binding.~~ Ruled out — `RestorationStore` is a bare `UserDefaults`
   wrapper with no Combine/Observable publishing.
2. **Destination re-resolution racing the pop.** `destination(for:)` reads
   `filteredVideos` (derived from `store.videos` + `activeSearch`), which can
   change independently (e.g. a `resume_secs` POST-triggered refresh, or the
   position reporter, following pull-down dismiss). If `store.videos`
   mutates around the same time as the pop, the `.show` route may
   momentarily fail to resolve or re-resolve, which could confuse
   `NavigationStack`'s pop gesture recognition. **Not yet confirmed.**
3. **Gesture/touch handling residue from the custom pull-down dismiss.**
   `pullDownToDismiss` is a `DragGesture` with `.offset`/`.scaleEffect`
   applied to the player during the drag; if `dragOffset` or gesture state
   doesn't fully reset before `fullScreenCover` finishes its dismiss
   animation, touches on the underlying `NavigationStack` back button might
   be partially swallowed for a few frames. **Not yet confirmed** — most
   likely candidate given the "several taps needed" symptom (each tap maybe
   landing during a half-torn-down gesture/animation state).
4. Something in the six `RestorationTracking` onChange handlers causing an
   extra SwiftUI render pass that resets/re-applies `path` from a stale
   closure capture. No direct evidence yet; instrumentation below should
   show if `path` bounces or gets rewritten unexpectedly around the failed
   taps.

## Evidence from the v1.1.59 capture (2026-08-03 04:25 UTC)

The symptom is not a stuck back button — **the player re-presents itself**.
Sixteen identical cycles in 60s, each one:

```
seq 115  pull-down dismiss                   translation 244, video 188
seq 116  grid playing changed 188 -> nil     +10ms
seq 117  grid playing changed nil -> 188     +97ms   <- player is back
seq 119  player dismissed 188                +1.1s   (old player tears down)
seq 122  source -> offline_hls, master.m3u8 refetched, segment_00000
seq 127  grid playing changed 188 -> 188
```

The user's description matches: the video "briefly goes away, then comes back
over and over". The nav-bar back button appears dead because a full-screen
cover is on top of `EpisodesView` again by the time the tap lands.

Ruled out by this capture:

- **Boot restore is not re-running.** `initialLoad()` calls
  `api.classifications()`, and `200 /api/classifications` appears exactly once
  in the whole log (seq 6, launch). Restore also builds its queue with
  `startPaused: true`, yet all 16 re-mounts log `paused:"false"`.
- **Hypothesis 2 (destination re-resolution) is dead.** `grid path changed`
  fires once (`""` -> `show(Bluey)`) at launch, `episodes appear` once,
  `episodes disappear` only at the very end; `show route unresolved` never
  fires.
- **Nothing is logged in the 97ms gap** between `nil` and `188` — no net, no
  cache, no store activity.

`playing` is assigned in exactly two places (`VideoGridView.swift`
`initialLoad` and `begin`), and `initialLoad` is out, so either `begin()` is
being called again or the `@State` is being re-established some other way.
The v1.1.59 instrumentation cannot tell those apart, hence the additions below.

## Instrumentation added (next build, DEVLOG-gated)

Aimed squarely at the remaining fork:

- **A — a new presentation.** Some `onPlay` closure calls `play()`/`begin()`
  again. `"play requested"` / `"begin playback"` fire, each carrying a
  `caller` tag (`episodes`, `shows`, `grid-cell`, `downloads`,
  `movie-detail`, `resume-alert`), and the new player carries a **fresh**
  `inst`.
- **B — SwiftUI re-creating the cover's content.** No `begin playback` record,
  but `"player cover built"` fires and the re-mounted player reuses the
  **same** `inst`.

New call sites:

- `VideoGridView.swift` — `"play requested"` (meta `video_id`, `caller`),
  `"begin playback"` (meta `video_id`, `caller`, `start_secs`, `had_playing`),
  `"player cover built"` (meta `video_id`, `start_secs`, `start_paused`),
  `"initial load applying"` (meta `path`, `player`) — the last one makes a
  re-run of boot restore impossible to miss.
- `VideoPlayerView.swift` — `"player appear"` and `"player setup"`, and an
  `inst` (per-view-identity id, from a `@State` UUID) added to those plus
  `"player dismissed"` and `"pull-down dismiss"`.

Read it with:

```bash
jq -c 'select(.kind=="nav")|{seq,ts,msg,inst:.meta.inst,caller:.meta.caller,meta}' log/ios.jsonl | tail -40
```

## Clean-slate helper

A **Clear Restoration** home-screen quick action
(`com.patatatube.clearRestoration` -> `AppModel.clearRestoration` ->
`RestorationStore.clear()`) drops the saved path/player/anchors so a
reproduction starts from a known-empty state. It does not touch the running
session.

## Instrumentation added earlier (v1.1.59, DEVLOG-gated)

All new call sites, `kind: .nav`:

- `VideoPlayerView.swift` — `"pull-down dismiss"` when the drag exceeds the
  150pt threshold and `dismiss()` is about to be called. Meta: `video_id`,
  `translation`.
- `VideoGridView.swift`
  - `"grid path changed"` on every `path` onChange. Meta: `from`/`to`,
    rendered via `RestorationTracking.describe([Route])` as
    `show(title)>downloads` etc.
  - `"grid playing changed"` on every `playing` onChange. Meta: `from`/`to`
    video id or `"nil"`.
  - `"show route unresolved"` — fires from `destination(for:)` (via an
    `EmptyView().onAppear`, not inline in body) when a `.show(title)` route
    fails to resolve against `filteredVideos`. Meta: `title`.
- `EpisodesView.swift` — `"episodes appear"` / `"episodes disappear"` on the
  list's `onAppear`/`onDisappear`. Meta: `show`.

(Existing) `VideoPlayerView.swift` `onDisappear` already logs
`"player dismissed"` for every dismiss cause (pull-down, playback-end,
malformed setup) — meta: `video_id`.

## How to reproduce and read the evidence

1. Install AltStore build v1.1.59 (DEVLOG) — source URL:
   `https://raw.githubusercontent.com/grillermo/patatatube/main/ios/apps.json`.
2. `./serve` locally (truncates `log/ios.jsonl` on each start — copy it
   elsewhere before restarting if a repro is still being analyzed).
3. On the iPad: open a show, play an episode, pull down to dismiss, then tap
   the back button repeatedly until it actually navigates back.
4. Pull the log:
   ```bash
   grep '"kind":"nav"' log/ios.jsonl | tail -60
   ```
   Look specifically at the interleaving of `"pull-down dismiss"` →
   `"player dismissed"` → `"grid playing changed"` → the sequence of failed
   back taps. Key questions:
   - Does `"grid path changed"` fire (and with what `from`/`to`) on each
     failed tap, or does the path stay unchanged until the 4th tap actually
     works?
   - Does `"episodes appear"` re-fire between taps (i.e. is `EpisodesView`
     being torn down and recreated, not just failing to pop)?
   - Does `"show route unresolved"` ever fire during this window (confirms
     hypothesis 2)?
   - What's the `seq` gap / timing between `"player dismissed"` and the
     first back tap — is the sequence rushed (dismiss animation still
     in-flight)?

## Next steps

- Reproduce on the new instrumented build and decide A vs B from `caller` /
  `inst` (see above).
- Hypothesis 2 is eliminated; 3 and 4 remain live, and both fall under A/B.
- Once root-caused, fix, verify with the same repro, then run `./deploy
  patch` to ship a clean (non-instrumented) build.

## Root cause

`VideoGridView`'s `.task { await initialLoad(scrollProxy:) }` is restarted by
SwiftUI every time the grid re-enters the view hierarchy, and presenting or
dismissing the player's `fullScreenCover` does exactly that. Each restart
re-ran boot restoration against a `RestorationState` snapshot loaded *before*
its two `await`s — i.e. from before the dismissal — so it re-presented the
player that had just been dismissed (`startPaused: true`, same view `inst`)
and, on runs where `store.videos` was momentarily empty, resolved the `.show`
route to nothing and assigned `path = []`. Re-presenting the cover took the
grid out of the hierarchy again, which restarted the task again: a
self-sustaining loop (152 restore runs in one 30s capture).

Hypotheses 2, 3 and 4 above are all eliminated: the trigger is neither route
re-resolution, nor gesture residue, nor the `RestorationTracking` save
handlers.

Fixed by `RestorationGate` (one claim per launch, held by `AppModel` so it
outlives the view) plus `RestorationApplyDecision` (a restore may seed empty
state, never overwrite a live path or a live player).
