# Plex Library Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serve the `/Volumes/Media/media` movie/TV library through PatataTube with Plex metadata, iOS-first, converting files to iPad-compatible MP4 only on first play/download.

**Architecture:** Library files become ordinary rows in the existing `videos` SQLite table (`source='library'`) with Plex metadata columns. A new `plex.py` talks to the local Plex server; a new `library.py` holds scan + ffmpeg conversion logic. `main.py` gains scan/prepare/single-video/preview endpoints and token-gates streaming. The SwiftUI app gains a refresh button, show→episode navigation, and a prepare-then-poll playback gate.

**Tech Stack:** FastAPI, SQLite, httpx, ffmpeg/ffprobe, Plex HTTP API, SwiftPM (PatataTubeKit), SwiftUI/AVKit.

**Spec:** `docs/superpowers/specs/2026-07-07-plex-library-design.md`

## Global Constraints

- `CLASSIFICATIONS = ["children", "adults", "education", "tv", "movies"]` — `entertainment` removed.
- Library rows: status `unconverted` → `converting` → `done`; failure → back to `unconverted` + `error_msg`. **Never delete a library row on error** (row-delete-on-error applies only to `source='download'`).
- Converted file: sibling of the original, same name, `.mp4` extension; if that path is the source itself or already exists, `{stem}.ios.mp4`. Write to a hidden temp file in the same directory, `os.replace` on success.
- Video codec policy: h264 ≤2266px wide → copy+`avc1`; hevc ≤2266px → copy+`hvc1`; else libx264 `-preset veryfast -crf 23 -pix_fmt yuv420p -profile:v high -tag:v avc1`, plus `-vf "scale='min(2266,iw)':-2"` when width >2266.
- Audio codec policy: aac/ac3/eac3 → copy; none → `-an`; else `-c:a aac -b:a 128k -ac 2`.
- Passthrough (no ffmpeg, no copy): mp4/mov container AND (h264, or hevc tagged `hvc1`) AND width ≤2266 AND audio aac/ac3/eac3 or absent.
- All new endpoints + stream endpoint auth: `Authorization: Bearer <UPLOAD_TOKEN>` via `_check_token`; stream (and preview) also accept `?token=` query param.
- Plex config: `PLEX_URL` (default `http://localhost:32400`), `PLEX_TOKEN` (env; scan → 503 without it). Plex JSON contains raw control characters — **always parse with `json.loads(text, strict=False)`**, never `resp.json()`.
- Delete on library rows = tombstone (`deleted_at`) + unlink `converted_path`; **never unlink `source_path`**.
- Async pytest tests need `@pytest.mark.asyncio`; integration tests follow the reload-db-then-main `client` fixture pattern.
- Python venv: `python_env/`; run tests with `python -m pytest`.
- Swift tests: `cd ios/PatataTubeKit && swift test`.

---

### Task 1: DB schema, classifications, library helpers

**Files:**
- Modify: `db.py`
- Test: `tests/test_db.py`

**Interfaces:**
- Produces: `db.upsert_library_video(item: dict) -> tuple[int, str]` (status: `"created"|"updated"|"tombstoned"`), `db.tombstone_video(video_id: int) -> None`, `db.get_converted_paths() -> set[str]`, `db.set_library_state(video_id: int, status: str, converted_path: str | None = None, error_msg: str | None = None) -> None`. New columns: `source, source_path, converted_path, show_title, season, episode, summary, plex_rating_key, show_rating_key, deleted_at`. `get_all_videos` excludes tombstoned rows.

- [ ] **Step 1: Write failing tests**

Append to `tests/test_db.py` (match its existing style — it uses a `tmp_path` + reload fixture; if it has a fixture named differently, reuse that file's fixture):

```python
LIB_ITEM = {
    "source_path": "/Volumes/Media/media/tv/The.Bear.S01/The.Bear.S01E01.mkv",
    "title": "System",
    "classification": "tv",
    "show_title": "The Bear",
    "season": 1,
    "episode": 1,
    "summary": "Carmy retrains the crew.",
    "plex_rating_key": "1264",
    "show_rating_key": "1262",
}


def test_classifications_updated():
    import db
    assert db.CLASSIFICATIONS == ["children", "adults", "education", "tv", "movies"]


def test_upsert_library_video_creates_row(fresh_db):
    import db
    vid, status = db.upsert_library_video(LIB_ITEM)
    assert status == "created"
    row = db.get_video(vid)
    assert row["source"] == "library"
    assert row["status"] == "unconverted"
    assert row["source_path"] == LIB_ITEM["source_path"]
    assert row["show_title"] == "The Bear"
    assert row["season"] == 1 and row["episode"] == 1
    assert row["classification"] == "tv"
    assert row["deleted_at"] is None


def test_upsert_library_video_updates_existing(fresh_db):
    import db
    vid, _ = db.upsert_library_video(LIB_ITEM)
    vid2, status = db.upsert_library_video({**LIB_ITEM, "title": "System (renamed)"})
    assert vid2 == vid and status == "updated"
    assert db.get_video(vid)["title"] == "System (renamed)"


def test_upsert_skips_tombstoned(fresh_db):
    import db
    vid, _ = db.upsert_library_video(LIB_ITEM)
    db.tombstone_video(vid)
    vid2, status = db.upsert_library_video(LIB_ITEM)
    assert vid2 == vid and status == "tombstoned"
    assert db.get_video(vid)["deleted_at"] is not None


def test_get_all_videos_excludes_tombstoned(fresh_db):
    import db
    vid, _ = db.upsert_library_video(LIB_ITEM)
    assert any(v["id"] == vid for v in db.get_all_videos())
    db.tombstone_video(vid)
    assert not any(v["id"] == vid for v in db.get_all_videos())


def test_set_library_state_and_converted_paths(fresh_db):
    import db
    vid, _ = db.upsert_library_video(LIB_ITEM)
    db.set_library_state(vid, "converting")
    assert db.get_video(vid)["status"] == "converting"
    db.set_library_state(vid, "done", converted_path="/tmp/x.mp4")
    row = db.get_video(vid)
    assert row["status"] == "done" and row["converted_path"] == "/tmp/x.mp4"
    assert db.get_converted_paths() == {"/tmp/x.mp4"}
    db.set_library_state(vid, "unconverted", error_msg="boom")
    row = db.get_video(vid)
    assert row["status"] == "unconverted" and row["error_msg"] == "boom"
```

If `tests/test_db.py` has no reusable fresh-DB fixture, add one at its top:

```python
import importlib
import pytest


@pytest.fixture()
def fresh_db(monkeypatch, tmp_path):
    monkeypatch.setenv("DB_PATH", str(tmp_path / "test.db"))
    import db
    importlib.reload(db)
    db.init_db()
    yield
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `python -m pytest tests/test_db.py -v`
Expected: FAIL — `AssertionError` on classifications, `AttributeError: module 'db' has no attribute 'upsert_library_video'`.

- [ ] **Step 3: Implement in `db.py`**

Change line 6:

```python
CLASSIFICATIONS = ["children", "adults", "education", "tv", "movies"]
```

In `init_db()`, after the existing `classification` guard, add:

```python
        if "source" not in columns:
            conn.execute("ALTER TABLE videos ADD COLUMN source TEXT NOT NULL DEFAULT 'download'")
        if "source_path" not in columns:
            conn.execute("ALTER TABLE videos ADD COLUMN source_path TEXT")
        if "converted_path" not in columns:
            conn.execute("ALTER TABLE videos ADD COLUMN converted_path TEXT")
        if "show_title" not in columns:
            conn.execute("ALTER TABLE videos ADD COLUMN show_title TEXT")
        if "season" not in columns:
            conn.execute("ALTER TABLE videos ADD COLUMN season INTEGER")
        if "episode" not in columns:
            conn.execute("ALTER TABLE videos ADD COLUMN episode INTEGER")
        if "summary" not in columns:
            conn.execute("ALTER TABLE videos ADD COLUMN summary TEXT")
        if "plex_rating_key" not in columns:
            conn.execute("ALTER TABLE videos ADD COLUMN plex_rating_key TEXT")
        if "show_rating_key" not in columns:
            conn.execute("ALTER TABLE videos ADD COLUMN show_rating_key TEXT")
        if "deleted_at" not in columns:
            conn.execute("ALTER TABLE videos ADD COLUMN deleted_at TEXT")
        conn.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_videos_source_path ON videos(source_path)"
        )
```

In `get_all_videos`, exclude tombstones (both branches):

```python
def get_all_videos(classification: str | None = None) -> list[dict]:
    with _conn() as conn:
        if classification:
            rows = conn.execute(
                "SELECT * FROM videos WHERE deleted_at IS NULL AND classification = ?"
                " ORDER BY position DESC, created_at DESC",
                (classification,),
            ).fetchall()
        else:
            rows = conn.execute(
                "SELECT * FROM videos WHERE deleted_at IS NULL ORDER BY position DESC, created_at DESC"
            ).fetchall()
        return [dict(r) for r in rows]
