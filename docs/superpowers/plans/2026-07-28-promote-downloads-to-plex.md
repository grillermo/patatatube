# Promote Downloads to Plex Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Classifying a *downloaded* video as `tv` or `movies` physically moves its file into the Plex-managed library directory, hard-deletes the PatataTube row, and asks Plex to rescan — so the video comes back later as a normal library row.

**Architecture:** A new `promote.py` owns the move: destination resolution (env-overridable), title sanitization, collision-free naming, copy-to-temp + `os.replace` + unlink source, then `hls.invalidate` → `db.delete_video` → best-effort Plex section refresh. `services.apply_classification` (the choke point both the SSR form and the JSON API already share) routes tv/movies + non-library rows into it and returns a `ClassificationResult` so callers can tell a promotion from an ordinary classify. On the client, `VideoAPI.classify` returns a `ClassifyResult { ok, promoted }`; `VideoStore` drops a promoted video from the list and purges its cached MP4 through a new narrow `MediaCaching` dependency.

**Tech Stack:** Python 3.13 / FastAPI / SQLite (`db.py`) / httpx (`plex.py`) / pytest. Swift 6 / SwiftPM package `ios/PatataTubeKit` / swift-testing (`@Test`, `#expect`).

## Global Constraints

- Only rows with `source != 'library'` are ever moved. Library rows keep their Plex-derived classification and are never touched by this feature.
- Only `status == 'done'` rows are movable.
- Destination directories: `LIBRARY_MOVIES_DIR` (default `/Volumes/Media/media/movies`), `LIBRARY_TV_DIR` (default `/Volumes/Media/media/tv`). Read per-call via `os.getenv`, never cached at import — matches the `FFMPEG_BIN`/`LIBRARY_AUDIO_LANGS` convention in this repo.
- Layout is flat for **both** classifications: `<dest dir>/<sanitized title>.mp4`. No per-item folders, no `Show/Season NN/` structure.
- The row is **hard-deleted** (`db.delete_video`), never tombstoned. Tombstones are for library rows only.
- Failure changes nothing: no classification write, no row delete, source file still in `videos/`. The endpoint returns **409**.
- `videos/` and `/Volumes/Media` are different filesystems. `os.rename` across them raises `EXDEV` — the move MUST be copy-to-temp-in-destination + `os.replace` + unlink source.
- Plex refresh is best-effort. A failed refresh never fails the request and never rolls anything back.
- Tests that reload `db`/`main`/`services` must follow the existing env-var-reload fixture pattern (`tests/test_api.py::client`, `tests/test_services.py::fresh_db`) because those modules read env at import time.
- Every async test carries `@pytest.mark.asyncio` (no global asyncio mode). None of the tests in this plan are async.

---

## File Structure

**Create:**
- `promote.py` — the whole move: destination resolution, naming, copy/replace/unlink, cleanup, row delete, Plex refresh trigger. One responsibility: turning a download row into a file Plex owns.
- `tests/test_promote.py` — unit tests for `promote.py` against `tmp_path` directories.
- `ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoStorePromoteTests.swift` — store-level tests for the promoted-removal path.

**Modify:**
- `plex.py` — add `refresh_sections(section_type)`.
- `services.py` — `apply_classification` returns `ClassificationResult`, routes promotions.
- `router.py:262-283` (`upload_file`), `:691-695` (SSR classify), `:718-722` (API classify) — reject tv/movies at upload, translate `PromotionError` → 409, expose `promoted`.
- `tests/test_services.py`, `tests/test_api.py`, `tests/test_plex.py` — cover the new behavior.
- `ios/PatataTubeKit/Sources/PatataTubeKit/APIClient.swift` — `ClassifyResult`, protocol signature change.
- `ios/PatataTubeKit/Sources/PatataTubeKit/VideoStore.swift` — `MediaCaching` dep, promoted-removal branch.
- `ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoStoreTests.swift`, `APIClientReadTests.swift` — update `FakeAPI` and the classify test to the new return type.
- `ios/PatataTube/Sources/AppModel.swift:65` — inject `CacheManager` into `VideoStore`.
- `.env.example` — document the two new vars.

---

### Task 1: Destination resolution and filename derivation

Pure functions with no side effects beyond `Path.exists()`. Everything the move needs to decide *where* the file goes.

**Files:**
- Create: `promote.py`
- Test: `tests/test_promote.py`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `PromotionError(RuntimeError)`
  - `PROMOTED_CLASSIFICATIONS: frozenset[str]` — `{"movies", "tv"}`
  - `dest_dir(classification: str) -> Path`
  - `sanitize_title(title: str | None, video_id: int) -> str`
  - `unique_target(directory: Path, stem: str) -> Path`
  - `VIDEOS_DIR: Path` — `Path("videos")`, monkeypatched by tests

- [ ] **Step 1: Write the failing tests**

Create `tests/test_promote.py`:

