# Plan: LLM-generated human-distinguishable version labels

## Problem

Movies with multiple Plex versions show poor labels in the iOS version Picker
(`VideoCell.swift:55-66`). Current `plex._version_label` (plex.py:55) uses only
`videoResolution`, so:

- Two 1080p releases collide → both read "1080p", indistinguishable.
- Releases with no digit resolution (DVDRip) fall back to raw title/filename.
- Distinguishing tokens the human cares about (`Dual-Lat`, `DVDRip-Lat`) are dropped.

Example filenames for one movie:

```
Kiki.Entregas.a.Domicilio.1989.720p-Dual-Lat/...
Kiki.Entregas.a.Domicilio.1989.DVDRip-Lat/...
Kiki.Entregas.a.domicilio.1989.1080p-dual-lat/...
```

Desired labels (resolution + unique attrs only):

```
720p Dual Lat
DVDRip Lat
1080p Dual Lat
```

## Decisions (confirmed)

- **Location:** Python backend. Store human label in `video_versions.label`; iOS renders as-is.
- **Trigger:** Only videos with 2+ versions.
- **Fallback:** Hard-fail (raise) on missing key / API error / bad response — for **scan**.
- **Migration:** Re-label all existing multi-version library videos.
- **Migration placement (deviation, flagged):** Standalone script, **not** `init_db`.
  Rationale: hard-fail inside `init_db` bricks app startup whenever the key is
  unset or OpenAI is down. Standalone one-shot keeps the hard-fail semantics
  without endangering boot.

## iOS

No change. `VideoCell` Picker already shows `version.label` (falls back to
`"Version <id>"`). Better server labels flow through the JSON API
(`views/serializers.py:30`) automatically.

## New module: `version_namer.py` (repo root)

Mirrors `search_word_service.rb`: single OpenAI chat call, cheap model, Bearer key.

```
label_versions(filenames: list[str]) -> list[str]
```

- Key: `VERSION_NAME_LLM_API_KEY` (env). Missing → raise `VersionNamerError`.
- Model: `VERSION_NAME_LLM_MODEL` env, default `gpt-5-nano` (matches reference).
- HTTP: `httpx` (already a dep, used in plex.py). Timeout 30s.
- Body: `max_completion_tokens`, `reasoning_effort: "minimal"`, system + user messages.
- **System prompt:** return a JSON array of short labels, one per input line, in
  the same order; keep only resolution and the unique differentiating attributes
  (edition/source/language like `Dual Lat`, `DVDRip Lat`); drop the movie title,
  year, punctuation, paths; make each label visually easy for a human to tell apart.
- **User content:** the filenames (basenames of `source_path`), numbered, one per line.
- **Parse:** `json.loads` the array. Hard-fail (`VersionNamerError`) if not a
  list or `len != len(filenames)` or any empty string. Strip each entry.

## Integration 1 — scan path (`library.py`)

In `scan_library`, after the `versions` list is filtered (library.py:158-168),
before `db.upsert_library_video(item)`:

- If `len(versions) > 1`:
  - **Idempotency guard:** ask db for already-stored labels of these exact
    `source_path`s (new `db.get_version_labels(source_paths) -> dict`). If every
    incoming path already has a non-empty stored label, reuse them — **skip the
    LLM call**. This keeps every rescan from re-billing/re-risking a hard-fail.
  - Else call `version_namer.label_versions([Path(v["source_path"]).name for v in versions])`
    and assign each returned string to `v["label"]`.
- Single-version items keep the existing simple label untouched.

Labels then persist through the existing `_sync_versions` write path (db.py:521).

## Integration 2 — migration script

`scripts/relabel_versions.py` (run: `python -m scripts.relabel_versions`, or a
plain script — match repo style; there is no `scripts/` yet, so a top-level
`relabel_versions.py` is simplest):

- Load `.env` (python-dotenv, like the app).
- Query all library videos having `>= 2` rows in `video_versions`.
- For each: gather version `source_path` basenames in `position` order, call
  `version_namer.label_versions`, `UPDATE video_versions SET label = ?` per id.
- Hard-fail on first error (surfaces the problem; safe because it is not boot path).
- Print a per-video summary (id, title, old → new labels).

New db helper for the query/update, or inline SQL in the script using `db._conn()`.

## Tests (`tests/test_version_namer.py`)

Follow existing async/monkeypatch patterns (CLAUDE.md note on the `client` fixture).

- `label_versions` happy path: monkeypatch httpx POST → returns JSON array; assert
  parsed, stripped, order preserved.
- Missing `VERSION_NAME_LLM_API_KEY` → raises.
- Count mismatch / non-list / empty entry → raises.
- Non-200 status → raises.
- Scan integration: monkeypatch `version_namer.label_versions`, seed a 2-version
  item, assert stored labels come from the namer; assert single-version item does
  **not** invoke it; assert second scan with unchanged paths skips the LLM.

## Config

- Add `VERSION_NAME_LLM_API_KEY=` (and optional `VERSION_NAME_LLM_MODEL=`) to `.env.example`.

## Files touched

| File | Change |
|------|--------|
| `version_namer.py` | new — OpenAI client, `label_versions` |
| `library.py` | call namer for multi-version items in `scan_library` |
| `db.py` | `get_version_labels(source_paths)` helper (idempotency guard) |
| `relabel_versions.py` | new — one-shot migration, hard-fail |
| `tests/test_version_namer.py` | new — unit + scan integration |
| `.env.example` | new key(s) |
| iOS | none |

## Open question

- Batch strategy for the migration: one LLM call **per video** (simple, N calls)
  vs one batched call for many videos (cheaper, more parsing risk). Plan assumes
  **per video** for correctness. Say if you want batching.
