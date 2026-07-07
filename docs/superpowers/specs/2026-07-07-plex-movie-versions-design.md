# Plex movie versions as alternate sources

**Date:** 2026-07-07
**Status:** Design approved, pending implementation plan

## Problem

A movie in Plex has one `ratingKey` but can hold multiple `Media` entries, each
with its own `Part.file` — these are different-quality versions of the same
movie (e.g. 1080p and 4K). Today `plex._part_file` returns only the **first**
Part, so every other version is invisible to PatataTube. There is no way for the
user to see or choose an alternate version, and download status is tracked per
movie, not per version.

## Goal

- Store every Plex version of a movie as an alternate source in the DB.
- Let the user choose a version from the three-dots menu on each `VideoCell`.
- Persist the chosen version server-side (shared across devices).
- Make each version independently downloadable on iOS; the download status icon
  reflects the **chosen** version's cache state.

## Decisions (from brainstorming)

| Question | Decision |
|----------|----------|
| Data model | One `videos` row per movie + a `video_versions` child table |
| Chosen version persistence | Server DB, shared (`videos.chosen_version_id`) |
| Version label | Resolution + size, e.g. `1080p · 2.4 GB` |
| Default chosen version | First in Plex Media order |
| Scope of the picker | Movies only (picker hidden otherwise) |

**Implementation choice:** the `video_versions` table is used uniformly for
**all** library rows. Episodes and single-version movies simply have exactly one
version row. This keeps a single streaming/conversion/cache code path instead of
branching movie-vs-episode. The version **picker** is the only movie-specific UI,
gated on `versions.count > 1`.

## Data model & migration

### New table `video_versions`

| col | notes |
|-----|-------|
| `id` | PK |
| `video_id` | FK → `videos.id` |
| `source_path` | the `Part.file`; unique index lives here now |
| `converted_path` | per-version iPad-ready mp4 (nullable) |
| `status` | `unconverted → converting → done` per version |
| `error_msg` | per-version failure text (nullable) |
| `label` | e.g. `1080p · 2.4 GB`, from Plex `videoResolution` + `Part.size` |
| `plex_position` | Plex `Media` order; drives default pick + version ordering |

### `videos` changes (library rows)

- Gains `chosen_version_id` (FK → `video_versions.id`, nullable).
- Represents one movie/episode, keyed on `plex_rating_key` (was `source_path`).
- Old `source_path` / `converted_path` columns are retained for **download**
  rows (non-library) and are no longer authoritative for library rows.

### Migration (idempotent, in `init_db`)

1. `CREATE TABLE IF NOT EXISTS video_versions` + additive `ALTER TABLE videos
   ADD COLUMN chosen_version_id`.
2. Backfill: for each existing library `videos` row, insert one
   `video_versions` row from its `source_path` / `converted_path` / `status`,
   then set that row's `chosen_version_id` to the new version id. Idempotent:
   skip rows that already have a `chosen_version_id`.
3. Drop the unique index on `videos.source_path`; create a unique index on
   `video_versions.source_path`.

Movie card ordering (`position` / `created_at`) is unchanged.

## Backend (Python)

### `plex.py`

- `_movie_item` returns the movie plus a `versions` list built by walking every
  `Media` / `Part`:
  `[{source_path, label, plex_position, videoResolution, size}, ...]`.
- `label` = `videoResolution` mapped (`"4k" → "4K"`, else `"{res}p"`) + a
  humanized `Part.size`.
- `_episode_item` returns a single-element `versions` list (behavior unchanged).

### `db.py`

- `upsert_library_video(item)` keys on `plex_rating_key`: upserts the movie row,
  upserts each version (unique on `source_path`), prunes version rows whose files
  disappeared from Plex, and sets `chosen_version_id` when null (first in Plex
  order).
- `set_version_state(version_id, status, converted_path=None, error_msg=None)` —
  per-version status updates; never deletes the row (mirrors `set_library_state`).
- `set_chosen_version(video_id, version_id)` — validates the version belongs to
  the video.
- `get_versions(video_id)`, `get_version(version_id)`.
- `get_converted_paths()` reads from `video_versions`.

### `services.py`

- `apply_choose_version(video_id, version_id)` — shared write logic called by
  both the SSR form endpoint and the JSON API endpoint (matches the existing
  `apply_move` / `apply_classification` pattern).

### `views/serializers.py`

Library rows gain:

