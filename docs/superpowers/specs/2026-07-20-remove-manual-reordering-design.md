# Remove Manual Video Reordering

## Goal

Remove the up/down video-reordering feature from the PWA, native iOS app, and
server API. Keep every unrelated per-video action and preserve the current
stable newest-first list ordering.

## Scope

The PWA no longer renders the Move up or Move down forms. Its download control
remains in the card action row, with the row and its CSS renamed so they no
longer describe the deleted feature.

The iOS video-cell menu no longer renders Move up or Move down. The associated
callbacks disappear from `VideoCell` and its caller. The unused iOS networking
and store methods disappear from `APIClientProtocol`, `APIClient`, and
`VideoStore`, together with their test-double fields and reorder-specific
tests.

The server no longer accepts either the PWA form route or JSON API route for
moving a video. `MoveRequest`, `services.apply_move`, and `db.move_video` are
deleted. Requests to the former routes receive the framework's normal 404
response.

Documentation and manual-test instructions will no longer claim that either
client supports reordering.

## Retained Ordering Data

The `videos.position` column and its existing population/backfill logic remain.
They also provide stable newest-first ordering and capture Plex/library added
timestamps, independently of manual movement. Existing video order therefore
stays unchanged, and newly added videos continue to appear newest first.

The API's `position` field and the iOS `Video.position` model field remain for
compatibility and read-only diagnostics. The similarly named
`video_versions.position` is unrelated: it orders versions within a movie and
is unchanged.

## Unchanged Behavior

Download, playback, classify, delete, version selection, filtering, searching,
and library refresh behavior remain unchanged. The PWA classification menu and
iOS ellipsis menu remain available with only the reorder actions removed.

## Verification

Regression tests will assert that both former server routes return 404. Existing
tests whose only purpose was to exercise reorder mutations will be removed;
remaining client and server tests must pass. Static checks will confirm that no
Move up/Move down control, callback, client method, endpoint, service, or
database mutation remains. The iOS package and app test targets will be built
and tested using the repository's existing commands.