```python
from pathlib import Path

import pytest

import promote


def test_dest_dir_defaults_to_the_plex_media_volume(monkeypatch):
    monkeypatch.delenv("LIBRARY_MOVIES_DIR", raising=False)
    monkeypatch.delenv("LIBRARY_TV_DIR", raising=False)
    assert promote.dest_dir("movies") == Path("/Volumes/Media/media/movies")
    assert promote.dest_dir("tv") == Path("/Volumes/Media/media/tv")


def test_dest_dir_reads_env_on_every_call(monkeypatch, tmp_path):
    monkeypatch.setenv("LIBRARY_MOVIES_DIR", str(tmp_path / "films"))
    assert promote.dest_dir("movies") == tmp_path / "films"
    monkeypatch.setenv("LIBRARY_MOVIES_DIR", str(tmp_path / "other"))
    assert promote.dest_dir("movies") == tmp_path / "other"


def test_dest_dir_rejects_a_non_library_classification():
    with pytest.raises(promote.PromotionError):
        promote.dest_dir("children")


def test_promoted_classifications_are_tv_and_movies():
    assert promote.PROMOTED_CLASSIFICATIONS == frozenset({"tv", "movies"})


def test_sanitize_title_strips_path_and_reserved_characters():
    assert promote.sanitize_title('Rick & Morty: S01/E02?', 7) == "Rick & Morty S01 E02"


def test_sanitize_title_falls_back_to_the_video_id():
    assert promote.sanitize_title(None, 7) == "video-7"
    assert promote.sanitize_title("   ...  ", 7) == "video-7"


def test_sanitize_title_caps_length_at_150_characters():
    assert promote.sanitize_title("a" * 200, 7) == "a" * 150


def test_unique_target_uses_the_plain_name_when_free(tmp_path):
    assert promote.unique_target(tmp_path, "Akira") == tmp_path / "Akira.mp4"


def test_unique_target_suffixes_past_a_collision(tmp_path):
    (tmp_path / "Akira.mp4").write_bytes(b"")
    (tmp_path / "Akira (2).mp4").write_bytes(b"")
    assert promote.unique_target(tmp_path, "Akira") == tmp_path / "Akira (3).mp4"


def test_unique_target_gives_up_after_fifty_collisions(tmp_path):
    (tmp_path / "Akira.mp4").write_bytes(b"")
    for n in range(2, 51):
        (tmp_path / f"Akira ({n}).mp4").write_bytes(b"")
    with pytest.raises(promote.PromotionError):
        promote.unique_target(tmp_path, "Akira")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tests/test_promote.py -v`
Expected: FAIL — collection error, `ModuleNotFoundError: No module named 'promote'`.

- [ ] **Step 3: Write the implementation**

Create `promote.py`:

```python
"""Move a finished download into the Plex-managed library on disk.

Classifying a downloaded video as tv/movies hands it over to Plex: the file
lands in Plex's own directory and the PatataTube row goes away. It comes back
on a later scan_library() as a normal library row.
"""

import os
import re
from pathlib import Path

VIDEOS_DIR = Path("videos")

# Classification -> (env var holding its Plex directory, default path).
_DEST_ENV = {
    "movies": ("LIBRARY_MOVIES_DIR", "/Volumes/Media/media/movies"),
    "tv": ("LIBRARY_TV_DIR", "/Volumes/Media/media/tv"),
}

PROMOTED_CLASSIFICATIONS = frozenset(_DEST_ENV)

# Path separators, Windows/SMB-reserved characters, and control characters.
_UNSAFE = re.compile(r'[\\/:*?"<>|\x00-\x1f]')


class PromotionError(RuntimeError):
    """Raised when a video cannot be moved into the Plex library."""


def dest_dir(classification: str) -> Path:
    """Plex directory for a classification, read per-call so env changes apply."""
    try:
        env_name, default = _DEST_ENV[classification]
    except KeyError:
        raise PromotionError(f"not a library classification: {classification}") from None
    return Path(os.getenv(env_name, default))


def sanitize_title(title: str | None, video_id: int) -> str:
    """Filename stem from a video title; Plex matches movies on the filename."""
    cleaned = _UNSAFE.sub(" ", title or "")
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    cleaned = cleaned[:150].strip(" .")
    return cleaned or f"video-{video_id}"


def unique_target(directory: Path, stem: str) -> Path:
    """`{stem}.mp4` in directory, suffixed ` (2)`, ` (3)`... past a collision."""
    target = directory / f"{stem}.mp4"
    if not target.exists():
        return target
    for n in range(2, 51):
        target = directory / f"{stem} ({n}).mp4"
        if not target.exists():
            return target
    raise PromotionError(f"no free filename for {stem!r} in {directory}")
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python -m pytest tests/test_promote.py -v`
Expected: PASS, 9 passed.

- [ ] **Step 5: Commit**

```bash
git add promote.py tests/test_promote.py
git commit -m "feat: add destination and filename rules for Plex promotion"
```

---

### Task 2: The move itself

Copy → replace → unlink → invalidate HLS → delete row. No Plex call yet (Task 3).

**Files:**
- Modify: `promote.py`
- Test: `tests/test_promote.py`

**Interfaces:**
- Consumes: `promote.dest_dir`, `promote.sanitize_title`, `promote.unique_target`, `promote.VIDEOS_DIR`, `promote.PromotionError` (Task 1); `db.delete_video(video_id)`, `db.get_video(video_id)`, `db.add_video(url, platform=None, source_key=None, title=None, preview_url=None) -> int`, `db.update_video(video_id, status, filename=None, ...)`, `hls.invalidate(video_id)` (existing).
- Produces: `promote_to_plex(video: dict, classification: str) -> Path` — takes the row dict from `db.get_video`, returns the new on-disk path.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_promote.py`:

```python
import importlib


@pytest.fixture()
def promote_env(monkeypatch, tmp_path):
    """Fresh db + a videos/ dir and a Plex movies/tv dir, all under tmp_path."""
    monkeypatch.setenv("DB_PATH", str(tmp_path / "test.db"))
    import db
    importlib.reload(db)
    db.init_db()

    videos_dir = tmp_path / "videos"
    videos_dir.mkdir()
    movies_dir = tmp_path / "movies"
    movies_dir.mkdir()
    tv_dir = tmp_path / "tv"
    tv_dir.mkdir()

    importlib.reload(promote)
    monkeypatch.setattr(promote, "VIDEOS_DIR", videos_dir)
    monkeypatch.setenv("LIBRARY_MOVIES_DIR", str(movies_dir))
    monkeypatch.setenv("LIBRARY_TV_DIR", str(tv_dir))
    # Most tests do not want to talk to Plex. The real function is stashed under
    # _real_refresh_plex so the few tests that do can put it back.
    monkeypatch.setattr(promote, "_real_refresh_plex", promote._refresh_plex, raising=False)
    monkeypatch.setattr(promote, "_refresh_plex", lambda classification: None)
    return db, videos_dir, movies_dir, tv_dir


