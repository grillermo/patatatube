# Player Orientation Lock Design

## Goal

Add an orientation-lock toggle to the video player. The control appears with
the playback controls and locks the player to the interface orientation shown
when the user activates it. While locked, later device rotations do not rotate
the player. Unlocking immediately restores normal rotation behavior and aligns
the interface with the latest valid device orientation.

## Scope

The feature applies to iPhone and iPad, during normal and play-and-sleep
playback. It is independent of the device's Control Center Rotation Lock.

The lock starts off for every player presentation. It remains active when
autoplay advances within that presentation and resets when the player is
dismissed. The completed play-and-sleep black overlay continues to block all
controls and gestures.

## Orientation Coordination

Introduce an app-scoped, main-actor orientation coordinator. It owns:

- the platform's normal supported-orientation mask;
- the player's locked interface orientation, when active; and
- the latest valid physical device orientation observed during playback.

The coordinator accepts only portrait, portrait-upside-down, landscape-left,
and landscape-right device orientations. It ignores face-up, face-down, and
unknown readings so they cannot produce an invalid rotation request. Portrait
upside down remains supported on iPad and unsupported on iPhone, matching the
existing application configuration.

Activating the toggle captures the current window scene's interface
orientation and restricts the application's supported orientations to that
single orientation. Device-orientation observation continues while locked so
the coordinator knows the most recent valid orientation without applying it.

Deactivating the toggle restores the platform's normal orientation mask and
asks the active window scene to adopt the latest valid supported device
orientation immediately. Dismissing the player performs the same reset before
the player disappears. Rotation-request failures are non-fatal: playback
continues, and the normal supported-orientation mask is restored whenever the
lock is cleared.

The device's Control Center Rotation Lock cannot be read or modified through
public iOS APIs. The PatataTube toggle therefore represents only PatataTube's
in-player lock state. System Rotation Lock may still prevent iOS from following
a physical device rotation after the app-specific lock is removed.

## Player Control

Place a custom system-style button in the upper-right player overlay, above
the existing `AVPlayerViewController`. iOS does not expose a public API for
adding a custom control directly to its native transport bar or observing the
transport bar's exact visibility. A simultaneous tap observer therefore shows
the custom button when the user taps the video, while allowing the same tap to
reach AVKit and show its native controls. An auto-hide task uses the native
controls' usual disappearance cadence.

The unlocked appearance uses an unlocked-rotation symbol. The active
appearance uses a locked-rotation symbol and a clear active tint. The control
has an accessible hit target and updates its accessibility label between
"Lock video orientation" and "Unlock video orientation."

Tapping the button toggles the coordinator without pausing, seeking, or
otherwise changing playback. Interaction with the button refreshes its
auto-hide task. When the play-and-sleep completion overlay appears, it remains
above the player control and swallows all interaction as it does today.

## State Flow

1. Present a player with orientation lock off.
2. Tap the video; AVKit controls and the custom orientation button appear.
3. Tap the button; capture the displayed interface orientation and lock to it.
4. Continue tracking valid device orientation changes without rotating.
5. Either unlock and rotate to the latest valid supported orientation, or
   dismiss and restore normal orientation behavior.
6. Autoplay item replacement does not reset the state because the player
   presentation remains active.

## Testing

Unit-test the coordinator's state transitions:

- locking captures and applies the displayed interface orientation;
- rotations while locked update the pending physical orientation only;
- unlocking restores the normal platform mask and requests the pending
  orientation;
- invalid physical orientations are ignored;
- iPhone and iPad supported-orientation differences are preserved; and
- player dismissal resets the lock while autoplay item replacement does not.

Player-view tests cover the initial unlocked state, toggle behavior, the
control's show-and-auto-hide lifecycle, accessibility labels, availability in
normal and play-and-sleep playback, and blocking by the completed sleep
overlay.

Manual verification covers portrait and both landscape directions on iPhone
and iPad, unlocking after rotating while locked, autoplay, dismissal and
re-presentation, and behavior when Control Center Rotation Lock is enabled.