```

Append new helpers at the end of the file:

```python
def upsert_library_video(item: dict) -> tuple[int, str]:
    """Insert or update a library row keyed on source_path.

    Returns (video_id, status) with status in {"created", "updated", "tombstoned"}.
    Tombstoned rows are left untouched so a rescan never resurrects a delete.
    """
    with _conn() as conn:
        row = conn.execute(
            "SELECT id, deleted_at FROM videos WHERE source_path = ?",
            (item["source_path"],),
        ).fetchone()
        if row:
            if row["deleted_at"]:
                return row["id"], "tombstoned"
            conn.execute(
                """
                UPDATE videos
                SET title = ?, classification = ?, show_title = ?, season = ?,
                    episode = ?, summary = ?, plex_rating_key = ?, show_rating_key = ?
                WHERE id = ?
                """,
                (
                    item.get("title"),
                    item["classification"],
                    item.get("show_title"),
                    item.get("season"),
                    item.get("episode"),
                    item.get("summary"),
                    item.get("plex_rating_key"),
                    item.get("show_rating_key"),
                    row["id"],
                ),
            )
            return row["id"], "updated"

        next_position = (conn.execute("SELECT MAX(position) FROM videos").fetchone()[0] or 0) + 1
        cur = conn.execute(
            """
            INSERT INTO videos (
                url, title, status, classification, source, source_path,
                show_title, season, episode, summary, plex_rating_key,
                show_rating_key, created_at, position
            )
            VALUES (?, ?, 'unconverted', ?, 'library', ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                item["source_path"],
                item.get("title"),
                item["classification"],
                item["source_path"],
                item.get("show_title"),
                item.get("season"),
                item.get("episode"),
                item.get("summary"),
                item.get("plex_rating_key"),
                item.get("show_rating_key"),
                datetime.now(timezone.utc).isoformat(),
                next_position,
            ),
        )
        return cur.lastrowid, "created"


def tombstone_video(video_id: int) -> None:
    with _conn() as conn:
        conn.execute(
            "UPDATE videos SET deleted_at = ? WHERE id = ?",
            (datetime.now(timezone.utc).isoformat(), video_id),
        )


def get_converted_paths() -> set[str]:
    with _conn() as conn:
        rows = conn.execute(
            "SELECT converted_path FROM videos WHERE converted_path IS NOT NULL"
        ).fetchall()
        return {r["converted_path"] for r in rows}


def set_library_state(
    video_id: int,
    status: str,
    converted_path: str | None = None,
    error_msg: str | None = None,
) -> None:
    """Status updates for library rows. Unlike update_video, never deletes the row."""
    with _conn() as conn:
        conn.execute(
            """
            UPDATE videos
            SET status = ?, converted_path = COALESCE(?, converted_path), error_msg = ?
            WHERE id = ?
            """,
            (status, converted_path, error_msg, video_id),
        )
```

- [ ] **Step 4: Run tests, verify pass; run full suite**

Run: `python -m pytest tests/test_db.py -v` — expected: PASS.
Run: `python -m pytest tests/` — expected: one pre-existing failure category is possible: `views/templates.py` or tests referencing `entertainment`. `grep -rn "entertainment" --include="*.py" .` — update any test fixture or template default that hardcodes it to use `tv`. All tests green before committing.

- [ ] **Step 5: Commit**

```bash
git add db.py tests/test_db.py
git commit -m "feat: library schema, tombstones, tv/movies classifications"
```

---

### Task 2: Plex client module

**Files:**
- Create: `plex.py`
- Test: `tests/test_plex.py`

**Interfaces:**
- Produces: `plex.fetch_library_items() -> list[dict]` — each dict has keys `source_path, title, classification, show_title, season, episode, summary, plex_rating_key, show_rating_key` (movie rows: `show_title/season/episode/show_rating_key` are `None`, classification `"movies"`; episodes: classification `"tv"`). `plex.fetch_thumb(rating_key: str) -> bytes`. Both raise `plex.PlexError` on HTTP/config trouble.
- Consumes: nothing from other tasks.

- [ ] **Step 1: Write failing tests**

Create `tests/test_plex.py`. Network is mocked by patching `plex._get_json`; only the normalization logic is under test:

```python
import plex


SECTIONS = {"MediaContainer": {"Directory": [
    {"key": "1", "type": "movie", "title": "Movies"},
    {"key": "2", "type": "show", "title": "TV Shows"},
]}}

MOVIES = {"MediaContainer": {"Metadata": [
    {
        "ratingKey": "42",
        "title": "Akira",
        "summary": "Neo-Tokyo.",
        "Media": [{"Part": [{"file": "/Volumes/Media/media/movies/Akira/Akira.mkv"}]}],
    },
]}}

SHOWS = {"MediaContainer": {"Metadata": [{"ratingKey": "1262", "title": "The Bear"}]}}

EPISODES = {"MediaContainer": {"Metadata": [
    {
        "ratingKey": "1264",
        "grandparentRatingKey": "1262",
        "grandparentTitle": "The Bear",
        "title": "System",
        "parentIndex": 1,
        "index": 1,
        "summary": "Carmy retrains the crew.",
        "Media": [{"Part": [{"file": "/Volumes/Media/media/tv/The.Bear/S01E01.mkv"}]}],
    },
]}}


def fake_get_json(path, params=None):
    if path == "/library/sections":
        return SECTIONS
    if path == "/library/sections/1/all":
        return MOVIES
    if path == "/library/sections/2/all":
        return SHOWS
    if path == "/library/metadata/1262/allLeaves":
        return EPISODES
    raise AssertionError(f"unexpected path {path}")


def test_fetch_library_items(monkeypatch):
    monkeypatch.setattr(plex, "_get_json", fake_get_json)
    items = plex.fetch_library_items()
    assert len(items) == 2

    movie = next(i for i in items if i["classification"] == "movies")
    assert movie == {
        "source_path": "/Volumes/Media/media/movies/Akira/Akira.mkv",
        "title": "Akira",
        "classification": "movies",
        "show_title": None,
        "season": None,
        "episode": None,
        "summary": "Neo-Tokyo.",
        "plex_rating_key": "42",
        "show_rating_key": None,
    }

    ep = next(i for i in items if i["classification"] == "tv")
    assert ep == {
        "source_path": "/Volumes/Media/media/tv/The.Bear/S01E01.mkv",
        "title": "System",
        "classification": "tv",
        "show_title": "The Bear",
        "season": 1,
        "episode": 1,
        "summary": "Carmy retrains the crew.",
        "plex_rating_key": "1264",
        "show_rating_key": "1262",
    }


def test_item_without_file_is_skipped(monkeypatch):
    broken = {"MediaContainer": {"Metadata": [{"ratingKey": "9", "title": "NoFile", "Media": []}]}}

    def fake(path, params=None):
        if path == "/library/sections":
            return SECTIONS
        if path == "/library/sections/1/all":
            return broken
        if path == "/library/sections/2/all":
            return {"MediaContainer": {"Metadata": []}}
        raise AssertionError(path)

    monkeypatch.setattr(plex, "_get_json", fake)
    assert plex.fetch_library_items() == []


def test_parse_json_tolerates_control_chars():
    # Plex responses contain raw control characters; strict parsing must be off.
    raw = '{"MediaContainer": {"summary": "line1\x01line2"}}'
    assert plex._parse_json(raw)["MediaContainer"]["summary"] == "line1\x01line2"
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `python -m pytest tests/test_plex.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'plex'`.

- [ ] **Step 3: Create `plex.py`**

```python
"""Thin client for the local Plex Media Server HTTP API.

Plex JSON responses can contain raw control characters in summaries,
so every parse goes through _parse_json (strict=False), never resp.json().
"""

import json
import os

import httpx


class PlexError(RuntimeError):
    pass


def _base_url() -> str:
    return os.getenv("PLEX_URL", "http://localhost:32400").rstrip("/")


def _token() -> str:
    token = os.getenv("PLEX_TOKEN", "")
    if not token:
        raise PlexError("PLEX_TOKEN is not configured")
    return token


def _parse_json(text: str) -> dict:
    return json.loads(text, strict=False)


def _get_json(path: str, params: dict | None = None) -> dict:
    params = dict(params or {})
    params["X-Plex-Token"] = _token()
    try:
        resp = httpx.get(
            f"{_base_url()}{path}",
            params=params,
            headers={"Accept": "application/json"},
            timeout=30,
        )
        resp.raise_for_status()
    except httpx.HTTPError as exc:
        raise PlexError(f"Plex request failed: {exc}") from exc
    return _parse_json(resp.text)


def _part_file(meta: dict) -> str | None:
    for media in meta.get("Media") or []:
        for part in media.get("Part") or []:
            if part.get("file"):
                return part["file"]
    return None


def _movie_item(meta: dict) -> dict | None:
    path = _part_file(meta)
    if not path:
        return None
    return {
        "source_path": path,
        "title": meta.get("title"),
        "classification": "movies",
        "show_title": None,
        "season": None,
        "episode": None,
        "summary": meta.get("summary"),
        "plex_rating_key": str(meta["ratingKey"]),
        "show_rating_key": None,
    }


def _episode_item(meta: dict) -> dict | None:
    path = _part_file(meta)
    if not path:
        return None
    return {
        "source_path": path,
        "title": meta.get("title"),
        "classification": "tv",
        "show_title": meta.get("grandparentTitle"),
        "season": meta.get("parentIndex"),
        "episode": meta.get("index"),
        "summary": meta.get("summary"),
        "plex_rating_key": str(meta["ratingKey"]),
        "show_rating_key": (
            str(meta["grandparentRatingKey"]) if meta.get("grandparentRatingKey") else None
        ),
    }


def fetch_library_items() -> list[dict]:
    """All movie and episode items known to Plex, normalized for db.upsert_library_video."""
    sections = _get_json("/library/sections")["MediaContainer"].get("Directory", [])
    items: list[dict] = []
    for section in sections:
        if section.get("type") == "movie":
            metadata = _get_json(f"/library/sections/{section['key']}/all")[
                "MediaContainer"
            ].get("Metadata", [])
            items.extend(filter(None, (_movie_item(m) for m in metadata)))
        elif section.get("type") == "show":
            shows = _get_json(f"/library/sections/{section['key']}/all")[
                "MediaContainer"
            ].get("Metadata", [])
            for show in shows:
                episodes = _get_json(
                    f"/library/metadata/{show['ratingKey']}/allLeaves"
                )["MediaContainer"].get("Metadata", [])
                items.extend(filter(None, (_episode_item(e) for e in episodes)))
    return items


def fetch_thumb(rating_key: str) -> bytes:
    """JPEG bytes of the item's poster/thumb."""
    try:
        resp = httpx.get(
            f"{_base_url()}/library/metadata/{rating_key}/thumb",
            params={"X-Plex-Token": _token()},
            timeout=30,
            follow_redirects=True,
        )
        resp.raise_for_status()
    except httpx.HTTPError as exc:
        raise PlexError(f"Plex thumb fetch failed: {exc}") from exc
    return resp.content
```

- [ ] **Step 4: Run tests, verify pass**

Run: `python -m pytest tests/test_plex.py -v` — expected: PASS.

- [ ] **Step 5: Smoke-test against the real Plex server (manual, informative)**

Run: `PLEX_TOKEN=$(defaults read com.plexapp.plexmediaserver PlexOnlineToken) python_env/bin/python -c "import plex; items = plex.fetch_library_items(); print(len(items), items[0])"`
Expected: item count in the hundreds (~1000+) and a normalized first dict. Failure here is environmental (Plex down / LuLu firewall blocking python) — the unit tests are the gate; report but don't block.

- [ ] **Step 6: Commit**

```bash
git add plex.py tests/test_plex.py
git commit -m "feat: Plex API client with normalized library items"
```

---

### Task 3: Conversion policy (pure logic)

**Files:**
- Create: `library.py`
- Test: `tests/test_library.py`

**Interfaces:**
- Produces: `library.ConversionPlan` dataclass (`passthrough: bool`, `video_args: list[str]`, `audio_args: list[str]`), `library.plan_conversion(probe: dict) -> ConversionPlan`, `library.conversion_target(source: Path) -> Path`, `library.IPAD_MAX_WIDTH = 2266`.
- Consumes: probe dicts shaped like `downloader._probe_media` output (ffprobe `-show_streams -show_format` JSON).

- [ ] **Step 1: Write failing tests**

Create `tests/test_library.py`:

```python
from pathlib import Path

import library


def probe(container="matroska,webm", vcodec="hevc", width=1920, tag="[0][0][0][0]",
          acodec="eac3", with_audio=True):
    streams = [{
        "codec_type": "video",
        "codec_name": vcodec,
        "width": width,
        "codec_tag_string": tag,
    }]
    if with_audio:
        streams.append({"codec_type": "audio", "codec_name": acodec, "channels": 6})
    return {"streams": streams, "format": {"format_name": container}}


def test_passthrough_compatible_mp4():
    p = probe(container="mov,mp4,m4a,3gp,3g2,mj2", vcodec="h264", acodec="aac")
    plan = library.plan_conversion(p)
    assert plan.passthrough


def test_passthrough_hevc_requires_hvc1_tag():
    good = probe(container="mov,mp4,m4a,3gp,3g2,mj2", vcodec="hevc", tag="hvc1")
    assert library.plan_conversion(good).passthrough
    bad = probe(container="mov,mp4,m4a,3gp,3g2,mj2", vcodec="hevc", tag="hev1")
    assert not library.plan_conversion(bad).passthrough


def test_no_passthrough_above_ipad_width():
    p = probe(container="mov,mp4,m4a,3gp,3g2,mj2", vcodec="h264", acodec="aac", width=3840)
    assert not library.plan_conversion(p).passthrough


def test_mkv_hevc_remuxes_with_hvc1():
    plan = library.plan_conversion(probe())
    assert not plan.passthrough
    assert plan.video_args == ["-c:v", "copy", "-tag:v", "hvc1"]
    assert plan.audio_args == ["-c:a", "copy"]


def test_mkv_h264_remuxes_with_avc1():
    plan = library.plan_conversion(probe(vcodec="h264"))
    assert plan.video_args == ["-c:v", "copy", "-tag:v", "avc1"]


def test_4k_downscales_and_reencodes():
    plan = library.plan_conversion(probe(width=3840))
    assert plan.video_args == [
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
        "-pix_fmt", "yuv420p", "-profile:v", "high", "-tag:v", "avc1",
        "-vf", "scale='min(2266,iw)':-2",
    ]


def test_unsupported_codecs_reencode():
    plan = library.plan_conversion(probe(vcodec="vp9", acodec="dts"))
    assert plan.video_args[0:2] == ["-c:v", "libx264"]
    assert plan.audio_args == ["-c:a", "aac", "-b:a", "128k", "-ac", "2"]


def test_no_audio_stream():
    plan = library.plan_conversion(probe(with_audio=False))
    assert plan.audio_args == ["-an"]


def test_conversion_target_swaps_extension(tmp_path):
    src = tmp_path / "movie.mkv"
    src.touch()
    assert library.conversion_target(src) == tmp_path / "movie.mp4"


def test_conversion_target_collision_falls_back(tmp_path):
    src = tmp_path / "movie.mp4"
    src.touch()
    assert library.conversion_target(src) == tmp_path / "movie.ios.mp4"

    other = tmp_path / "film.mkv"
    other.touch()
    (tmp_path / "film.mp4").touch()  # pre-existing sibling from another release
    assert library.conversion_target(other) == tmp_path / "film.ios.mp4"
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `python -m pytest tests/test_library.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'library'`.

- [ ] **Step 3: Create `library.py`**

```python
"""Library scanning and on-demand iPad conversion for /Volumes/Media files."""

from dataclasses import dataclass, field
from pathlib import Path

# iPad mini 6th gen panel long edge; wider sources get downscaled.
IPAD_MAX_WIDTH = 2266
_COMPAT_VIDEO = {"h264", "hevc"}
_COMPAT_AUDIO = {"aac", "ac3", "eac3"}

_REENCODE_VIDEO_ARGS = [
    "-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
    "-pix_fmt", "yuv420p", "-profile:v", "high", "-tag:v", "avc1",
]
_SCALE_ARGS = ["-vf", f"scale='min({IPAD_MAX_WIDTH},iw)':-2"]


@dataclass
class ConversionPlan:
    passthrough: bool
    video_args: list[str] = field(default_factory=list)
    audio_args: list[str] = field(default_factory=list)


def _first_stream(probe: dict, stream_type: str) -> dict | None:
    for stream in probe.get("streams", []):
        if stream.get("codec_type") == stream_type:
            return stream
    return None


def plan_conversion(probe: dict) -> ConversionPlan:
    video = _first_stream(probe, "video")
    audio = _first_stream(probe, "audio")
    if not video:
        raise RuntimeError("No video stream found")

    container = probe.get("format", {}).get("format_name", "")
    is_mp4 = "mp4" in container
    vcodec = video.get("codec_name")
    width = int(video.get("width") or 0)
    fits = width <= IPAD_MAX_WIDTH
    video_compat = vcodec in _COMPAT_VIDEO and fits
    hevc_tagged = vcodec != "hevc" or video.get("codec_tag_string") == "hvc1"
    audio_compat = audio is None or audio.get("codec_name") in _COMPAT_AUDIO

    if is_mp4 and video_compat and hevc_tagged and audio_compat:
        return ConversionPlan(passthrough=True)

    if video_compat:
        tag = "hvc1" if vcodec == "hevc" else "avc1"
        video_args = ["-c:v", "copy", "-tag:v", tag]
    else:
        video_args = list(_REENCODE_VIDEO_ARGS)
        if not fits:
            video_args += _SCALE_ARGS

    if audio is None:
        audio_args = ["-an"]
    elif audio_compat:
        audio_args = ["-c:a", "copy"]
    else:
        audio_args = ["-c:a", "aac", "-b:a", "128k", "-ac", "2"]

    return ConversionPlan(passthrough=False, video_args=video_args, audio_args=audio_args)


def conversion_target(source: Path) -> Path:
    """Sibling mp4 path for a converted file; .ios.mp4 on name collision."""
    target = source.with_suffix(".mp4")
    if target == source or target.exists():
        target = source.with_suffix(".ios.mp4")
    return target
```

- [ ] **Step 4: Run tests, verify pass**

Run: `python -m pytest tests/test_library.py -v` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add library.py tests/test_library.py
git commit -m "feat: iPad conversion policy and target naming"
```

---

### Task 4: Conversion runner + scan service

**Files:**
- Modify: `library.py`
- Test: `tests/test_library.py`

**Interfaces:**
- Consumes: Task 1 db helpers, Task 2 `plex.fetch_library_items`, Task 3 policy, `downloader._probe_media`.
- Produces: `library.convert_library_video(video_id: int) -> None` (sync; safe as a FastAPI BackgroundTask), `library.probe_source(path: Path) -> dict`, `library.scan_library() -> dict` returning `{"added": int, "updated": int, "skipped": int}`.

- [ ] **Step 1: Write failing tests**

Append to `tests/test_library.py` (needs the same `fresh_db` fixture as Task 1 — import it or copy it into this file):

```python
import importlib
import pytest


@pytest.fixture()
def fresh_db(monkeypatch, tmp_path):
    monkeypatch.setenv("DB_PATH", str(tmp_path / "test.db"))
    import db
    importlib.reload(db)
    db.init_db()
    yield


def lib_row(tmp_path, name="ep.mkv"):
    import db
    src = tmp_path / name
    src.write_bytes(b"fake")
    vid, _ = db.upsert_library_video({
        "source_path": str(src),
        "title": "Ep",
        "classification": "tv",
        "show_title": "Show",
        "season": 1,
        "episode": 1,
        "summary": None,
        "plex_rating_key": "1",
        "show_rating_key": "2",
    })
    return vid, src


def test_convert_passthrough_marks_done_no_copy(fresh_db, tmp_path, monkeypatch):
    import db
    vid, src = lib_row(tmp_path, "ep.mp4")
    monkeypatch.setattr(library, "probe_source", lambda p: probe(
        container="mov,mp4,m4a,3gp,3g2,mj2", vcodec="h264", acodec="aac"))
    library.convert_library_video(vid)
    row = db.get_video(vid)
    assert row["status"] == "done" and row["converted_path"] is None


def test_convert_runs_ffmpeg_and_records_sibling(fresh_db, tmp_path, monkeypatch):
    import db
    vid, src = lib_row(tmp_path)
    monkeypatch.setattr(library, "probe_source", lambda p: probe())
    calls = []

    def fake_run(cmd):
        calls.append(cmd)
        Path(cmd[-1]).write_bytes(b"converted")  # ffmpeg output file

    monkeypatch.setattr(library, "_run_ffmpeg", fake_run)
    library.convert_library_video(vid)
    row = db.get_video(vid)
    assert row["status"] == "done"
    assert row["converted_path"] == str(tmp_path / "ep.mp4")
    assert (tmp_path / "ep.mp4").read_bytes() == b"converted"
    cmd = calls[0]
    assert "-c:v" in cmd and "copy" in cmd and "+faststart" in cmd
    assert cmd[-1].startswith(str(tmp_path / "."))  # hidden temp file, atomic replace


def test_convert_failure_returns_to_unconverted(fresh_db, tmp_path, monkeypatch):
    import db
    vid, src = lib_row(tmp_path)
    monkeypatch.setattr(library, "probe_source", lambda p: probe())

    def boom(cmd):
        raise RuntimeError("ffmpeg exploded")

    monkeypatch.setattr(library, "_run_ffmpeg", boom)
    library.convert_library_video(vid)
    row = db.get_video(vid)
    assert row["status"] == "unconverted"
    assert "ffmpeg exploded" in row["error_msg"]
    assert not (tmp_path / "ep.mp4").exists()


def test_convert_missing_source(fresh_db, tmp_path):
    import db
    vid, src = lib_row(tmp_path)
    src.unlink()
    library.convert_library_video(vid)
    row = db.get_video(vid)
    assert row["status"] == "unconverted" and "missing" in row["error_msg"]


def test_scan_library(fresh_db, tmp_path, monkeypatch):
    import db
    import plex
    src = tmp_path / "a.mkv"
    src.write_bytes(b"x")
    gone = tmp_path / "gone.mkv"  # never created
    converted = tmp_path / "b.mp4"
    converted.write_bytes(b"x")

    def item(path):
        return {"source_path": str(path), "title": path.stem, "classification": "movies",
                "show_title": None, "season": None, "episode": None, "summary": None,
                "plex_rating_key": "1", "show_rating_key": None}

    monkeypatch.setattr(plex, "fetch_library_items",
                        lambda: [item(src), item(gone), item(converted)])
    # b.mp4 is a prior conversion output of some row: must be self-excluded
    vid, _ = db.upsert_library_video(item(tmp_path / "b.mkv"))
    (tmp_path / "b.mkv").write_bytes(b"x")
    db.set_library_state(vid, "done", converted_path=str(converted))

    result = library.scan_library()
    assert result == {"added": 1, "updated": 0, "skipped": 2}

    result = library.scan_library()
    assert result == {"added": 0, "updated": 1, "skipped": 2}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `python -m pytest tests/test_library.py -v`
Expected: new tests FAIL with `AttributeError: module 'library' has no attribute 'convert_library_video'` (Task 3 tests still pass).

- [ ] **Step 3: Extend `library.py`**

Add imports at the top:

```python
import os
import subprocess

import db
import plex
from downloader import _probe_media
```

Append:

```python
FFMPEG_BIN = os.getenv("FFMPEG_BIN", "ffmpeg")


def probe_source(path: Path) -> dict:
    """Indirection point so tests can fake probes without ffprobe installed."""
    return _probe_media(path)


def _run_ffmpeg(cmd: list[str]) -> None:
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if proc.returncode != 0:
        raise RuntimeError((proc.stdout or "").strip() or "ffmpeg failed while converting")


def convert_library_video(video_id: int) -> None:
    """Convert a library row's source to an iPad-ready sibling mp4.

    Runs synchronously (FastAPI executes sync background tasks on a thread).
    Failures set status back to 'unconverted' with error_msg; the row is never deleted.
    """
    video = db.get_video(video_id)
    if not video or video.get("source") != "library":
        return

    source = Path(video["source_path"])
    tmp = None
    try:
        if not source.exists():
            raise RuntimeError(f"source file missing: {source}")

        plan = plan_conversion(probe_source(source))
        if plan.passthrough:
            db.set_library_state(video_id, "done")
            return

        target = conversion_target(source)
        # Hidden temp file in the same directory: invisible to Plex and our scans,
        # and os.replace stays atomic because it is on the same volume.
        tmp = target.with_name("." + target.name)
        cmd = [
            FFMPEG_BIN, "-hide_banner", "-loglevel", "error", "-y",
            "-i", str(source),
            "-map", "0:v:0", "-map", "0:a:0?", "-sn", "-dn",
            *plan.video_args, *plan.audio_args,
            "-movflags", "+faststart",
            str(tmp),
        ]
        _run_ffmpeg(cmd)
        os.replace(tmp, target)
        db.set_library_state(video_id, "done", converted_path=str(target))
    except Exception as exc:  # noqa: BLE001 — background task, must not raise
        if tmp is not None:
            Path(tmp).unlink(missing_ok=True)
        db.set_library_state(video_id, "unconverted", error_msg=str(exc))


def scan_library() -> dict:
    """Upsert every Plex library item into the videos table. Metadata only, no ffmpeg."""
    items = plex.fetch_library_items()
    converted = db.get_converted_paths()
    added = updated = skipped = 0
    for item in items:
        path = item["source_path"]
        if path in converted or not Path(path).exists():
            skipped += 1
            continue
        _, status = db.upsert_library_video(item)
        if status == "created":
            added += 1
        elif status == "updated":
            updated += 1
        else:  # tombstoned
            skipped += 1
    return {"added": added, "updated": updated, "skipped": skipped}
```

- [ ] **Step 4: Run tests, verify pass; full suite**

Run: `python -m pytest tests/test_library.py -v` — expected: PASS.
Run: `python -m pytest tests/` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add library.py tests/test_library.py
git commit -m "feat: on-demand library conversion and Plex scan service"
```

---

### Task 5: Serializer — library fields

**Files:**
- Modify: `views/serializers.py`
- Test: `tests/test_serializers.py`

**Interfaces:**
- Produces: `serialize_video` output gains `source, show_title, season, episode, summary, show_preview_url`; library rows get `preview_url = "/videos/{id}/preview"` and `show_preview_url = "/videos/{id}/preview?kind=show"` (when `show_rating_key` set).
- Consumes: row dicts with Task 1 columns.

- [ ] **Step 1: Write failing tests**

Append to `tests/test_serializers.py`:

```python
def test_serialize_library_episode():
    from views.serializers import serialize_video
    row = {
        "id": 7, "url": "/vol/tv/ep.mkv", "title": "System", "platform": None,
        "source_key": None, "preview_url": None, "classification": "tv",
        "position": 3, "status": "unconverted", "error_msg": None,
        "source": "library", "show_title": "The Bear", "season": 1, "episode": 1,
        "summary": "Carmy.", "plex_rating_key": "1264", "show_rating_key": "1262",
    }
    data = serialize_video(row)
    assert data["source"] == "library"
    assert data["show_title"] == "The Bear"
    assert data["season"] == 1 and data["episode"] == 1
    assert data["summary"] == "Carmy."
    assert data["preview_url"] == "/videos/7/preview"
    assert data["show_preview_url"] == "/videos/7/preview?kind=show"
    assert data["stream_path"] == "/videos/7/stream"


def test_serialize_download_row_defaults():
    from views.serializers import serialize_video
    row = {"id": 1, "url": "https://x.com/s/1", "status": "done"}
    data = serialize_video(row)
    assert data["source"] == "download"
    assert data["show_title"] is None and data["show_preview_url"] is None
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `python -m pytest tests/test_serializers.py -v`
Expected: FAIL with `KeyError: 'source'` / assertion errors.

- [ ] **Step 3: Implement**

Replace `views/serializers.py` body:

```python
"""Canonical video presenter shared by the SSR page and the JSON API."""


def serialize_video(video: dict) -> dict:
    source = video.get("source") or "download"
    data = {
        "id": video["id"],
        "url": video["url"],
        "title": video.get("title"),
        "platform": video.get("platform"),
        "source_key": video.get("source_key"),
        "preview_url": video.get("preview_url"),
        "classification": video.get("classification") or "children",
        "position": video.get("position"),
        "status": video["status"],
        "error_msg": video.get("error_msg"),
        "stream_path": f"/videos/{video['id']}/stream",
        "source": source,
        "show_title": video.get("show_title"),
        "season": video.get("season"),
        "episode": video.get("episode"),
        "summary": video.get("summary"),
        "show_preview_url": None,
    }
    if source == "library":
        data["preview_url"] = f"/videos/{video['id']}/preview"
        if video.get("show_rating_key"):
            data["show_preview_url"] = f"/videos/{video['id']}/preview?kind=show"
    return data
```

- [ ] **Step 4: Run tests, verify pass**

Run: `python -m pytest tests/test_serializers.py tests/test_api.py -v` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add views/serializers.py tests/test_serializers.py
git commit -m "feat: serialize library metadata and preview routes"
```

---

### Task 6: Scan endpoint + tombstoning delete

**Files:**
- Modify: `main.py`
- Test: `tests/test_api.py`

**Interfaces:**
- Produces: `POST /api/library/scan` (token; 503 without `PLEX_TOKEN`; 502 on `PlexError`; 200 → scan counts). `POST /api/video/{id}/delete` tombstones library rows (removes `converted_path` file only).
- Consumes: `library.scan_library`, `db.tombstone_video`.

- [ ] **Step 1: Write failing tests**

Append to `tests/test_api.py`:

```python
AUTH = {"Authorization": "Bearer test-secret"}

LIB_ITEM_API = {
    "source_path": None,  # filled per-test with tmp file
    "title": "System", "classification": "tv", "show_title": "The Bear",
    "season": 1, "episode": 1, "summary": "Carmy.",
    "plex_rating_key": "1264", "show_rating_key": "1262",
}


def make_library_row(tmp_path, name="ep.mkv"):
    import db
    src = tmp_path / name
    src.write_bytes(b"fake")
    vid, _ = db.upsert_library_video({**LIB_ITEM_API, "source_path": str(src)})
    return vid, src


def test_scan_requires_token(client):
    assert client.post("/api/library/scan").status_code == 401


def test_scan_without_plex_token_is_503(client, monkeypatch):
    monkeypatch.delenv("PLEX_TOKEN", raising=False)
    resp = client.post("/api/library/scan", headers=AUTH)
    assert resp.status_code == 503


def test_scan_success(client, monkeypatch, tmp_path):
    monkeypatch.setenv("PLEX_TOKEN", "plex-token")
    src = tmp_path / "a.mkv"
    src.write_bytes(b"x")
    import plex
    monkeypatch.setattr(plex, "fetch_library_items", lambda: [
        {**LIB_ITEM_API, "source_path": str(src)},
    ])
    resp = client.post("/api/library/scan", headers=AUTH)
    assert resp.status_code == 200
    assert resp.json() == {"added": 1, "updated": 0, "skipped": 0}

    videos = client.get("/api/videos").json()
    lib = [v for v in videos if v["source"] == "library"]
    assert len(lib) == 1 and lib[0]["status"] == "unconverted"


def test_scan_plex_down_is_502(client, monkeypatch):
    monkeypatch.setenv("PLEX_TOKEN", "plex-token")
    import plex
    def boom():
        raise plex.PlexError("connection refused")
    monkeypatch.setattr(plex, "fetch_library_items", boom)
    resp = client.post("/api/library/scan", headers=AUTH)
    assert resp.status_code == 502


def test_delete_library_video_tombstones(client, tmp_path):
    import db
    vid, src = make_library_row(tmp_path)
    converted = tmp_path / "ep.mp4"
    converted.write_bytes(b"converted")
    db.set_library_state(vid, "done", converted_path=str(converted))

    resp = client.post(f"/api/video/{vid}/delete", headers=AUTH)
    assert resp.status_code == 200
    assert src.exists()                     # original never touched
    assert not converted.exists()           # our copy removed
    assert db.get_video(vid)["deleted_at"] is not None
    assert vid not in [v["id"] for v in client.get("/api/videos").json()]
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `python -m pytest tests/test_api.py -v -k "scan or tombstone"`
Expected: FAIL — 404 on `/api/library/scan`, delete test fails on tombstone assertions.

- [ ] **Step 3: Implement in `main.py`**

Add imports near the top (after `import services`):

```python
import library
import plex
```

Add the scan endpoint after `api_delete_video`:

```python
@app.post("/api/library/scan")
async def api_library_scan(request: Request):
    _check_token(request)
    if not os.getenv("PLEX_TOKEN"):
        raise HTTPException(status_code=503, detail="Plex not configured (set PLEX_TOKEN)")
    try:
        return await asyncio.to_thread(library.scan_library)
    except plex.PlexError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
```

Replace `api_delete_video`:

```python
@app.post("/api/video/{video_id}/delete")
async def api_delete_video(video_id: int, request: Request):
    _check_token(request)
    video = db.get_video(video_id)
    if video:
        if video.get("source") == "library":
            if video.get("converted_path"):
                Path(video["converted_path"]).unlink(missing_ok=True)
            db.tombstone_video(video_id)
        else:
            if video.get("filename"):
                (VIDEOS_DIR / video["filename"]).unlink(missing_ok=True)
            db.delete_video(video_id)
    return {"ok": True}
```

- [ ] **Step 4: Run tests, verify pass; full suite**

Run: `python -m pytest tests/test_api.py -v` then `python -m pytest tests/` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add main.py tests/test_api.py
git commit -m "feat: library scan endpoint and tombstoning delete"
```

---

### Task 7: Prepare endpoint + single-video endpoint

**Files:**
- Modify: `main.py`
- Test: `tests/test_api.py`

**Interfaces:**
- Produces: `POST /api/videos/{id}/prepare` (token) — 200 `{"status": "done"}` when ready or passthrough; 202 `{"status": "converting"}` when queued/in progress; 404 unknown/tombstoned; 400 for download rows. `GET /api/videos/{id}` (token) — serialized video or 404.
- Consumes: `library.convert_library_video`, `library.plan_conversion`, `library.probe_source`.

- [ ] **Step 1: Write failing tests**

Append to `tests/test_api.py`:

```python
def test_get_single_video(client, tmp_path):
    vid, _ = make_library_row(tmp_path)
    assert client.get(f"/api/videos/{vid}").status_code == 401
    resp = client.get(f"/api/videos/{vid}", headers=AUTH)
    assert resp.status_code == 200
    assert resp.json()["id"] == vid
    assert client.get("/api/videos/99999", headers=AUTH).status_code == 404


def test_prepare_passthrough_returns_done(client, tmp_path, monkeypatch):
    import library
    vid, _ = make_library_row(tmp_path, name="ep.mp4")
    monkeypatch.setattr(library, "probe_source", lambda p: {
        "streams": [
            {"codec_type": "video", "codec_name": "h264", "width": 1920,
             "codec_tag_string": "avc1"},
            {"codec_type": "audio", "codec_name": "aac", "channels": 2},
        ],
        "format": {"format_name": "mov,mp4,m4a,3gp,3g2,mj2"},
    })
    resp = client.post(f"/api/videos/{vid}/prepare", headers=AUTH)
    assert resp.status_code == 200
    assert resp.json() == {"status": "done"}
    import db
    assert db.get_video(vid)["status"] == "done"


def test_prepare_queues_conversion(client, tmp_path, monkeypatch):
    import library
    vid, _ = make_library_row(tmp_path)
    monkeypatch.setattr(library, "probe_source", lambda p: {
        "streams": [{"codec_type": "video", "codec_name": "hevc", "width": 1920,
                     "codec_tag_string": "[0][0][0][0]"}],
        "format": {"format_name": "matroska,webm"},
    })
    converted = []
    monkeypatch.setattr("main.library.convert_library_video",
                        lambda video_id: converted.append(video_id))
    resp = client.post(f"/api/videos/{vid}/prepare", headers=AUTH)
    assert resp.status_code == 202
    assert resp.json() == {"status": "converting"}
    assert converted == [vid]  # TestClient runs background tasks before returning
    import db
    assert db.get_video(vid)["status"] == "converting"


def test_prepare_while_converting_is_noop_202(client, tmp_path, monkeypatch):
    import db
    vid, _ = make_library_row(tmp_path)
    db.set_library_state(vid, "converting")
    called = []
    monkeypatch.setattr("main.library.convert_library_video", lambda v: called.append(v))
    resp = client.post(f"/api/videos/{vid}/prepare", headers=AUTH)
    assert resp.status_code == 202 and called == []


def test_prepare_download_row_is_400(client, monkeypatch):
    import db
    monkeypatch.setattr("main.download_video", lambda *a, **kw: None)
    up = client.post("/upload", json={"url": "https://twitter.com/x/status/9"}, headers=AUTH)
    resp = client.post(f"/api/videos/{up.json()['id']}/prepare", headers=AUTH)
    assert resp.status_code == 400
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `python -m pytest tests/test_api.py -v -k "prepare or single"`
Expected: FAIL — 404/405 on the new routes.

- [ ] **Step 3: Implement in `main.py`**

Add after the scan endpoint. **Route order matters:** FastAPI matches in declaration order and `/api/videos` (list) has no param so there is no conflict, but declare `GET /api/videos/{video_id}` after the existing list route to keep reading order sane.

```python
@app.get("/api/videos/{video_id}")
async def api_video(video_id: int, request: Request):
    _check_token(request)
    video = db.get_video(video_id)
    if not video or video.get("deleted_at"):
        raise HTTPException(status_code=404, detail="Video not found")
    return serialize_video(video)


@app.post("/api/videos/{video_id}/prepare")
async def api_prepare_video(video_id: int, request: Request, background_tasks: BackgroundTasks):
    _check_token(request)
    video = db.get_video(video_id)
    if not video or video.get("deleted_at"):
        raise HTTPException(status_code=404, detail="Video not found")
    if video.get("source") != "library":
        raise HTTPException(status_code=400, detail="Only library videos need preparing")

    if video["status"] == "done":
        return {"status": "done"}
    if video["status"] == "converting":
        return JSONResponse({"status": "converting"}, status_code=202)

    source = Path(video["source_path"])
    if not source.exists():
        db.set_library_state(video_id, "unconverted", error_msg=f"source file missing: {source}")
        raise HTTPException(status_code=404, detail="Source file missing")

    try:
        plan = await asyncio.to_thread(lambda: library.plan_conversion(library.probe_source(source)))
    except Exception as exc:  # ffprobe failure
        db.set_library_state(video_id, "unconverted", error_msg=str(exc))
        raise HTTPException(status_code=500, detail=str(exc)) from exc

    if plan.passthrough:
        db.set_library_state(video_id, "done")
        return {"status": "done"}

    db.set_library_state(video_id, "converting")
    background_tasks.add_task(library.convert_library_video, video_id)
    return JSONResponse({"status": "converting"}, status_code=202)
```

- [ ] **Step 4: Run tests, verify pass; full suite**

Run: `python -m pytest tests/test_api.py -v` then `python -m pytest tests/` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add main.py tests/test_api.py
git commit -m "feat: prepare endpoint with passthrough detection, single-video endpoint"
```

---

### Task 8: Stream auth + library path resolution + SSR token

**Files:**
- Modify: `main.py`, `views/templates.py:114`
- Test: `tests/test_api.py`

**Interfaces:**
- Produces: `_check_token_or_query(request)` helper in `main.py`; stream endpoint gated (Bearer or `?token=`), resolves library paths, 409 for unprepared library rows. SSR `<source src>` gains `?token=`.
- Consumes: Task 1 columns.

**Heads-up:** existing stream tests in `tests/test_api.py` will start failing with 401 — update them to send `AUTH` headers as part of this task.

- [ ] **Step 1: Write failing tests**

Append to `tests/test_api.py`:

```python
def make_done_download_video(tmp_path):
    """A completed download row whose mp4 exists under videos/."""
    import db
    from pathlib import Path
    vid = db.add_video("https://twitter.com/x/status/55", platform="twitter")
    Path("videos").mkdir(exist_ok=True)
    f = Path("videos") / f"{vid}.mp4"
    f.write_bytes(b"\x00" * 100)
    db.update_video(vid, "done", filename=f"{vid}.mp4")
    return vid, f


def test_stream_requires_token(client, tmp_path):
    vid, f = make_done_download_video(tmp_path)
    try:
        assert client.get(f"/videos/{vid}/stream").status_code == 401
        assert client.get(f"/videos/{vid}/stream", headers=AUTH).status_code == 200
        assert client.get(f"/videos/{vid}/stream?token=test-secret").status_code == 200
        assert client.get(f"/videos/{vid}/stream?token=wrong").status_code == 401
    finally:
        f.unlink(missing_ok=True)


def test_stream_library_serves_converted_copy(client, tmp_path):
    import db
    vid, src = make_library_row(tmp_path)
    converted = tmp_path / "ep.mp4"
    converted.write_bytes(b"converted-bytes")
    db.set_library_state(vid, "done", converted_path=str(converted))
    resp = client.get(f"/videos/{vid}/stream", headers=AUTH)
    assert resp.status_code == 200
    assert resp.content == b"converted-bytes"


def test_stream_library_passthrough_serves_original(client, tmp_path):
    import db
    vid, src = make_library_row(tmp_path, name="ep.mp4")
    db.set_library_state(vid, "done")  # passthrough: no converted_path
    resp = client.get(f"/videos/{vid}/stream", headers=AUTH)
    assert resp.status_code == 200
    assert resp.content == b"fake"


def test_stream_unprepared_library_is_409(client, tmp_path):
    vid, _ = make_library_row(tmp_path)
    assert client.get(f"/videos/{vid}/stream", headers=AUTH).status_code == 409


def test_ssr_page_appends_stream_token(client, tmp_path):
    vid, f = make_done_download_video(tmp_path)
    try:
        html = client.get("/videos").text
        assert f"/videos/{vid}/stream?token=test-secret" in html
    finally:
        f.unlink(missing_ok=True)
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `python -m pytest tests/test_api.py -v -k stream`
Expected: new tests FAIL (200 without token, 404 for library rows).

- [ ] **Step 3: Implement**

In `main.py`, add below `_check_token`:

```python
def _check_token_or_query(request: Request):
    """Bearer auth with a ?token= fallback for HTML <video> tags, which can't send headers."""
    token = os.getenv("UPLOAD_TOKEN", "")
    if not token:
        raise HTTPException(status_code=503, detail="Upload not configured")
    auth = request.headers.get("Authorization", "")
    if auth.startswith("Bearer ") and secrets.compare_digest(auth[7:], token):
        return
    query_token = request.query_params.get("token", "")
    if query_token and secrets.compare_digest(query_token, token):
        return
    raise HTTPException(status_code=401, detail="Unauthorized")
```

Replace the guard section at the top of `stream_video` (keep the Range/206 logic untouched):

```python
@app.get("/videos/{video_id}/stream")
async def stream_video(video_id: int, request: Request):
    _check_token_or_query(request)
    video = db.get_video(video_id)
    if not video or video.get("deleted_at"):
        raise HTTPException(status_code=404, detail="Video not found or not ready")

    if video.get("source") == "library":
        if video["status"] != "done":
            raise HTTPException(status_code=409, detail="Video not prepared yet")
        file_path = Path(video["converted_path"] or video["source_path"])
        mime = "video/mp4"
    else:
        if video["status"] != "done" or not video["filename"]:
            raise HTTPException(status_code=404, detail="Video not found or not ready")
        file_path = VIDEOS_DIR / video["filename"]
        mime = _guess_mime(video["filename"])

    if not file_path.exists():
        raise HTTPException(status_code=404, detail="Video file missing")

    file_size = file_path.stat().st_size
    range_header = request.headers.get("Range")
    # ... existing Range / StreamingResponse code unchanged from here ...
```

In `views/templates.py`, add `import os` at the top, and change line 114:

```python
                <source src="/videos/{v['id']}/stream?token={escape(os.getenv('UPLOAD_TOKEN', ''))}" type="video/mp4">
```

Check the page's inline JS: `grep -n "stream" views/templates.py` — `resolveVideoSource`/`preloadEntireVideo` read the `<source src>`/`currentSrc`, which now carries the token, so no JS change; if any JS builds `/videos/{id}/stream` from scratch, append the same `?token=` there.

Update existing stream tests in `tests/test_api.py` that now get 401: add `headers=AUTH` (or `?token=test-secret`) to their requests.

- [ ] **Step 4: Run tests, verify pass; full suite**

Run: `python -m pytest tests/ -v` — expected: PASS (including updated legacy stream tests).

- [ ] **Step 5: Commit**

```bash
git add main.py views/templates.py tests/test_api.py
git commit -m "feat: token-gate streaming, resolve library paths, SSR token"
```

---

### Task 9: Preview proxy endpoint + env docs

**Files:**
- Modify: `main.py`, `.env.example`
- Test: `tests/test_api.py`

**Interfaces:**
- Produces: `GET /videos/{id}/preview[?kind=show]` (Bearer or `?token=`) — JPEG bytes, disk-cached under `data/previews/{rating_key}.jpg`; 404 for non-library/missing key.
- Consumes: `plex.fetch_thumb`.

- [ ] **Step 1: Write failing tests**

Append to `tests/test_api.py`:

```python
def test_preview_proxies_and_caches(client, tmp_path, monkeypatch):
    import plex
    vid, _ = make_library_row(tmp_path)
    calls = []

    def fake_thumb(rating_key):
        calls.append(rating_key)
        return b"jpegbytes"

    monkeypatch.setattr(plex, "fetch_thumb", fake_thumb)
    monkeypatch.setattr("main.PREVIEWS_DIR", tmp_path / "previews")

    assert client.get(f"/videos/{vid}/preview").status_code == 401

    resp = client.get(f"/videos/{vid}/preview", headers=AUTH)
    assert resp.status_code == 200
    assert resp.content == b"jpegbytes"
    assert resp.headers["content-type"] == "image/jpeg"
    assert calls == ["1264"]

    resp = client.get(f"/videos/{vid}/preview", headers=AUTH)  # served from disk cache
    assert resp.status_code == 200 and calls == ["1264"]

    resp = client.get(f"/videos/{vid}/preview?kind=show", headers=AUTH)
    assert resp.status_code == 200 and calls == ["1264", "1262"]


def test_preview_404_for_download_rows(client, monkeypatch):
    import db
    vid = db.add_video("https://twitter.com/x/status/77", platform="twitter")
    assert client.get(f"/videos/{vid}/preview", headers=AUTH).status_code == 404
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `python -m pytest tests/test_api.py -v -k preview`
Expected: FAIL with 404 (route missing).

- [ ] **Step 3: Implement**

In `main.py` add near `VIDEOS_DIR`:

```python
PREVIEWS_DIR = Path("data/previews")
```

Add endpoint (before the stream endpoint, both live under `/videos/{video_id}/`):

```python
@app.get("/videos/{video_id}/preview")
async def video_preview(video_id: int, request: Request, kind: str = "item"):
    _check_token_or_query(request)
    video = db.get_video(video_id)
    if not video or video.get("source") != "library" or video.get("deleted_at"):
        raise HTTPException(status_code=404, detail="No preview")
    rating_key = video.get("show_rating_key") if kind == "show" else video.get("plex_rating_key")
    if not rating_key:
        raise HTTPException(status_code=404, detail="No preview")

    cache_file = PREVIEWS_DIR / f"{rating_key}.jpg"
    if not cache_file.exists():
        try:
            content = await asyncio.to_thread(plex.fetch_thumb, rating_key)
        except plex.PlexError as exc:
            raise HTTPException(status_code=502, detail=str(exc)) from exc
        PREVIEWS_DIR.mkdir(parents=True, exist_ok=True)
        cache_file.write_bytes(content)

    return Response(
        content=cache_file.read_bytes(),
        media_type="image/jpeg",
        headers={"Cache-Control": "public, max-age=86400"},
    )
```

Append to `.env.example`:

```
# Plex library integration
PLEX_URL=http://localhost:32400
PLEX_TOKEN=
```

- [ ] **Step 4: Run tests, verify pass; full suite**

Run: `python -m pytest tests/ -v` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add main.py .env.example tests/test_api.py
git commit -m "feat: Plex thumbnail proxy with disk cache"
```

---

### Task 10: iOS — Video model fields

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/Video.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoTests.swift`

**Interfaces:**
- Produces: `Video` gains `public let source: String?`, `showTitle: String?`, `season: Int?`, `episode: Int?`, `summary: String?`, `showPreviewUrl: String?`. Convenience `public var isLibrary: Bool { source == "library" }`.

- [ ] **Step 1: Write failing test**

Append to `VideoTests.swift` (match the file's existing decode-test style):

```swift
func testDecodesLibraryFields() throws {
    let json = """
    {"id": 7, "url": "/vol/ep.mkv", "title": "System", "platform": null,
     "source_key": null, "preview_url": "/videos/7/preview",
     "classification": "tv", "position": 3, "status": "unconverted",
     "error_msg": null, "stream_path": "/videos/7/stream",
     "source": "library", "show_title": "The Bear", "season": 1,
     "episode": 1, "summary": "Carmy.", "show_preview_url": "/videos/7/preview?kind=show"}
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let video = try decoder.decode(Video.self, from: json)
    XCTAssertEqual(video.source, "library")
    XCTAssertTrue(video.isLibrary)
    XCTAssertEqual(video.showTitle, "The Bear")
    XCTAssertEqual(video.season, 1)
    XCTAssertEqual(video.episode, 1)
    XCTAssertEqual(video.summary, "Carmy.")
    XCTAssertEqual(video.showPreviewUrl, "/videos/7/preview?kind=show")
}

func testDecodesLegacyPayloadWithoutLibraryFields() throws {
    let json = """
    {"id": 1, "url": "https://x.com/s/1", "title": null, "platform": "twitter",
     "source_key": null, "preview_url": null, "classification": "children",
     "position": 1, "status": "done", "error_msg": null,
     "stream_path": "/videos/1/stream"}
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let video = try decoder.decode(Video.self, from: json)
    XCTAssertNil(video.source)
    XCTAssertFalse(video.isLibrary)
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `cd ios/PatataTubeKit && swift test`
Expected: FAIL — `value of type 'Video' has no member 'source'`.

- [ ] **Step 3: Implement**

Replace `Video.swift`:

```swift
public struct Video: Codable, Identifiable, Equatable, Sendable {
    public let id: Int
    public let url: String
    public let title: String?
    public let platform: String?
    public let sourceKey: String?
    public let previewUrl: String?
    public let classification: String
    public let position: Int?
    public let status: String
    public let errorMsg: String?
    public let streamPath: String
    public let source: String?
    public let showTitle: String?
    public let season: Int?
    public let episode: Int?
    public let summary: String?
    public let showPreviewUrl: String?

    public var isLibrary: Bool { source == "library" }

    public init(id: Int, url: String, title: String?, platform: String?,
                sourceKey: String?, previewUrl: String?, classification: String,
                position: Int?, status: String, errorMsg: String?, streamPath: String,
                source: String? = nil, showTitle: String? = nil, season: Int? = nil,
                episode: Int? = nil, summary: String? = nil, showPreviewUrl: String? = nil) {
        self.id = id; self.url = url; self.title = title; self.platform = platform
        self.sourceKey = sourceKey; self.previewUrl = previewUrl
        self.classification = classification; self.position = position
        self.status = status; self.errorMsg = errorMsg; self.streamPath = streamPath
        self.source = source; self.showTitle = showTitle; self.season = season
        self.episode = episode; self.summary = summary; self.showPreviewUrl = showPreviewUrl
    }

    func withClassification(_ c: String) -> Video {
        Video(id: id, url: url, title: title, platform: platform, sourceKey: sourceKey,
              previewUrl: previewUrl, classification: c, position: position,
              status: status, errorMsg: errorMsg, streamPath: streamPath,
              source: source, showTitle: showTitle, season: season,
              episode: episode, summary: summary, showPreviewUrl: showPreviewUrl)
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `cd ios/PatataTubeKit && swift test` — expected: PASS (all Kit tests — existing `Video(...)` call sites in tests compile because new params are defaulted).

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/Video.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoTests.swift
git commit -m "feat(ios): library metadata fields on Video"
```

---

### Task 11: iOS — ShowGroup grouping

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/ShowGroup.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/ShowGroupTests.swift`

**Interfaces:**
- Produces: `public struct ShowGroup: Identifiable, Equatable, Hashable, Sendable` with `title: String`, `episodes: [Video]` (sorted by season, then episode), `id: String` (= title), `posterPath: String?`, `static func group(_ videos: [Video]) -> [ShowGroup]` (alphabetical by title; ignores videos without `showTitle`), `func seasons() -> [(number: Int, episodes: [Video])]`.

- [ ] **Step 1: Write failing tests**

Create `ShowGroupTests.swift`:

```swift
import XCTest
@testable import PatataTubeKit

final class ShowGroupTests: XCTestCase {
    private func episode(_ id: Int, show: String, season: Int, ep: Int) -> Video {
        Video(id: id, url: "/x", title: "E\(ep)", platform: nil, sourceKey: nil,
              previewUrl: nil, classification: "tv", position: id, status: "unconverted",
              errorMsg: nil, streamPath: "/videos/\(id)/stream", source: "library",
              showTitle: show, season: season, episode: ep,
              summary: nil, showPreviewUrl: "/videos/\(id)/preview?kind=show")
    }

    func testGroupsAndSorts() {
        let videos = [
            episode(1, show: "The Bear", season: 2, ep: 1),
            episode(2, show: "Bluey", season: 1, ep: 3),
            episode(3, show: "The Bear", season: 1, ep: 2),
            episode(4, show: "The Bear", season: 1, ep: 1),
        ]
        let groups = ShowGroup.group(videos)
        XCTAssertEqual(groups.map(\.title), ["Bluey", "The Bear"])
        XCTAssertEqual(groups[1].episodes.map(\.id), [4, 3, 1])
        XCTAssertEqual(groups[1].posterPath, "/videos/4/preview?kind=show")
    }

    func testSeasonsSplit() {
        let groups = ShowGroup.group([
            episode(1, show: "The Bear", season: 2, ep: 1),
            episode(2, show: "The Bear", season: 1, ep: 1),
        ])
        let seasons = groups[0].seasons()
        XCTAssertEqual(seasons.map(\.number), [1, 2])
        XCTAssertEqual(seasons[1].episodes.map(\.id), [1])
    }

    func testIgnoresVideosWithoutShowTitle() {
        let movie = Video(id: 9, url: "/m", title: "Akira", platform: nil, sourceKey: nil,
                          previewUrl: nil, classification: "movies", position: 9,
                          status: "done", errorMsg: nil, streamPath: "/videos/9/stream",
                          source: "library")
        XCTAssertTrue(ShowGroup.group([movie]).isEmpty)
    }
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `cd ios/PatataTubeKit && swift test`
Expected: FAIL — `cannot find 'ShowGroup' in scope`.

- [ ] **Step 3: Create `ShowGroup.swift`**

```swift
import Foundation

/// Client-side grouping of library TV episodes into shows.
public struct ShowGroup: Identifiable, Equatable, Hashable, Sendable {
    public let title: String
    /// Sorted by season, then episode.
    public let episodes: [Video]

    public var id: String { title }
    public var posterPath: String? { episodes.first?.showPreviewUrl }

    public static func group(_ videos: [Video]) -> [ShowGroup] {
        let grouped = Dictionary(grouping: videos.filter { $0.showTitle != nil },
                                 by: { $0.showTitle! })
        return grouped
            .map { title, episodes in
                ShowGroup(title: title, episodes: episodes.sorted {
                    ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0)
                })
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    public func seasons() -> [(number: Int, episodes: [Video])] {
        let grouped = Dictionary(grouping: episodes, by: { $0.season ?? 0 })
        return grouped.keys.sorted().map { (number: $0, episodes: grouped[$0]!) }
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `cd ios/PatataTubeKit && swift test` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/ShowGroup.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/ShowGroupTests.swift
git commit -m "feat(ios): ShowGroup episode grouping"
```

---

### Task 12: iOS — APIClient scan/prepare/single-video/image

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/APIClient.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/APIClientLibraryTests.swift` (create)

**Interfaces:**
- Produces (added to `VideoAPI` protocol and `APIClient`):
  - `func scanLibrary() async throws -> ScanResult` — `public struct ScanResult: Decodable, Equatable, Sendable { public let added: Int; public let updated: Int; public let skipped: Int }`
  - `func prepare(id: Int) async throws -> String` (the returned `status` string)
  - `func video(id: Int) async throws -> Video`
  - `func imageData(path: String) async throws -> Data` — relative path → base URL + Bearer header; absolute `http(s)` URL → plain fetch.
- Consumes: `MockURLProtocol` test helper already in the Kit tests.

- [ ] **Step 1: Write failing tests**

Create `APIClientLibraryTests.swift`. Read `MockURLProtocol.swift` and `APIClientReadTests.swift` first and copy their session/stub setup exactly (helper names may differ slightly; adapt):

```swift
import XCTest
@testable import PatataTubeKit

final class APIClientLibraryTests: XCTestCase {
    private func makeClient(handler: @escaping (URLRequest) -> (Int, Data)) -> APIClient {
        MockURLProtocol.handler = { request in
            let (status, data) = handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: nil, headerFields: nil)!
            return (response, data)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let store = InMemoryCredentialStore()
        store.baseURL = URL(string: "https://example.test")
        store.token = "secret"
        return APIClient(store: store, session: URLSession(configuration: config))
    }

    func testScanLibrary() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/library/scan")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            return (200, #"{"added": 3, "updated": 1, "skipped": 2}"#.data(using: .utf8)!)
        }
        let result = try await client.scanLibrary()
        XCTAssertEqual(result, ScanResult(added: 3, updated: 1, skipped: 2))
    }

    func testPrepare() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/videos/7/prepare")
            return (202, #"{"status": "converting"}"#.data(using: .utf8)!)
        }
        let status = try await client.prepare(id: 7)
        XCTAssertEqual(status, "converting")
    }

    func testFetchSingleVideo() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/videos/7")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            let body = #"{"id": 7, "url": "/x", "title": null, "platform": null,
                "source_key": null, "preview_url": null, "classification": "tv",
                "position": 1, "status": "done", "error_msg": null,
                "stream_path": "/videos/7/stream", "source": "library"}"#
            return (200, body.data(using: .utf8)!)
        }
        let video = try await client.video(id: 7)
        XCTAssertEqual(video.id, 7)
        XCTAssertEqual(video.status, "done")
    }

    func testImageDataRelativePathIsAuthed() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.absoluteString,
                           "https://example.test/videos/7/preview?kind=show")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            return (200, Data([0xFF, 0xD8]))
        }
        let data = try await client.imageData(path: "/videos/7/preview?kind=show")
        XCTAssertEqual(data, Data([0xFF, 0xD8]))
    }

    func testImageDataAbsoluteURLSkipsAuth() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.host, "i.ytimg.com")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, Data([0x01]))
        }
        _ = try await client.imageData(path: "https://i.ytimg.com/vi/x/hqdefault.jpg")
    }
}
```

If the Kit has no `InMemoryCredentialStore`, check `CredentialStoreTests.swift`/`VideoStoreTests.swift` for the existing in-memory test double and use that; create one in the test target only if none exists:

```swift
final class InMemoryCredentialStore: CredentialStore {
    var baseURL: URL?
    var token: String?
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `cd ios/PatataTubeKit && swift test`
Expected: FAIL — `no member 'scanLibrary'`.

- [ ] **Step 3: Implement in `APIClient.swift`**

Add to the file (outside the class):

```swift
public struct ScanResult: Decodable, Equatable, Sendable {
    public let added: Int
    public let updated: Int
    public let skipped: Int

    public init(added: Int, updated: Int, skipped: Int) {
        self.added = added; self.updated = updated; self.skipped = skipped
    }
}
```

Add to the `VideoAPI` protocol:

```swift
    func scanLibrary() async throws -> ScanResult
    func prepare(id: Int) async throws -> String
    func video(id: Int) async throws -> Video
    func imageData(path: String) async throws -> Data
```

Add to `APIClient`:

```swift
    public func scanLibrary() async throws -> ScanResult {
        let data = try await authedPost("api/library/scan", body: [:])
        do { return try Self.makeDecoder().decode(ScanResult.self, from: data) }
        catch { throw APIError.decoding(String(describing: error)) }
    }

    public func prepare(id: Int) async throws -> String {
        let data = try await authedPost("api/videos/\(id)/prepare", body: [:])
        struct Result: Decodable { let status: String }
        do { return try JSONDecoder().decode(Result.self, from: data).status }
        catch { throw APIError.decoding(String(describing: error)) }
    }

    public func video(id: Int) async throws -> Video {
        let data = try await authedGet("api/videos/\(id)")
        do { return try Self.makeDecoder().decode(Video.self, from: data) }
        catch { throw APIError.decoding(String(describing: error)) }
    }

    /// Fetches image bytes. Relative paths hit the configured server with Bearer auth;
    /// absolute URLs (e.g. YouTube thumbnails) are fetched as-is.
    public func imageData(path: String) async throws -> Data {
        if let absolute = URL(string: path), absolute.scheme?.hasPrefix("http") == true {
            let (data, response) = try await session.data(from: absolute)
            try Self.check(response)
            return data
        }
        return try await authedGet(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    private func authedGet(_ path: String) async throws -> Data {
        guard let token = store.token, !token.isEmpty else { throw APIError.notConfigured }
        // appendingPathComponent would percent-encode "?", so build from the full string.
        guard let url = URL(string: path, relativeTo: try base().appendingPathComponent("/")) else {
            throw APIError.notConfigured
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try Self.check(response)
        return data
    }
```

Note: any other `VideoAPI` conformances in tests (mocks in `VideoStoreTests.swift`) must gain the four new methods — add simple stubs there (`fatalError("unused")` or fixed returns) to keep compilation green.

- [ ] **Step 4: Run tests, verify pass**

Run: `cd ios/PatataTubeKit && swift test` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/APIClient.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/APIClientLibraryTests.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoStoreTests.swift
git commit -m "feat(ios): library API methods on APIClient"
```

---

### Task 13: iOS — VideoStore refresh + ensureReady

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/VideoStore.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoStoreTests.swift`

**Interfaces:**
- Produces: `VideoStore.refreshLibrary() async` (scan then reload; scan errors land in `errorText` but the reload still runs), `VideoStore.ensureReady(id: Int, pollIntervalSeconds: Double = 2.0) async throws -> Video`, `public enum PrepareError: Error, Equatable { case conversionFailed(String) }`.
- Consumes: Task 12 API methods.

- [ ] **Step 1: Write failing tests**

Open `VideoStoreTests.swift`, find the existing mock `VideoAPI` implementation, extend it so the new protocol methods are scriptable, then append:

```swift
    func testRefreshLibraryScansThenReloads() async {
        let api = MockVideoAPI()   // adapt to the file's actual mock type name
        api.scanResult = ScanResult(added: 2, updated: 0, skipped: 1)
        api.videosResult = [TestFixtures.video(id: 1)]  // adapt to existing fixture helpers
        let store = await VideoStore(api: api)
        await store.refreshLibrary()
        let videos = await store.videos
        XCTAssertEqual(api.scanCalls, 1)
        XCTAssertEqual(videos.map(\.id), [1])
    }

    func testEnsureReadyPollsUntilDone() async throws {
        let api = MockVideoAPI()
        api.prepareResult = "converting"
        api.videoResults = [
            TestFixtures.video(id: 7, status: "converting"),
            TestFixtures.video(id: 7, status: "converting"),
            TestFixtures.video(id: 7, status: "done"),
        ]
        let store = await VideoStore(api: api)
        let ready = try await store.ensureReady(id: 7, pollIntervalSeconds: 0.01)
        XCTAssertEqual(ready.status, "done")
        XCTAssertEqual(api.videoCalls, 3)
    }

    func testEnsureReadyThrowsOnConversionError() async {
        let api = MockVideoAPI()
        api.prepareResult = "converting"
        api.videoResults = [
            TestFixtures.video(id: 7, status: "unconverted", errorMsg: "ffmpeg exploded"),
        ]
        let store = await VideoStore(api: api)
        do {
            _ = try await store.ensureReady(id: 7, pollIntervalSeconds: 0.01)
            XCTFail("expected throw")
        } catch let error as PrepareError {
            XCTAssertEqual(error, .conversionFailed("ffmpeg exploded"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
```

Extend the mock with the needed knobs (adapt names to the file):

```swift
    var scanResult = ScanResult(added: 0, updated: 0, skipped: 0)
    var scanCalls = 0
    var prepareResult = "done"
    var videoResults: [Video] = []
    var videoCalls = 0

    func scanLibrary() async throws -> ScanResult { scanCalls += 1; return scanResult }
    func prepare(id: Int) async throws -> String { prepareResult }
    func video(id: Int) async throws -> Video {
        videoCalls += 1
        return videoResults.isEmpty ? TestFixtures.video(id: id)
            : videoResults[min(videoCalls, videoResults.count) - 1]
    }
    func imageData(path: String) async throws -> Data { Data() }
```

If there is no `TestFixtures.video` helper, use whatever inline `Video(...)` construction the file already uses, adding `status:`/`errorMsg:` arguments as needed.

- [ ] **Step 2: Run tests, verify they fail**

Run: `cd ios/PatataTubeKit && swift test`
Expected: FAIL — `no member 'refreshLibrary'`.

- [ ] **Step 3: Implement in `VideoStore.swift`**

Add outside the class:

```swift
public enum PrepareError: Error, Equatable {
    case conversionFailed(String)
}
```

Add inside `VideoStore`:

```swift
    /// Scan the server-side Plex library, then reload the list.
    /// A failed scan surfaces in errorText but still refreshes the list.
    public func refreshLibrary() async {
        do {
            _ = try await api.scanLibrary()
        } catch {
            errorText = String(describing: error)
        }
        await load()
    }

    /// Kicks off server-side conversion (if needed) and polls until the video
    /// is streamable. Throws PrepareError when the server reports a failed conversion.
    public func ensureReady(id: Int, pollIntervalSeconds: Double = 2.0) async throws -> Video {
        let status = try await api.prepare(id: id)
        if status == "done" {
            return try await api.video(id: id)
        }
        while true {
            let video = try await api.video(id: id)
            if video.status == "done" { return video }
            if let message = video.errorMsg, !message.isEmpty {
                throw PrepareError.conversionFailed(message)
            }
            try await Task.sleep(nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000))
        }
    }
```

- [ ] **Step 4: Run tests, verify pass**

Run: `cd ios/PatataTubeKit && swift test` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/VideoStore.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoStoreTests.swift
git commit -m "feat(ios): library refresh and prepare-poll in VideoStore"
```

---

### Task 14: iOS — CacheManager bearer auth

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift`

**Interfaces:**
- Produces: `download(id:from:preview:bearerToken:)` — new optional `bearerToken: String? = nil` last parameter; when set, both the video download and the preview fetch send `Authorization: Bearer <token>`. Existing call sites compile unchanged.

- [ ] **Step 1: Write failing test**

Append to `CacheManagerTests.swift` (reuse its MockURLProtocol setup):

```swift
    func testDownloadSendsBearerToken() async throws {
        var seenAuth: [String?] = []
        MockURLProtocol.handler = { request in
            seenAuth.append(request.value(forHTTPHeaderField: "Authorization"))
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data("video".utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let manager = CacheManager(root: FileManager.default.temporaryDirectory
                                       .appendingPathComponent(UUID().uuidString),
                                   session: URLSession(configuration: config))
        try await manager.download(id: 7,
                                   from: URL(string: "https://example.test/videos/7/stream")!,
                                   preview: URL(string: "https://example.test/videos/7/preview")!,
                                   bearerToken: "secret")
        XCTAssertEqual(seenAuth, ["Bearer secret", "Bearer secret"])
    }
```

Note: `MockURLProtocol` must support `session.download(for:)`; if the existing mock only implements data tasks, downloads still route through `URLProtocol` — if the test errors on the download step, check how existing CacheManager tests stub downloads and mirror that.

- [ ] **Step 2: Run test, verify it fails**

Run: `cd ios/PatataTubeKit && swift test`
Expected: FAIL — `extra argument 'bearerToken'`.

- [ ] **Step 3: Implement**

In `CacheManager.swift`, replace `download` and `cachePreview`:

```swift
    public func download(id: Int, from remote: URL, preview: URL? = nil,
                         bearerToken: String? = nil) async throws {
        lock.withLock { inFlight[id] = 0 }
        do {
            var request = URLRequest(url: remote)
            if let bearerToken {
                request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
            }
            let (tempURL, response) = try await session.download(for: request)
            lock.withLock { inFlight[id] = nil }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw APIError.badStatus(http.statusCode)
            }
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let destination = localURL(for: id)
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: tempURL, to: destination)
        } catch {
            lock.withLock { inFlight[id] = nil }
            throw error
        }
        // Best-effort: a missing preview must not fail the cached video.
        if let preview { try? await cachePreview(id: id, from: preview, bearerToken: bearerToken) }
    }

    private func cachePreview(id: Int, from remote: URL, bearerToken: String? = nil) async throws {
        var request = URLRequest(url: remote)
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.badStatus(http.statusCode)
        }
        let ext = remote.pathExtension.lowercased()
        let safeExt = (1...4).contains(ext.count) && ext.allSatisfy(\.isLetter) ? ext : "jpg"
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("\(id).preview.\(safeExt)")
        try? fileManager.removeItem(at: destination)
        try data.write(to: destination)
    }
```

- [ ] **Step 4: Run tests, verify pass**

Run: `cd ios/PatataTubeKit && swift test` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift
git commit -m "feat(ios): bearer auth on cache downloads"
```

---

### Task 15: iOS — app UI (refresh, shows, preparing gate, authed playback)

**Files:**
- Create: `ios/PatataTube/Sources/AuthedImage.swift`, `ios/PatataTube/Sources/ShowsView.swift`, `ios/PatataTube/Sources/EpisodesView.swift`
- Modify: `ios/PatataTube/Sources/VideoGridView.swift`, `ios/PatataTube/Sources/VideoCell.swift`, `ios/PatataTube/Sources/VideoPlayerView.swift`
- Test: no automated app-target tests exist; gate is a clean `xcodegen generate` + Xcode build plus the Kit suite.

**Interfaces:**
- Consumes: `ShowGroup`, `VideoStore.refreshLibrary/ensureReady`, `APIClient.imageData`, `CacheManager.download(bearerToken:)`, `model.credentials.token`.

- [ ] **Step 1: Create `AuthedImage.swift`**

```swift
// ios/PatataTube/Sources/AuthedImage.swift
import SwiftUI
import PatataTubeKit

/// Image loaded through APIClient so token-gated server previews work.
/// Absolute URLs (YouTube thumbs) load without auth; local file URLs load directly.
struct AuthedImage: View {
    let path: String?
    var localFileURL: URL? = nil
    @EnvironmentObject var model: AppModel
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ProgressView()
            }
        }
        .task(id: path) { await loadImage() }
    }

    private func loadImage() async {
        if let localFileURL, let data = try? Data(contentsOf: localFileURL) {
            image = UIImage(data: data)
            return
        }
        guard let path else { return }
        if let data = try? await model.api.imageData(path: path) {
            image = UIImage(data: data)
        }
    }
}
```

- [ ] **Step 2: Update `VideoCell.swift` preview to use it**

Replace the `AsyncImage` block (lines 26–31) and the `previewURL` helper:

```swift
                    if video.previewUrl != nil || cachedPreviewURL != nil {
                        AuthedImage(path: video.previewUrl, localFileURL: cachedPreviewURL)
                            .clipped()
                    }
