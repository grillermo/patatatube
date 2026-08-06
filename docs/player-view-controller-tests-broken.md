# `PlayerViewControllerTests` does not compile (pre-existing)

Status: **open**, unrelated to the shared-options-menu refactor
(`bcf2212`, branch `refactor/shared-options-menu`). Noted 2026-08-06.

## Symptom

The app builds fine:

```bash
cd ios/PatataTube
xcodebuild -project PatataTube.xcodeproj -scheme PatataTube \
  -destination 'generic/platform=iOS Simulator' build      # ** BUILD SUCCEEDED **
```

The *test* build does not:

```bash
xcodebuild -project PatataTube.xcodeproj -scheme PatataTube \
  -destination 'platform=iOS Simulator,id=<a real simulator udid>' build-for-testing
```

```
Tests/PlayerViewControllerTests.swift:15:40: error: missing argument for parameter 'revealControlsToken' in call
Tests/PlayerViewControllerTests.swift:21:69: error: generic parameter 'T' could not be inferred
Tests/PlayerViewControllerTests.swift:21:72: error: cannot convert value of type '[Any]' to expected argument type 'T?'
Tests/PlayerViewControllerTests.swift:21:76: error: value of type 'T?' has no member 'filter'
** TEST BUILD FAILED **
```

Only the first error is real. `sut` fails to type-check at line 15, so
`controller` at line 21 has no type and the three follow-on errors are
cascade noise.

## Cause

`PlayerViewController` gained a stored `let revealControlsToken: Int`
(`ios/PatataTube/Sources/PlayerViewController.swift:58`) in commit
`9364aca` *feat(ios): reveal playback controls on restored session*
(2026-08-02). That commit touched only `PlayerViewController.swift` and
`VideoPlayerView.swift` — the test's memberwise `init` call was never
updated, so it has been stale ever since.

Nothing in the test exercises the token: it asserts the installed
controller has exactly one non-cancelling simultaneous tap recognizer.

## Fix

Add the argument to the `PlayerViewController(...)` call at
`ios/PatataTube/Tests/PlayerViewControllerTests.swift:12`:

```swift
let sut = PlayerViewController(
    player: AVPlayer(),
    attached: true,
    resumeAfterDetaching: false,
    revealControlsToken: 0,      // 0 = don't reveal; see updateUIViewController
    onPlayerTap: {},
    onSceneAvailable: { _ in }
)
```

Order matters — it is a memberwise init, so the argument goes where the
property is declared. Check the current property order in
`PlayerViewController.swift` before assuming the placement above.

`0` is the right value for this test: `makeUIViewController` only calls
`revealPlaybackControls()` when the token is `> 0`
(`PlayerViewController.swift:70-71`), so `0` keeps the test on the plain
path it means to test.

## Verify

```bash
cd ios/PatataTube
xcrun simctl list devices available | grep iPad     # pick a udid
xcodebuild -project PatataTube.xcodeproj -scheme PatataTube \
  -destination 'platform=iOS Simulator,id=<udid>' test
```

`-destination 'generic/platform=iOS Simulator'` is fine for `build` but
is rejected by `build-for-testing`/`test`; those need a concrete
simulator id. A named destination like
`platform=iOS Simulator,name=iPad Pro 13-inch (M4)` fails on this
machine ("Unable to find a device matching the provided destination
specifier") — the installed runtimes differ. Use `-showdestinations` or
`simctl list` to get a real udid.

## Also worth checking once it compiles

Whether any *other* test in the target is stale for the same reason —
the failure above stops the build before the rest of the suite is
type-checked, so it may be hiding more of the same. `swift test` in
`ios/PatataTubeKit` is a separate target and is unaffected.