def _finished_download(db, videos_dir, title="Akira", body=b"video-bytes"):
    video_id = db.add_video("https://youtu.be/abc", platform="youtube", title=title)
    (videos_dir / f"{video_id}.mp4").write_bytes(body)
    db.update_video(video_id, "done", filename=f"{video_id}.mp4")
    return video_id


def test_promote_moves_the_file_and_deletes_the_row(promote_env):
    db, videos_dir, movies_dir, _ = promote_env
    video_id = _finished_download(db, videos_dir)

    target = promote.promote_to_plex(db.get_video(video_id), "movies")

    assert target == movies_dir / "Akira.mp4"
    assert target.read_bytes() == b"video-bytes"
    assert not (videos_dir / f"{video_id}.mp4").exists()
    assert db.get_video(video_id) is None


def test_promote_leaves_no_temp_file_behind(promote_env):
    db, videos_dir, movies_dir, _ = promote_env
    promote.promote_to_plex(db.get_video(_finished_download(db, videos_dir)), "movies")
    assert sorted(p.name for p in movies_dir.iterdir()) == ["Akira.mp4"]


def test_promote_uses_the_tv_directory_for_tv(promote_env):
    db, videos_dir, _, tv_dir = promote_env
    video_id = _finished_download(db, videos_dir, title="Chef Show")
    assert promote.promote_to_plex(db.get_video(video_id), "tv") == tv_dir / "Chef Show.mp4"


def test_promote_invalidates_the_hls_package_before_deleting(promote_env, monkeypatch):
    db, videos_dir, _, _ = promote_env
    invalidated = []
    import hls
    monkeypatch.setattr(hls, "invalidate", invalidated.append)
    video_id = _finished_download(db, videos_dir)

    promote.promote_to_plex(db.get_video(video_id), "movies")

    assert invalidated == [video_id]


def test_promote_refuses_a_library_row(promote_env):
    db, _, _, _ = promote_env
    video = {"id": 1, "source": "library", "status": "done", "filename": "1.mp4"}
    with pytest.raises(promote.PromotionError):
        promote.promote_to_plex(video, "movies")


def test_promote_refuses_a_download_still_in_progress(promote_env):
    db, videos_dir, _, _ = promote_env
    video_id = db.add_video("https://youtu.be/abc", platform="youtube", title="Akira")
    with pytest.raises(promote.PromotionError):
        promote.promote_to_plex(db.get_video(video_id), "movies")
    assert db.get_video(video_id) is not None


def test_promote_refuses_when_the_file_is_gone(promote_env):
    db, videos_dir, _, _ = promote_env
    video_id = _finished_download(db, videos_dir)
    (videos_dir / f"{video_id}.mp4").unlink()
    with pytest.raises(promote.PromotionError):
        promote.promote_to_plex(db.get_video(video_id), "movies")
    assert db.get_video(video_id) is not None


def test_promote_refuses_when_the_media_volume_is_not_mounted(promote_env, monkeypatch, tmp_path):
    db, videos_dir, _, _ = promote_env
    monkeypatch.setenv("LIBRARY_MOVIES_DIR", str(tmp_path / "not-mounted"))
    video_id = _finished_download(db, videos_dir)

    with pytest.raises(promote.PromotionError):
        promote.promote_to_plex(db.get_video(video_id), "movies")

    assert (videos_dir / f"{video_id}.mp4").exists()
    assert db.get_video(video_id) is not None


def test_promote_suffixes_a_colliding_name(promote_env):
    db, videos_dir, movies_dir, _ = promote_env
    (movies_dir / "Akira.mp4").write_bytes(b"already here")
    video_id = _finished_download(db, videos_dir)

    target = promote.promote_to_plex(db.get_video(video_id), "movies")

    assert target == movies_dir / "Akira (2).mp4"
    assert (movies_dir / "Akira.mp4").read_bytes() == b"already here"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tests/test_promote.py -v -k promote_`
Expected: FAIL with `AttributeError: module 'promote' has no attribute '_refresh_plex'` (raised inside the fixture).

- [ ] **Step 3: Write the implementation**

In `promote.py`, add `logging`, `shutil`, `db`, `hls` to the imports and append the move:

```python
import logging
import shutil

import db
import hls

logger = logging.getLogger(__name__)
```

```python
def _refresh_plex(classification: str) -> None:
    """Placeholder until Task 3 wires the real Plex scan trigger."""


def promote_to_plex(video: dict, classification: str) -> Path:
    """Move a finished download into its Plex directory and drop its row.

    Returns the new path. On any failure nothing changes: the source file stays
    in videos/, the row stays, and no classification is written.
    """
    if video.get("source") == "library":
        raise PromotionError("library videos are managed by Plex already")
    if video.get("status") != "done":
        raise PromotionError(f"video {video['id']} is not downloaded yet")
    filename = video.get("filename")
    if not filename:
        raise PromotionError(f"video {video['id']} has no file")
    source = VIDEOS_DIR / filename
    if not source.exists():
        raise PromotionError(f"file missing: {source}")

    directory = dest_dir(classification)
    if not directory.is_dir():
        raise PromotionError(f"library directory is unavailable: {directory}")

    target = unique_target(directory, sanitize_title(video.get("title"), video["id"]))
    # videos/ lives on the boot volume and the library on /Volumes/Media, so a
    # plain os.rename would fail with EXDEV. Copy to a hidden sibling of the
    # target first: that replace is same-volume and atomic, so Plex never picks
    # up a half-written file, and the dotfile is invisible to its scanner.
    tmp = target.with_name(f".{target.name}.part")
    try:
        shutil.copyfile(source, tmp)
        os.replace(tmp, target)
    except OSError as exc:
        tmp.unlink(missing_ok=True)
        raise PromotionError(f"could not move {source} to {target}: {exc}") from exc

    source.unlink(missing_ok=True)
    hls.invalidate(video["id"])
    db.delete_video(video["id"])
    _refresh_plex(classification)
    return target
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python -m pytest tests/test_promote.py -v`
Expected: PASS, 18 passed.

- [ ] **Step 5: Commit**

```bash
git add promote.py tests/test_promote.py
git commit -m "feat: move promoted downloads into the Plex library directory"
```

---

### Task 3: Trigger a Plex section scan

**Files:**
- Modify: `plex.py`, `promote.py`
- Test: `tests/test_plex.py`, `tests/test_promote.py`

**Interfaces:**
- Consumes: `plex._get_json(path, params=None)`, `plex._base_url()`, `plex._token()`, `plex.PlexError` (existing); `promote._refresh_plex` (Task 2 placeholder).
- Produces: `plex.refresh_sections(section_type: str) -> int` — number of sections refreshed.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_plex.py`:

```python
def test_refresh_sections_hits_every_matching_section(monkeypatch):
    monkeypatch.setenv("PLEX_TOKEN", "tok")
    monkeypatch.setattr(plex, "_get_json", fake_get_json)
    called = []

    def fake_get(url, params=None, timeout=None, trust_env=None):
        called.append(url)
        return httpx.Response(200, request=httpx.Request("GET", url))

    monkeypatch.setattr(plex.httpx, "get", fake_get)

    assert plex.refresh_sections("movie") == 1
    assert called == ["http://localhost:32400/library/sections/1/refresh"]


def test_refresh_sections_picks_show_sections_for_tv(monkeypatch):
    monkeypatch.setenv("PLEX_TOKEN", "tok")
    monkeypatch.setattr(plex, "_get_json", fake_get_json)
    called = []

    def fake_get(url, params=None, timeout=None, trust_env=None):
        called.append(url)
        return httpx.Response(200, request=httpx.Request("GET", url))

    monkeypatch.setattr(plex.httpx, "get", fake_get)

    assert plex.refresh_sections("show") == 1
    assert called == ["http://localhost:32400/library/sections/2/refresh"]


def test_refresh_sections_raises_plex_error_on_transport_failure(monkeypatch):
    monkeypatch.setenv("PLEX_TOKEN", "tok")
    monkeypatch.setattr(plex, "_get_json", fake_get_json)

    def fake_get(url, params=None, timeout=None, trust_env=None):
        raise httpx.ConnectError("refused")

    monkeypatch.setattr(plex.httpx, "get", fake_get)

    with pytest.raises(plex.PlexError):
        plex.refresh_sections("movie")
```

Append to `tests/test_promote.py`:

```python
def test_promote_asks_plex_to_rescan_the_matching_section(promote_env, monkeypatch):
    db, videos_dir, _, _ = promote_env
    monkeypatch.setenv("PLEX_TOKEN", "tok")
    # The fixture stubbed _refresh_plex out; put the real one back for this test.
    monkeypatch.setattr(promote, "_refresh_plex", promote._real_refresh_plex)
    refreshed = []
    import plex
    monkeypatch.setattr(plex, "refresh_sections", lambda t: refreshed.append(t) or 1)

    promote.promote_to_plex(db.get_video(_finished_download(db, videos_dir)), "movies")

    assert refreshed == ["movie"]


def test_promote_survives_a_plex_refresh_failure(promote_env, monkeypatch):
    db, videos_dir, movies_dir, _ = promote_env
    monkeypatch.setenv("PLEX_TOKEN", "tok")
    import plex

    def boom(section_type):
        raise plex.PlexError("plex is down")

    monkeypatch.setattr(promote, "_refresh_plex", promote._real_refresh_plex)
    monkeypatch.setattr(plex, "refresh_sections", boom)
    video_id = _finished_download(db, videos_dir)

    assert promote.promote_to_plex(db.get_video(video_id), "movies") == movies_dir / "Akira.mp4"
    assert db.get_video(video_id) is None


def test_promote_skips_the_plex_call_without_a_token(promote_env, monkeypatch):
    db, videos_dir, _, _ = promote_env
    monkeypatch.delenv("PLEX_TOKEN", raising=False)
    import plex

    def boom(section_type):
        raise AssertionError("must not call Plex without a token")

    monkeypatch.setattr(promote, "_refresh_plex", promote._real_refresh_plex)
    monkeypatch.setattr(plex, "refresh_sections", boom)

    promote.promote_to_plex(db.get_video(_finished_download(db, videos_dir)), "movies")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tests/test_plex.py tests/test_promote.py -v -k refresh`
Expected: FAIL with `AttributeError: module 'plex' has no attribute 'refresh_sections'`.

- [ ] **Step 3: Write the implementation**

Append to `plex.py`:

```python
def refresh_sections(section_type: str) -> int:
    """Ask Plex to rescan every section of a type ('movie' or 'show').

    Returns how many sections were told to refresh. Plex answers immediately
    and scans in the background, so this does not wait for indexing.
    """
    sections = _get_json("/library/sections")["MediaContainer"].get("Directory", [])
    keys = [s["key"] for s in sections if s.get("type") == section_type]
    for key in keys:
        try:
            resp = httpx.get(
                f"{_base_url()}/library/sections/{key}/refresh",
                params={"X-Plex-Token": _token()},
                timeout=30,
                trust_env=False,
            )
            resp.raise_for_status()
        except httpx.HTTPError as exc:
            raise PlexError(f"Plex refresh failed: {exc}") from exc
    return len(keys)
```

Replace the `_refresh_plex` placeholder in `promote.py` and add `import plex` at the top:

```python
def _refresh_plex(classification: str) -> None:
    """Best-effort rescan: the file is already in place, so a failure is not fatal."""
    if not os.getenv("PLEX_TOKEN"):
        return
    try:
        plex.refresh_sections("movie" if classification == "movies" else "show")
    except Exception as exc:  # noqa: BLE001 - never fail an already-completed move
        logger.warning("Plex refresh after promoting to %s failed: %s", classification, exc)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python -m pytest tests/test_plex.py tests/test_promote.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add plex.py promote.py tests/test_plex.py tests/test_promote.py
git commit -m "feat: trigger a Plex section rescan after promoting a download"
```

---

### Task 4: Wire promotion into the classify endpoints

**Files:**
- Modify: `services.py`, `router.py:262-283`, `router.py:691-695`, `router.py:718-722`, `.env.example`
- Test: `tests/test_services.py`, `tests/test_api.py`

**Interfaces:**
- Consumes: `promote.promote_to_plex(video, classification)`, `promote.PROMOTED_CLASSIFICATIONS`, `promote.PromotionError` (Tasks 1-3); `db.get_video`, `db.set_video_classification`, `CLASSIFICATIONS` (existing).
- Produces: `services.ClassificationResult(ok: bool, promoted: bool = False)` — frozen dataclass; `services.apply_classification(video_id, classification) -> ClassificationResult` (return type changed from `bool`). API response gains `"promoted": bool`.

- [ ] **Step 1: Write the failing tests**

Rewrite the two existing tests in `tests/test_services.py` for the new return type and add the promotion tests:

```python
def test_apply_classification_accepts_valid(fresh_db):
    db, services = fresh_db
    vid = db.add_video("https://twitter.com/x/status/1")
    result = services.apply_classification(vid, "adults")
    assert (result.ok, result.promoted) == (True, False)
    assert db.get_video(vid)["classification"] == "adults"


def test_apply_classification_rejects_invalid(fresh_db):
    db, services = fresh_db
    vid = db.add_video("https://twitter.com/x/status/1")
    db.set_video_classification(vid, "children")
    result = services.apply_classification(vid, "bogus")
    assert (result.ok, result.promoted) == (False, False)
    assert db.get_video(vid)["classification"] == "children"


def test_apply_classification_promotes_a_download_to_movies(fresh_db, monkeypatch):
    db, services = fresh_db
    import promote
    moved = []
    monkeypatch.setattr(
        promote, "promote_to_plex",
        lambda video, classification: moved.append((video["id"], classification)),
    )
    vid = db.add_video("https://youtu.be/abc")
    db.update_video(vid, "done", filename=f"{vid}.mp4")

    result = services.apply_classification(vid, "movies")

    assert (result.ok, result.promoted) == (True, True)
    assert moved == [(vid, "movies")]


def test_apply_classification_leaves_library_rows_alone(fresh_db, monkeypatch):
    db, services = fresh_db
    import promote
    monkeypatch.setattr(
        promote, "promote_to_plex",
        lambda video, classification: pytest.fail("library rows must not move"),
    )
    video_id, _ = db.upsert_library_video({
        "source_path": "/media/movies/x.mkv",
        "title": "X",
        "classification": "movies",
        "versions": [{"source_path": "/media/movies/x.mkv", "label": "1080p"}],
    })

    result = services.apply_classification(video_id, "tv")

    assert (result.ok, result.promoted) == (True, False)
    assert db.get_video(video_id)["classification"] == "tv"


def test_apply_classification_propagates_a_promotion_failure(fresh_db, monkeypatch):
    db, services = fresh_db
    import promote

    def boom(video, classification):
        raise promote.PromotionError("library directory is unavailable")

    monkeypatch.setattr(promote, "promote_to_plex", boom)
    vid = db.add_video("https://youtu.be/abc")
    db.update_video(vid, "done", filename=f"{vid}.mp4")
    db.set_video_classification(vid, "children")

    with pytest.raises(promote.PromotionError):
        services.apply_classification(vid, "movies")

    assert db.get_video(vid)["classification"] == "children"
```

Add to `tests/test_api.py`:

```python
def test_api_classify_to_movies_promotes_and_reports_it(client, monkeypatch, tmp_path):
    import db
    import promote
    videos_dir = tmp_path / "videos"
    videos_dir.mkdir()
    movies_dir = tmp_path / "movies"
    movies_dir.mkdir()
    monkeypatch.setattr(promote, "VIDEOS_DIR", videos_dir)
    monkeypatch.setenv("LIBRARY_MOVIES_DIR", str(movies_dir))
    monkeypatch.setattr(promote, "_refresh_plex", lambda classification: None)
    video_id = db.add_video("https://youtu.be/abc", platform="youtube", title="Akira")
    (videos_dir / f"{video_id}.mp4").write_bytes(b"bytes")
    db.update_video(video_id, "done", filename=f"{video_id}.mp4")

    resp = client.post(
        f"/api/videos/{video_id}/classify",
        json={"classification": "movies"},
        headers={"Authorization": "Bearer test-secret"},
    )

    assert resp.status_code == 200
    assert resp.json() == {"ok": True, "promoted": True}
    assert (movies_dir / "Akira.mp4").exists()
    assert db.get_video(video_id) is None


def test_api_classify_to_children_does_not_promote(client, monkeypatch):
    import db
    video_id = db.add_video("https://youtu.be/abc", platform="youtube", title="Akira")
    db.update_video(video_id, "done", filename=f"{video_id}.mp4")

    resp = client.post(
        f"/api/videos/{video_id}/classify",
        json={"classification": "children"},
        headers={"Authorization": "Bearer test-secret"},
    )

    assert resp.json() == {"ok": True, "promoted": False}
    assert db.get_video(video_id)["classification"] == "children"


def test_api_classify_returns_409_when_the_move_fails(client, monkeypatch, tmp_path):
    import db
    import promote
    videos_dir = tmp_path / "videos"
    videos_dir.mkdir()
    monkeypatch.setattr(promote, "VIDEOS_DIR", videos_dir)
    monkeypatch.setenv("LIBRARY_MOVIES_DIR", str(tmp_path / "not-mounted"))
    video_id = db.add_video("https://youtu.be/abc", platform="youtube", title="Akira")
    (videos_dir / f"{video_id}.mp4").write_bytes(b"bytes")
    db.update_video(video_id, "done", filename=f"{video_id}.mp4")
    db.set_video_classification(video_id, "children")

    resp = client.post(
        f"/api/videos/{video_id}/classify",
        json={"classification": "movies"},
        headers={"Authorization": "Bearer test-secret"},
    )

    assert resp.status_code == 409
    assert (videos_dir / f"{video_id}.mp4").exists()
    assert db.get_video(video_id)["classification"] == "children"


def test_ssr_classify_returns_409_when_the_move_fails(client, monkeypatch, tmp_path):
    import db
    import promote
    videos_dir = tmp_path / "videos"
    videos_dir.mkdir()
    monkeypatch.setattr(promote, "VIDEOS_DIR", videos_dir)
    monkeypatch.setenv("LIBRARY_MOVIES_DIR", str(tmp_path / "not-mounted"))
    video_id = db.add_video("https://youtu.be/abc", platform="youtube", title="Akira")
    (videos_dir / f"{video_id}.mp4").write_bytes(b"bytes")
    db.update_video(video_id, "done", filename=f"{video_id}.mp4")

    resp = client.post(
        f"/videos/{video_id}/classify",
        data={"classification": "movies"},
        follow_redirects=False,
    )

    assert resp.status_code == 409
    assert db.get_video(video_id) is not None


def test_upload_file_rejects_a_library_classification(client):
    resp = client.post(
        "/upload/file",
        files={"file": ("video.mp4", b"bytes", "video/mp4")},
        data={"classification": "movies"},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 400
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tests/test_services.py tests/test_api.py -v -k "classif or upload_file_rejects"`
Expected: FAIL — `AttributeError: 'bool' object has no attribute 'ok'`.

- [ ] **Step 3: Write the implementation**

Replace `services.py` in full:

```python
"""Mutation logic shared by the SSR form endpoints and the JSON API."""

from dataclasses import dataclass

import db
import hls
import promote
from db import CLASSIFICATIONS


@dataclass(frozen=True)
class ClassificationResult:
    """`promoted` means the file moved into Plex and the row is gone."""

    ok: bool
    promoted: bool = False


def apply_classification(video_id: int, classification: str) -> ClassificationResult:
    """Set a classification, or hand a download over to Plex when it is tv/movies.

    Raises promote.PromotionError when the move fails; nothing is written then.
    """
    if classification not in CLASSIFICATIONS:
        return ClassificationResult(ok=False)
    if classification in promote.PROMOTED_CLASSIFICATIONS:
        video = db.get_video(video_id)
        if video and video.get("source") != "library":
            promote.promote_to_plex(video, classification)
            return ClassificationResult(ok=True, promoted=True)
    db.set_video_classification(video_id, classification)
    return ClassificationResult(ok=True)


def choose_version(video_id: int, version_id: int) -> bool:
    chosen = db.set_chosen_version(video_id, version_id)
    if chosen:
        hls.invalidate(video_id)
    return chosen
```

In `router.py`, add `import promote` alongside the existing `import services`, then change the three call sites.

`router.py:268-270` — reject library classifications before writing the upload to disk:

```python
    _check_token(request)
    if classification not in CLASSIFICATIONS:
        raise HTTPException(status_code=400, detail="Invalid classification")
    if classification in promote.PROMOTED_CLASSIFICATIONS:
        raise HTTPException(
            status_code=400,
            detail="Upload into children/adults/anabel, then classify it to move it into Plex",
        )
```

`router.py:691-695` — the SSR form endpoint:

```python
@router.post("/videos/{video_id}/classify")
async def classify_video_endpoint(video_id: int, classification: str = Form(...), current_classification: str | None = Form(default=None)):
    try:
        services.apply_classification(video_id, classification)
    except promote.PromotionError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    redirect_url = f"/?classification={current_classification}" if current_classification else "/"
    return RedirectResponse(url=redirect_url, status_code=303)
```

`router.py:718-722` — the JSON endpoint:

```python
@router.post("/api/videos/{video_id}/classify")
async def api_classify_video(video_id: int, body: ClassifyRequest, request: Request):
    _check_token(request)
    try:
        result = services.apply_classification(video_id, body.classification)
    except promote.PromotionError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return {"ok": result.ok, "promoted": result.promoted}
```

Append to `.env.example`:

```
# Plex-managed directories. Classifying a downloaded video as movies/tv moves
# its file here and drops the PatataTube row; Plex picks it up on the rescan.
LIBRARY_MOVIES_DIR=/Volumes/Media/media/movies
LIBRARY_TV_DIR=/Volumes/Media/media/tv
```

- [ ] **Step 4: Run the full Python suite**

Run: `python -m pytest tests/ -v`
Expected: PASS. If any other test asserts `apply_classification(...) is True`, update it to `.ok is True` — that is the only signature change.

- [ ] **Step 5: Commit**

```bash
git add services.py router.py .env.example tests/test_services.py tests/test_api.py
git commit -m "feat: classify a download as tv/movies to move it into Plex"
```

---