```

Delete the now-unused `previewURL` computed property. Also change the status badge condition from `video.status != "completed"` to `video.status != "done"` (pre-existing bug: the server's terminal status is `done`, so the badge never hid; with library rows the badge must clear once prepared).

- [ ] **Step 3: Create `ShowsView.swift` and `EpisodesView.swift`**

```swift
// ios/PatataTube/Sources/ShowsView.swift
import SwiftUI
import PatataTubeKit

/// Grid of TV shows; tap navigates to that show's episodes.
struct ShowsView: View {
    let videos: [Video]
    let onPlay: (Video) -> Void
    let onDownload: (Video) -> Void

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 16)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(ShowGroup.group(videos)) { show in
                NavigationLink(value: show) {
                    VStack(alignment: .leading, spacing: 6) {
                        AuthedImage(path: show.posterPath)
                            .aspectRatio(2.0/3.0, contentMode: .fit)
                            .background(.secondary.opacity(0.2))
                            .cornerRadius(8)
                        Text(show.title).font(.subheadline).lineLimit(2)
                        Text("\(show.episodes.count) episodes")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .navigationDestination(for: ShowGroup.self) { show in
            EpisodesView(show: show, onPlay: onPlay, onDownload: onDownload)
        }
    }
}
```

```swift
// ios/PatataTube/Sources/EpisodesView.swift
import SwiftUI
import PatataTubeKit

/// Episode list for one show, sectioned by season.
struct EpisodesView: View {
    let show: ShowGroup
    let onPlay: (Video) -> Void
    let onDownload: (Video) -> Void
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            ForEach(show.seasons(), id: \.number) { season in
                Section("Season \(season.number)") {
                    ForEach(season.episodes) { episode in
                        row(for: episode)
                    }
                }
            }
        }
        .navigationTitle(show.title)
    }

    private func row(for episode: Video) -> some View {
        HStack(spacing: 12) {
            AuthedImage(path: episode.previewUrl)
                .frame(width: 120, height: 68)
                .background(.secondary.opacity(0.2))
                .cornerRadius(6)
                .clipped()
            VStack(alignment: .leading, spacing: 4) {
                Text("E\(episode.episode ?? 0) — \(episode.title ?? "Untitled")")
                    .font(.subheadline)
                if let summary = episode.summary {
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            switch model.cache.state(for: episode.id) {
            case .cached:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .downloading(let p):
                ProgressView(value: p)
            case .notCached:
                Button { onDownload(episode) } label: { Image(systemName: "arrow.down.circle") }
                    .buttonStyle(.plain)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onPlay(episode) }
    }
}
```

- [ ] **Step 4: Wire `VideoGridView.swift`**

Changes:
1. Delete the hardcoded classification default; keep server-driven: `@State private var classifications: [String] = ["children", "adults", "education", "tv", "movies"]`.
2. Add states: `@State private var preparing = false`.
3. Toolbar — add a refresh button next to the plus:

```swift
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await store.refreshLibrary() }
                    } label: {
                        if store.isLoading { ProgressView() }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                }
