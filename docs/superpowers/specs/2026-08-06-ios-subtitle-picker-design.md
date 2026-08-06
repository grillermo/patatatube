# iOS Subtitle Picker — Design

## Problem

Sidecar subtitles (`.srt`/`.vtt`/`.sub`) exist for some library movies and are
already discovered by `subtitles.py` and packaged into HLS by `hls.py`
(`EXT-X-MEDIA:TYPE=SUBTITLES`, WebVTT). But nothing in the iOS app lets a user
turn subtitles on, pick a language, or even see they exist — the only place
subtitle metadata surfaces today is a hidden debug-info sheet
(`VideoCell.swift`), fed by a per-request filesystem probe that only runs on
the single-video detail endpoint and that no screen actually calls.

## Architecture

### Backend: move subtitle discovery onto the scan-time pattern

Audio tracks are discovered once, at library scan/convert time, and cached as
JSON on `video_versions.audio_langs` (`library.py: _probe_missing_audio_langs`).
The list endpoint (`GET /api/videos`) exposes them for free from that column —
no filesystem or ffprobe work per request.

Subtitles currently work differently: `router.py`'s single-video detail
endpoint (`GET /api/videos/{id}`) calls `hls.discover_subtitles` live, on every
request, and the list endpoint never calls it at all. Two discovery paths for
one concept. This design collapses them onto the audio pattern:

- New `video_versions.subtitle_langs` column (JSON), added via an idempotent
  `ALTER TABLE` guard in `db.py` (same shape as the `audio_langs` guard).
- New `library.py: _probe_missing_subtitle_langs`, mirroring
  `_probe_missing_audio_langs` structurally, but calling
  `subtitles.discover_subtitles(source_path)` (a directory scan — no ffprobe,
  cheaper than the audio probe) instead of `probe_source`. Called from
  `scan_library` alongside the existing audio probe call.
- `views/serializers.py` gets a `_subtitle_tracks(version)` helper mirroring
  `_audio_tracks`, turning `subtitle_tracks` into a normal list-endpoint field
  (language, name, default, forced) instead of a detail-only one.
- The ad hoc live probe currently in `router.py` (~line 1080, in
  `api_video`) is removed — no longer needed once scan-time data exists.

### Backend: persisted subtitle preference

- New `videos.subtitle_lang` column (nullable TEXT), added the same way
  `audio_lang` was.
- New `db.set_subtitle_lang(video_id, lang)`, mirroring `db.set_audio_lang`.
- New `POST /api/videos/{video_id}/subtitle`, body `{lang: str | null}`,
  mirroring `POST /api/videos/{video_id}/audio`'s auth/validation shape
  (404 if missing, 400 if not a library row, 400 if `lang` isn't in that
  version's `subtitle_langs`). `null` means "subtitles off."
  **Unlike audio, this never calls `hls.invalidate` or triggers reconversion**
  — every discovered subtitle language is already packaged into the HLS
  multivariant playlist at conversion time (packaging happens once, in
  `hls.py`, independent of which language the client currently has selected).
  Choosing a subtitle language is purely a stored client preference; the
  server does no re-work.
- `views/serializers.py` includes `subtitle_lang` in the video-level payload
  (parallel to `audio_lang`).

### iOS: model

- `Video.swift`: add `subtitleLang: String?` (video-level, mirrors
  `audioLang`) and a per-version `subtitleTracks: [SubtitleTrack]`
  (`SubtitleTrack` struct already exists, mirrors `AudioTrack`).
- `APIClient.swift`: add `chooseSubtitle(id: Int, lang: String?) async throws
  -> Bool`, mirroring `chooseAudio`.
- `VideoStore.swift`: add `chooseSubtitle(id:lang:)`, mirroring
  `chooseAudio`, updating local state optimistically the same way.

### iOS: UI — pick before playback

`MovieDetailView.swift`, next to the existing Audio `Picker` (~line 114): add
a `Picker("Subtitles", …)` listing "Off" plus each track's language for the
chosen version. On first view of a video with no stored `subtitle_lang`,
default the picker to whichever track has `default == true` (the flag
`subtitles.py` already computes). Selecting a track calls
`store.chooseSubtitle`.

### iOS: UI — pick or change during playback

`VideoPlayerView.swift`: add `applySubtitleSelection(item: AVPlayerItem, lang:
String?) async`, structurally identical to `applyAudioSelection` (line 700)
but against `item.asset.loadMediaSelectionGroup(for: .legible)` instead of
`.audible`. Call it alongside every existing `applyAudioSelection` call site
(initial setup and advance-to-next-item).

Add a CC button to the transport controls, visible only when
`!video.subtitleTracks.isEmpty`, showing a `Menu` of "Off" + available tracks.
Selecting an option does two things immediately: calls `item.select(_:in:)`
for instant effect, and calls `store.chooseSubtitle` so the choice persists
for next time. This is the same "picker sets default, in-player button
overrides live" split the design conversation settled on.

No `plex_kind` gating — this works for any library row (movies or TV
episodes) with a non-empty `subtitleTracks`, since `subtitles.discover_subtitles`
is generic over `source_path`.

## Error handling

- No sidecar subtitles found for a version → `subtitle_tracks: []`. Both the
  Picker and the CC button simply don't render, matching the existing
  `if !video.subtitleTracks.isEmpty` guard already used by the debug sheet.
- A previously-chosen `subtitle_lang` that no longer matches any track (e.g.
  sidecar files changed and a rescan updated `subtitle_langs`) →
  `applySubtitleSelection` finds no matching option and leaves subtitles off,
  identical to how `applyAudioSelection` handles a stale audio choice today.
- Offline/cached playback: `SegmentCache` already caches subtitle playlists
  and segments as part of the HLS package (see its doc comment), so no
  additional caching work is needed for offline subtitle switching.

## Testing

Backend:
- `tests/test_serializers.py`: extend for the new `_subtitle_tracks` helper
  (scaffolding already exists — `test_injected_subtitle_tracks_are_passed_through`
  currently tests the old inject-by-hand shape and needs updating for the new
  scan-time-derived shape).
- `library.py`: a test for `_probe_missing_subtitle_langs`, mirroring whatever
  test coverage `_probe_missing_audio_langs` has.
- API test for `POST /api/videos/{id}/subtitle`: 404 missing video, 400
  non-library video, 400 unknown language, 200 + persisted value on success,
  and that it does **not** call `hls.invalidate` (unlike the audio endpoint).

iOS:
- `VideoTests.swift` / `APIClientReadTests.swift`: extend for the new
  video-level `subtitleLang` field (subtitle-tracks JSON decoding scaffolding
  already exists in these files).
- Manual test per `ios/README.md`'s checklist: exercise the CC menu and the
  MovieDetailView picker against the 8 movies currently confirmed to have
  sidecar subs — Glass, Master and Commander: The Far Side of the World,
  Nouvelle Vague, Pressure, Project Hail Mary, The Day the Earth Stood Still,
  The Devil Wears Prada 2, The Gorge, and both extended-edition LOTR films
  (Return of the King, Two Towers) — plus one movie with none, to confirm the
  UI stays hidden.

## Scope

Library rows only (movies and TV episodes with `source == 'library'`).
Download rows (Twitter/YouTube) never have sidecar subtitles and are excluded,
matching the existing comment in `views/serializers.py` ("Download rows are
always `[]`").
