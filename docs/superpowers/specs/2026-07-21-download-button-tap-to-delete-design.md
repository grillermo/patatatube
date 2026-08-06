# Download button: tap-to-arm → tap-to-delete cached file

**Date:** 2026-07-21
**Status:** Approved

## Problem

The shared iOS `DownloadButton` shows a non-interactive green checkmark once a
video is cached offline. There is no in-place way to remove that cached file;
deletion only exists buried in per-view menus (`removeCached` / `removeAllCached`).
Users want a direct gesture on the button itself to free space.

## Behavior

Extend the `.cached` presentation into a two-tap destructive control:

1. **Cached (idle):** green `checkmark.circle.fill` — now a tappable `Button`.
2. **First tap → armed:** button becomes a red `x.circle.fill`. A 3-second
   auto-revert timer starts.
3. **Second tap (while armed):** calls `onDelete()`, removes the cached file for
   the button's specific version, and the button returns to the `.notCached`
   download icon (`arrow.down.circle`), ready to re-download.
4. **No second tap within 3s:** button disarms back to the green checkmark.
   Re-arming restarts the timer.
5. **Leaving/refresh:** view `.task` id change or poll `reset` disarms.
6. **External removal:** if `poll` observes `.notCached` while armed (file gone
   by other means), drop the armed state and fall through to the observed state.

Scope is **cached-only**. `.downloading` keeps its existing cancel ring;
`.notCached` and `.loading` are unchanged.

## State model — `DownloadButtonState`

Add an armed concept to the existing `@Observable` class. Represent it as a
separate `isArmed: Bool` flag rather than a new `Phase`, because arming is
orthogonal to the download lifecycle (it only applies on top of `.cached`).

- `arm()` — set `isArmed = true`. Caller (the view) owns the 3s auto-revert
  `Task` using the injected `Clock`, mirroring `poll`. Restarting cancels the
  prior task.
- `disarm()` — set `isArmed = false`.
- `effectiveState` unchanged; a new derived `showsArmedDelete: Bool` is true only
  when `isArmed && effectiveState == .cached`.
- `reset(to:)` and `observe(_:)` clear `isArmed` when the state is no longer
  `.cached`, covering view-leave and external-removal cases.

## View — `DownloadButton`

- New closure prop: `onDelete: () -> Void`.
- `.cached` case becomes a `Button`:
  - Not armed → green checkmark, `accessibilityLabel("Downloaded")`, tap → arm +
    start auto-revert task.
  - Armed → red `x.circle.fill`, `accessibilityLabel("Delete download")`, tap →
    `onDelete()` then `state.reset(to: .notCached)`.
- Auto-revert task lives in the view (holds `@Environment(\.continuousClock)`),
  stored so re-arm cancels it and view teardown cancels it.

## Callback wiring (3 call sites)

- `VideoCell` — add `onDelete` prop, thread it through `VideoGridView`, call
  `cache.removeCached(id: videoId, versionId: versionId)`.
- `EpisodesView` — add `onDelete` closure, same `removeCached` shape as its
  existing `onCancel`.
- `MovieDetailView` — `model.cache.removeCached(id: currentVideo.id,
  versionId: ...)`, matching existing line 110.

Use `removeCached` (specific chosen version), not `removeAllCached`, so the
button's version identity matches what gets deleted.

## Testing

`DownloadButtonState` logic is the testable core. Cover with the injected
`Clock` (test clock, same pattern as `poll`):

- arm → no tap → disarm after timeout.
- arm → delete transition clears armed and lands on `.notCached`.
- `observe(.notCached)` while armed drops armed.

No iOS UI test target exists; add a line to `ios/README.md` manual checklist.

## Risks

`DownloadButtonState` lives in the app target (`PatataTube/Sources`), not the
`PatataTubeKit` package, so tests aren't runnable via `swift build` alone. Logic
stays in the `@Observable` class driven by the injected clock, keeping it
unit-testable in principle.
