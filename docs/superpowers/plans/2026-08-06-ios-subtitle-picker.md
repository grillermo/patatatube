# iOS Subtitle Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the iOS app discover, pick a default for, and play sidecar subtitles for library movies and TV episodes, replacing the current dead-end where subtitle metadata is discovered live per-request but never reaches any real screen.

**Architecture:** Move subtitle discovery onto the same scan-time-cache pattern audio tracks already use (`video_versions.audio_langs` → new `video_versions.subtitle_langs`), expose a video-level `subtitle_tracks` + `subtitle_lang` pair through the existing serializer, add a `POST /api/videos/{id}/subtitle` preference endpoint that never triggers reconversion (every language is already packaged into HLS), and on iOS add a picker in `MovieDetailView` plus apply-on-load logic in `VideoPlayerView`. Live in-player switching comes for free from AVKit's native captions button (the player already wraps `AVPlayerViewController`) — no custom control needed.

**Tech Stack:** Python/FastAPI/SQLite (backend), Swift/SwiftUI/AVKit (`ios/PatataTubeKit`, `ios/PatataTube`).

## Global Constraints

- Scope is library rows only (`source == 'library'`), both movies and TV episodes — download rows never have sidecar subtitles (`views/serializers.py` comment, unchanged).
- `POST /api/videos/{id}/subtitle` must **never** call `hls.invalidate` or enqueue a conversion job — all subtitle languages are already packaged into the HLS multivariant playlist at conversion time; changing the pick is a pure preference write.
- `videos.subtitle_lang` semantics: `NULL` = never chosen (the player forces nothing and lets AVKit auto-select; the picker *displays* the server's `default`-flagged track), `""` = explicitly off (the player actively deselects), any other string = the chosen language tag. The three states are distinct all the way to `applySubtitleSelection` — see gap #5.
- No custom CC/subtitle button in `VideoPlayerView` — `PlayerViewController.swift` already wraps `AVPlayerViewController`, which shows a native captions menu automatically once the current item's asset has more than one `.legible` option.
- Follow existing patterns exactly: `set_version_subtitle_langs` mirrors `set_version_audio_langs` (`db.py:578`), `_probe_missing_subtitle_langs` mirrors `_probe_missing_audio_langs` (`library.py:273`), `applySubtitleSelection` mirrors `applyAudioSelection` (`VideoPlayerView.swift:700`).
- **Subtitles only exist on the HLS playback routes.** `playerItem` (`VideoPlayerView.swift:474-516`) prefers a cached `local_mp4` and falls back to `proxy_mp4`/`direct_mp4`; those assets have zero `.legible` options, so both the picker's effect and AVKit's captions button are silently absent there. Only `offline_hls`/`proxy_hls`/`direct_hls` carry subtitles.

---

## Known gaps — verified against the code, resolve before starting

These were found auditing the plan against the current tree. Each changes work in a task below.

1. **Scan-time cache ≠ what HLS actually packages.** `hls.build_hls_package` (`hls.py:224-244`) re-runs `discover_subtitles(source)` at package time and *drops* any track that fails `convert_to_webvtt` (VobSub, malformed, OSError), so `master.m3u8` can carry a strict subset of `video_versions.subtitle_langs`. The picker will therefore list languages the player cannot select; `applySubtitleSelection` no-ops on those (no crash, but a dead menu entry). Two options — decide before Task 2:
   - *Accept*: dead entries are rare; document it. (Default — no extra work.)
   - *Fix*: have `converter`/`hls` write the packaged track list back via `db.set_version_subtitle_langs` after `build_hls_package`, so the cache reflects what shipped. Costs one extra task, and re-probing at scan time must then not clobber it (guard on `subtitle_langs is None`, which Task 2 already does).
2. **Existing rows read as "no subtitles" until a rescan.** `subtitle_langs` starts NULL and only `scan_library` fills it (Task 2), while Task 4 deletes the live per-request probe. Between deploying and the next scan, `GET /api/videos/{id}` returns `subtitle_tracks: []` for rows that previously returned real tracks — a visible regression. Task 4 gets an explicit post-deploy `POST /api/library/scan` step; do not skip it.
3. **`subtitle_tracks` becomes a list-endpoint field.** Today it is populated only in `api_video` (detail). After Task 3 it is derived in `serialize_video`, so every library row in `GET /api/videos` carries it. That is required — `EpisodesView`/`VideoCell` only ever see list rows — but it grows the list payload by roughly one dict per sidecar per row. Confirm the list response size is still acceptable on a full library during Task 4 Step 6.
4. **TV episodes have no detail screen.** `MovieDetailView` is instantiated in exactly one place (`VideoGridView.swift:678`, the movies grid). Episodes render through `EpisodesView`, which has no Version/Audio picker at all. Task 7 as written therefore delivers movies only, contradicting the stated goal. Task 7b below adds the episode-level picker; drop it only by narrowing the goal explicitly.
5. **RESOLVED — `effectiveSubtitleLang` applies only an explicit choice.** Falling back to the `default`-flagged track would have made Task 8 *force* a `.legible` selection on every library item, overriding both the viewer's system captions preference and AVKit's own handling of `DEFAULT=YES`/`AUTOSELECT=YES` (already emitted by `hls._master_playlist:170-177`). Decided against: `effectiveSubtitleLang` returns `nil` whenever `subtitleLang` is `nil`, leaving an untouched video to AVKit's auto-select, which the playlist already steers correctly. Resolving the server's default track is the **picker's** job (display only), not the player's. Tasks 5, 7, 7b and 8 below are written to this decision — the picker still shows the default language pre-selected, but nothing is sent to the server and nothing is forced in the player until the user picks.

---

### Task 1: Backend — DB schema and accessors for subtitle preference and per-version cache

**Files:**
- Modify: `db.py:148-149` (add `videos.subtitle_lang` column guard), `db.py:235-238` (add `video_versions.subtitle_langs` column guard), `db.py:563-566` (add `set_subtitle_lang` near `set_audio_lang`), `db.py:578-583` (add `set_version_subtitle_langs` near `set_version_audio_langs`)
- Test: `tests/test_db.py`

**Interfaces:**
- Produces: `db.set_subtitle_lang(video_id: int, lang: str | None) -> None`, `db.set_version_subtitle_langs(version_id: int, subtitle_langs_json: str) -> None`. Both columns are picked up automatically by every existing `SELECT *` read path (`get_video`, `get_all_videos`/`_attach_versions`, `get_video_version`, `get_video_versions`) — no reader changes needed.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_db.py` (place near `test_audio_lang_roundtrip` / `test_version_audio_langs_roundtrip`, using the existing `_lib_item(tmp_path)` helper already defined in that file):

```python
def test_subtitle_lang_roundtrip(fresh_db, tmp_path):
    import db

    vid, _ = db.upsert_library_video(_lib_item(tmp_path))
    assert db.get_video(vid)["subtitle_lang"] is None
    db.set_subtitle_lang(vid, "es")
    assert db.get_video(vid)["subtitle_lang"] == "es"
    db.set_subtitle_lang(vid, "")
    assert db.get_video(vid)["subtitle_lang"] == ""


def test_version_subtitle_langs_roundtrip(fresh_db, tmp_path):
    import db

    vid, _ = db.upsert_library_video(_lib_item(tmp_path))
    version = db.get_video_versions(vid)[0]
    assert version["subtitle_langs"] is None
    db.set_version_subtitle_langs(
        version["id"],
        '[{"language": "en", "name": "English", "default": true, "forced": false}]',
    )
    version = db.get_video_versions(vid)[0]
    assert version["subtitle_langs"] == (
        '[{"language": "en", "name": "English", "default": true, "forced": false}]'
    )
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tests/test_db.py::test_subtitle_lang_roundtrip tests/test_db.py::test_version_subtitle_langs_roundtrip -v`
Expected: FAIL — `AttributeError`/`KeyError` (`subtitle_lang` column doesn't exist yet, `set_subtitle_lang` doesn't exist yet).

- [ ] **Step 3: Add the column guards**

In `db.py`, right after the existing `audio_lang` guard:

```python
        if "audio_lang" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN audio_lang TEXT")
        # NULL = never chosen (client falls back to the server's default-flagged
        # subtitle track); "" = explicitly off; anything else = the chosen
        # language tag. See views/serializers.py for how this is exposed.
        if "subtitle_lang" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN subtitle_lang TEXT")
```

Right after the existing `converted_langs` guard (in the `version_columns` block):

```python
        if "audio_langs" not in version_columns:
            _add_column(conn, "ALTER TABLE video_versions ADD COLUMN audio_langs TEXT")
        if "converted_langs" not in version_columns:
            _add_column(conn, "ALTER TABLE video_versions ADD COLUMN converted_langs TEXT")
        # JSON list of {language, name, default, forced}, filled once at scan
        # time by library.py's _probe_missing_subtitle_langs (mirrors
        # audio_langs). NULL means "not probed yet", not "no subtitles" — an
        # empty JSON array `[]` means the latter.
        if "subtitle_langs" not in version_columns:
            _add_column(conn, "ALTER TABLE video_versions ADD COLUMN subtitle_langs TEXT")
```

- [ ] **Step 4: Add the accessor functions**

In `db.py`, right after `set_audio_lang` (line 563-566):

```python
def set_subtitle_lang(video_id: int, lang: str | None) -> None:
    with _conn() as conn:
        conn.execute("UPDATE videos SET subtitle_lang = ? WHERE id = ?", (lang, video_id))
```

Right after `set_version_audio_langs` (line 578-583):

```python
def set_version_subtitle_langs(version_id: int, subtitle_langs_json: str) -> None:
    with _conn() as conn:
        conn.execute(
            "UPDATE video_versions SET subtitle_langs = ? WHERE id = ?",
            (subtitle_langs_json, version_id),
        )
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `python -m pytest tests/test_db.py::test_subtitle_lang_roundtrip tests/test_db.py::test_version_subtitle_langs_roundtrip -v`
Expected: PASS

- [ ] **Step 6: Run the full db test suite to check for regressions**

Run: `python -m pytest tests/test_db.py -v`
Expected: PASS (all tests, including the pre-existing audio ones)

- [ ] **Step 7: Commit**

```bash
git add db.py tests/test_db.py
git commit -m "feat: add subtitle_lang and subtitle_langs columns"
```

---

### Task 2: Backend — scan-time subtitle discovery cache

**Files:**
- Modify: `library.py:1-13` (import), `library.py:273-282` (add `_probe_missing_subtitle_langs` near `_probe_missing_audio_langs`), `library.py:336` (call it from `scan_library`)
- Test: `tests/test_library.py`

**Interfaces:**
- Consumes: `db.get_video_versions(video_id) -> list[dict]` (has `subtitle_langs` key from Task 1), `db.set_version_subtitle_langs(version_id, json_str)` (Task 1), `subtitles.discover_subtitles(video_path) -> list[SubtitleTrack]` (existing, `subtitles.py:206`), where `SubtitleTrack` has `.language: str`, `.name: str`, `.default: bool`, `.forced: bool` (existing, `subtitles.py:98-104`).
- Produces: `library._probe_missing_subtitle_langs(video_id: int) -> None`, called from `scan_library`. After a scan, every version's `subtitle_langs` column holds a JSON list of `{"language": ..., "name": ..., "default": ..., "forced": ...}`.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_library.py`, near `test_scan_probes_missing_audio_langs` (uses real sidecar files on `tmp_path` rather than monkeypatching, since `discover_subtitles` is a cheap filesystem scan):

```python
def test_scan_probes_missing_subtitle_langs(fresh_db, tmp_path, monkeypatch):
    import db
    import plex

    src = tmp_path / "a.mkv"
    src.write_bytes(b"x")
    (tmp_path / "a.eng.srt").write_bytes(b"1\n00:00:00,000 --> 00:00:01,000\nhi\n")
    item = {"source_path": str(src), "title": "a", "plex_kind": "movies",
            "show_title": None, "season": None, "episode": None, "summary": None,
            "plex_rating_key": "a", "show_rating_key": None}
    monkeypatch.setattr(plex, "fetch_library_items", lambda: [item])
    monkeypatch.setattr(library, "probe_source", lambda p: {"streams": [], "format": {}})

    calls = []
    real_discover = library.discover_subtitles

    def counting_discover(path):
        calls.append(str(path))
        return real_discover(path)

    monkeypatch.setattr(library, "discover_subtitles", counting_discover)

    library.scan_library()
    movie = db.get_all_videos(plex_kind="movies")[0]
    version = db.get_video_versions(movie["id"])[0]
    import json
    tracks = json.loads(version["subtitle_langs"])
    assert [t["language"] for t in tracks] == ["en"]
    assert calls == [str(src)]

    library.scan_library()  # second scan: already probed, no new discovery call
    assert calls == [str(src)]


def test_scan_survives_subtitle_probe_failure(fresh_db, tmp_path, monkeypatch):
    import db
    import plex

    src = tmp_path / "a.mkv"
    src.write_bytes(b"x")
    item = {"source_path": str(src), "title": "a", "plex_kind": "movies",
            "show_title": None, "season": None, "episode": None, "summary": None,
            "plex_rating_key": "a", "show_rating_key": None}
    monkeypatch.setattr(plex, "fetch_library_items", lambda: [item])
    monkeypatch.setattr(library, "probe_source", lambda p: {"streams": [], "format": {}})

    def boom(path):
        raise RuntimeError("fs error")

    monkeypatch.setattr(library, "discover_subtitles", boom)
    result = library.scan_library()
    assert result["added"] == 1  # scan not aborted
```

Make sure `import library` is present at the top of the relevant test (check the file's existing top-of-file imports; `test_scan_probes_missing_audio_langs` already relies on a module-level `import library` — reuse it, don't re-import locally).

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tests/test_library.py::test_scan_probes_missing_subtitle_langs tests/test_library.py::test_scan_survives_subtitle_probe_failure -v`
Expected: FAIL — `AttributeError: module 'library' has no attribute 'discover_subtitles'`

- [ ] **Step 3: Add the import and probe function**

In `library.py`, add to the imports (near `from downloader import _probe_media`, line 12):

```python
from subtitles import discover_subtitles
```

Add `_probe_missing_subtitle_langs`, right after `_probe_missing_audio_langs` (`library.py:273-282`):

```python
def _probe_missing_subtitle_langs(video_id: int) -> None:
    """Fill missing per-version subtitle metadata without aborting a library scan."""
    for version in db.get_video_versions(video_id):
        if version.get("subtitle_langs") is not None:
            continue
        try:
            tracks = discover_subtitles(Path(version["source_path"]))
        except Exception:  # noqa: BLE001 - scan must survive a bad file
            continue
        db.set_version_subtitle_langs(version["id"], json.dumps([
            {
                "language": track.language,
                "name": track.name,
                "default": track.default,
                "forced": track.forced,
            }
            for track in tracks
        ]))
```

- [ ] **Step 4: Call it from `scan_library`**

In `library.py:336`, right after the existing `_probe_missing_audio_langs(video_id)` call:

```python
        _probe_missing_audio_langs(video_id)
        _probe_missing_subtitle_langs(video_id)
        _heal_missing_conversions(video_id)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `python -m pytest tests/test_library.py::test_scan_probes_missing_subtitle_langs tests/test_library.py::test_scan_survives_subtitle_probe_failure -v`
Expected: PASS

- [ ] **Step 6: Run the full library test suite to check for regressions**

Run: `python -m pytest tests/test_library.py -v`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add library.py tests/test_library.py
git commit -m "feat: probe subtitle sidecars at library scan time"
```

---

### Task 3: Backend — expose subtitle_tracks/subtitle_lang through the serializer

**Files:**
- Modify: `views/serializers.py` (add `_subtitle_tracks` helper, wire into `serialize_video`)
- Test: `tests/test_serializers.py` (update `import json`, replace `test_injected_subtitle_tracks_are_passed_through`)

**Interfaces:**
- Consumes: a `version` dict with a `subtitle_langs` key holding a JSON string (from Task 1/2) or `None`.
- Produces: `serialize_video(video)["subtitle_tracks"]` — video-level list of `{"language", "name", "default", "forced"}` dicts, derived from the video's chosen version (or first version) when `video["versions"]` is present; `[]` otherwise. `serialize_video(video)["subtitle_lang"]` — the raw `video.get("subtitle_lang")` value, present only when `video["versions"]` is present (same condition `audio_lang` already uses).

- [ ] **Step 1: Write the failing tests**

In `tests/test_serializers.py`, add `import json` at the top (file currently only imports `serialize_video`). Replace `test_injected_subtitle_tracks_are_passed_through` (lines 104-112) with:

```python
def test_serialize_subtitle_tracks_from_chosen_version():
    video = _library_video()
    video["subtitle_lang"] = "en"
    video["versions"][0]["subtitle_langs"] = json.dumps([
        {"language": "en", "name": "English", "default": True, "forced": False},
        {"language": "es", "name": "Spanish", "default": False, "forced": False},
    ])
    data = serialize_video(video)
    assert data["subtitle_lang"] == "en"
    assert data["subtitle_tracks"] == [
        {"language": "en", "name": "English", "default": True, "forced": False},
        {"language": "es", "name": "Spanish", "default": False, "forced": False},
    ]


def test_serialize_subtitle_tracks_unprobed():
    video = _library_video()
    data = serialize_video(video)
    assert data["subtitle_tracks"] == []
    assert data["subtitle_lang"] is None
```

(`_library_video()` is the existing fixture at the top of the file — its single version already has `is_chosen: True`, which the new derivation logic keys off.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tests/test_serializers.py::test_serialize_subtitle_tracks_from_chosen_version tests/test_serializers.py::test_serialize_subtitle_tracks_unprobed -v`
Expected: FAIL — `KeyError: 'subtitle_lang'` (not yet emitted) and the tracks list not matching (still driven by the old `video.get("subtitle_tracks")` mechanism).

- [ ] **Step 3: Add `_subtitle_tracks` and wire it in**

In `views/serializers.py`, add right after `_audio_tracks` (lines 8-30):

```python
def _subtitle_tracks(version: dict) -> list[dict]:
    """Parse the scan-time-cached subtitle track list for one version."""
    try:
        return json.loads(version.get("subtitle_langs") or "[]")
    except (TypeError, ValueError):
        return []
```

Remove the unconditional injection line from the top of `serialize_video`'s `data` dict (currently lines 93-96):

```python
        "show_preview_url": None,
        # Sidecar subtitles only exist for library rows; callers that have
        # discovered them inject `subtitle_tracks`. Download rows are always [].
        "subtitle_tracks": video.get("subtitle_tracks") or [],
    }
```

Replace with:

```python
        "show_preview_url": None,
        "subtitle_tracks": [],
    }
```

Then, inside the existing `if video.get("versions") is not None:` block (lines 100-112), add the subtitle fields:

```python
    if video.get("versions") is not None:
        data["chosen_version_id"] = video.get("chosen_version_id")
        data["audio_lang"] = video.get("audio_lang")
        data["subtitle_lang"] = video.get("subtitle_lang")
        versions = video.get("versions") or []
        chosen = next((v for v in versions if v.get("is_chosen")), None) or (
            versions[0] if versions else None
        )
        if chosen:
            data["subtitle_tracks"] = _subtitle_tracks(chosen)
        data["versions"] = [
            {
                "id": version["id"],
                "label": version.get("label"),
                "status": version["status"],
                "is_chosen": bool(version.get("is_chosen")),
                "audio_tracks": _audio_tracks(version),
            }
            for version in versions
        ]
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python -m pytest tests/test_serializers.py -v`
Expected: PASS — all tests, including the two new ones and the full-shape/download-row tests that still expect `"subtitle_tracks": []` unconditionally.

- [ ] **Step 5: Commit**

```bash
git add views/serializers.py tests/test_serializers.py
git commit -m "feat: derive subtitle_tracks and subtitle_lang from scan-time data"
```

---

### Task 4: Backend — subtitle preference endpoint, remove the live-probe detail path

**Files:**
- Modify: `router.py:153-155` (add `SubtitleRequest` model near `AudioRequest`), `router.py:987-988` (add `POST /api/videos/{video_id}/subtitle` endpoint after `api_choose_audio`), `router.py:1067-1090` (simplify `api_video` — remove the ad hoc `hls.discover_subtitles` block)
- Test: `tests/test_api.py`

**Interfaces:**
- Consumes: `db.get_video`, `db.get_video_version`, `db.set_subtitle_lang` (Task 1), `serialize_video` (Task 3).
- Produces: `POST /api/videos/{video_id}/subtitle` — body `{"lang": str | None}`. `lang: null` clears to "not chosen" (falls back to server default on the client). `lang: ""` means explicit off. `lang: "<tag>"` must be present in the chosen version's `subtitle_langs` or the request 400s. Response `{"ok": true}` on success. Never calls `hls.invalidate`.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_api.py`, near the existing `_seed_multi_audio_movie`/audio tests (reuse the `client`/`AUTH` fixtures already used by those tests):

```python
def _seed_subtitle_movie(tmp_path, subtitle_langs=None):
    import db

    src = tmp_path / "m.mkv"
    src.write_bytes(b"x")
    vid, _ = db.upsert_library_video({
        "source_path": str(src), "title": "M", "plex_kind": "movies",
        "show_title": None, "season": None, "episode": None, "summary": None,
        "plex_rating_key": "sm1", "show_rating_key": None,
    })
    version = db.get_video_versions(vid)[0]
    if subtitle_langs is None:
        subtitle_langs = [
            {"language": "en", "name": "English", "default": True, "forced": False},
            {"language": "es", "name": "Spanish", "default": False, "forced": False},
        ]
    db.set_version_subtitle_langs(version["id"], json.dumps(subtitle_langs))
    db.set_library_state(vid, "done", converted_path=str(tmp_path / "m.mp4"), version_id=version["id"])
    return vid, version["id"]


def test_choose_subtitle_requires_token(client, tmp_path):
    vid, _ = _seed_subtitle_movie(tmp_path)

    resp = client.post(f"/api/videos/{vid}/subtitle", json={"lang": "es"})

    assert resp.status_code in (401, 403)


def test_choose_subtitle_sets_lang(client, tmp_path):
    import db

    vid, _ = _seed_subtitle_movie(tmp_path)
    resp = client.post(f"/api/videos/{vid}/subtitle", json={"lang": "es"}, headers=AUTH)

    assert resp.status_code == 200
    assert resp.json() == {"ok": True}
    assert db.get_video(vid)["subtitle_lang"] == "es"


def test_choose_subtitle_off_is_valid(client, tmp_path):
    import db

    vid, _ = _seed_subtitle_movie(tmp_path)
    resp = client.post(f"/api/videos/{vid}/subtitle", json={"lang": ""}, headers=AUTH)

    assert resp.status_code == 200
    assert db.get_video(vid)["subtitle_lang"] == ""


def test_choose_subtitle_rejects_unknown_lang(client, tmp_path):
    vid, _ = _seed_subtitle_movie(tmp_path)

    resp = client.post(f"/api/videos/{vid}/subtitle", json={"lang": "jp"}, headers=AUTH)

    assert resp.status_code == 400


def test_choose_subtitle_does_not_invalidate_hls(client, tmp_path, monkeypatch):
    import hls

    vid, _ = _seed_subtitle_movie(tmp_path)
    calls = []
    monkeypatch.setattr(hls, "invalidate", lambda video_id: calls.append(video_id))

    resp = client.post(f"/api/videos/{vid}/subtitle", json={"lang": "es"}, headers=AUTH)

    assert resp.status_code == 200
    assert calls == []


def test_get_video_exposes_subtitle_tracks_from_scan_cache(client, tmp_path):
    vid, _ = _seed_subtitle_movie(tmp_path)

    resp = client.get(f"/api/videos/{vid}", headers=AUTH)

    assert resp.status_code == 200
    body = resp.json()
    assert body["subtitle_tracks"] == [
        {"language": "en", "name": "English", "default": True, "forced": False},
        {"language": "es", "name": "Spanish", "default": False, "forced": False},
    ]
```

Check the top of `tests/test_api.py` for an existing `import json` (used elsewhere in the file, e.g. by `_seed_multi_audio_movie`) — reuse it, don't add a duplicate.

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tests/test_api.py -k choose_subtitle -v`
Run: `python -m pytest tests/test_api.py::test_get_video_exposes_subtitle_tracks_from_scan_cache -v`
Expected: FAIL — 404 (no such route) for the `/subtitle` tests; the detail-endpoint test currently passes already by the old live-probe mechanism, but re-run it after Step 4 to confirm the new path also satisfies it.

- [ ] **Step 3: Add `SubtitleRequest` and the endpoint**

In `router.py`, right after `class AudioRequest` (lines 153-155):

```python
class SubtitleRequest(BaseModel):
    lang: str | None = None
```

Right after `api_choose_audio`'s `return {"ok": True}` (`router.py:987`), before `api_save_position`:

```python
@router.post("/api/videos/{video_id}/subtitle")
async def api_choose_subtitle(video_id: int, body: SubtitleRequest, request: Request):
    """Persist a subtitle preference. Unlike audio, this never re-converts —
    every discovered language is already packaged into the HLS multivariant
    playlist at conversion time (see hls.py), so there is nothing to invalidate.
    """
    _check_token(request)
    video = db.get_video(video_id)
    if not video or video.get("deleted_at"):
        raise HTTPException(status_code=404, detail="Video not found")
    if video.get("source") != "library":
        raise HTTPException(status_code=400, detail="Only library videos have subtitles")

    if body.lang:
        version = db.get_video_version(video_id)
        if not version:
            raise HTTPException(status_code=404, detail="Version not found")
        try:
            available = {
                track["language"] for track in json.loads(version.get("subtitle_langs") or "[]")
            }
        except (TypeError, ValueError):
            available = set()
        if body.lang not in available:
            raise HTTPException(status_code=400, detail="Language not available")

    db.set_subtitle_lang(video_id, body.lang)
    return {"ok": True}
```

(`body.lang` truthiness: `None` and `""` both skip the availability check — `None` means "reset to unchosen" and `""` means "explicit off," neither is a language that needs validating; only a non-empty string goes through the check.)

- [ ] **Step 4: Simplify `api_video`, removing the live filesystem probe**

Replace the whole `api_video` function (`router.py:1067-1090`):

```python
@router.get("/api/videos/{video_id}")
async def api_video(video_id: int, request: Request):
    _check_token(request)
    video = db.get_video(video_id)
    if not video or video.get("deleted_at"):
        raise HTTPException(status_code=404, detail="Video not found")
    return serialize_video(video)
```

Check whether `hls.discover_subtitles` (or `hls` generally) is still referenced elsewhere in `router.py` before removing any now-unused import — `hls.safe_asset_path`, `hls.HLS_CONTENT_TYPES`, and `hls.invalidate` are all still used (confirmed at `router.py:716,721,973`), so the `import hls` line stays; only the `hls.discover_subtitles(...)` call site goes away.

- [ ] **Step 5: Run tests to verify they pass**

Run: `python -m pytest tests/test_api.py -k "choose_subtitle or exposes_subtitle_tracks" -v`
Expected: PASS

- [ ] **Step 6: Run the full API test suite to check for regressions**

Run: `python -m pytest tests/test_api.py -v`
Expected: PASS

- [ ] **Step 7: Run the entire backend test suite**

Run: `python -m pytest tests/ -v`
Expected: PASS

- [ ] **Step 7b: Backfill the cache on the running server (gap #2)**

The live probe is now gone and `subtitle_langs` is NULL on every existing row, so
until a scan runs the detail endpoint reports no subtitles at all. Run one scan
and confirm the cache filled and the list payload is still sane:

```bash
curl -sX POST localhost:3050/api/library/scan -H "Authorization: Bearer $UPLOAD_TOKEN"
sqlite3 data/videos.db "SELECT COUNT(*) FROM video_versions WHERE subtitle_langs IS NULL"   # expect 0
curl -s localhost:3050/api/videos -H "Authorization: Bearer $UPLOAD_TOKEN" | wc -c           # compare to before
```

- [ ] **Step 8: Commit**

```bash
git add router.py tests/test_api.py
git commit -m "feat: add subtitle preference endpoint, drop live subtitle probe"
```

---

### Task 5: iOS — Video model additions (subtitleLang, effectiveSubtitleLang, defaultSubtitleLang, withSubtitleLang)

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/Video.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoTests.swift`, `ios/PatataTubeKit/Tests/PatataTubeKitTests/APIClientReadTests.swift`

**Interfaces:**
- Produces: `Video.subtitleLang: String?` (new stored property, decodes `subtitle_lang` via existing snake→camel `keyDecodingStrategy`), `Video.effectiveSubtitleLang: String?` (computed — the stored choice only; `""` and `nil` both resolve to `nil`, per gap #5), `Video.defaultSubtitleLang: String?` (computed — the `default`-flagged entry in `subtitleTracks`, used by the pickers for display), `Video.withSubtitleLang(_ lang: String?) -> Video`.

- [ ] **Step 1: Write the failing tests**

Add to `ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoTests.swift` (mirror the existing decode tests in that file, which construct a raw JSON string and decode it):

```swift
@Test func decodesSubtitleLang() throws {
    let json = #"{"id":1,"url":"u","status":"done","group_id":3,"plex_kind":null,"subtitle_lang":"es","subtitle_tracks":[]}"#
    let video = try JSONDecoder().decode(Video.self, from: Data(json.utf8))
    #expect(video.subtitleLang == "es")
}

@Test func subtitleLangDefaultsToNilWhenAbsent() throws {
    let json = #"{"id":1,"url":"u","status":"done","subtitle_tracks":[]}"#
    let video = try JSONDecoder().decode(Video.self, from: Data(json.utf8))
    #expect(video.subtitleLang == nil)
}

// Gap #5: an unchosen video applies nothing — AVKit auto-selects from the
// playlist's DEFAULT=YES instead. The default track surfaces only through
// `defaultSubtitleLang`, which the pickers use for display.
@Test func effectiveSubtitleLangIsNilWhenNeverChosen() {
    let video = Video(
        id: 1, url: "u", title: nil, platform: nil, sourceKey: nil, previewUrl: nil,
        groupID: nil, plexKind: nil, position: nil, status: "done", errorMsg: nil,
        streamPath: "", subtitleTracks: [
            SubtitleTrack(language: "en", name: "English", default: true, forced: false),
            SubtitleTrack(language: "es", name: "Spanish", default: false, forced: false),
        ]
    )
    #expect(video.effectiveSubtitleLang == nil)
    #expect(video.defaultSubtitleLang == "en")
}

@Test func defaultSubtitleLangIsNilWithoutAFlaggedTrack() {
    let video = Video(
        id: 1, url: "u", title: nil, platform: nil, sourceKey: nil, previewUrl: nil,
        groupID: nil, plexKind: nil, position: nil, status: "done", errorMsg: nil,
        streamPath: "", subtitleTracks: [
            SubtitleTrack(language: "es", name: "Spanish", default: false, forced: false),
        ]
    )
    #expect(video.defaultSubtitleLang == nil)
}

@Test func effectiveSubtitleLangHonorsExplicitOff() {
    let video = Video(
        id: 1, url: "u", title: nil, platform: nil, sourceKey: nil, previewUrl: nil,
        groupID: nil, plexKind: nil, position: nil, status: "done", errorMsg: nil,
        streamPath: "", subtitleTracks: [
            SubtitleTrack(language: "en", name: "English", default: true, forced: false),
        ], subtitleLang: ""
    )
    #expect(video.effectiveSubtitleLang == nil)
}

@Test func effectiveSubtitleLangHonorsExplicitChoice() {
    let video = Video(
        id: 1, url: "u", title: nil, platform: nil, sourceKey: nil, previewUrl: nil,
        groupID: nil, plexKind: nil, position: nil, status: "done", errorMsg: nil,
        streamPath: "", subtitleTracks: [
            SubtitleTrack(language: "en", name: "English", default: true, forced: false),
            SubtitleTrack(language: "es", name: "Spanish", default: false, forced: false),
        ], subtitleLang: "es"
    )
    #expect(video.effectiveSubtitleLang == "es")
}
```

Check the existing `Video(...)` memberwise-style calls elsewhere in this test file for the exact parameter order/labels already in use (e.g. `VideoHashableTests.swift:11`) and match it — the designated initializer signature is defined in Task 5 Step 3 below, so the test calls above must line up with it exactly once that step is done. If a required parameter is missing from an example call above, add it with a sensible default matching the surrounding tests' style (e.g. `resumeSecs: 0` is already defaulted in the initializer).

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios/PatataTubeKit && swift test --filter VideoTests`
Expected: FAIL — `subtitleLang`/`effectiveSubtitleLang` not found on `Video`.

- [ ] **Step 3: Add `subtitleLang` to `Video`**

In `ios/PatataTubeKit/Sources/PatataTubeKit/Video.swift`, add the stored property (after `audioLang`, before `resumeSecs`, line 79):

```swift
    public let audioLang: String?
    public let subtitleLang: String?
    public let resumeSecs: Double
```

Add to `CodingKeys` (line 82-90):

```swift
        case audioLang
        case subtitleLang
        case resumeSecs
```

Add to the designated initializer's parameter list and body (lines 102-122) — insert `subtitleLang: String? = nil` right after `audioLang: String? = nil`, and `self.subtitleLang = subtitleLang` right after `self.audioLang = audioLang`.

Add to the `Decodable` initializer (lines 124-154) — right after `self.audioLang = try c.decodeIfPresent(String.self, forKey: .audioLang)`:

```swift
        self.subtitleLang = try c.decodeIfPresent(String.self, forKey: .subtitleLang)
```

Update the three existing `with*` methods (`withChosenVersion`, `withGroupID`, `withAudioLang`, lines 156-196) to thread `subtitleLang` through unchanged (they currently rebuild a full `Video`, listing every field — add `subtitleLang: subtitleLang` to each of the three `Video(...)` calls, right after the existing `audioLang:` argument).

- [ ] **Step 4: Add `withSubtitleLang`, `effectiveSubtitleLang` and `defaultSubtitleLang`**

Right after `withAudioLang` (line 187-196):

```swift
    func withSubtitleLang(_ lang: String?) -> Video {
        return Video(id: id, url: url, title: title, platform: platform, sourceKey: sourceKey,
              previewUrl: previewUrl, groupID: groupID, plexKind: plexKind, position: position,
              status: status, errorMsg: errorMsg, streamPath: streamPath,
              source: source, showTitle: showTitle, season: season,
              episode: episode, summary: summary, showPreviewUrl: showPreviewUrl,
              chosenVersionId: chosenVersionId, versions: versions,
              hlsPath: hlsPath, subtitleTracks: subtitleTracks,
              sourceFilename: sourceFilename, audioLang: audioLang, subtitleLang: lang,
              resumeSecs: resumeSecs)
    }

    /// The subtitle language to force on the player, or `nil` to force nothing.
    /// Only an explicit stored choice counts (`""` means explicitly off). A
    /// video the user has never touched deliberately resolves to `nil`: the HLS
    /// multivariant playlist already carries DEFAULT=YES/AUTOSELECT=YES for the
    /// server's default track (see hls._master_playlist), so AVKit's own
    /// auto-select honours the viewer's system captions preference. Forcing a
    /// selection here would override it. See `defaultSubtitleLang` for the
    /// display-side resolution the pickers use.
    public var effectiveSubtitleLang: String? {
        guard let subtitleLang, !subtitleLang.isEmpty else { return nil }
        return subtitleLang
    }

    /// Whichever track the server flagged `default`, for showing a sensible
    /// pre-selection in a picker. Never fed to the player — see
    /// `effectiveSubtitleLang`.
    public var defaultSubtitleLang: String? {
        subtitleTracks.first(where: { $0.default })?.language
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd ios/PatataTubeKit && swift test --filter VideoTests`
Expected: PASS

- [ ] **Step 6: Update `APIClientReadTests.swift` for the new field**

Find the existing subtitle-tracks decode test in `ios/PatataTubeKit/Tests/PatataTubeKitTests/APIClientReadTests.swift` (around line 85, JSON literal containing `"subtitle_tracks":[...]`) and add `"subtitle_lang":"en",` next to it in the JSON literal, plus an assertion:

```swift
#expect(videos[0].subtitleLang == "en")
```

- [ ] **Step 7: Run the full PatataTubeKit test suite (both configurations)**

Run: `cd ios/PatataTubeKit && swift test`
Run: `cd ios/PatataTubeKit && swift test -c release`
Expected: PASS. (Per the project's known caveat, a full parallel run may show unrelated pre-existing flakiness — re-run the specific `VideoTests`/`APIClientReadTests` filtered if anything outside those looks off.)

- [ ] **Step 8: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/Video.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoTests.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/APIClientReadTests.swift
git commit -m "feat: add subtitleLang and effectiveSubtitleLang to Video"
```

---

### Task 6: iOS — APIClient.chooseSubtitle and VideoStore.chooseSubtitle

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/APIClient.swift`, `ios/PatataTubeKit/Sources/PatataTubeKit/VideoStore.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoStoreTests.swift`

**Interfaces:**
- Consumes: `Video.withSubtitleLang(_:)` (Task 5).
- Produces: `VideoAPI.chooseSubtitle(id: Int, lang: String?) async throws -> Bool` (protocol method with a default `{ false }` implementation, overridden by the real `APIClient`), `VideoStore.chooseSubtitle(id: Int, lang: String?) async -> Void`.

- [ ] **Step 1: Write the failing test**

Add to `ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoStoreTests.swift`. First, extend the `FakeAPI` mock (near `chooseAudioResult`/`chosenAudio`, lines 80-81, and `chooseAudio(id:lang:)`, lines 99-103):

```swift
    var chooseSubtitleResult = true
    private(set) var chosenSubtitle: [(id: Int, lang: String?)] = []
```

```swift
    func chooseSubtitle(id: Int, lang: String?) async throws -> Bool {
        if let mutationError { throw mutationError }
        chosenSubtitle.append((id, lang))
        return chooseSubtitleResult
    }
```

Then add the tests themselves, mirroring `chooseAudioOptimisticallyUpdatesThenReloads`/`chooseAudioRevertsWhenServerReturnsNotOk` (lines 1064-1088) — but note `chooseSubtitle` does **not** reload (no server-side reconversion can happen), so assert `loadCount` stays at 1, not 2:

```swift
@MainActor @Test func chooseSubtitleOptimisticallyUpdates() async {
    let api = FakeAPI()
    api.videosToReturn = [makeVideo(id: 1)]
    let store = VideoStore(api: api, defaults: makeDefaults())
    await store.load()

    await store.chooseSubtitle(id: 1, lang: "es")

    #expect(api.chosenSubtitle.map(\.id) == [1])
    #expect(api.chosenSubtitle.map(\.lang) == ["es"])
    #expect(store.videos[0].subtitleLang == "es")
    #expect(api.loadCount == 1)
}

@MainActor @Test func chooseSubtitleRevertsWhenServerReturnsNotOk() async {
    let api = FakeAPI()
    api.videosToReturn = [makeVideo(id: 1)]
    api.chooseSubtitleResult = false
    let store = VideoStore(api: api, defaults: makeDefaults())
    await store.load()

    await store.chooseSubtitle(id: 1, lang: "es")

    #expect(store.videos[0].subtitleLang == nil)
}
```

Check `makeVideo(id:)` in this file for its default parameters — it should not need changes since `subtitleLang` defaults to `nil` in `Video`'s initializer (Task 5).

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios/PatataTubeKit && swift test --filter chooseSubtitle`
Expected: FAIL — `chooseSubtitle` not found on `VideoStore`/`FakeAPI` doesn't conform yet (compile error until Step 3/4 land).

- [ ] **Step 3: Add `chooseSubtitle` to `APIClient.swift`**

In the `VideoAPI` protocol (right after `chooseAudio`, line 28):

```swift
    func chooseAudio(id: Int, lang: String) async throws -> Bool
```

leave that line as-is, but note `chooseSubtitle` goes in the **default-implementation extension** instead (right after `promote`, lines 54, inside `public extension VideoAPI { ... }`), so the several test-double conformers elsewhere in the codebase that don't exercise subtitles don't need editing:

```swift
    func chooseSubtitle(id: Int, lang: String?) async throws -> Bool { false }
```

Then in the real `APIClient` class, right after `chooseAudio` (line 152-154):

```swift
    public func chooseSubtitle(id: Int, lang: String?) async throws -> Bool {
        try await postOK("api/videos/\(id)/subtitle", body: ["lang": lang ?? NSNull()])
    }
```

(`FakeAPI` in `VideoStoreTests.swift` gets its own explicit override from Step 1 above, which takes precedence over the protocol default.)

- [ ] **Step 4: Add `chooseSubtitle` to `VideoStore.swift`**

Right after `chooseAudio` (`VideoStore.swift:364-381`):

```swift
    /// Optimistically records the chosen subtitle language. Unlike audio, this
    /// never triggers a server-side reconversion (every subtitle language is
    /// already packaged into HLS), so there is no need to reload after.
    public func chooseSubtitle(id: Int, lang: String?) async {
        guard let index = videos.firstIndex(where: { $0.id == id }) else { return }
        let previous = videos[index]
        videos[index] = videos[index].withSubtitleLang(lang)
        do {
            let ok = try await api.chooseSubtitle(id: id, lang: lang)
            if !ok { videos[index] = previous }
        } catch {
            videos[index] = previous
            report(error)
        }
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd ios/PatataTubeKit && swift test --filter chooseSubtitle`
Expected: PASS

- [ ] **Step 6: Run the full PatataTubeKit test suite (both configurations)**

Run: `cd ios/PatataTubeKit && swift test`
Run: `cd ios/PatataTubeKit && swift test -c release`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/APIClient.swift ios/PatataTubeKit/Sources/PatataTubeKit/VideoStore.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoStoreTests.swift
git commit -m "feat: add chooseSubtitle to APIClient and VideoStore"
```

---

### Task 7: iOS — Subtitles picker in MovieDetailView

**Files:**
- Modify: `ios/PatataTube/Sources/MovieDetailView.swift`

**Interfaces:**
- Consumes: `Video.subtitleTracks: [SubtitleTrack]`, `Video.effectiveSubtitleLang: String?`, `Video.defaultSubtitleLang: String?` (Task 5), `VideoStore.chooseSubtitle(id:lang:)` (Task 6).

No automated test target exists for `ios/PatataTube/` (per `ios/README.md` — manual checklist only). This task is verified manually in Step 2.

- [ ] **Step 1: Add the picker**

In `ios/PatataTube/Sources/MovieDetailView.swift`, right after the existing Audio `Picker` block (lines 112-131, ending with `.pickerStyle(.menu)` before `Spacer()`):

```swift
                    let subtitleTracks = currentVideo.subtitleTracks
                    if !subtitleTracks.isEmpty {
                        Picker("Subtitles", selection: Binding(
                            // Display-side resolution (gap #5): show the server's
                            // default track as selected while nothing is stored,
                            // without that ever reaching the player or the server.
                            get: {
                                currentVideo.effectiveSubtitleLang
                                    ?? (currentVideo.subtitleLang == nil ? currentVideo.defaultSubtitleLang ?? "" : "")
                            },
                            set: { lang in
                                // Compare against the optional, not `?? ""`: with
                                // nothing stored the displayed value is the default
                                // track, so picking "Off" ("") is a real change that
                                // a `?? ""` comparison would swallow.
                                guard lang != currentVideo.subtitleLang else { return }
                                Task { await store.chooseSubtitle(id: currentVideo.id, lang: lang) }
                            }
                        )) {
                            Text("Off").tag("")
                            ForEach(subtitleTracks, id: \.language) { t in
                                Text(t.name).tag(t.language)
                            }
                        }
                        .pickerStyle(.menu)
                    }
```

Place it directly before the closing `Spacer()` (line 132), so it sits alongside Version/Audio in the same `HStack`.

- [ ] **Step 2: Manually verify in the simulator**

Run: `cd ios/PatataTube && xcodegen generate && open PatataTube.xcodeproj`, then Run on Simulator (Debug — `DEVLOG` is on automatically per `CLAUDE.md`).

Against a movie confirmed to have sidecar subs (e.g. "Glass" or "Project Hail Mary" from the earlier audit — needs a completed `scan_library` run and at least one `convert` job done so `subtitle_langs` is populated):
- Open its detail page. Confirm a "Subtitles" picker appears, showing the server's default-flagged language pre-selected (not "Off"), and that **no** `POST /api/videos/{id}/subtitle` fires just from opening it — the pre-selection is display-only until tapped (gap #5).
- Explicitly pick the language that was already displayed as the default. Confirm it *does* POST (the stored value went `nil` → `"en"`), since the picker was showing a resolved default, not a stored choice.
- Change it to a different language; confirm `log/ios.jsonl` shows the `POST /api/videos/{id}/subtitle` succeed (`grep '"kind":"net"' log/ios.jsonl | tail`) and the picker's selection persists across leaving and re-entering the detail page.
- Set it to "Off"; confirm the same persistence.
- Open a movie confirmed to have **no** sidecar subs; confirm no Subtitles picker renders at all.

- [ ] **Step 3: Commit**

```bash
git add ios/PatataTube/Sources/MovieDetailView.swift
git commit -m "feat: add Subtitles picker to MovieDetailView"
```

---

### Task 7b: iOS — subtitle picker for TV episodes (gap #4)

`MovieDetailView` is reachable only from the movies grid (`VideoGridView.swift:678`).
Episodes render in `EpisodesView`, which today exposes no track pickers at all —
it only forwards `episode.audioLang` to `DownloadButton` (`EpisodesView.swift:305`).
Without this task the plan's goal covers movies only.

**Files:**
- Modify: `ios/PatataTube/Sources/EpisodesView.swift`

**Interfaces:**
- Consumes: `Video.subtitleTracks`, `Video.effectiveSubtitleLang`, `Video.defaultSubtitleLang` (Task 5), `VideoStore.chooseSubtitle(id:lang:)` (Task 6). List rows carry `subtitle_tracks` after Task 3, so no extra fetch is needed.

- [ ] **Step 1: Decide the placement**

Read `EpisodesView.swift` around the episode row (line ~280-320) first. Two shapes fit:
- A per-episode `Menu` in the row's trailing accessory, next to the download button — matches how the row already surfaces per-episode state, but one control per row on a 20-episode season.
- A single season-level "Subtitles" picker in the toolbar that applies to the tapped episode on play — fewer controls, but the preference is per-video server-side, so it must fan out over the season's episodes (N POSTs) or be stored client-side only.

Pick the per-episode `Menu` unless the row is already crowded; it maps 1:1 onto the
existing `chooseSubtitle(id:lang:)` call and needs no new persistence concept.

- [ ] **Step 2: Add the control**

Mirror Task 7's binding exactly — same `""`-means-off tagging, same
display-only default resolution via `defaultSubtitleLang`, and the same
`guard lang != episode.subtitleLang` comparison against the *optional* (so "Off"
is postable while nothing is stored) — scoped to the row's `episode` instead of
`currentVideo`. Render nothing when `episode.subtitleTracks.isEmpty`.

- [ ] **Step 3: Manually verify in the simulator**

Against a show with sidecar subs on at least one episode (needs a completed
`scan_library`):
- Confirm the control appears only on episodes that have tracks.
- Change the language on one episode; confirm the POST succeeds in `log/ios.jsonl`
  and that the sibling episodes' selections are unaffected (the preference is
  per-video, not per-show).
- Play that episode; confirm the chosen language renders (Task 8's apply logic is
  shared, so this exercises it on the episode path too).

- [ ] **Step 4: Commit**

```bash
git add ios/PatataTube/Sources/EpisodesView.swift
git commit -m "feat: add subtitle picker to episode rows"
```

---

### Task 8: iOS — apply the resolved subtitle selection in VideoPlayerView

**Files:**
- Modify: `ios/PatataTube/Sources/VideoPlayerView.swift`

**Interfaces:**
- Consumes: `Video.subtitleLang: String?` and `Video.effectiveSubtitleLang: String?` (Task 5), the existing `normalizedLanguage(_:)` helper (`VideoPlayerView.swift:712-715`).

No automated test target exists for `ios/PatataTube/`; verified manually in Step 3.

- [ ] **Step 1: Add `applySubtitleSelection`**

Three-way, not two-way. Under gap #5's semantics both "never chosen" and
"explicitly off" make `effectiveSubtitleLang` `nil`, but they need *opposite*
player behaviour: never-chosen must leave AVKit's auto-select alone (which turns
the playlist's DEFAULT=YES track on), while explicitly-off must actively
deselect it. Branch on the raw `subtitleLang`, not on the resolved value.

Right after `applyAudioSelection` (`VideoPlayerView.swift:697-709`):

```swift
    /// Applies the user's stored subtitle choice, if there is one.
    ///
    /// - `nil` (never chosen): does nothing at all, leaving AVKit's own
    ///   auto-select to honour the playlist's DEFAULT=YES/AUTOSELECT=YES and
    ///   the viewer's system captions preference.
    /// - `""` (explicitly off): deselects the legible group, which is the only
    ///   way to beat that same auto-select.
    /// - a language tag: selects the matching option; no match leaves the
    ///   selection untouched.
    ///
    /// Live in-player switching is handled by AVKit's own captions menu, not
    /// this app.
    private func applySubtitleSelection(item: AVPlayerItem, lang: String?) async {
        guard let lang,
              let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
        if lang.isEmpty {
            item.select(nil, in: group)
            return
        }
        let target = normalizedLanguage(lang)
        guard let option = group.options.first(where: { option in
            guard let tag = option.extendedLanguageTag ?? option.locale?.identifier else { return false }
            return normalizedLanguage(tag) == target
        }) else { return }
        item.select(option, in: group)
    }
```

Note the argument is now the **raw** `video.subtitleLang`, not
`effectiveSubtitleLang` — `effectiveSubtitleLang` collapses `""` into `nil` and
would lose the off case. `effectiveSubtitleLang` stays useful to the pickers and
to any future caller that only wants "is a language forced", so keep it.

- [ ] **Step 2: Call it at both existing `applyAudioSelection` call sites**

At line 249 (initial setup), right after:

```swift
        Task { await applyAudioSelection(item: item, lang: video.audioLang) }
```

add:

```swift
        Task { await applySubtitleSelection(item: item, lang: video.subtitleLang) }
```

At line 646 (advance to next item), right after:

```swift
        Task { await applyAudioSelection(item: item, lang: videos[nextIndex].audioLang) }
```

add:

```swift
        Task { await applySubtitleSelection(item: item, lang: videos[nextIndex].subtitleLang) }
```

- [ ] **Step 3: Manually verify in the simulator**

Using the same movie from Task 7's manual check (a confirmed default-flagged subtitle track). All three branches of gap #5's semantics need covering:

- **Never chosen** (`subtitle_lang` still NULL — verify with `sqlite3 data/videos.db "SELECT subtitle_lang FROM videos WHERE id = <id>"`). Play it fresh (must be `done`, not `converting`). Whatever happens is AVKit's auto-select, not this app: with iOS captions set to Off/Automatic the expected result is **no subtitles**, and with a system captions language set they appear. Either way, confirm the app forced nothing — no `item.select` runs down this path. If subtitles turn on unasked here, the culprit is `DEFAULT=YES` in `master.m3u8`, not Task 8.
- **Explicit language.** Pick a language in the detail picker, then play. Confirm that language renders, including when it differs from the server's default-flagged track.
- **Explicit off.** Set the picker to "Off", then play. Confirm no subtitles render — this is the case that needs `item.select(nil, in: group)`, since the playlist's DEFAULT=YES would otherwise switch them on. Also confirm no crash/hang on an item whose asset has zero legible options.
- Tap to reveal AVKit's transport bar; confirm its "..." menu (or captions icon) lists the same languages and lets you switch live — this is stock AVKit behavior, not app code, so this step only confirms nothing in `PlayerViewController.swift` is suppressing it (e.g. `allowsPictureInPicturePlayback = false` and `updatesNowPlayingInfoCenter = false` are the only overrides there — neither affects `.legible` groups). A live switch here is *not* persisted to the server; that is intended.
- Play a movie with no sidecar subs at all; confirm no crash (the `guard let group = try? await ...` path silently no-ops).
- **Downloaded (offline) playback — expected to have no subtitles.** Download the
  same movie, then play it with the network off. `log/ios.jsonl` will show
  `source -> local_mp4` (`grep '"msg":"source -> ' log/ios.jsonl | tail`), and that
  asset has zero `.legible` options: no rendered subtitles and no AVKit captions
  button. Confirm it does not crash or hang, and that the picker still shows the
  stored choice. This is the constraint noted at the top of the plan, not a bug to
  fix here — if offline subtitles are wanted, the cache must store the HLS package
  (the `offline_hls` route at `VideoPlayerView.swift:479`) rather than the flat MP4,
  which is a separate piece of work.
- Confirm the languages AVKit lists match the picker's list. A mismatch is gap #1
  (a sidecar that failed `convert_to_webvtt` never reached `master.m3u8`), not a
  bug in this code.

- [ ] **Step 4: Commit**

```bash
git add ios/PatataTube/Sources/VideoPlayerView.swift
git commit -m "feat: apply resolved subtitle selection on playback"
```

---

### Task 9: Full regression pass

**Files:** none (verification only)

- [ ] **Step 1: Run the full backend test suite**

Run: `python -m pytest tests/ -v`
Expected: PASS, no regressions from Tasks 1-4.

- [ ] **Step 2: Run the full PatataTubeKit suite in both configurations**

Run: `cd ios/PatataTubeKit && swift test`
Run: `cd ios/PatataTubeKit && swift test -c release`
Expected: PASS (both — `DevLog`'s two build configurations exercise opposite halves of its gating per `CLAUDE.md`, and Tasks 5-6 touch code that DevLog instruments elsewhere in the package).

- [ ] **Step 3: Re-run the Task 7, 7b and Task 8 manual checklists end to end**

Confirm the full flow once more without interruption: scan a library with real sidecar subs present → detail page shows the picker pre-selected to the default track → change it → play → subtitles appear in the chosen language → background/foreground the app → position/selection both still correct on return.

- [ ] **Step 4: Update `ios/README.md`'s manual test checklist**

Add a line for the new subtitle-picker flow (Version/Audio picker already has an entry there per existing convention — mirror its wording) so future manual passes cover it.

- [ ] **Step 5: Commit**

```bash
git add ios/README.md
git commit -m "docs: add subtitle picker to manual test checklist"
```