```json
"versions": [ {"id": ..., "label": ..., "status": ..., "is_chosen": ...}, ... ],
"chosen_version_id": ...
```

- Top-level `status` = the chosen version's status.
- `stream_path` stays `/videos/{id}/stream` (chosen resolves server-side).
- Non-library rows: `versions` is empty / omitted.

### `main.py`

- `POST /api/videos/{id}/version` (token-gated) and SSR `POST
  /videos/{id}/version`. Body: `version_id`. Both call
  `services.apply_choose_version`.

## Conversion & streaming

- `convert_library_video(video_id)` → `convert_library_version(version_id)`:
  reads the version's `source_path`, writes the sibling mp4, calls
  `set_version_state`. `plan_conversion` is untouched.
- `/videos/{id}/prepare` resolves the **chosen** version, kicks its conversion,
  returns the chosen version's status. iOS `ensureReady` keeps polling
  `video.status` (now mirroring the chosen version) — no iOS polling change.
- `/videos/{id}/stream` resolves the chosen version → its `converted_path`
  (or `source_path` if passthrough). Adds an optional `?version_id=` override so
  a specific version can stream/download without first mutating the server
  choice; the main iOS flow relies on the chosen default and does not need it.
  Token-gating unchanged.
- Switching back to a previously-converted version is instant — each version
  keeps its own `converted_path`, so no reconversion.

## iOS

### `Video.swift`

```swift
struct VideoVersion: Codable, Identifiable, Sendable {
    let id: Int; let label: String; let status: String; let isChosen: Bool
}
let versions: [VideoVersion]   // empty for non-library rows
let chosenVersionId: Int?
var chosenVersion: VideoVersion? { versions.first { $0.isChosen } }
```

### `CacheManager`

- Cache key moves to version granularity so each version caches independently:
  `localURL(videoId:versionId:)` → `"{videoId}.v{versionId}.mp4"`.
- `state(...)` / `download(...)` take the version id. Single-version rows pass
  the sole/chosen version id.
- Previews stay keyed by movie id (one poster per movie).

### `VideoCell`

- Menu gains a **Versions** section, rendered only when `versions.count > 1`:
  one button per version, checkmark on the chosen one, tap calls
  `onChooseVersion(versionId)`.
- Download button + status icon read the `cacheState` of the **chosen** version.
  Switching version re-renders the cell → the icon flips to that version's state
  (cached green / not-cached arrow / downloading). Download targets the chosen
  version.
- Single-version movies and episodes: no Versions section; everything routes
  through the sole version transparently.

### `VideoStore`

- `chooseVersion(id:versionId:)` — optimistic (flip `isChosen` locally, update
  top-level `status` to the new version's status), `POST
  /api/videos/{id}/version`, roll back on failure. Mirrors `classify`.

### `APIClient`

- `chooseVersion(id:versionId:)` → the new endpoint.

### Play flow

- `ensureReady` unchanged; playback streams `/videos/{id}/stream`, chosen
  version resolved server-side.

## Edge cases

- **Single-version movie / any episode:** exactly one version row; picker hidden;
  download/stream/convert flow through the sole `chosen_version_id`. No special
  branch beyond the `versions.count > 1` UI guard.
- **Version disappears from Plex** (file removed / re-tagged): `upsert_library_video`
  prunes the orphan version row. If it was the chosen one, re-point
  `chosen_version_id` to the first remaining version.
- **Chosen version's converted file deleted server-side:** status reverts to
  `unconverted` on next scan/probe; `prepare` reconverts on demand (existing
  library behavior, now per version).

## Testing

- `db`: migration backfill creates one version per legacy library row and sets
  `chosen_version_id`; unique index enforced on `video_versions.source_path`.
- `plex`: a movie metadata blob with two `Media` yields two versions with
  correct labels and Plex ordering; an episode yields one.
- `services` / API: `POST /api/videos/{id}/version` changes the chosen version;
  rejects a `version_id` not belonging to the video.
- serializer: library row emits `versions` + `chosen_version_id`; top-level
  `status` mirrors the chosen version.
- conversion: `convert_library_version` converts only its own version and leaves
  siblings untouched.
- Follow the existing integration-test pattern (reload `db` then `main` after
  setting `DB_PATH` / `UPLOAD_TOKEN`).
- iOS: `swift build` the kit; decode a two-version library JSON into `Video`;
  `CacheManager` caches two versions of one movie to distinct files.