```

4. Body — when the `tv` filter is active, render shows instead of the flat grid:

```swift
            ScrollView {
                filterTabs
                if store.filter == "tv" {
                    ShowsView(videos: store.videos,
                              onPlay: { play($0) },
                              onDownload: { download($0) })
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        // ... existing ForEach unchanged, but onPlay: { play(video) },
                        //     onDownload: { download(video) }
                    }
                    .padding()
                }
            }
```

5. Prepare gate — new `play` helper plus a preparing overlay:

```swift
    private func play(_ video: Video) {
        guard video.isLibrary, video.status != "done" else {
            playing = video
            return
        }
        preparing = true
        Task {
            defer { preparing = false }
            do {
                playing = try await store.ensureReady(id: video.id)
            } catch {
                store.errorText = String(describing: error)
            }
        }
    }
```

Overlay (add alongside the existing error banner overlay):

```swift
            .overlay {
                if preparing {
                    ZStack {
                        Color.black.opacity(0.4).ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Preparing…").foregroundStyle(.white)
                        }
                        .padding(24)
                        .background(.thinMaterial)
                        .cornerRadius(12)
                    }
                }
            }
```

6. Download gate — replace `download`:

```swift
    private func download(_ video: Video) {
        Task {
            var target = video
            if video.isLibrary, video.status != "done" {
                preparing = true
                defer { preparing = false }
                do { target = try await store.ensureReady(id: video.id) }
                catch { store.errorText = String(describing: error); return }
            }
            guard let url = model.streamURL(for: target) else { return }
            let preview: URL?
            if let p = target.previewUrl {
                preview = p.hasPrefix("http") ? URL(string: p)
                    : model.credentials.baseURL?.appendingPathComponent(
                        p.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            } else { preview = nil }
            try? await model.cache.download(id: target.id, from: url, preview: preview,
                                            bearerToken: model.credentials.token)
        }
    }
```

- [ ] **Step 5: Authed playback in `VideoPlayerView.swift`**

Replace `setup()`:

```swift
    private func setup() {
        let player: AVPlayer
        if model.cache.state(for: video.id) == .cached {
            player = AVPlayer(url: model.cache.localURL(for: video.id))
        } else {
            guard let url = model.streamURL(for: video) else { return }
            var options: [String: Any] = [:]
            if let token = model.credentials.token {
                options["AVURLAssetHTTPHeaderFieldsKey"] = ["Authorization": "Bearer \(token)"]
            }
            let asset = AVURLAsset(url: url, options: options)
            player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        }
        self.player = player
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem, queue: .main
        ) { _ in dismiss() }
    }
