# Audio Language Selector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the iOS app pick an audio language for multi-language Plex library movies; conversions keep English + Spanish tracks, choice persists server-side, missing languages auto re-convert.

**Architecture:** ffprobe track lists are stored per version at scan time. Conversion maps every allowlisted audio track into the mp4. The HLS package carries only the chosen language and is invalidated when the choice or the converted file changes. iOS shows a per-movie picker in `MovieDetailView` and applies the choice via `AVMediaSelectionGroup` for mp4 playback.

**Tech Stack:** FastAPI + SQLite (idempotent migration guards), ffmpeg/ffprobe, pytest; SwiftUI + AVKit, SwiftPM package `PatataTubeKit`.

**Spec:** `docs/superpowers/specs/2026-07-19-audio-language-selector-design.md`

## Global Constraints

- Allowlist env var: `LIBRARY_AUDIO_LANGS`, default value exactly `eng,spa`.
- New JSON API fields: video `audio_lang` (string|null), version `audio_tracks` (list of `{"lang", "title", "available"}`).
- New endpoint: `POST /api/videos/{video_id}/audio` body `{"lang": "<code>"}`, Bearer token-gated.
- Library rows never get an `error` status and are never row-deleted; failures revert to `unconverted` with `error_msg`.
- Schema changes are additive idempotent guards in `db.init_db()` — no migrations framework.
- Async tests need `@pytest.mark.asyncio` individually (no global asyncio mode).
- Python venv: `python_env/`; run tests with `python -m pytest tests/`.
- iOS logic lives in `ios/PatataTubeKit` (verify with `swift build`); app shell in `ios/PatataTube` has no automated tests — manual checklist in `ios/README.md`.
- The `rtk` shell hook mangles some grep/sed output in this repo; prefer the Read tool over shell text commands when verifying files.

---

### Task 1: DB columns and accessors

**Files:**
- Modify: `db.py` (init_db guards around line 90; new functions after `set_chosen_version` ~line 416; `set_library_state` ~line 770)
- Test: `tests/test_db.py`

**Interfaces:**
- Produces: columns `videos.audio_lang TEXT`, `video_versions.audio_langs TEXT`, `video_versions.converted_langs TEXT`; `db.set_audio_lang(video_id: int, lang: str) -> None`; `db.set_version_audio_langs(version_id: int, audio_langs_json: str) -> None`; `db.set_library_state(..., converted_langs: str | None = None)`.
- Version dicts returned by `get_video_versions` / `get_video_version` / `_attach_versions` automatically include the new columns (they do `SELECT *`).

- [ ] **Step 1: Write failing tests**