### Task 5: iOS — carry `promoted` through the API client

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/APIClient.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/APIClientReadTests.swift:104-113`, `ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoStoreTests.swift:14-42,161-187`

**Interfaces:**
- Consumes: the `{"ok": bool, "promoted": bool}` body from Task 4.
- Produces: `public struct ClassifyResult: Decodable, Equatable, Sendable { let ok: Bool; let promoted: Bool }` with `init(ok:promoted:)` defaulting `promoted` to `false`; `VideoAPI.classify(id:classification:) async throws -> ClassifyResult` (was `Bool`).

- [ ] **Step 1: Write the failing test**

Replace `classifySendsBody` in `APIClientReadTests.swift` and add a second case:

```swift
        @Test func classifySendsBody() async throws {
            MockURLProtocol.handler = { req in
                #expect(req.url?.path == "/api/videos/3/classify")
                let json = try JSONSerialization.jsonObject(with: req.httpBodyData()) as! [String: String]
                #expect(json["classification"] == "education")
                return (jsonResponse(req.url!), #"{"ok":false,"promoted":false}"#.data(using: .utf8)!)
            }
            let result = try await makeClient().classify(id: 3, classification: "education")
            #expect(result == ClassifyResult(ok: false, promoted: false))
        }

        @Test func classifyDefaultsPromotedToFalseWhenAbsent() async throws {
            MockURLProtocol.handler = { req in
                (jsonResponse(req.url!), #"{"ok":true}"#.data(using: .utf8)!)
            }
            let result = try await makeClient().classify(id: 3, classification: "children")
            #expect(result == ClassifyResult(ok: true, promoted: false))
        }

        @Test func classifyReportsAPromotion() async throws {
            MockURLProtocol.handler = { req in
                (jsonResponse(req.url!), #"{"ok":true,"promoted":true}"#.data(using: .utf8)!)
            }
            let result = try await makeClient().classify(id: 3, classification: "movies")
            #expect(result == ClassifyResult(ok: true, promoted: true))
        }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios/PatataTubeKit && swift test --filter APIClient`
Expected: FAIL — `cannot find 'ClassifyResult' in scope`.

- [ ] **Step 3: Write the implementation**

In `APIClient.swift`, add below `ScanResult`:

```swift
/// Result of a classify call. `promoted` means the server moved the file into
/// the Plex library and deleted the row — the video no longer exists here.
public struct ClassifyResult: Decodable, Equatable, Sendable {
    public let ok: Bool
    public let promoted: Bool

    public init(ok: Bool, promoted: Bool = false) {
        self.ok = ok
        self.promoted = promoted
    }

    private enum CodingKeys: String, CodingKey { case ok, promoted }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decode(Bool.self, forKey: .ok)
        promoted = try c.decodeIfPresent(Bool.self, forKey: .promoted) ?? false
    }
}
```

Change the protocol requirement (`APIClient.swift:22`):

```swift
    func classify(id: Int, classification: String) async throws -> ClassifyResult
```

Replace the implementation (`APIClient.swift:87-89`):

```swift
    public func classify(id: Int, classification: String) async throws -> ClassifyResult {
        let data = try await authedPost(
            "api/videos/\(id)/classify", body: ["classification": classification]
        )
        do { return try JSONDecoder().decode(ClassifyResult.self, from: data) }
        catch { throw APIError.decoding(String(describing: error)) }
    }
```

Update `FakeAPI` in `VideoStoreTests.swift:16` and `:38-42`:

```swift
    var classifyResult = ClassifyResult(ok: true)
```

```swift
    func classify(id: Int, classification: String) async throws -> ClassifyResult {
        if let mutationError { throw mutationError }
        if throwOnClassify { throw APIError.badStatus(500) }
        return classifyResult
    }
```

And the two assignments that used bools (`VideoStoreTests.swift:163`, `:172`):

```swift
    api.classifyResult = ClassifyResult(ok: true)
```

```swift
    api.classifyResult = ClassifyResult(ok: false)
```

- [ ] **Step 4: Run the tests**

Run: `cd ios/PatataTubeKit && swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/APIClient.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/APIClientReadTests.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoStoreTests.swift
git commit -m "feat: decode the promoted flag from the classify response"
```

---

### Task 6: iOS — drop a promoted video and purge its cache

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/VideoStore.swift:17-32,138-149`, `ios/PatataTube/Sources/AppModel.swift:65`
- Create: `ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoStorePromoteTests.swift`

**Interfaces:**
- Consumes: `ClassifyResult` (Task 5); `CacheManager.removeAllCached(id: Int)` (existing, `CacheManager.swift:623`).
- Produces: `public protocol MediaCaching: Sendable { func removeAllCached(id: Int) }`; `extension CacheManager: MediaCaching {}`; `VideoStore.init(api:cache:mediaCache:defaults:)` with `mediaCache: MediaCaching? = nil`.

- [ ] **Step 1: Write the failing test**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoStorePromoteTests.swift`:

```swift
import Testing
import Foundation
@testable import PatataTubeKit

private final class SpyMediaCache: MediaCaching, @unchecked Sendable {
    private(set) var purged: [Int] = []
    func removeAllCached(id: Int) { purged.append(id) }
}

private final class PromoteAPI: VideoAPI, @unchecked Sendable {
    var videosToReturn: [Video] = []
    var classifyResult = ClassifyResult(ok: true, promoted: true)

    func videos(classification: String?) async throws -> [Video] { videosToReturn }
    func classifications() async throws -> [String] { ["children", "movies"] }
    func classify(id: Int, classification: String) async throws -> ClassifyResult { classifyResult }
    func chooseVersion(id: Int, versionId: Int) async throws -> Bool { true }
    func chooseAudio(id: Int, lang: String) async throws -> Bool { true }
    func upload(url: String) async throws -> Int { 0 }
    func delete(id: Int) async throws -> Bool { true }
    func scanLibrary() async throws -> ScanResult { ScanResult(added: 0, updated: 0, skipped: 0) }
    func prepare(id: Int) async throws -> String { "done" }
    func video(id: Int) async throws -> Video { videosToReturn[0] }
    func imageData(path: String) async throws -> Data { Data() }
}

private func video(_ id: Int) -> Video {
    Video(id: id, url: "u\(id)", title: "t\(id)", platform: nil, sourceKey: nil,
          previewUrl: nil, classification: "children", position: id,
          status: "completed", errorMsg: nil, streamPath: "/videos/\(id)/stream",
          chosenVersionId: nil, versions: [])
}

@MainActor @Test func classifyRemovesAPromotedVideoFromTheList() async {
    let api = PromoteAPI(); api.videosToReturn = [video(1), video(2)]
    api.classifyResult = ClassifyResult(ok: true, promoted: true)
    let store = VideoStore(api: api)
    await store.load()

    await store.classify(id: 1, to: "movies")

    #expect(store.videos.map(\.id) == [2])
    #expect(store.errorText == nil)
}

@MainActor @Test func classifyPurgesTheCachedFileOfAPromotedVideo() async {
    let api = PromoteAPI(); api.videosToReturn = [video(1)]
    api.classifyResult = ClassifyResult(ok: true, promoted: true)
    let spy = SpyMediaCache()
    let store = VideoStore(api: api, mediaCache: spy)
    await store.load()

    await store.classify(id: 1, to: "movies")

    #expect(spy.purged == [1])
}

@MainActor @Test func classifyKeepsTheVideoWhenNotPromoted() async {
    let api = PromoteAPI(); api.videosToReturn = [video(1)]
    api.classifyResult = ClassifyResult(ok: true, promoted: false)
    let spy = SpyMediaCache()
    let store = VideoStore(api: api, mediaCache: spy)
    await store.load()

    await store.classify(id: 1, to: "adults")

    #expect(store.videos.map(\.id) == [1])
    #expect(store.videos[0].classification == "adults")
    #expect(spy.purged.isEmpty)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios/PatataTubeKit && swift test --filter VideoStorePromote`
Expected: FAIL — `cannot find type 'MediaCaching' in scope`.

- [ ] **Step 3: Write the implementation**

In `VideoStore.swift`, add above the class:

```swift
/// The one thing VideoStore needs from CacheManager: dropping a video's
/// downloaded files once the server says the video is gone.
public protocol MediaCaching: Sendable {
    func removeAllCached(id: Int)
}
```

Add the stored property next to `cache` (`VideoStore.swift:18`) and widen the init:

```swift
    private let mediaCache: MediaCaching?
```

```swift
    public init(api: VideoAPI, cache: VideoListCaching? = nil,
                mediaCache: MediaCaching? = nil, defaults: UserDefaults = .standard) {
        self.api = api
        self.cache = cache
        self.mediaCache = mediaCache
        self.defaults = defaults
        self.filter = defaults.string(forKey: Self.filterKey)
    }
```

Replace `classify` (`VideoStore.swift:138-149`):

```swift
    /// Optimistically re-buckets the video. A `promoted` response means the
    /// server moved the file into Plex and deleted the row, so the video is
    /// dropped from the list and its download purged instead.
    public func classify(id: Int, to classification: String) async {
        guard let index = videos.firstIndex(where: { $0.id == id }) else { return }
        let previous = videos
        videos[index] = videos[index].withClassification(classification)
        do {
            let result = try await api.classify(id: id, classification: classification)
            if result.promoted {
                videos.removeAll { $0.id == id }
                mediaCache?.removeAllCached(id: id)
            } else if !result.ok {
                videos = previous
            }
        } catch {
            videos = previous
            report(error)
        }
    }
```

In `CacheManager.swift`, add at the end of the file:

```swift
extension CacheManager: MediaCaching {}
```

In `AppModel.swift:65`:

```swift
        self.store = VideoStore(api: api, cache: videoListCache, mediaCache: cache)
```

- [ ] **Step 4: Run the tests and build the app target**

Run: `cd ios/PatataTubeKit && swift test`
Expected: PASS.

Run: `cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS' build`
Expected: BUILD SUCCEEDED. (If the scheme name is not `PatataTube`, get it from `xcodebuild -list -project PatataTube.xcodeproj`.) This step exists to catch the one app-shell change — the `AppModel.swift:65` call site; `swift test` alone does not compile it.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/VideoStore.swift ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoStorePromoteTests.swift ios/PatataTube/Sources/AppModel.swift
git commit -m "feat: drop promoted videos from the list and purge their cache"
```

---

### Task 7: Document the behavior

**Files:**
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing code-facing.

- [ ] **Step 1: Update the architecture notes**

In `CLAUDE.md`, under "### Plex library (library rows)", add:

```markdown
### Promoting downloads into Plex

- Classifying a **download** row as `tv` or `movies` hands the file to Plex: `promote.py` copies `videos/{id}.mp4` to `<LIBRARY_TV_DIR|LIBRARY_MOVIES_DIR>/<sanitized title>.mp4` (flat, no folders), unlinks the source, invalidates HLS, **hard-deletes the row**, and best-effort triggers a Plex section rescan. The video reappears later as a library row via `scan_library`.
- The copy is deliberate: `videos/` and `/Volumes/Media` are different filesystems, so `os.rename` raises `EXDEV`. It copies to a hidden `.name.part` inside the destination, then `os.replace`s it — same-volume and atomic, so Plex never scans a partial file.
- Any failure (volume unmounted, collision, permissions) raises `promote.PromotionError` → **409**, and nothing changes: no move, no classification write, no delete.
- **Library** rows never move. Their `tv`/`movies` classification comes from the Plex section they live in (`plex.py`), so reclassifying one only rewrites the column until the next scan.
- `/upload/file` rejects `tv`/`movies` with 400 — a queued upload has no file to move yet.
```

- [ ] **Step 2: Run the full suite one more time**

Run: `python -m pytest tests/ -v && cd ios/PatataTubeKit && swift test`
Expected: PASS on both.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: describe promoting downloads into the Plex library"
```