```

- [ ] **Step 6: Build and verify**

Run: `cd ios/PatataTubeKit && swift test` — expected: PASS.
Run: `cd ios/PatataTube && xcodegen generate` — expected: project generates. Build for iPad simulator:
`xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPad mini (6th generation)' build` (if that simulator name is unavailable, list with `xcrun simctl list devices` and pick an iPad). Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add ios/PatataTube/Sources/
git commit -m "feat(ios): library UI - refresh, shows navigation, preparing gate, authed playback"
```

---

### Task 16: Docs + manual test checklist

**Files:**
- Modify: `ios/README.md`, `CLAUDE.md`

**Interfaces:** none — documentation.

- [ ] **Step 1: Append to the manual test checklist in `ios/README.md`**

```markdown
### Plex library

- [ ] Settings has valid base URL + token; tap the refresh (↻) toolbar button — spinner shows, then movie/TV items appear.
- [ ] "movies" tab shows the movie grid with Plex posters.
- [ ] "tv" tab shows one card per show with poster + episode count; tapping opens seasons → episodes with thumbs and summaries.
- [ ] Playing an unprepared mkv episode shows "Preparing…", then plays (remux takes seconds).
- [ ] Playing an already-compatible mp4 movie starts without any conversion wait.
- [ ] Downloading an unprepared episode prepares first, then caches; airplane mode playback works from cache.
- [ ] Delete on a library video removes it from the list; the original file on /Volumes/Media is untouched; a later refresh does not resurrect it.
- [ ] A conversion failure (e.g. unplug the Media volume mid-convert) shows an error and the episode can be retried.
```

- [ ] **Step 2: Update `CLAUDE.md`**

In the Architecture section, append a short subsection:

```markdown
### Plex library (library rows)

- `plex.py` fetches metadata from the local Plex server (`PLEX_URL`/`PLEX_TOKEN`); its JSON contains raw control characters, so it parses with `json.loads(text, strict=False)`.
- `library.py` owns scanning (`scan_library`) and on-demand ffmpeg conversion (`convert_library_video`): passthrough / remux / transcode per the iPad codec policy (`plan_conversion`), converted file written as a sibling `{name}.mp4`.
- Library rows live in the same `videos` table with `source='library'`, statuses `unconverted → converting → done`; failures set `error_msg` and revert to `unconverted` (never row-delete). Deletes tombstone via `deleted_at` and never touch `source_path`.
- Stream endpoint is token-gated (Bearer or `?token=`); library previews proxy Plex thumbs at `/videos/{id}/preview` with a disk cache in `data/previews/`.
```

- [ ] **Step 3: Full verification**

Run: `python -m pytest tests/` — expected: PASS.
Run: `cd ios/PatataTubeKit && swift test` — expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add ios/README.md CLAUDE.md
git commit -m "docs: Plex library architecture and manual test checklist"
```