Append to `tests/test_db.py` (follow the file's existing fixture pattern — open the file first and reuse its fresh-db fixture name; the snippets below assume a fixture that reloads `db` with a tmp `DB_PATH`, as in `tests/test_library.py::fresh_db`):

```python
def _lib_item(tmp_path, name="m.mkv", key="k1"):
    src = tmp_path / name
    src.write_bytes(b"x")
    return {
        "source_path": str(src), "title": "M", "classification": "movies",
        "show_title": None, "season": None, "episode": None, "summary": None,
        "plex_rating_key": key, "show_rating_key": None,
    }


def test_audio_lang_roundtrip(fresh_db, tmp_path):
    import db
    vid, _ = db.upsert_library_video(_lib_item(tmp_path))
    assert db.get_video(vid)["audio_lang"] is None
    db.set_audio_lang(vid, "spa")
    assert db.get_video(vid)["audio_lang"] == "spa"


def test_version_audio_langs_roundtrip(fresh_db, tmp_path):
    import db
    vid, _ = db.upsert_library_video(_lib_item(tmp_path))
    version = db.get_video_versions(vid)[0]
    assert version["audio_langs"] is None
    db.set_version_audio_langs(version["id"], '[{"lang": "eng", "title": ""}]')
    version = db.get_video_versions(vid)[0]
    assert version["audio_langs"] == '[{"lang": "eng", "title": ""}]'


def test_set_library_state_stores_converted_langs(fresh_db, tmp_path):
    import db
    vid, _ = db.upsert_library_video(_lib_item(tmp_path))
    version = db.get_video_versions(vid)[0]
    db.set_library_state(vid, "done", converted_path="/tmp/out.mp4",
                         converted_langs='["eng", "spa"]', version_id=version["id"])
    version = db.get_video_versions(vid)[0]
    assert version["converted_langs"] == '["eng", "spa"]'


def test_set_library_state_error_clears_converted_langs(fresh_db, tmp_path):
    import db
    vid, _ = db.upsert_library_video(_lib_item(tmp_path))
    version = db.get_video_versions(vid)[0]
    db.set_library_state(vid, "done", converted_path="/tmp/out.mp4",
                         converted_langs='["eng"]', version_id=version["id"])
    db.set_library_state(vid, "unconverted", error_msg="boom", version_id=version["id"])
    version = db.get_video_versions(vid)[0]
    assert version["converted_langs"] is None  # cleared together with converted_path
```

If `tests/test_db.py` already defines an equivalent library-item helper, reuse it instead of adding `_lib_item`.

- [ ] **Step 2: Run tests, verify failure**

Run: `python -m pytest tests/test_db.py -k "audio or converted_langs" -v`
Expected: FAIL (`no such column: audio_lang` / `AttributeError: set_audio_lang`)

- [ ] **Step 3: Implement**

In `db.py::init_db`, after the `hls_status` guard (line 92-93):

```python
        if "audio_lang" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN audio_lang TEXT")
```

`video_versions` is created by `CREATE TABLE IF NOT EXISTS`, so existing DBs need column guards. After the `executescript` that creates `video_versions` (line 94-110):

```python
        version_columns = {
            row["name"] for row in conn.execute("PRAGMA table_info(video_versions)").fetchall()
        }
        if "audio_langs" not in version_columns:
            _add_column(conn, "ALTER TABLE video_versions ADD COLUMN audio_langs TEXT")
        if "converted_langs" not in version_columns:
            _add_column(conn, "ALTER TABLE video_versions ADD COLUMN converted_langs TEXT")
```

New accessors after `set_chosen_version` (~line 416):

```python
def set_audio_lang(video_id: int, lang: str) -> None:
    with _conn() as conn:
        conn.execute("UPDATE videos SET audio_lang = ? WHERE id = ?", (lang, video_id))


def set_version_audio_langs(version_id: int, audio_langs_json: str) -> None:
    with _conn() as conn:
        conn.execute(
            "UPDATE video_versions SET audio_langs = ? WHERE id = ?",
            (audio_langs_json, version_id),
        )
```

In `set_library_state`: add parameter `converted_langs: str | None = None` (after `error_msg`), extend the version UPDATE to `converted_langs = COALESCE(?, converted_langs)` with the new value in the params tuple, and in the existing error branch that NULLs `converted_path`, also set `converted_langs = NULL`:

```python
                conn.execute(
                    """
                    UPDATE video_versions
                    SET status = ?,
                        converted_path = COALESCE(?, converted_path),
                        converted_langs = COALESCE(?, converted_langs),
                        error_msg = ?
                    WHERE video_id = ? AND id = ?
                    """,
                    (status, converted_path, converted_langs, error_msg, video_id, version_id),
                )
                if error_msg and status == "unconverted":
                    conn.execute(
                        """
                        UPDATE video_versions
                        SET converted_path = NULL, converted_langs = NULL
                        WHERE video_id = ? AND id = ?
                        """,
                        (video_id, version_id),
                    )
```

Leave the non-library fallback UPDATE at the bottom of `set_library_state` unchanged.

- [ ] **Step 4: Run tests, verify pass**

Run: `python -m pytest tests/test_db.py -v`
Expected: all PASS (new + existing)

- [ ] **Step 5: Commit**

```bash
git add db.py tests/test_db.py
git commit -m "feat(db): audio_lang, audio_langs, converted_langs columns"
```

---

### Task 2: Multi-track conversion planning in library.py

**Files:**
- Modify: `library.py` (`ConversionPlan`, `plan_conversion`, new helpers; lines 16-72)
- Test: `tests/test_library.py`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `library.allowed_audio_langs() -> list[str]` — parses `LIBRARY_AUDIO_LANGS` env (default `"eng,spa"`), lowercased, stripped, empties dropped. Read per-call, not at import.
  - `library.audio_track_list(probe: dict) -> list[dict]` — `[{"lang": <tag or "und">, "title": <tag or "">}, ...]` for every audio stream in stream order.
  - `library.select_audio_indices(probe: dict, langs: list[str]) -> list[int]` — indices *within the audio streams* whose language is in `langs`; falls back to `[0]` when no match but audio exists; `[]` when no audio.
  - `ConversionPlan` gains `audio_maps: list[int]` (selected audio indices) and `audio_langs: list[str]` (their language codes, same order).
  - `plan_conversion(probe, audio_indices: list[int] | None = None)` — `None` means "select via `allowed_audio_langs()`". Audio args are now per-output-stream: `-c:a:0 copy` / `-c:a:1 aac -b:a:1 128k -ac:a:1 2`.

- [ ] **Step 1: Update existing tests + add new ones**

In `tests/test_library.py`, extend the `probe()` helper to support multiple audio tracks (keep the old signature working):

```python
def probe(container="matroska,webm", vcodec="hevc", width=1920, tag="[0][0][0][0]",
          acodec="eac3", with_audio=True, audio=None):
    """audio: optional list of (codec, lang, title) tuples; overrides acodec/with_audio."""
    streams = [{
        "codec_type": "video",
        "codec_name": vcodec,
        "width": width,
        "codec_tag_string": tag,
    }]
    if audio is not None:
        for codec, lang, title in audio:
            streams.append({
                "codec_type": "audio", "codec_name": codec, "channels": 6,
                "tags": {"language": lang, "title": title},
            })
    elif with_audio:
        streams.append({"codec_type": "audio", "codec_name": acodec, "channels": 6})
    return {"streams": streams, "format": {"format_name": container}}
```

Update the two existing assertions to the per-stream arg shape:
- `test_mkv_hevc_remuxes_with_hvc1`: `assert plan.audio_args == ["-c:a:0", "copy"]`
- `test_unsupported_codecs_reencode`: `assert plan.audio_args == ["-c:a:0", "aac", "-b:a:0", "128k", "-ac:a:0", "2"]`

Add new tests:

```python
def multi_probe():
    # Track order mirrors the real MULTI mkv problem: allowlisted langs are not first.
    return probe(audio=[
        ("eac3", "cat", ""),
        ("eac3", "eng", ""),
        ("eac3", "spa", "Latin American"),
        ("dts", "spa", "European"),
    ])


def test_allowed_audio_langs_default(monkeypatch):
    monkeypatch.delenv("LIBRARY_AUDIO_LANGS", raising=False)
    assert library.allowed_audio_langs() == ["eng", "spa"]
    monkeypatch.setenv("LIBRARY_AUDIO_LANGS", " ENG , jpn,")
    assert library.allowed_audio_langs() == ["eng", "jpn"]


def test_audio_track_list():
    assert library.audio_track_list(multi_probe()) == [
        {"lang": "cat", "title": ""},
        {"lang": "eng", "title": ""},
        {"lang": "spa", "title": "Latin American"},
        {"lang": "spa", "title": "European"},
    ]


def test_audio_track_list_untagged():
    assert library.audio_track_list(probe()) == [{"lang": "und", "title": ""}]


def test_select_audio_indices_allowlist():
    assert library.select_audio_indices(multi_probe(), ["eng", "spa"]) == [1, 2, 3]


def test_select_audio_indices_fallback_first():
    assert library.select_audio_indices(multi_probe(), ["jpn"]) == [0]


def test_select_audio_indices_no_audio():
    assert library.select_audio_indices(probe(with_audio=False), ["eng"]) == []


def test_plan_conversion_multi_track(monkeypatch):
    monkeypatch.delenv("LIBRARY_AUDIO_LANGS", raising=False)
    plan = library.plan_conversion(multi_probe())
    assert not plan.passthrough
    assert plan.audio_maps == [1, 2, 3]
    assert plan.audio_langs == ["eng", "spa", "spa"]
    # eac3 tracks copy; the dts track transcodes, per-output-stream args
    assert plan.audio_args == [
        "-c:a:0", "copy",
        "-c:a:1", "copy",
        "-c:a:2", "aac", "-b:a:2", "128k", "-ac:a:2", "2",
    ]


def test_plan_conversion_explicit_indices():
    plan = library.plan_conversion(multi_probe(), audio_indices=[2])
    assert plan.audio_maps == [2]
    assert plan.audio_langs == ["spa"]
    assert plan.audio_args == ["-c:a:0", "copy"]


def test_plan_conversion_no_audio_keeps_an():
    plan = library.plan_conversion(probe(with_audio=False))
    assert plan.audio_maps == []
    assert plan.audio_args == ["-an"]
```

- [ ] **Step 2: Run tests, verify failure**

Run: `python -m pytest tests/test_library.py -v`
Expected: new tests FAIL (`AttributeError: allowed_audio_langs`), the two updated assertions FAIL.

- [ ] **Step 3: Implement in `library.py`**

Replace the audio-related parts (keep `_first_stream` for video; video logic unchanged):

```python
def allowed_audio_langs() -> list[str]:
    """Languages kept in conversions. Read per-call so tests and .env changes apply."""
    raw = os.getenv("LIBRARY_AUDIO_LANGS", "eng,spa")
    return [part.strip().lower() for part in raw.split(",") if part.strip()]


def _audio_streams(probe: dict) -> list[dict]:
    return [s for s in probe.get("streams", []) if s.get("codec_type") == "audio"]


def audio_track_list(probe: dict) -> list[dict]:
    """[{lang, title}] per audio stream, in stream order. Untagged streams -> 'und'."""
    tracks = []
    for stream in _audio_streams(probe):
        tags = stream.get("tags") or {}
        tracks.append({
            "lang": (tags.get("language") or "und").lower(),
            "title": tags.get("title") or "",
        })
    return tracks


def select_audio_indices(probe: dict, langs: list[str]) -> list[int]:
    """Audio-stream indices whose language is allowlisted; first track when none match."""
    streams = _audio_streams(probe)
    if not streams:
        return []
    tracks = audio_track_list(probe)
    selected = [i for i, t in enumerate(tracks) if t["lang"] in langs]
    return selected or [0]
```

`ConversionPlan` gains the new fields:

```python
@dataclass
class ConversionPlan:
    passthrough: bool
    video_args: list[str] = field(default_factory=list)
    audio_args: list[str] = field(default_factory=list)
    audio_maps: list[int] = field(default_factory=list)
    audio_langs: list[str] = field(default_factory=list)
```

`plan_conversion` — compute selection before the passthrough return so every plan carries maps/langs; passthrough gate keeps its existing first-audio compat check:

```python
def plan_conversion(probe: dict, audio_indices: list[int] | None = None) -> ConversionPlan:
    video = _first_stream(probe, "video")
    audio = _first_stream(probe, "audio")
    if not video:
        raise RuntimeError("No video stream found")

    if audio_indices is None:
        audio_indices = select_audio_indices(probe, allowed_audio_langs())
    audio_streams = _audio_streams(probe)
    tracks = audio_track_list(probe)
    audio_langs = [tracks[i]["lang"] for i in audio_indices]

    container = probe.get("format", {}).get("format_name", "")
    is_mp4 = "mp4" in container
    vcodec = video.get("codec_name")
    width = int(video.get("width") or 0)
    fits = width <= IPAD_MAX_WIDTH
    video_compat = vcodec in _COMPAT_VIDEO and fits
    hevc_tagged = vcodec != "hevc" or video.get("codec_tag_string") == "hvc1"
    audio_compat = audio is None or audio.get("codec_name") in _COMPAT_AUDIO

    if is_mp4 and video_compat and hevc_tagged and audio_compat:
        return ConversionPlan(passthrough=True, audio_maps=audio_indices, audio_langs=audio_langs)

    if video_compat:
        tag = "hvc1" if vcodec == "hevc" else "avc1"
        video_args = ["-c:v", "copy", "-tag:v", tag]
    else:
        video_args = list(_REENCODE_VIDEO_ARGS)
        if not fits:
            video_args += _SCALE_ARGS

    if not audio_indices:
        audio_args = ["-an"]
    else:
        audio_args = []
        for out_idx, in_idx in enumerate(audio_indices):
            if audio_streams[in_idx].get("codec_name") in _COMPAT_AUDIO:
                audio_args += [f"-c:a:{out_idx}", "copy"]
            else:
                audio_args += [
                    f"-c:a:{out_idx}", "aac",
                    f"-b:a:{out_idx}", "128k",
                    f"-ac:a:{out_idx}", "2",
                ]

    return ConversionPlan(
        passthrough=False,
        video_args=video_args,
        audio_args=audio_args,
        audio_maps=audio_indices,
        audio_langs=audio_langs,
    )
```

- [ ] **Step 4: Run tests, verify pass**

Run: `python -m pytest tests/test_library.py tests/test_hls.py -v`
Expected: test_library PASS. If test_hls asserts on old `audio_args` shape, update those assertions the same way (`["-c:a:0", "copy"]`).

- [ ] **Step 5: Commit**

```bash
git add library.py tests/test_library.py tests/test_hls.py
git commit -m "feat(library): plan multi-track audio via LIBRARY_AUDIO_LANGS allowlist"
```

---

### Task 3: HLS — chosen-language audio + invalidate helper

**Files:**
- Modify: `hls.py` (`build_ffmpeg_command` line 89-111, `build_hls_package` line 188, `prepare` line 248; new `invalidate`)
- Test: `tests/test_hls.py`

**Interfaces:**
- Consumes: `plan_conversion(probe, audio_indices=...)`, `select_audio_indices`, `audio_track_list` from Task 2.
- Produces:
  - `hls.invalidate(video_id) -> None` — `shutil.rmtree(hls_dir_for(video_id), ignore_errors=True)` then `db.set_hls_status(video_id, "none")`.
  - `build_hls_package(..., audio_lang: str | None = None)` — maps the first audio track matching `audio_lang`; falls back to the first audio track when no match/None.
  - `build_ffmpeg_command(source, out_dir, plan)` — maps from `plan.audio_maps` instead of hardcoded `0:a:0?`.
  - `prepare(video_id, source_path)` reads `db.get_video(video_id)["audio_lang"]` and passes it through.

- [ ] **Step 1: Write failing tests**

Open `tests/test_hls.py` first and mirror its existing fake-probe/fake-ffmpeg style. Add:

```python
def test_build_command_maps_selected_audio(tmp_path):
    plan = library.ConversionPlan(
        passthrough=False,
        video_args=["-c:v", "copy", "-tag:v", "avc1"],
        audio_args=["-c:a:0", "copy"],
        audio_maps=[2],
        audio_langs=["spa"],
    )
    cmd = hls.build_ffmpeg_command(Path("in.mp4"), tmp_path, plan)
    assert ["-map", "0:v:0", "-map", "0:a:2"] == cmd[cmd.index("-map"):cmd.index("-map") + 4]


def test_build_command_no_audio(tmp_path):
    plan = library.ConversionPlan(passthrough=False, video_args=["-c:v", "copy"],
                                  audio_args=["-an"], audio_maps=[], audio_langs=[])
    cmd = hls.build_ffmpeg_command(Path("in.mp4"), tmp_path, plan)
    assert "0:a:0?" not in cmd and cmd.count("-map") == 1


def test_build_package_selects_audio_lang(tmp_path, monkeypatch):
    # multi-audio probe: cat first, spa second
    probe = {
        "streams": [
            {"codec_type": "video", "codec_name": "h264", "width": 1920},
            {"codec_type": "audio", "codec_name": "eac3", "tags": {"language": "cat"}},
            {"codec_type": "audio", "codec_name": "eac3", "tags": {"language": "spa"}},
        ],
        "format": {"format_name": "mov,mp4,m4a,3gp,3g2,mj2", "duration": "10"},
    }
    commands = []
    hls.build_hls_package(1, tmp_path / "in.mp4", output_root=tmp_path / "out",
                          probe=probe, subtitles=[], run_ffmpeg=commands.append,
                          audio_lang="spa")
    cmd = commands[0]
    assert "0:a:1" in cmd  # second audio stream, not the first


@pytest.fixture()
def fresh_db(monkeypatch, tmp_path):
    # If tests/test_hls.py already has a DB fixture, reuse it and skip this one.
    import importlib
    monkeypatch.setenv("DB_PATH", str(tmp_path / "test.db"))
    import db
    importlib.reload(db)
    db.init_db()
    yield


def test_invalidate_removes_dir_and_resets_status(fresh_db, tmp_path, monkeypatch):
    import db
    vid = db.add_video("http://x")
    db.set_hls_status(vid, "done")
    monkeypatch.setattr(hls, "HLS_DIR", tmp_path)
    d = tmp_path / str(vid)
    d.mkdir()
    (d / "master.m3u8").write_text("x")
    hls.invalidate(vid)
    assert not d.exists()
    assert db.get_video(vid)["hls_status"] == "none"
```

(`hls.invalidate` must call `hls_dir_for(video_id)` — which reads the module-level `HLS_DIR` at call time — so the `monkeypatch.setattr(hls, "HLS_DIR", tmp_path)` above works. `hls.py`'s reloaded `db` reference: `invalidate` calls `db.set_hls_status` through the module attribute, and the fixture reloads `db` in place, so the same module object is updated — matching how existing tests in this file handle it.)

- [ ] **Step 2: Run tests, verify failure**

Run: `python -m pytest tests/test_hls.py -v`
Expected: new tests FAIL.

- [ ] **Step 3: Implement in `hls.py`**

Add `import shutil` at the top. New helper:

```python
def invalidate(video_id) -> None:
    """Drop the packaged HLS output so the next play repackages from the
    current converted file / audio choice."""
    shutil.rmtree(hls_dir_for(video_id), ignore_errors=True)
    db.set_hls_status(video_id, "none")
```

`build_ffmpeg_command`: replace the hardcoded maps:

```python
def build_ffmpeg_command(source: Path, out_dir: Path, plan) -> list[str]:
    """Construct the fMP4 HLS ffmpeg command for a conversion ``plan``.

    Passthrough sources use a global ``-c copy``; otherwise the per-stream
    args from ``plan_conversion`` (which transcode only incompatible streams).
    Audio maps come from the plan — at most one track for HLS output.
    """
    if plan.passthrough:
        codec_args = ["-c", "copy"]
    else:
        codec_args = [*plan.video_args, *plan.audio_args]
    map_args = ["-map", "0:v:0"]
    for idx in plan.audio_maps:
        map_args += ["-map", f"0:a:{idx}"]
    return [
        FFMPEG_BIN, "-hide_banner", "-loglevel", "error", "-y",
        "-i", str(source),
        *map_args,
        *codec_args,
        "-f", "hls",
        "-hls_playlist_type", "vod",
        "-hls_time", str(HLS_TIME),
        "-hls_segment_type", "fmp4",
        "-hls_fmp4_init_filename", "init.mp4",
        "-hls_segment_filename", str(out_dir / "segment_%05d.m4s"),
        str(out_dir / "video.m3u8"),
    ]
```

`build_hls_package` signature gains `audio_lang: str | None = None`; after probing, compute the single-track selection and pass it to `plan_conversion`:

```python
    from library import audio_track_list, plan_conversion, probe_source, select_audio_indices
    # (adjust the existing module-level import at the top of hls.py instead of a local import)

    probe = probe if probe is not None else probe_source(source)
    audio_indices: list[int] | None = None
    if audio_lang:
        tracks = audio_track_list(probe)
        match = next((i for i, t in enumerate(tracks) if t["lang"] == audio_lang), None)
        audio_indices = [match] if match is not None else None
    if audio_indices is None:
        tracks = audio_track_list(probe)
        audio_indices = [0] if tracks else []
    plan = plan_conversion(probe, audio_indices=audio_indices)
```

(The fallback keeps today's behavior — first audio track — for videos with no choice; the HLS package always carries at most one audio track.)

`prepare`: look up the choice:

```python
def prepare(video_id: int, source_path) -> None:
    try:
        video = db.get_video(video_id)
        audio_lang = video.get("audio_lang") if video else None
        build_hls_package(video_id, source_path, audio_lang=audio_lang)
        db.set_hls_status(video_id, "done")
    except Exception:  # noqa: BLE001 - background task, must not raise
        traceback.print_exc()
        db.set_hls_status(video_id, "none")
```

- [ ] **Step 4: Run tests, verify pass**

Run: `python -m pytest tests/test_hls.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add hls.py tests/test_hls.py
git commit -m "feat(hls): package chosen audio language, add invalidate helper"
```

---

### Task 4: Conversion writes all allowlisted tracks + converted_langs

**Files:**
- Modify: `library.py` (`convert_library_video`, lines 97-139)
- Test: `tests/test_library.py`

**Interfaces:**
- Consumes: `plan.audio_maps` / `plan.audio_langs` (Task 2), `db.set_library_state(converted_langs=...)` (Task 1), `hls.invalidate` (Task 3).
- Produces: converted mp4 containing every allowlisted audio track; version row's `converted_langs` set on success (JSON list of lang codes); HLS package invalidated after the file is replaced. Passthrough stores *all* source langs (the original file is served as-is).

- [ ] **Step 1: Write failing tests**

Add to `tests/test_library.py` (reuses `fresh_db`, `lib_row`, `multi_probe` from Tasks above):

```python
def test_convert_maps_allowlisted_tracks_and_records_langs(fresh_db, tmp_path, monkeypatch):
    import db
    monkeypatch.delenv("LIBRARY_AUDIO_LANGS", raising=False)
    vid, src = lib_row(tmp_path)
    monkeypatch.setattr(library, "probe_source", lambda p: multi_probe())
    calls = []

    def fake_run(cmd):
        calls.append(cmd)
        Path(cmd[-1]).write_bytes(b"converted")

    monkeypatch.setattr(library, "_run_ffmpeg", fake_run)
    invalidated = []
    import hls
    monkeypatch.setattr(hls, "invalidate", invalidated.append)
    library.convert_library_video(vid)

    cmd = calls[0]
    maps = [cmd[i + 1] for i, a in enumerate(cmd) if a == "-map"]
    assert maps == ["0:v:0", "0:a:1", "0:a:2", "0:a:3"]  # eng + both spa, not cat
    version = db.get_video_versions(vid)[0]
    assert version["converted_langs"] == '["eng", "spa", "spa"]'
    assert invalidated == [vid]


def test_convert_passthrough_records_all_source_langs(fresh_db, tmp_path, monkeypatch):
    import db
    vid, src = lib_row(tmp_path, "ep.mp4")
    monkeypatch.setattr(library, "probe_source", lambda p: probe(
        container="mov,mp4,m4a,3gp,3g2,mj2", vcodec="h264",
        audio=[("aac", "cat", ""), ("aac", "eng", "")]))
    library.convert_library_video(vid)
    version = db.get_video_versions(vid)[0]
    assert version["status"] == "done"
    assert version["converted_langs"] == '["cat", "eng"]'
```

- [ ] **Step 2: Run tests, verify failure**

Run: `python -m pytest tests/test_library.py -k convert -v`
Expected: new tests FAIL (maps still `0:a:0?`, converted_langs None).

- [ ] **Step 3: Implement**

In `convert_library_video`:

```python
        probe = probe_source(source)
        plan = plan_conversion(probe)
        if plan.passthrough:
            db.set_library_state(
                video_id, "done",
                converted_langs=json.dumps([t["lang"] for t in audio_track_list(probe)]),
                version_id=version["id"],
            )
            return

        target = conversion_target(source)
        tmp = target.with_name("." + target.name)
        map_args = ["-map", "0:v:0"]
        for idx in plan.audio_maps:
            map_args += ["-map", f"0:a:{idx}"]
        cmd = [
            FFMPEG_BIN, "-hide_banner", "-loglevel", "error", "-y",
            "-i", str(source),
            *map_args, "-sn", "-dn",
            *plan.video_args, *plan.audio_args,
            "-movflags", "+faststart",
            str(tmp),
        ]
        _run_ffmpeg(cmd)
        os.replace(tmp, target)
        db.set_library_state(
            video_id, "done",
            converted_path=str(target),
            converted_langs=json.dumps(plan.audio_langs),
            version_id=version["id"],
        )
        # The streamable file changed; any packaged HLS output is stale.
        # Function-level import: hls imports library at module load, so a
        # top-level import here would be circular.
        import hls
        hls.invalidate(video_id)
```

Add `import json` to `library.py`'s imports.

- [ ] **Step 4: Run tests, verify pass**

Run: `python -m pytest tests/test_library.py -v`
Expected: PASS (the pre-existing `test_convert_runs_ffmpeg_and_records_sibling` uses a single-eac3 untagged probe → selection falls back to `[0]`, command shape still matches its assertions).

- [ ] **Step 5: Commit**

```bash
git add library.py tests/test_library.py
git commit -m "feat(library): convert all allowlisted audio tracks, record converted_langs"
```

---

### Task 5: Scan probes missing audio track lists

**Files:**
- Modify: `library.py` (`scan_library`, lines 162-207; new `_probe_missing_audio_langs`)
- Test: `tests/test_library.py`

**Interfaces:**
- Consumes: `db.set_version_audio_langs` (Task 1), `audio_track_list` (Task 2), `probe_source`.
- Produces: after every scan, each surviving version row has `audio_langs` populated (unless its probe failed — retried next scan). Incremental: rows with non-NULL `audio_langs` are never re-probed.

- [ ] **Step 1: Write failing tests**

```python
def test_scan_probes_missing_audio_langs(fresh_db, tmp_path, monkeypatch):
    import db
    import plex
    src = tmp_path / "a.mkv"
    src.write_bytes(b"x")
    item = {"source_path": str(src), "title": "a", "classification": "movies",
            "show_title": None, "season": None, "episode": None, "summary": None,
            "plex_rating_key": "a", "show_rating_key": None}
    monkeypatch.setattr(plex, "fetch_library_items", lambda: [item])
    probes = []

    def fake_probe(path):
        probes.append(str(path))
        return multi_probe()

    monkeypatch.setattr(library, "probe_source", fake_probe)
    library.scan_library()
    movie = db.get_all_videos("movies")[0]
    version = db.get_video_versions(movie["id"])[0]
    import json
    assert [t["lang"] for t in json.loads(version["audio_langs"])] == ["cat", "eng", "spa", "spa"]
    assert probes == [str(src)]

    library.scan_library()  # second scan: already probed, no new ffprobe call
    assert probes == [str(src)]


def test_scan_survives_probe_failure(fresh_db, tmp_path, monkeypatch):
    import db
    import plex
    src = tmp_path / "a.mkv"
    src.write_bytes(b"x")
    item = {"source_path": str(src), "title": "a", "classification": "movies",
            "show_title": None, "season": None, "episode": None, "summary": None,
            "plex_rating_key": "a", "show_rating_key": None}
    monkeypatch.setattr(plex, "fetch_library_items", lambda: [item])

    def boom(path):
        raise RuntimeError("ffprobe missing")

    monkeypatch.setattr(library, "probe_source", boom)
    result = library.scan_library()
    assert result["added"] == 1  # scan not aborted
    movie = db.get_all_videos("movies")[0]
    assert db.get_video_versions(movie["id"])[0]["audio_langs"] is None  # retried next scan
```

- [ ] **Step 2: Run tests, verify failure**

Run: `python -m pytest tests/test_library.py -k scan -v`
Expected: new tests FAIL.

- [ ] **Step 3: Implement**

New helper in `library.py`:

```python
def _probe_missing_audio_langs(video_id: int) -> None:
    """Fill audio_langs for versions that were never probed. Failures skip the
    version (left NULL, retried next scan) and never abort the scan."""
    for version in db.get_video_versions(video_id):
        if version.get("audio_langs") is not None:
            continue
        try:
            probe = probe_source(Path(version["source_path"]))
        except Exception:  # noqa: BLE001 - scan must survive a bad file
            continue
        db.set_version_audio_langs(version["id"], json.dumps(audio_track_list(probe)))
```

In `scan_library`, after the upsert result handling (only for live rows):

```python
        video_id, status = db.upsert_library_video(item)
        if status == "created":
            added += 1
        elif status == "updated":
            updated += 1
        else:  # tombstoned
            skipped += 1
            continue
        _probe_missing_audio_langs(video_id)
```

(Note the existing code unpacks as `_, status` — rename to `video_id, status` and add the `continue` on the tombstoned branch.)

- [ ] **Step 4: Run tests, verify pass**

Run: `python -m pytest tests/test_library.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add library.py tests/test_library.py
git commit -m "feat(library): scan backfills per-version audio track lists"
```

---

### Task 6: Serializer exposes audio_lang + audio_tracks

**Files:**
- Modify: `views/serializers.py`
- Test: `tests/test_serializers.py`

**Interfaces:**
- Consumes: version dict keys `audio_langs`, `converted_langs` (Task 1); `library.allowed_audio_langs` (Task 2).
- Produces: for library rows, `data["audio_lang"]` (may be None) and each serialized version gains `"audio_tracks": [{"lang", "title", "available"}]` — source tracks ∩ allowlist, deduped by lang (first occurrence's title wins). `available` is True when the lang appears in `converted_langs`; when `converted_langs` is NULL (pre-feature conversion), only the source's first track counts as available.

- [ ] **Step 1: Write failing tests**

Open `tests/test_serializers.py` and mirror its row-dict style. Add:

```python
def _library_video(**over):
    video = {
        "id": 1, "url": "/x/y.mkv", "status": "done", "source": "library",
        "classification": "movies", "chosen_version_id": 10, "audio_lang": "spa",
        "versions": [{
            "id": 10, "label": "1080p", "status": "done", "is_chosen": True,
            "audio_langs": (
                '[{"lang": "cat", "title": ""}, {"lang": "eng", "title": ""},'
                ' {"lang": "spa", "title": "Latin American"}, {"lang": "spa", "title": "European"}]'
            ),
            "converted_langs": '["eng", "spa", "spa"]',
        }],
    }
    video.update(over)
    return video


def test_serialize_audio_tracks(monkeypatch):
    monkeypatch.delenv("LIBRARY_AUDIO_LANGS", raising=False)
    data = serialize_video(_library_video())
    assert data["audio_lang"] == "spa"
    assert data["versions"][0]["audio_tracks"] == [
        {"lang": "eng", "title": "", "available": True},
        {"lang": "spa", "title": "Latin American", "available": True},
    ]


def test_serialize_audio_tracks_legacy_conversion(monkeypatch):
    """NULL converted_langs = pre-feature file: only the first source track is present."""
    monkeypatch.delenv("LIBRARY_AUDIO_LANGS", raising=False)
    video = _library_video()
    video["versions"][0]["converted_langs"] = None
    data = serialize_video(video)
    assert data["versions"][0]["audio_tracks"] == [
        {"lang": "eng", "title": "", "available": False},
        {"lang": "spa", "title": "Latin American", "available": False},
    ]


def test_serialize_audio_tracks_unprobed(monkeypatch):
    video = _library_video()
    video["versions"][0]["audio_langs"] = None
    data = serialize_video(video)
    assert data["versions"][0]["audio_tracks"] == []
    assert data["audio_lang"] == "spa"
```

(In the legacy test the source's first track is `cat`, which is not allowlisted, so nothing is available — matching reality: the pre-feature Lilo & Stitch conversion is Catalan.)

- [ ] **Step 2: Run tests, verify failure**

Run: `python -m pytest tests/test_serializers.py -v`
Expected: new tests FAIL (KeyError `audio_tracks`).

- [ ] **Step 3: Implement in `views/serializers.py`**

Add imports at top:

```python
import json

from library import allowed_audio_langs
```

Helper + wiring:

```python
def _audio_tracks(version: dict) -> list[dict]:
    """Selector entries for one version: source tracks ∩ allowlist, deduped by
    lang. `available` = present in the converted file; NULL converted_langs
    means a pre-feature single-track conversion (first source track only)."""
    try:
        source_tracks = json.loads(version.get("audio_langs") or "[]")
    except (TypeError, ValueError):
        return []
    converted = None
    if version.get("converted_langs"):
        try:
            converted = json.loads(version["converted_langs"])
        except (TypeError, ValueError):
            converted = None
    allowed = allowed_audio_langs()
    first_lang = source_tracks[0]["lang"] if source_tracks else None
    tracks, seen = [], set()
    for track in source_tracks:
        lang = track.get("lang")
        if lang not in allowed or lang in seen:
            continue
        seen.add(lang)
        if converted is not None:
            available = lang in converted
        else:
            available = lang == first_lang
        tracks.append({"lang": lang, "title": track.get("title") or "", "available": available})
    return tracks
```

In `serialize_video`, inside the `if video.get("versions") is not None:` block:

```python
        data["chosen_version_id"] = video.get("chosen_version_id")
        data["audio_lang"] = video.get("audio_lang")
        data["versions"] = [
            {
                "id": version["id"],
                "label": version.get("label"),
                "status": version["status"],
                "is_chosen": bool(version.get("is_chosen")),
                "audio_tracks": _audio_tracks(version),
            }
            for version in video.get("versions", [])
        ]
```

- [ ] **Step 4: Run tests, verify pass**

Run: `python -m pytest tests/test_serializers.py tests/test_api.py -v`
Expected: PASS (test_api exercises `/api/videos`; if it asserts exact version-dict keys, add `audio_tracks` there).

- [ ] **Step 5: Commit**

```bash
git add views/serializers.py tests/test_serializers.py
git commit -m "feat(api): serialize audio_lang and per-version audio_tracks"
```

---

### Task 7: POST /api/videos/{id}/audio endpoint

**Files:**
- Modify: `router.py` (request model near line 104; endpoint after `api_choose_video_version` ~line 633)
- Test: `tests/test_api.py`

**Interfaces:**
- Consumes: `db.set_audio_lang`, `db.get_video_version` (audio_langs/converted_langs keys), `hls.invalidate`, `library.allowed_audio_langs`, `library.convert_library_video`, `db.set_library_state`.
- Produces: `POST /api/videos/{video_id}/audio` body `{"lang": "spa"}` → `{"ok": true}`. 401/403 per existing `_check_token` behavior, 404 unknown/deleted video or no version, 400 non-library video or lang not in source∩allowlist. When the chosen version is `done` but the lang is missing from its converted file, flips the version to `converting` and schedules `library.convert_library_video`.

- [ ] **Step 1: Write failing tests**

Open `tests/test_api.py` and copy its `client` fixture pattern (env vars set, `db` and app modules reloaded — note the module list now includes `router`; follow whatever the file already reloads) and its existing library-row seeding helpers. Add:

```python
def _seed_multi_audio_movie(tmp_path, converted_langs='["eng", "spa"]', status="done"):
    import db
    src = tmp_path / "m.mkv"
    src.write_bytes(b"x")
    vid, _ = db.upsert_library_video({
        "source_path": str(src), "title": "M", "classification": "movies",
        "show_title": None, "season": None, "episode": None, "summary": None,
        "plex_rating_key": "m1", "show_rating_key": None,
    })
    version = db.get_video_versions(vid)[0]
    db.set_version_audio_langs(version["id"], json.dumps([
        {"lang": "cat", "title": ""}, {"lang": "eng", "title": ""},
        {"lang": "spa", "title": ""},
    ]))
    db.set_library_state(vid, status, converted_path=str(tmp_path / "m.mp4"),
                         converted_langs=converted_langs, version_id=version["id"])
    return vid, version["id"]


def test_choose_audio_requires_token(client, tmp_path):
    vid, _ = _seed_multi_audio_movie(tmp_path)
    resp = client.post(f"/api/videos/{vid}/audio", json={"lang": "spa"})
    assert resp.status_code in (401, 403)


def test_choose_audio_sets_lang(client, tmp_path, auth_headers):
    import db
    vid, _ = _seed_multi_audio_movie(tmp_path)
    resp = client.post(f"/api/videos/{vid}/audio", json={"lang": "spa"}, headers=auth_headers)
    assert resp.status_code == 200 and resp.json() == {"ok": True}
    assert db.get_video(vid)["audio_lang"] == "spa"
    # still done: spa is already in the converted file
    assert db.get_video(vid)["status"] == "done"


def test_choose_audio_rejects_unknown_lang(client, tmp_path, auth_headers):
    vid, _ = _seed_multi_audio_movie(tmp_path)
    assert client.post(f"/api/videos/{vid}/audio", json={"lang": "jpn"},
                       headers=auth_headers).status_code == 400
    # cat is in the source but not the allowlist
    assert client.post(f"/api/videos/{vid}/audio", json={"lang": "cat"},
                       headers=auth_headers).status_code == 400


def test_choose_audio_triggers_reconvert_when_missing(client, tmp_path, auth_headers, monkeypatch):
    import db
    import library
    vid, _ = _seed_multi_audio_movie(tmp_path, converted_langs='["cat"]')
    converted = []
    monkeypatch.setattr(library, "convert_library_video", converted.append)
    resp = client.post(f"/api/videos/{vid}/audio", json={"lang": "spa"}, headers=auth_headers)
    assert resp.status_code == 200
    assert db.get_video(vid)["status"] == "converting"
    assert converted == [vid]


def test_choose_audio_legacy_null_converted_langs_reconverts(client, tmp_path, auth_headers, monkeypatch):
    import db
    import library
    vid, _ = _seed_multi_audio_movie(tmp_path, converted_langs=None)
    monkeypatch.setattr(library, "convert_library_video", lambda vid: None)
    client.post(f"/api/videos/{vid}/audio", json={"lang": "spa"}, headers=auth_headers)
    assert db.get_video(vid)["status"] == "converting"
```

(If the file has no `auth_headers` fixture, build headers inline the way its other token-gated tests do. `monkeypatch.setattr(library, ...)` must target the module object the reloaded `router` actually holds — follow how existing tests patch `library`/`downloader`.)

- [ ] **Step 2: Run tests, verify failure**

Run: `python -m pytest tests/test_api.py -k choose_audio -v`
Expected: FAIL with 404 (endpoint missing).

- [ ] **Step 3: Implement in `router.py`**

Request model next to `VersionRequest` (~line 104):

```python
class AudioRequest(BaseModel):
    lang: str
```

Endpoint after `api_choose_video_version`:

```python
@router.post("/api/videos/{video_id}/audio")
async def api_choose_audio(
    video_id: int, body: AudioRequest, request: Request, background_tasks: BackgroundTasks
):
    _check_token(request)
    video = db.get_video(video_id)
    if not video or video.get("deleted_at"):
        raise HTTPException(status_code=404, detail="Video not found")
    if video.get("source") != "library":
        raise HTTPException(status_code=400, detail="Only library videos have audio tracks")
    version = db.get_video_version(video_id)
    if not version:
        raise HTTPException(status_code=404, detail="Version not found")

    try:
        source_langs = {t["lang"] for t in json.loads(version.get("audio_langs") or "[]")}
    except (TypeError, ValueError):
        source_langs = set()
    if body.lang not in library.allowed_audio_langs() or body.lang not in source_langs:
        raise HTTPException(status_code=400, detail="Language not available")

    db.set_audio_lang(video_id, body.lang)
    # The packaged HLS output carries a single audio track; the choice changed.
    hls.invalidate(video_id)

    converted = None
    if version.get("converted_langs"):
        try:
            converted = json.loads(version["converted_langs"])
        except (TypeError, ValueError):
            converted = None
    if version["status"] == "done" and (converted is None or body.lang not in converted):
        # Converted file lacks this language: re-convert from source with the
        # current allowlist. NULL converted_langs = pre-feature single-track file.
        db.set_library_state(video_id, "converting", version_id=version["id"])
        background_tasks.add_task(library.convert_library_video, video_id)
    return {"ok": True}
```

`router.py` already imports `db`, `hls`, `library`; confirm `json` is imported (add if missing).

- [ ] **Step 4: Run tests, verify pass**

Run: `python -m pytest tests/test_api.py -v`
Expected: PASS.

- [ ] **Step 5: Run the whole backend suite**

Run: `python -m pytest tests/`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add router.py tests/test_api.py
git commit -m "feat(api): POST /api/videos/{id}/audio chooses language, re-converts if missing"
```

---

### Task 8: iOS models, API client, store, cache eviction (PatataTubeKit)

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/Video.swift`
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/APIClient.swift`
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/VideoStore.swift`
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift`

**Interfaces:**
- Consumes: API JSON from Tasks 6-7 (snake_case; decoder uses `.convertFromSnakeCase`, so `audio_lang` → `audioLang`, `audio_tracks` → `audioTracks`).
- Produces:
  - `public struct AudioTrack: Codable, Equatable, Hashable, Sendable { let lang: String; let title: String; let available: Bool }`
  - `VideoVersion.audioTracks: [AudioTrack]` (missing key decodes to `[]`)
  - `Video.audioLang: String?` and `Video.withAudioLang(_:) -> Video`
  - `VideoAPI.chooseAudio(id: Int, lang: String) async throws -> Bool` (+ `APIClient` impl)
  - `VideoStore.chooseAudio(id: Int, lang: String) async` — optimistic, reloads on success
  - `CacheManager.removeCached(id: Int, versionId: Int? = nil)`

- [ ] **Step 1: Extend Video.swift**

New type above `VideoVersion`:

```swift
public struct AudioTrack: Codable, Equatable, Hashable, Sendable {
    public let lang: String
    public let title: String
    public let available: Bool

    public init(lang: String, title: String, available: Bool) {
        self.lang = lang; self.title = title; self.available = available
    }
}
```

`VideoVersion` gains the field with a lenient decode (synthesized decoding would fail on old cached lists, and `VideoListCache` replays stored JSON):

```swift
public struct VideoVersion: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: Int
    public let label: String?
    public let status: String
    public let isChosen: Bool
    public let audioTracks: [AudioTrack]

    public init(id: Int, label: String?, status: String, isChosen: Bool,
                audioTracks: [AudioTrack] = []) {
        self.id = id
        self.label = label
        self.status = status
        self.isChosen = isChosen
        self.audioTracks = audioTracks
    }

    enum CodingKeys: String, CodingKey { case id, label, status, isChosen, audioTracks }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(Int.self, forKey: .id)
        self.label = try c.decodeIfPresent(String.self, forKey: .label)
        self.status = try c.decode(String.self, forKey: .status)
        self.isChosen = try c.decode(Bool.self, forKey: .isChosen)
        self.audioTracks = try c.decodeIfPresent([AudioTrack].self, forKey: .audioTracks) ?? []
    }
}
```

`Video`: add `public let audioLang: String?`; add `audioLang` to `CodingKeys`, to the memberwise `init` (defaulted `audioLang: String? = nil`), and `self.audioLang = try c.decodeIfPresent(String.self, forKey: .audioLang)` in `init(from:)`. Thread `audioLang: audioLang` through `withClassification` and `withChosenVersion` (in `withChosenVersion`'s versions.map, pass `audioTracks: $0.audioTracks` to the rebuilt `VideoVersion`). Add:

```swift
    func withAudioLang(_ lang: String) -> Video {
        return Video(id: id, url: url, title: title, platform: platform, sourceKey: sourceKey,
              previewUrl: previewUrl, classification: classification, position: position,
              status: status, errorMsg: errorMsg, streamPath: streamPath,
              source: source, showTitle: showTitle, season: season,
              episode: episode, summary: summary, showPreviewUrl: showPreviewUrl,
              chosenVersionId: chosenVersionId, versions: versions,
              hlsPath: hlsPath, subtitleTracks: subtitleTracks,
              sourceFilename: sourceFilename, audioLang: lang)
    }
```

(Put `audioLang` last in the memberwise init parameter list so existing call sites keep compiling.)

- [ ] **Step 2: APIClient + protocol**

In `VideoAPI` protocol, after `chooseVersion`:

```swift
    func chooseAudio(id: Int, lang: String) async throws -> Bool
```

In `APIClient`, after `chooseVersion`:

```swift
    public func chooseAudio(id: Int, lang: String) async throws -> Bool {
        try await postOK("api/videos/\(id)/audio", body: ["lang": lang])
    }
```

Search the package and app for other `VideoAPI` conformers (e.g. mocks/fakes) and add a stub `chooseAudio` to each so everything compiles.

- [ ] **Step 3: VideoStore**

After `chooseVersion`:

```swift
    /// Optimistically records the chosen audio language, then reloads so a
    /// server-triggered re-conversion ("converting" status) shows up.
    public func chooseAudio(id: Int, lang: String) async {
        guard let index = videos.firstIndex(where: { $0.id == id }) else { return }
        let previous = videos[index]
        videos[index] = videos[index].withAudioLang(lang)
        do {
            let ok = try await api.chooseAudio(id: id, lang: lang)
            if ok {
                await load()
            } else {
                videos[index] = previous
            }
        } catch {
            videos[index] = previous
            errorText = String(describing: error)
        }
    }
```

- [ ] **Step 4: CacheManager**

After `cancel`:

```swift
    /// Deletes a cached MP4. Used when the server re-converts a file with a
    /// different audio track set, making the cached copy stale.
    public func removeCached(id: Int, versionId: Int? = nil) {
        try? fileManager.removeItem(at: localURL(for: id, versionId: versionId))
    }
```

- [ ] **Step 5: Build**

Run: `cd ios/PatataTubeKit && swift build`
Expected: succeeds with no errors.

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTubeKit
git commit -m "feat(ios): audio track model, chooseAudio API/store, cache eviction"
```

---

### Task 9: Audio picker in MovieDetailView

**Files:**
- Modify: `ios/PatataTube/Sources/MovieDetailView.swift`

**Interfaces:**
- Consumes: `VideoVersion.audioTracks`, `Video.audioLang`, `store.chooseAudio(id:lang:)`, `model.cache.removeCached(id:versionId:)` (Task 8).
- Produces: an "Audio" menu picker in the detail action row, visible when the chosen version has ≥ 2 audio tracks.

- [ ] **Step 1: Implement**

Add a computed property near `currentVideo`:

```swift
    private var chosenVersion: VideoVersion? {
        currentVideo.versions.first { $0.isChosen } ?? currentVideo.versions.first
    }
```

In the `HStack(spacing: 16)`, after the existing Version picker `if` block and before `Spacer()`:

```swift
                    let audioTracks = chosenVersion?.audioTracks ?? []
                    if audioTracks.count > 1 {
                        Picker("Audio", selection: Binding(
                            get: { currentVideo.audioLang ?? audioTracks.first?.lang ?? "" },
                            set: { lang in
                                guard lang != currentVideo.audioLang else { return }
                                if audioTracks.first(where: { $0.lang == lang })?.available == false {
                                    // Server will re-convert; the cached MP4 is about to go stale.
                                    model.cache.removeCached(id: currentVideo.id,
                                                             versionId: currentVideo.chosenVersionId)
                                }
                                Task { await store.chooseAudio(id: currentVideo.id, lang: lang) }
                            }
                        )) {
                            ForEach(audioTracks, id: \.lang) { track in
                                Text(audioLabel(for: track)).tag(track.lang)
                            }
                        }
                        .pickerStyle(.menu)
                    }
```

Helper next to `pollCacheState`:

```swift
    /// "spa" → "Spanish"; the source's title tag disambiguates when present.
    private func audioLabel(for track: AudioTrack) -> String {
        let name = Locale.current.localizedString(forLanguageCode: track.lang) ?? track.lang
        return track.title.isEmpty ? name : "\(name) — \(track.title)"
    }
```

Also reset the download UI when the language flips a re-conversion, mirroring the existing version-change reset — extend the existing `.onChange(of: currentVideo.chosenVersionId)` with a sibling:

```swift
        .onChange(of: currentVideo.audioLang) { _, _ in
            activeDownloadID = nil
            downloadPhase = .idle
            observedCacheState = nil
            progress = 0
        }
```

- [ ] **Step 2: Build the app project**

Run: `cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO`
Expected: build succeeds. (If the scheme name differs, list with `xcodebuild -list -project PatataTube.xcodeproj`.)

- [ ] **Step 3: Commit**

```bash
git add ios/PatataTube
git commit -m "feat(ios): audio language picker in movie detail view"
```

---

### Task 10: Apply the language at playback

**Files:**
- Modify: `ios/PatataTube/Sources/VideoPlayerView.swift`

**Interfaces:**
- Consumes: `Video.audioLang`.
- Produces: mp4 playback (cached file or direct stream) starts on the chosen language when the asset carries it. HLS needs nothing here — the server packages only the chosen track.

- [ ] **Step 1: Implement**

Add to `VideoPlayerView`:

```swift
    /// Selects the audible option matching the server-side language choice.
    /// mp4 assets carry every allowlisted track; HLS already serves only the
    /// chosen one. No match (or no selection group) leaves the default track.
    private func applyAudioSelection(item: AVPlayerItem, lang: String?) async {
        guard let lang,
              let group = try? await item.asset.loadMediaSelectionGroup(for: .audible) else { return }
        let target = normalizedLanguage(lang)
        guard let option = group.options.first(where: { option in
            guard let tag = option.extendedLanguageTag ?? option.locale?.identifier else { return false }
            return normalizedLanguage(tag) == target
        }) else { return }
        item.select(option, in: group)
    }

    /// "spa" (server, ISO 639-2) and "es-419" (asset, BCP-47) both → "es".
    private func normalizedLanguage(_ code: String) -> String {
        let base = code.split(separator: "-").first.map(String.init) ?? code.lowercased()
        return Locale.LanguageCode(base).identifier(.alpha2) ?? base.lowercased()
    }
```

In `setup()`, after `self.player = player`:

```swift
        Task { await applyAudioSelection(item: item, lang: video.audioLang) }
```

In `advance(by:)`, after `player.replaceCurrentItem(with: item)`:

```swift
        Task { await applyAudioSelection(item: item, lang: videos[nextIndex].audioLang) }
```

(`Locale.LanguageCode.identifier(.alpha2)` requires iOS 16 — the app already uses iOS 16+ APIs; if the deployment target complains, replace `normalizedLanguage` with a `["spa": "es", "eng": "en"]`-style lookup built from `Locale.LanguageCode.isoLanguageCodes`.)

- [ ] **Step 2: Build**

Run: `cd ios/PatataTube && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add ios/PatataTube
git commit -m "feat(ios): start playback on the chosen audio language"
```

---

### Task 11: Docs, env example, full verification

**Files:**
- Modify: `.env.example`
- Modify: `ios/README.md` (manual test checklist)
- Modify: `CLAUDE.md` (Plex library section)

**Interfaces:** none — documentation + final verification.

- [ ] **Step 1: .env.example**

Add:

```
# Audio languages kept in library conversions (ISO 639-2 codes, comma-separated)
LIBRARY_AUDIO_LANGS=eng,spa
```

- [ ] **Step 2: ios/README.md manual checklist additions**

Append to the existing checklist:

```markdown
### Audio language selector (library movies)
- [ ] Open a MULTI movie's detail page: an "Audio" picker appears next to the
      Version picker, listing English/Spanish with source title tags.
- [ ] Single-audio movies show no Audio picker.
- [ ] Pick a language already in the converted file: play starts on that
      language immediately (no conversion).
- [ ] Pick a language missing from an old (pre-feature) conversion: status
      flips to "converting"; when done, playback uses the new language and the
      cached copy re-downloads.
- [ ] Cache a movie, go offline: cached playback still honors the picker
      choice (tracks are embedded in the MP4).
- [ ] While streaming (HLS), switching language repackages: next play carries
      the new language.
```

- [ ] **Step 3: CLAUDE.md**

In the "Plex library (library rows)" section, append one bullet:

```markdown
- Conversions keep every audio track matching `LIBRARY_AUDIO_LANGS` (default `eng,spa`; first track as fallback). Per-version `audio_langs`/`converted_langs` are JSON columns filled at scan/convert time; the per-movie choice lives in `videos.audio_lang` (`POST /api/videos/{id}/audio`), and the HLS package carries only the chosen language (invalidated via `hls.invalidate` on change).
```

- [ ] **Step 4: Full verification**

Run: `python -m pytest tests/` — all PASS.
Run: `cd ios/PatataTubeKit && swift build` — succeeds.
Run: `cd ios/PatataTube && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO` — succeeds.

- [ ] **Step 5: Commit**

```bash
git add .env.example ios/README.md CLAUDE.md
git commit -m "docs: audio language selector env, checklist, architecture notes"
```

---

## Post-implementation manual smoke (server + device)

1. Restart the server (`./serve`); first `/api/library/scan` probes the library once (slower, expected).
2. In the app: Lilo & Stitch detail → Audio picker shows English/Spanish; picking either triggers re-conversion (current file is Catalan-only). Wait for `done`, play, verify language.
3. Verify with `ffprobe` that the new converted mp4 has eng + both spa tracks with language tags.
