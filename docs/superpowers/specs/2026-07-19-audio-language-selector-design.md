# Audio Language Selector — Design

**Date:** 2026-07-19
**Status:** Approved

## Problem

Library sources (e.g. MULTI mkvs) can carry many audio language tracks, but
`convert_library_video` maps only the first audio track (`-map 0:a:0?`). The
converted mp4 therefore has a single, arbitrary language — for
`Lilo and Stitch 2002 MULTI` that is Catalan (track order: cat, chi, cze, …).
There is no way to pick a language from the iOS app.

## Goal

A language selector in the iOS movie detail view. Choice persists server-side
per movie. Conversions keep English plus all Spanish tracks so switching
between them needs no re-conversion; picking a language missing from an
already-converted file triggers an automatic re-conversion. Selector UI is
iOS-only (no web PWA changes).

## Decisions made during brainstorming

- **Scope:** iOS UI only, but backend changes allowed.
- **Languages kept in conversions:** English + all Spanish tracks (a source
  may have several `spa` tracks, e.g. Castilian and Latin American — keep all).
- **Persistence:** server-side per movie (like `chosen_version_id`).
- **Missing language:** auto re-convert from source.
- **Language discovery:** stored in DB at scan time (approach B), probed
  incrementally with ffprobe.

## Design

### 1. Data model (`db.py`, idempotent ALTER guards)

- `video_versions.audio_langs TEXT` — JSON array of the source file's audio
  tracks in stream order: `[{"lang": "eng", "title": ""}, {"lang": "spa",
  "title": "Latin American"}, …]`. `NULL` = not probed yet.
- `video_versions.converted_langs TEXT` — JSON array of language codes
  actually present in the converted file, written when a conversion succeeds.
  `NULL` (pre-feature conversions) is treated as "first source track only",
  so picking any other language triggers a re-conversion.
- `videos.audio_lang TEXT` — the chosen language code for this movie.

### 2. Scan (`library.py scan_library`)

After upserting an item, for each surviving version whose `audio_langs` is
`NULL`: ffprobe the source (via the existing `probe_source` indirection) and
store the track list. Incremental: the first scan after deploy probes the
whole library once (~100 ms per file, header read only); later scans probe
only new files. A probe failure leaves `audio_langs` `NULL` (retried next
scan) and never aborts the scan.

### 3. Conversion (`library.py`)

- New env var `LIBRARY_AUDIO_LANGS`, default `eng,spa`. The ffmpeg map keeps
  every audio track whose language tag is in the allowlist; if none match,
  keep the first audio track (current behavior).
- `plan_conversion` produces per-track audio args: tracks with a compatible
  codec (`aac`/`ac3`/`eac3`) get `-c:a:N copy`, others are transcoded to
  aac 128k stereo. Stream language tags carry through the mp4 mux.
- Passthrough rule unchanged: mp4 sources that pass all checks are served
  as-is, whatever tracks they contain.
- On success, write `converted_langs` from the tracks that were mapped.

### 4. API (`main.py`, `views/serializers.py`)

- `serialize_video`: the video gains `audio_lang`; the chosen version gains
  `audio_tracks: [{"lang", "title", "available"}]` — source tracks
  intersected with the allowlist, `available` = language present in the
  converted file (or first-track rule for `NULL` `converted_langs`).
- `POST /api/videos/{id}/audio` with body `{"lang": "spa"}` — token-gated.
  Validates the code against the source's tracks ∩ allowlist (400 otherwise).
  Sets `videos.audio_lang`. If the language is missing from
  `converted_langs`, sets the version status back to `unconverted` and
  schedules `convert_library_video` as a background task — the existing
  converting flow (`error_msg` on failure, never row-delete).

### 5. iOS UI (`MovieDetailView`, `Video`, `VideoStore`, `APIClient`)

- `Video` decodes `audio_lang` and the version's `audio_tracks`.
- Detail view: an "Audio" menu picker beside the Version picker, shown only
  when the chosen version has more than one track. Display names come from
  `Locale` (ISO 639-2 code → localized language name, falling back to the
  raw code); the track's title tag is appended to disambiguate duplicates
  ("Spanish — Latin American").
- Picking calls `store.chooseAudio` with an optimistic update, mirroring
  `chooseVersion`. If the picked track is not `available`, the row flips to
  `converting` server-side (existing status chip shows it) and the app
  evicts the cached mp4 for that video/version, since the server will
  replace the file.

### 6. Playback (`VideoPlayerView` / `PlayerViewController`)

When the AVPlayerItem is ready, read the asset's audible
`AVMediaSelectionGroup` and select the option whose language matches
`audio_lang` (alpha-3 server codes normalized against the asset's BCP-47
tags). Applies to cached mp4 and direct-stream playback — the tracks are
embedded in the mp4. No match → default track, no error.

**HLS (discovered during planning):** online playback prefers the HLS
package (`hls.py`), which also maps only the first audio track. Rather than
emitting multi-audio HLS renditions, the package carries a single audio
track — the chosen language: `build_hls_package` learns an `audio_lang`
parameter, and `hls.prepare` reads the video's `audio_lang` to select the
matching track from the converted file. Choosing an audio language (and any
re-conversion) invalidates the package via a new `hls.invalidate(video_id)`
(deletes `data/hls/{id}`, resets `hls_status` to `none`); the next play
triggers the existing on-demand repackage, which is stream-copy and fast.
Consequence: switching language mid-stream waits for a repackage; cached
mp4 playback switches instantly.

**Duplicate same-language tracks:** the selector is keyed by language code,
so two `spa` tracks appear as one "Spanish" entry (conversion keeps both).
Refining between them happens in AVKit's built-in audio menu during
playback.

### 7. Testing

- **Python** (pytest, existing patterns — fake probes via `probe_source`,
  env/reload fixture from `tests/test_api.py`):
  - `plan_conversion`: allowlist hit / miss / mixed-codec tracks.
  - Scan probe backfill: fills `NULL` only, idempotent, survives probe failure.
  - Audio endpoint: happy path, invalid lang 400, token gate, re-convert
    trigger when lang unavailable.
- **iOS**: manual checklist additions in `ios/README.md` — selector visible
  on a MULTI movie, spa↔eng switch is instant, picking a language missing
  from an old conversion shows `converting` then plays the new language,
  offline cached playback respects the choice.

## Known costs / limits

- Movies converted before this feature carry one (arbitrary) audio track;
  first language pick outside it re-converts once. Lilo and Stitch re-converts
  once (currently Catalan-only).
- Language codes without a `Locale` display name render as the raw code.
- First scan after deploy is slower (one-time whole-library ffprobe pass).
