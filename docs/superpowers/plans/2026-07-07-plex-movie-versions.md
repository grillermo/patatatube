# Plex Movie Versions Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Store every Plex version of a library movie as an alternate source, let the user pick one from the VideoCell three-dots menu, persist the choice server-side, and track download status per chosen version on iOS.

**Architecture:** A new `video_versions` child table holds one row per Plex `Part` (source file). Each library `videos` row is one movie/episode keyed on `plex_rating_key` and points at a `chosen_version_id`. Conversion, streaming, prepare, and iOS caching all resolve through the chosen version. `videos.status` (library) is kept as a mirror of the chosen version's status so existing status reads keep working. The version table is used uniformly for all library rows (episodes = exactly one version); the picker UI is gated on `versions.count > 1`, which only happens for movies.

**Tech Stack:** FastAPI + SQLite (`db.py`), ffmpeg conversion (`library.py`), Plex HTTP client (`plex.py`), SwiftUI + SwiftPM (`ios/PatataTubeKit`, `ios/PatataTube`).

**Spec:** `docs/superpowers/specs/2026-07-07-plex-movie-versions-design.md`

**Conventions to follow:**
- Async tests need `@pytest.mark.asyncio` individually (no global asyncio mode).
- Integration tests reload `db` then `main` after setting env (see `tests/test_api.py` `client` fixture; `tests/test_services.py` `fresh_db` fixture).
- Run Python tests: `python -m pytest tests/ -q`. Run one: `python -m pytest tests/test_db.py::test_name -v`.
- iOS logic build: `cd ios/PatataTubeKit && swift build`. Kit tests: `swift test`.
- Commit after each task.

---

## Chunk 1: DB schema, migration, and version CRUD

### Task 1: Create `video_versions` table + `chosen_version_id` column

**Files:**
- Modify: `db.py` (`init_db`)
- Test: `tests/test_db.py`

- [ ] **Step 1: Write the failing test**

Add to `tests/test_db.py` (mirror the existing `fresh_db`/reload pattern already used in that file):

```python
def test_video_versions_table_and_chosen_column_exist(fresh_db):
    db = fresh_db
    with db._conn() as conn:
        vcols = {r["name"] for r in conn.execute("PRAGMA table_info(video_versions)")}
        assert {"id", "video_id", "source_path", "converted_path",
                "status", "error_msg", "label", "plex_position"} <= vcols
        cols = {r["name"] for r in conn.execute("PRAGMA table_info(videos)")}
        assert "chosen_version_id" in cols
```

If `tests/test_db.py` has no `fresh_db` fixture, add one identical to `tests/test_services.py`'s (set `DB_PATH`, reload `db`, `db.init_db()`, return `db`).

- [ ] **Step 2: Run test, verify it fails**

Run: `python -m pytest tests/test_db.py::test_video_versions_table_and_chosen_column_exist -v`
Expected: FAIL (no such table `video_versions`).

- [ ] **Step 3: Implement**

In `db.py` `init_db`, after the existing `ALTER TABLE` guards and before the index/backfill block, add:

```python
        conn.executescript("""
            CREATE TABLE IF NOT EXISTS video_versions (
                id             INTEGER PRIMARY KEY AUTOINCREMENT,
                video_id       INTEGER NOT NULL,
                source_path    TEXT NOT NULL,
                converted_path TEXT,
                status         TEXT NOT NULL DEFAULT 'unconverted',
                error_msg      TEXT,
                label          TEXT,
                plex_position  INTEGER NOT NULL DEFAULT 0
            );
        """)
        if "chosen_version_id" not in columns:
            conn.execute("ALTER TABLE videos ADD COLUMN chosen_version_id INTEGER")
        conn.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_video_versions_source_path "
            "ON video_versions(source_path)"
        )
        conn.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_videos_plex_rating_key "
            "ON videos(plex_rating_key) WHERE plex_rating_key IS NOT NULL"
        )
        conn.execute("DROP INDEX IF EXISTS idx_videos_source_path")
```

(`columns` is the set already computed near the top of `init_db`.)

- [ ] **Step 4: Run test, verify it passes**

Run: `python -m pytest tests/test_db.py::test_video_versions_table_and_chosen_column_exist -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add db.py tests/test_db.py
git commit -m "feat(db): add video_versions table and chosen_version_id"
```

---

### Task 2: Backfill existing library rows into `video_versions`

**Files:**
- Modify: `db.py` (`init_db`, new `_backfill_video_versions`)
- Test: `tests/test_db.py`

- [ ] **Step 1: Write the failing test**

```python
def test_backfill_creates_one_version_per_library_row(fresh_db):
    db = fresh_db
    with db._conn() as conn:
        conn.execute(
            "INSERT INTO videos (url, status, classification, source, source_path, "
            "converted_path, plex_rating_key, created_at, position) "
            "VALUES ('/m/a.mkv','done','movies','library','/m/a.mkv','/m/a.mp4','42','t',1)"
        )
    db._backfill_video_versions_public()  # thin wrapper below, or call init_db again
    with db._conn() as conn:
        vid = conn.execute("SELECT id, chosen_version_id FROM videos").fetchone()
        vers = conn.execute("SELECT * FROM video_versions WHERE video_id=?", (vid["id"],)).fetchall()
        assert len(vers) == 1
        assert vers[0]["source_path"] == "/m/a.mkv"
        assert vers[0]["converted_path"] == "/m/a.mp4"
        assert vers[0]["status"] == "done"
        assert vid["chosen_version_id"] == vers[0]["id"]
```

Simplest: don't add a public wrapper; instead call `db.init_db()` a second time (it's idempotent) and assert. Rewrite the test to insert the legacy row, then `db.init_db()`, then assert. Prefer that (tests real idempotency).

- [ ] **Step 2: Run test, verify it fails**

Run: `python -m pytest tests/test_db.py::test_backfill_creates_one_version_per_library_row -v`
Expected: FAIL (no version rows created).

- [ ] **Step 3: Implement**

Add to `db.py`:

```python
def _backfill_video_versions(conn: sqlite3.Connection) -> int:
    rows = conn.execute(
        "SELECT id, source_path, converted_path, status FROM videos "
        "WHERE source = 'library' AND chosen_version_id IS NULL "
        "AND source_path IS NOT NULL"
    ).fetchall()
    changed = 0
    for row in rows:
        cur = conn.execute(
            "INSERT INTO video_versions "
            "(video_id, source_path, converted_path, status, label, plex_position) "
            "VALUES (?, ?, ?, ?, NULL, 0)",
            (row["id"], row["source_path"], row["converted_path"], row["status"]),
        )
        conn.execute(
            "UPDATE videos SET chosen_version_id = ? WHERE id = ?",
            (cur.lastrowid, row["id"]),
        )
        changed += 1
    return changed
```

Call it in `init_db` alongside the other backfills:

```python
        _backfill_video_versions(conn)
```

(Place after `_backfill_library_added_at(conn)`, before `_delete_error_videos(conn)`.)

- [ ] **Step 4: Run test, verify it passes**

Run: `python -m pytest tests/test_db.py -q`
Expected: PASS (new test + existing tests still green).

- [ ] **Step 5: Commit**

```bash
git add db.py tests/test_db.py
git commit -m "feat(db): backfill legacy library rows into video_versions"
```

---

### Task 3: Version read/write helpers

**Files:**
- Modify: `db.py`
- Test: `tests/test_db.py`

- [ ] **Step 1: Write the failing test**

```python
def _insert_movie(db, rating_key="42"):
    with db._conn() as conn:
        cur = conn.execute(
            "INSERT INTO videos (url, status, classification, source, plex_rating_key, "
            "created_at, position) VALUES ('','unconverted','movies','library',?, 't', 1)",
            (rating_key,),
        )
        return cur.lastrowid

def test_version_helpers(fresh_db):
    db = fresh_db
    vid = _insert_movie(db)
    with db._conn() as conn:
        a = conn.execute("INSERT INTO video_versions (video_id, source_path, label, plex_position, status) "
                         "VALUES (?, '/m/1080.mkv', '1080p', 0, 'unconverted')", (vid,)).lastrowid
        b = conn.execute("INSERT INTO video_versions (video_id, source_path, label, plex_position, status) "
                         "VALUES (?, '/m/4k.mkv', '4K', 1, 'unconverted')", (vid,)).lastrowid

    assert [v["id"] for v in db.get_versions(vid)] == [a, b]          # ordered by plex_position
    assert db.get_version(b)["label"] == "4K"

    assert db.set_chosen_version(vid, a) is True
    assert db.get_video(vid)["chosen_version_id"] == a
    assert db.set_chosen_version(vid, 9999) is False                   # not a version of this video

    db.set_version_state(a, "done", converted_path="/m/1080.mp4")
    assert db.get_version(a)["status"] == "done"
    assert db.get_version(a)["converted_path"] == "/m/1080.mp4"
    assert db.get_video(vid)["status"] == "done"                       # mirrored (a is chosen)

    db.set_version_state(b, "converting")
    assert db.get_video(vid)["status"] == "done"                       # b not chosen -> no mirror

    assert db.get_converted_paths() == {"/m/1080.mp4"}
```

- [ ] **Step 2: Run test, verify it fails**

Run: `python -m pytest tests/test_db.py::test_version_helpers -v`
Expected: FAIL (`get_versions` not defined).

- [ ] **Step 3: Implement**

Add to `db.py`:

```python
def get_versions(video_id: int) -> list[dict]:
    with _conn() as conn:
        rows = conn.execute(
            "SELECT * FROM video_versions WHERE video_id = ? ORDER BY plex_position ASC, id ASC",
            (video_id,),
        ).fetchall()
        return [dict(r) for r in rows]


def get_version(version_id: int) -> dict | None:
    with _conn() as conn:
        row = conn.execute(
            "SELECT * FROM video_versions WHERE id = ?", (version_id,)
        ).fetchone()
        return dict(row) if row else None


def set_chosen_version(video_id: int, version_id: int) -> bool:
    with _conn() as conn:
        ver = conn.execute(
            "SELECT status FROM video_versions WHERE id = ? AND video_id = ?",
            (version_id, video_id),
        ).fetchone()
        if not ver:
            return False
        conn.execute(
            "UPDATE videos SET chosen_version_id = ?, status = ? WHERE id = ?",
            (version_id, ver["status"], video_id),
        )
        return True


def set_version_state(
    version_id: int,
    status: str,
    converted_path: str | None = None,
    error_msg: str | None = None,
) -> None:
    """Per-version status update; never deletes. Mirrors to videos.status when
    this version is the chosen one, so existing library status reads stay valid."""
    with _conn() as conn:
        conn.execute(
            "UPDATE video_versions "
            "SET status = ?, converted_path = COALESCE(?, converted_path), error_msg = ? "
            "WHERE id = ?",
            (status, converted_path, error_msg, version_id),
        )
        row = conn.execute(
            "SELECT video_id FROM video_versions WHERE id = ?", (version_id,)
        ).fetchone()
        if row:
            conn.execute(
                "UPDATE videos SET status = ? WHERE id = ? AND chosen_version_id = ?",
                (status, row["video_id"], version_id),
            )
```

Change `get_converted_paths` to read from `video_versions`:

```python
def get_converted_paths() -> set[str]:
    with _conn() as conn:
        rows = conn.execute(
            "SELECT converted_path FROM video_versions WHERE converted_path IS NOT NULL"
        ).fetchall()
        return {r["converted_path"] for r in rows}
```

- [ ] **Step 4: Run test, verify it passes**

Run: `python -m pytest tests/test_db.py -q`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add db.py tests/test_db.py
git commit -m "feat(db): version read/write helpers and status mirror"
```

---

### Task 4: `upsert_library_video` keyed on rating_key with version sync

**Files:**
- Modify: `db.py` (`upsert_library_video`, new `_sync_versions`, `_ensure_chosen_version`)
- Test: `tests/test_db.py`

**Note:** this changes the `item` shape — it now carries a `versions` list and no top-level `source_path`. `plex.py` (Task 6) and `library.scan_library` (Task 7) are updated to match; keep this task's tests self-contained by building `item` dicts directly.

- [ ] **Step 1: Write the failing test**

```python
def _movie_item(rating_key="42", versions=None, added_at=1000):
    return {
        "title": "Akira", "classification": "movies", "show_title": None,
        "season": None, "episode": None, "summary": "s",
        "plex_rating_key": rating_key, "show_rating_key": None, "added_at": added_at,
        "versions": versions if versions is not None else [
            {"source_path": "/m/1080.mkv", "label": "1080p", "plex_position": 0},
            {"source_path": "/m/4k.mkv", "label": "4K", "plex_position": 1},
        ],
    }

def test_upsert_creates_movie_with_versions_and_default_chosen(fresh_db):
    db = fresh_db
    vid, status = db.upsert_library_video(_movie_item())
    assert status == "created"
    vers = db.get_versions(vid)
    assert [v["label"] for v in vers] == ["1080p", "4K"]
    # default chosen = first in plex order
    assert db.get_video(vid)["chosen_version_id"] == vers[0]["id"]

def test_upsert_is_idempotent_and_prunes_removed_versions(fresh_db):
    db = fresh_db
    vid, _ = db.upsert_library_video(_movie_item())
    # Second scan drops the 4K version
    vid2, status = db.upsert_library_video(_movie_item(versions=[
        {"source_path": "/m/1080.mkv", "label": "1080p", "plex_position": 0},
    ]))
    assert vid2 == vid and status == "updated"
    assert [v["source_path"] for v in db.get_versions(vid)] == ["/m/1080.mkv"]

def test_upsert_reassigns_chosen_when_chosen_version_pruned(fresh_db):
    db = fresh_db
    vid, _ = db.upsert_library_video(_movie_item())
    vers = db.get_versions(vid)
    db.set_chosen_version(vid, vers[1]["id"])           # choose 4K
    db.upsert_library_video(_movie_item(versions=[      # 4K disappears
        {"source_path": "/m/1080.mkv", "label": "1080p", "plex_position": 0},
    ]))
    remaining = db.get_versions(vid)
    assert db.get_video(vid)["chosen_version_id"] == remaining[0]["id"]

def test_upsert_respects_tombstone(fresh_db):
    db = fresh_db
    vid, _ = db.upsert_library_video(_movie_item())
    db.tombstone_video(vid)
    _, status = db.upsert_library_video(_movie_item())
    assert status == "tombstoned"
```

- [ ] **Step 2: Run test, verify it fails**

Run: `python -m pytest tests/test_db.py -k upsert -v`
Expected: FAIL (current `upsert_library_video` reads `item["source_path"]`, KeyError).

- [ ] **Step 3: Implement**

Replace `upsert_library_video` in `db.py` and add helpers:

```python
def _sync_versions(conn: sqlite3.Connection, video_id: int, versions: list[dict]) -> None:
    incoming = [v["source_path"] for v in versions]
    if incoming:
        placeholders = ",".join("?" for _ in incoming)
        conn.execute(
            f"DELETE FROM video_versions WHERE video_id = ? "
            f"AND source_path NOT IN ({placeholders})",
            (video_id, *incoming),
        )
    else:
        conn.execute("DELETE FROM video_versions WHERE video_id = ?", (video_id,))
    for v in versions:
        # INSERT OR UPDATE keyed on the unique source_path. Preserve status/
        # converted_path on conflict (a re-scan must not un-convert a version).
        conn.execute(
            "INSERT INTO video_versions (video_id, source_path, label, plex_position, status) "
            "VALUES (?, ?, ?, ?, 'unconverted') "
            "ON CONFLICT(source_path) DO UPDATE SET "
            "  video_id = excluded.video_id, label = excluded.label, "
            "  plex_position = excluded.plex_position",
            (video_id, v["source_path"], v.get("label"), v.get("plex_position", 0)),
        )


def _ensure_chosen_version(conn: sqlite3.Connection, video_id: int) -> None:
    row = conn.execute(
        "SELECT chosen_version_id FROM videos WHERE id = ?", (video_id,)
    ).fetchone()
    chosen = row["chosen_version_id"] if row else None
    valid = None
    if chosen is not None:
        valid = conn.execute(
            "SELECT 1 FROM video_versions WHERE id = ? AND video_id = ?",
            (chosen, video_id),
        ).fetchone()
    if valid:
        return
    first = conn.execute(
        "SELECT id, status FROM video_versions WHERE video_id = ? "
        "ORDER BY plex_position ASC, id ASC LIMIT 1",
        (video_id,),
    ).fetchone()
    if first:
        conn.execute(
            "UPDATE videos SET chosen_version_id = ?, status = ? WHERE id = ?",
            (first["id"], first["status"], video_id),
        )
```

```python
def upsert_library_video(item: dict) -> tuple[int, str]:
    """Insert or update a library movie/episode keyed on plex_rating_key.

    item carries a "versions" list of {source_path, label, plex_position}.
    Returns (video_id, status) in {"created", "updated", "tombstoned"}.
    """
    versions = item["versions"]
    rating_key = item["plex_rating_key"]
    added_at = item.get("added_at")
    if added_at:
        created_at = datetime.fromtimestamp(int(added_at), timezone.utc).isoformat()
        position = int(added_at)
    else:
        created_at = datetime.now(timezone.utc).isoformat()
        position = None

    with _conn() as conn:
        row = conn.execute(
            "SELECT id, deleted_at FROM videos WHERE source = 'library' AND plex_rating_key = ?",
            (rating_key,),
        ).fetchone()

        if row:
            if row["deleted_at"]:
                return row["id"], "tombstoned"
            video_id = row["id"]
            conn.execute(
                """
                UPDATE videos
                SET url = ?, title = ?, classification = ?, show_title = ?, season = ?,
                    episode = ?, summary = ?, plex_rating_key = ?, show_rating_key = ?,
                    created_at = COALESCE(?, created_at),
                    position = COALESCE(?, position)
                WHERE id = ?
                """,
                (
                    versions[0]["source_path"], item.get("title"), item["classification"],
                    item.get("show_title"), item.get("season"), item.get("episode"),
                    item.get("summary"), rating_key, item.get("show_rating_key"),
                    created_at if added_at else None, position, video_id,
                ),
            )
            _sync_versions(conn, video_id, versions)
            _ensure_chosen_version(conn, video_id)
            return video_id, "updated"

        if position is None:
            position = (conn.execute("SELECT MAX(position) FROM videos").fetchone()[0] or 0) + 1
        cur = conn.execute(
            """
            INSERT INTO videos (
                url, title, status, classification, source,
                show_title, season, episode, summary, plex_rating_key,
                show_rating_key, created_at, position
            )
            VALUES (?, ?, 'unconverted', ?, 'library', ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                versions[0]["source_path"], item.get("title"), item["classification"],
                item.get("show_title"), item.get("season"), item.get("episode"),
                item.get("summary"), rating_key, item.get("show_rating_key"),
                created_at, position,
            ),
        )
        video_id = cur.lastrowid
        _sync_versions(conn, video_id, versions)
        _ensure_chosen_version(conn, video_id)
        return video_id, "created"
```

- [ ] **Step 4: Run test, verify it passes**

Run: `python -m pytest tests/test_db.py -q`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add db.py tests/test_db.py
git commit -m "feat(db): rating_key-keyed library upsert with version sync"
```

---

## Chunk 2: Plex parsing, scan, serializer

### Task 5: Version label + parsing helpers in `plex.py`

**Files:**
- Modify: `plex.py`
- Test: `tests/test_plex.py`

- [ ] **Step 1: Write the failing test**

Add to `tests/test_plex.py`:

```python
def test_version_label():
    assert plex._version_label({"videoResolution": "1080"}, {"size": 2_400_000_000}) == "1080p · 2.4 GB"
    assert plex._version_label({"videoResolution": "4k"}, {"size": 18_000_000_000}) == "4K · 18.0 GB"
    assert plex._version_label({"videoResolution": "480"}, {}) == "480p"
    assert plex._version_label({}, {"size": 700_000_000}) == "SD · 700 MB"

def test_versions_from_meta_multiple_media():
    meta = {"Media": [
        {"videoResolution": "1080", "Part": [{"file": "/m/1080.mkv", "size": 2_400_000_000}]},
        {"videoResolution": "4k", "Part": [{"file": "/m/4k.mkv", "size": 18_000_000_000}]},
    ]}
    versions = plex._versions(meta)
    assert [v["source_path"] for v in versions] == ["/m/1080.mkv", "/m/4k.mkv"]
    assert [v["plex_position"] for v in versions] == [0, 1]
    assert versions[1]["label"] == "4K · 18.0 GB"
```

- [ ] **Step 2: Run test, verify it fails**

Run: `python -m pytest tests/test_plex.py -k "version" -v`
Expected: FAIL (`_version_label` not defined).

- [ ] **Step 3: Implement**

Add to `plex.py`:

```python
def _humanize_size(nbytes: int | None) -> str | None:
    if not nbytes:
        return None
    gb = int(nbytes) / 1_000_000_000
    if gb >= 1:
        return f"{gb:.1f} GB"
    mb = int(nbytes) / 1_000_000
    return f"{mb:.0f} MB"


def _version_label(media: dict, part: dict) -> str:
    res = (media.get("videoResolution") or "").lower()
    if res == "4k":
        res_label = "4K"
    elif res:
        res_label = f"{res}p"
    else:
        res_label = "SD"
    size = _humanize_size(part.get("size"))
    return f"{res_label} · {size}" if size else res_label


def _versions(meta: dict) -> list[dict]:
    versions: list[dict] = []
    for media in meta.get("Media") or []:
        for part in media.get("Part") or []:
            if not part.get("file"):
                continue
            versions.append({
                "source_path": part["file"],
                "label": _version_label(media, part),
                "plex_position": len(versions),
            })
    return versions
```

- [ ] **Step 4: Run test, verify it passes**

Run: `python -m pytest tests/test_plex.py -k "version" -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add plex.py tests/test_plex.py
git commit -m "feat(plex): version label and parsing helpers"
```

---

### Task 6: `_movie_item`/`_episode_item` return a versions list

**Files:**
- Modify: `plex.py` (`_movie_item`, `_episode_item`; remove `_part_file`)
- Test: `tests/test_plex.py`

- [ ] **Step 1: Write the failing test**

Update the existing `test_fetch_library_items` expected dicts: movie and episode items no longer have top-level `source_path`; they gain `"versions": [...]`. New assertions:

```python
def test_fetch_library_items(monkeypatch):
    monkeypatch.setattr(plex, "_get_json", fake_get_json)
    items = plex.fetch_library_items()
    assert len(items) == 2

    movie = next(i for i in items if i["classification"] == "movies")
    assert "source_path" not in movie
    assert movie["title"] == "Akira"
    assert movie["plex_rating_key"] == "42"
    assert [v["source_path"] for v in movie["versions"]] == \
        ["/Volumes/Media/media/movies/Akira/Akira.mkv"]

    episode = next(i for i in items if i["classification"] == "tv")
    assert [v["source_path"] for v in episode["versions"]] == \
        ["/Volumes/Media/media/tv/The.Bear/S01E01.mkv"]
    assert episode["show_title"] == "The Bear"
```

- [ ] **Step 2: Run test, verify it fails**

Run: `python -m pytest tests/test_plex.py::test_fetch_library_items -v`
Expected: FAIL (movie still has `source_path`, no `versions`).

- [ ] **Step 3: Implement**

In `plex.py`, delete `_part_file`. Rewrite both item builders to use `_versions` and skip items with no versions:

```python
def _movie_item(meta: dict) -> dict | None:
    versions = _versions(meta)
    if not versions:
        return None
    return {
        "title": meta.get("title"),
        "classification": "movies",
        "show_title": None,
        "season": None,
        "episode": None,
        "summary": meta.get("summary"),
        "plex_rating_key": str(meta["ratingKey"]),
        "show_rating_key": None,
        "added_at": meta.get("addedAt"),
        "versions": versions,
    }


def _episode_item(meta: dict) -> dict | None:
    versions = _versions(meta)
    if not versions:
        return None
    return {
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
        "added_at": meta.get("addedAt"),
        "versions": versions,
    }
```

- [ ] **Step 4: Run test, verify it passes**

Run: `python -m pytest tests/test_plex.py -q`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add plex.py tests/test_plex.py
git commit -m "feat(plex): item builders emit versions list"
```

---

### Task 7: `scan_library` filters versions per item

**Files:**
- Modify: `library.py` (`scan_library`)
- Test: `tests/test_library.py`

- [ ] **Step 1: Write the failing test**

Add a test that fakes `plex.fetch_library_items` and real files via `tmp_path`. Mirror how existing library tests are structured (`monkeypatch.setattr`):

```python
def test_scan_library_filters_missing_version_files(monkeypatch, tmp_path):
    import db, library, plex
    real = tmp_path / "1080.mkv"; real.write_bytes(b"x")
    item = {
        "title": "Akira", "classification": "movies", "show_title": None,
        "season": None, "episode": None, "summary": None,
        "plex_rating_key": "42", "show_rating_key": None, "added_at": 1000,
        "versions": [
            {"source_path": str(real), "label": "1080p", "plex_position": 0},
            {"source_path": str(tmp_path / "missing.mkv"), "label": "4K", "plex_position": 1},
        ],
    }
    monkeypatch.setattr(plex, "fetch_library_items", lambda: [item])
    captured = {}
    def fake_upsert(it):
        captured["item"] = it
        return 1, "created"
    monkeypatch.setattr(db, "upsert_library_video", fake_upsert)
    monkeypatch.setattr(db, "get_converted_paths", lambda: set())
    result = library.scan_library()
    assert result["added"] == 1
    assert [v["source_path"] for v in captured["item"]["versions"]] == [str(real)]
```

(Reload `db`/`library` under a temp `DB_PATH` if the test module doesn't already; follow the file's existing setup.)

- [ ] **Step 2: Run test, verify it fails**

Run: `python -m pytest tests/test_library.py::test_scan_library_filters_missing_version_files -v`
Expected: FAIL (current `scan_library` reads `item["source_path"]`).

- [ ] **Step 3: Implement**

Rewrite `scan_library` in `library.py`:

```python
def scan_library() -> dict:
    """Upsert every Plex library item into the videos/video_versions tables.
    Metadata only, no ffmpeg. Versions whose files are missing (or are our own
    converted siblings) are filtered out; an item with no surviving version is skipped."""
    items = plex.fetch_library_items()
    converted = db.get_converted_paths()
    added = updated = skipped = 0
    for item in items:
        versions = [
            v for v in item["versions"]
            if v["source_path"] not in converted and Path(v["source_path"]).exists()
        ]
        if not versions:
            skipped += 1
            continue
        item = {**item, "versions": versions}
        if not item.get("added_at"):
            mtimes = []
            for v in versions:
                try:
                    mtimes.append(int(Path(v["source_path"]).stat().st_mtime))
                except OSError:
                    pass
            item["added_at"] = min(mtimes) if mtimes else None
        _, status = db.upsert_library_video(item)
        if status == "created":
            added += 1
        elif status == "updated":
            updated += 1
        else:  # tombstoned
            skipped += 1
    return {"added": added, "updated": updated, "skipped": skipped}
```

- [ ] **Step 4: Run test, verify it passes**

Run: `python -m pytest tests/test_library.py -q`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add library.py tests/test_library.py
git commit -m "feat(library): scan filters versions per item"
```

---

### Task 8: Serializer emits `versions` + `chosen_version_id`

**Files:**
- Modify: `views/serializers.py`
- Test: `tests/test_serializers.py`

- [ ] **Step 1: Write the failing test**

```python
def test_serialize_library_video_includes_versions():
    video = {
        "id": 7, "url": "/m/a.mkv", "status": "done", "classification": "movies",
        "source": "library", "title": "Akira", "chosen_version_id": 20,
        "versions": [
            {"id": 20, "label": "1080p", "status": "done"},
            {"id": 21, "label": "4K", "status": "unconverted"},
        ],
    }
    data = serialize_video(video)
    assert data["chosen_version_id"] == 20
    assert data["versions"] == [
        {"id": 20, "label": "1080p", "status": "done", "is_chosen": True},
        {"id": 21, "label": "4K", "status": "unconverted", "is_chosen": False},
    ]
    assert data["url"] == ""      # library url still redacted

def test_serialize_download_video_has_empty_versions():
    data = serialize_video({"id": 1, "url": "u", "status": "done", "classification": "children"})
    assert data["versions"] == []
    assert data["chosen_version_id"] is None
```

- [ ] **Step 2: Run test, verify it fails**

Run: `python -m pytest tests/test_serializers.py -k version -v`
Expected: FAIL (`versions` key absent).

- [ ] **Step 3: Implement**

In `views/serializers.py`, add to the base `data` dict:

```python
        "versions": [],
        "chosen_version_id": None,
```

Inside `if source == "library":` add:

```python
        chosen = video.get("chosen_version_id")
        data["chosen_version_id"] = chosen
        data["versions"] = [
            {
                "id": v["id"],
                "label": v.get("label"),
                "status": v["status"],
                "is_chosen": v["id"] == chosen,
            }
            for v in (video.get("versions") or [])
        ]
```

- [ ] **Step 4: Run test, verify it passes**

Run: `python -m pytest tests/test_serializers.py -q`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add views/serializers.py tests/test_serializers.py
git commit -m "feat(serializer): emit versions and chosen_version_id"
```

---

### Task 9: `get_video`/`get_all_videos` attach versions for library rows

**Files:**
- Modify: `db.py` (`get_video`, `get_all_videos`)
- Test: `tests/test_db.py`

- [ ] **Step 1: Write the failing test**

```python
def test_get_video_attaches_versions_for_library(fresh_db):
    db = fresh_db
    vid, _ = db.upsert_library_video(_movie_item())
    got = db.get_video(vid)
    assert [v["label"] for v in got["versions"]] == ["1080p", "4K"]
    # non-library rows get an empty list, not a crash
    dl = db.add_video("https://twitter.com/x/status/1")
    assert db.get_video(dl)["versions"] == []
```

(Reuse `_movie_item` helper from Task 4's tests.)

- [ ] **Step 2: Run test, verify it fails**

Run: `python -m pytest tests/test_db.py::test_get_video_attaches_versions_for_library -v`
Expected: FAIL (`KeyError: 'versions'`).

- [ ] **Step 3: Implement**

Add a helper and use it in both getters:

```python
def _with_versions(conn: sqlite3.Connection, video: dict) -> dict:
    if video.get("source") == "library":
        rows = conn.execute(
            "SELECT * FROM video_versions WHERE video_id = ? "
            "ORDER BY plex_position ASC, id ASC",
            (video["id"],),
        ).fetchall()
        video["versions"] = [dict(r) for r in rows]
    else:
        video["versions"] = []
    return video
```

In `get_video`: `return _with_versions(conn, dict(row)) if row else None`.

In `get_all_videos`: wrap the return, e.g. `return [_with_versions(conn, dict(r)) for r in rows]`.

- [ ] **Step 4: Run test, verify it passes**

Run: `python -m pytest tests/ -q`
Expected: PASS (full backend suite green).

- [ ] **Step 5: Commit**

```bash
git add db.py tests/test_db.py
git commit -m "feat(db): attach versions to fetched videos"
```

---

## Chunk 3: Conversion, streaming, endpoints

### Task 10: Per-version conversion

**Files:**
- Modify: `library.py` (`convert_library_video` → `convert_library_version`)
- Test: `tests/test_library.py`

- [ ] **Step 1: Write the failing test**

Model it on any existing `convert_library_video` test in `tests/test_library.py` (fake `probe_source`, `_run_ffmpeg`, and `os.replace`). Assert it reads the version's `source_path` and calls `db.set_version_state(version_id, "done", converted_path=...)`. If the file has no existing conversion test, write one that patches `library.probe_source` to return a passthrough plan and asserts `db.set_version_state` was called with `"done"`.

```python
def test_convert_library_version_passthrough(monkeypatch, fresh_db_module):
    db, library = fresh_db_module
    vid, _ = db.upsert_library_video(_movie_item(versions=[
        {"source_path": "/m/a.mp4", "label": "1080p", "plex_position": 0}]))
    version_id = db.get_versions(vid)[0]["id"]
    monkeypatch.setattr(library, "probe_source",
                        lambda p: {"streams": [{"codec_type": "video", "codec_name": "h264",
                                                "width": 1920, "codec_tag_string": "avc1"}],
                                   "format": {"format_name": "mov,mp4,m4a"}})
    monkeypatch.setattr(Path, "exists", lambda self: True)
    library.convert_library_version(version_id)
    assert db.get_version(version_id)["status"] == "done"
```

(Adapt the fixture to whatever `tests/test_library.py` already provides for a reloaded `db`+`library` under temp `DB_PATH`.)

- [ ] **Step 2: Run test, verify it fails**

Run: `python -m pytest tests/test_library.py -k convert_library_version -v`
Expected: FAIL (`convert_library_version` not defined).

- [ ] **Step 3: Implement**

Replace `convert_library_video` with `convert_library_version` in `library.py`:

```python
def convert_library_version(version_id: int) -> None:
    """Convert one library version's source to an iPad-ready sibling mp4.

    Runs synchronously (FastAPI executes sync background tasks on a thread).
    Failures set the version back to 'unconverted' with error_msg; never deletes."""
    version = db.get_version(version_id)
    if not version:
        return

    source = Path(version["source_path"])
    tmp = None
    try:
        if not source.exists():
            raise RuntimeError(f"source file missing: {source}")

        plan = plan_conversion(probe_source(source))
        if plan.passthrough:
            db.set_version_state(version_id, "done")
            return

        target = conversion_target(source)
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
        db.set_version_state(version_id, "done", converted_path=str(target))
    except Exception as exc:  # noqa: BLE001 — background task, must not raise
        if tmp is not None:
            Path(tmp).unlink(missing_ok=True)
        db.set_version_state(version_id, "unconverted", error_msg=str(exc))
```

- [ ] **Step 4: Run test, verify it passes**

Run: `python -m pytest tests/test_library.py -q`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add library.py tests/test_library.py
git commit -m "feat(library): convert per version"
```

---

### Task 11: `prepare` resolves and converts the chosen version

**Files:**
- Modify: `main.py` (`api_prepare_video`)
- Test: `tests/test_api.py`

- [ ] **Step 1: Write the failing test**

Add to `tests/test_api.py` (follow the `client` fixture pattern). Seed a library movie with a chosen version via `db.upsert_library_video`, patch `library.probe_source` to a re-encode plan, and assert `POST /api/videos/{id}/prepare` returns 202 with `{"status": "converting"}` and that the **chosen version** moves to `converting`.

```python
def test_prepare_converts_chosen_version(client, monkeypatch):
    import db, library
    vid, _ = db.upsert_library_video({
        "title": "Akira", "classification": "movies", "show_title": None,
        "season": None, "episode": None, "summary": None,
        "plex_rating_key": "42", "show_rating_key": None, "added_at": 1000,
        "versions": [{"source_path": "/m/a.mkv", "label": "1080p", "plex_position": 0}],
    })
    version_id = db.get_versions(vid)[0]["id"]
    monkeypatch.setattr(library, "probe_source", lambda p: {"streams": [
        {"codec_type": "video", "codec_name": "hevc", "width": 4000, "codec_tag_string": "hev1"}],
        "format": {"format_name": "matroska,webm"}})
    monkeypatch.setattr(library.Path, "exists", lambda self: True)
    resp = client.post(f"/api/videos/{vid}/prepare",
                       headers={"Authorization": "Bearer test-token"})
    assert resp.status_code == 202
    assert db.get_version(version_id)["status"] == "converting"
```

(Use the same auth token the `client` fixture configures.)

- [ ] **Step 2: Run test, verify it fails**

Run: `python -m pytest tests/test_api.py::test_prepare_converts_chosen_version -v`
Expected: FAIL (current prepare reads `video["source_path"]` / uses `set_library_state`).

- [ ] **Step 3: Implement**

Rewrite the body of `api_prepare_video` after the `source != "library"` guard to resolve the chosen version:

```python
    version_id = video.get("chosen_version_id")
    version = db.get_version(version_id) if version_id else None
    if not version:
        raise HTTPException(status_code=404, detail="No version to prepare")

    if version["status"] == "done":
        return {"status": "done"}
    if version["status"] == "converting":
        return JSONResponse({"status": "converting"}, status_code=202)

    source = Path(version["source_path"])
    if not source.exists():
        db.set_version_state(version_id, "unconverted", error_msg=f"source file missing: {source}")
        raise HTTPException(status_code=404, detail="Source file missing")

    db.set_version_state(version_id, "converting")
    try:
        plan = await asyncio.to_thread(lambda: library.plan_conversion(library.probe_source(source)))
    except Exception as exc:
        db.set_version_state(version_id, "unconverted", error_msg=str(exc))
        raise HTTPException(status_code=500, detail=str(exc)) from exc

    if plan.passthrough:
        db.set_version_state(version_id, "done")
        return {"status": "done"}

    background_tasks.add_task(library.convert_library_version, version_id)
    return JSONResponse({"status": "converting"}, status_code=202)
```

- [ ] **Step 4: Run test, verify it passes**

Run: `python -m pytest tests/test_api.py -q`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add main.py tests/test_api.py
git commit -m "feat(api): prepare converts the chosen version"
```

---

### Task 12: `stream` resolves the chosen version (with `?version_id=` override)

**Files:**
- Modify: `main.py` (`stream_video`, new `_resolve_stream_version`)
- Test: `tests/test_api.py`

- [ ] **Step 1: Write the failing test**

Seed a library movie whose chosen version is `done` with a real temp `converted_path`; assert `GET /videos/{id}/stream?token=...` streams it. Also assert `?version_id=<other>` streams a different version's file, and an unrelated `version_id` returns 404/409.

```python
def test_stream_uses_chosen_version(client, tmp_path):
    import db
    f = tmp_path / "1080.mp4"; f.write_bytes(b"data")
    vid, _ = db.upsert_library_video({
        "title": "A", "classification": "movies", "show_title": None, "season": None,
        "episode": None, "summary": None, "plex_rating_key": "42", "show_rating_key": None,
        "added_at": 1000,
        "versions": [{"source_path": str(f), "label": "1080p", "plex_position": 0}]})
    version_id = db.get_versions(vid)[0]["id"]
    db.set_version_state(version_id, "done", converted_path=str(f))
    resp = client.get(f"/videos/{vid}/stream?token=test-token")
    assert resp.status_code == 200
    assert resp.content == b"data"
```

- [ ] **Step 2: Run test, verify it fails**

Run: `python -m pytest tests/test_api.py::test_stream_uses_chosen_version -v`
Expected: FAIL (current stream reads `video["converted_path"]` which is NULL for the movie row).

- [ ] **Step 3: Implement**

Add a helper near `stream_video` in `main.py`:

```python
def _resolve_stream_version(video: dict, request: Request) -> dict | None:
    raw = request.query_params.get("version_id")
    if raw:
        try:
            v = db.get_version(int(raw))
        except ValueError:
            return None
        return v if v and v["video_id"] == video["id"] else None
    chosen = video.get("chosen_version_id")
    return db.get_version(chosen) if chosen else None
```

Replace the `if video.get("source") == "library":` branch in `stream_video`:

```python
    if video.get("source") == "library":
        version = _resolve_stream_version(video, request)
        if not version or version["status"] != "done":
            raise HTTPException(status_code=409, detail="Video not prepared yet")
        file_path = Path(version["converted_path"] or version["source_path"])
        mime = "video/mp4"
```

- [ ] **Step 4: Run test, verify it passes**

Run: `python -m pytest tests/test_api.py -q`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add main.py tests/test_api.py
git commit -m "feat(api): stream resolves chosen version"
```

---

### Task 13: Choose-version endpoints + service + delete cleanup

**Files:**
- Modify: `services.py`, `main.py` (new `VersionRequest`, SSR + API endpoints, `api_delete_video`)
- Test: `tests/test_services.py`, `tests/test_api.py`

- [ ] **Step 1: Write the failing tests**

`tests/test_services.py`:

```python
def test_apply_choose_version(fresh_db):
    db, services = fresh_db
    vid, _ = db.upsert_library_video({
        "title": "A", "classification": "movies", "show_title": None, "season": None,
        "episode": None, "summary": None, "plex_rating_key": "42", "show_rating_key": None,
        "added_at": 1000, "versions": [
            {"source_path": "/m/1080.mkv", "label": "1080p", "plex_position": 0},
            {"source_path": "/m/4k.mkv", "label": "4K", "plex_position": 1}]})
    v2 = db.get_versions(vid)[1]["id"]
    assert services.apply_choose_version(vid, v2) is True
    assert db.get_video(vid)["chosen_version_id"] == v2
    assert services.apply_choose_version(vid, 9999) is False
```

`tests/test_api.py`:

```python
def test_api_choose_version(client):
    import db
    vid, _ = db.upsert_library_video({
        "title": "A", "classification": "movies", "show_title": None, "season": None,
        "episode": None, "summary": None, "plex_rating_key": "42", "show_rating_key": None,
        "added_at": 1000, "versions": [
            {"source_path": "/m/1080.mkv", "label": "1080p", "plex_position": 0},
            {"source_path": "/m/4k.mkv", "label": "4K", "plex_position": 1}]})
    v2 = db.get_versions(vid)[1]["id"]
    resp = client.post(f"/api/videos/{vid}/version",
                       json={"version_id": v2},
                       headers={"Authorization": "Bearer test-token"})
    assert resp.status_code == 200 and resp.json() == {"ok": True}
    assert db.get_video(vid)["chosen_version_id"] == v2

def test_api_choose_version_requires_token(client):
    resp = client.post("/api/videos/1/version", json={"version_id": 1})
    assert resp.status_code == 401
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `python -m pytest tests/test_services.py tests/test_api.py -k "choose_version or choose" -v`
Expected: FAIL (`apply_choose_version` / endpoint missing).

- [ ] **Step 3: Implement**

`services.py`:

```python
def apply_choose_version(video_id: int, version_id: int) -> bool:
    return db.set_chosen_version(video_id, version_id)
```

`main.py` — add request model near `ClassifyRequest`:

```python
class VersionRequest(BaseModel):
    version_id: int
```

Add endpoints (SSR mirrors `move`/`classify`; API mirrors `api_classify_video`):

```python
@app.post("/videos/{video_id}/version")
async def choose_version_endpoint(video_id: int, version_id: int = Form(...),
                                  current_classification: str | None = Form(default=None)):
    services.apply_choose_version(video_id, version_id)
    redirect_url = f"/?classification={current_classification}" if current_classification else "/"
    return RedirectResponse(url=redirect_url, status_code=303)


@app.post("/api/videos/{video_id}/version")
async def api_choose_version(video_id: int, body: VersionRequest, request: Request):
    _check_token(request)
    ok = services.apply_choose_version(video_id, body.version_id)
    return {"ok": ok}
```

Update `api_delete_video` library branch to unlink every version's converted file:

```python
        if video.get("source") == "library":
            for v in db.get_versions(video_id):
                if v.get("converted_path"):
                    Path(v["converted_path"]).unlink(missing_ok=True)
            db.tombstone_video(video_id)
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `python -m pytest tests/ -q`
Expected: PASS (entire backend suite).

- [ ] **Step 5: Commit**

```bash
git add services.py main.py tests/test_services.py tests/test_api.py
git commit -m "feat(api): choose-version endpoints and per-version delete cleanup"
```

---

## Chunk 4: iOS

### Task 14: `Video` decodes versions + `chosenVersionId`

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/Video.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/` (new `VideoDecodingTests.swift`)

- [ ] **Step 1: Write the failing test**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoDecodingTests.swift`:

```swift
import Testing
import Foundation
@testable import PatataTubeKit

struct VideoDecodingTests {
    @Test func decodesVersionsAndChosen() throws {
        let json = """
        {"id":7,"url":"","title":"A","platform":null,"source_key":null,"preview_url":null,
         "classification":"movies","position":1,"status":"done","error_msg":null,
         "stream_path":"/videos/7/stream","source":"library",
         "chosen_version_id":20,
         "versions":[{"id":20,"label":"1080p","status":"done","is_chosen":true},
                     {"id":21,"label":"4K","status":"unconverted","is_chosen":false}]}
        """.data(using: .utf8)!
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        let v = try d.decode(Video.self, from: json)
        #expect(v.versions.count == 2)
        #expect(v.chosenVersionId == 20)
        #expect(v.chosenVersion?.label == "1080p")
    }

    @Test func decodesLegacyJSONWithoutVersions() throws {
        let json = """
        {"id":1,"url":"u","title":null,"platform":null,"source_key":null,"preview_url":null,
         "classification":"children","position":1,"status":"done","error_msg":null,
         "stream_path":"/videos/1/stream","source":null}
        """.data(using: .utf8)!
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        let v = try d.decode(Video.self, from: json)
        #expect(v.versions.isEmpty)
        #expect(v.chosenVersionId == nil)
    }
}
```

- [ ] **Step 2: Run test, verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter VideoDecodingTests`
Expected: FAIL (no `versions` member).

- [ ] **Step 3: Implement**

In `Video.swift`, add the version struct and fields, plus a custom `init(from:)` so old cached JSON (no `versions` key) still decodes:

```swift
public struct VideoVersion: Codable, Identifiable, Equatable, Sendable {
    public let id: Int
    public let label: String?
    public let status: String
    public let isChosen: Bool
    public init(id: Int, label: String?, status: String, isChosen: Bool) {
        self.id = id; self.label = label; self.status = status; self.isChosen = isChosen
    }
}
```

Add stored properties `public let versions: [VideoVersion]` and `public let chosenVersionId: Int?`; add them to the memberwise `init` (default `versions: [] , chosenVersionId: nil`) and to `withClassification`. Add:

```swift
public var chosenVersion: VideoVersion? { versions.first { $0.isChosen } }
```

Add an explicit `init(from decoder:)` (since synthesized decoding requires the non-optional `versions` key to be present):

```swift
public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(Int.self, forKey: .id)
    url = try c.decode(String.self, forKey: .url)
    title = try c.decodeIfPresent(String.self, forKey: .title)
    platform = try c.decodeIfPresent(String.self, forKey: .platform)
    sourceKey = try c.decodeIfPresent(String.self, forKey: .sourceKey)
    previewUrl = try c.decodeIfPresent(String.self, forKey: .previewUrl)
    classification = try c.decode(String.self, forKey: .classification)
    position = try c.decodeIfPresent(Int.self, forKey: .position)
    status = try c.decode(String.self, forKey: .status)
    errorMsg = try c.decodeIfPresent(String.self, forKey: .errorMsg)
    streamPath = try c.decode(String.self, forKey: .streamPath)
    source = try c.decodeIfPresent(String.self, forKey: .source)
    showTitle = try c.decodeIfPresent(String.self, forKey: .showTitle)
    season = try c.decodeIfPresent(Int.self, forKey: .season)
    episode = try c.decodeIfPresent(Int.self, forKey: .episode)
    summary = try c.decodeIfPresent(String.self, forKey: .summary)
    showPreviewUrl = try c.decodeIfPresent(String.self, forKey: .showPreviewUrl)
    versions = try c.decodeIfPresent([VideoVersion].self, forKey: .versions) ?? []
    chosenVersionId = try c.decodeIfPresent(Int.self, forKey: .chosenVersionId)
}
```

Add a `CodingKeys` enum covering every property (Swift no longer synthesizes it once you write `init(from:)`). Because `APIClient` decodes with `.convertFromSnakeCase`, keep camelCase key names (`streamPath`, `chosenVersionId`, etc.) — the decoder maps `stream_path`→`streamPath` automatically. Keep `Encodable` synthesized (it still works with explicit `CodingKeys`).

- [ ] **Step 4: Run test, verify it passes**

Run: `cd ios/PatataTubeKit && swift test --filter VideoDecodingTests`
Expected: PASS. Then `swift build` to confirm the whole kit compiles.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/Video.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoDecodingTests.swift
git commit -m "feat(ios): Video decodes versions and chosenVersionId"
```

---

### Task 15: `CacheManager` keyed by (videoId, versionId)

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift`

- [ ] **Step 1: Write the failing test**

Add a test that two versions of one movie cache to distinct files:

```swift
@Test func cachesVersionsIndependently() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let cache = CacheManager(root: root)
    #expect(cache.state(videoId: 7, versionId: 20) == .notCached)
    // simulate a cached file for version 20 only
    try Data([1,2,3]).write(to: cache.localURL(videoId: 7, versionId: 20))
    #expect(cache.state(videoId: 7, versionId: 20) == .cached)
    #expect(cache.state(videoId: 7, versionId: 21) == .notCached)
}
```

Keep/adjust existing `CacheManagerTests` to the new signatures (non-library case: `versionId: nil`).

- [ ] **Step 2: Run test, verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter CacheManagerTests`
Expected: FAIL (no `localURL(videoId:versionId:)`).

- [ ] **Step 3: Implement**

In `CacheManager.swift`:
- Change `inFlight` key to `String`: `private var inFlight: [String: Double] = [:]`.
- Add a private `cacheKey`:

```swift
private func filename(videoId: Int, versionId: Int?) -> String {
    versionId.map { "\(videoId).v\($0).mp4" } ?? "\(videoId).mp4"
}
public func localURL(videoId: Int, versionId: Int? = nil) -> URL {
    root.appendingPathComponent(filename(videoId: videoId, versionId: versionId))
}
public func state(videoId: Int, versionId: Int? = nil) -> CacheState {
    let url = localURL(videoId: videoId, versionId: versionId)
    if fileManager.fileExists(atPath: url.path) { return .cached }
    let key = filename(videoId: videoId, versionId: versionId)
    return lock.withLock { inFlight[key].map { .downloading($0) } ?? .notCached }
}
public func download(videoId: Int, versionId: Int? = nil, from remote: URL,
                     preview: URL? = nil, bearerToken: String? = nil) async throws {
    let key = filename(videoId: videoId, versionId: versionId)
    lock.withLock { inFlight[key] = 0 }
    // ... body identical to before, but destination = localURL(videoId:versionId:)
    //     and inFlight cleared via `key`, and preview still keyed by videoId.
}
```

Keep `cachedPreviewURL(for:)` keyed by video id (unchanged — one poster per movie). Update the `download` body's `destination` and all `inFlight[id]` references to use `key` / `localURL(videoId:versionId:)`. Preview caching still uses `cachePreview(id: videoId, ...)`.

- [ ] **Step 4: Run test, verify it passes**

Run: `cd ios/PatataTubeKit && swift test`
Expected: PASS (all kit tests). `swift build` clean.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift
git commit -m "feat(ios): cache keyed by video+version"
```

---

### Task 16: `chooseVersion` in `APIClient` + `VideoStore`

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/APIClient.swift`, `VideoStore.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoStoreTests.swift`

- [ ] **Step 1: Write the failing test**

In `VideoStoreTests.swift`, add `chooseVersion` to the mock (`MockAPI` conforms to `VideoAPI`) and a test:

```swift
// in MockAPI:
var chooseVersionResult = true
func chooseVersion(id: Int, versionId: Int) async throws -> Bool { chooseVersionResult }

@MainActor @Test func chooseVersionOptimisticallyUpdates() async {
    let api = MockAPI()
    let v = Video(id: 1, url: "", title: "A", platform: nil, sourceKey: nil,
                  previewUrl: nil, classification: "movies", position: 1,
                  status: "unconverted", errorMsg: nil, streamPath: "/videos/1/stream",
                  source: "library",
                  versions: [VideoVersion(id: 10, label: "1080p", status: "done", isChosen: true),
                             VideoVersion(id: 11, label: "4K", status: "unconverted", isChosen: false)],
                  chosenVersionId: 10)
    api.videosToReturn = [v]
    let store = VideoStore(api: api)
    await store.load()
    await store.chooseVersion(id: 1, versionId: 11)
    #expect(store.videos[0].chosenVersion?.id == 11)
}
```

(The `Video` memberwise init gains `versions`/`chosenVersionId` params from Task 14 — update the mock's `makeVideo` helper to pass defaults so existing tests compile.)

- [ ] **Step 2: Run test, verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter VideoStoreTests`
Expected: FAIL (no `chooseVersion` on `VideoAPI`).

- [ ] **Step 3: Implement**

`APIClient.swift` — add to the `VideoAPI` protocol:

```swift
    func chooseVersion(id: Int, versionId: Int) async throws -> Bool
```

Implement on `APIClient` (mirrors `move`/`classify`, which use `postOK` with a `[String: String]` body — send the id as a string):

```swift
    public func chooseVersion(id: Int, versionId: Int) async throws -> Bool {
        try await postOK("api/videos/\(id)/version", body: ["version_id": String(versionId)])
    }
```

Server-side `VersionRequest.version_id` is typed `int`; FastAPI/pydantic coerces the numeric string `"11"` to `11`. (If strict, change `authedPost`/`postOK` isn't worth it — pydantic v2 coerces str→int by default. Verify in the Task 13 integration test by also POSTing `{"version_id": "11"}` if desired.)

`VideoStore.swift` — add an optimistic action mirroring `classify`:

```swift
    public func chooseVersion(id: Int, versionId: Int) async {
        guard let index = videos.firstIndex(where: { $0.id == id }) else { return }
        let previous = videos
        videos[index] = videos[index].choosingVersion(versionId)
        do {
            let ok = try await api.chooseVersion(id: id, versionId: versionId)
            if !ok { videos = previous }
        } catch {
            videos = previous
            errorText = String(describing: error)
        }
    }
```

Add `choosingVersion` to `Video.swift` (rebuilds `versions` with the new `isChosen` and mirrors top-level `status` to the chosen version's status):

```swift
func choosingVersion(_ versionId: Int) -> Video {
    let newVersions = versions.map {
        VideoVersion(id: $0.id, label: $0.label, status: $0.status, isChosen: $0.id == versionId)
    }
    let newStatus = newVersions.first { $0.isChosen }?.status ?? status
    return Video(id: id, url: url, title: title, platform: platform, sourceKey: sourceKey,
                 previewUrl: previewUrl, classification: classification, position: position,
                 status: newStatus, errorMsg: errorMsg, streamPath: streamPath,
                 source: source, showTitle: showTitle, season: season, episode: episode,
                 summary: summary, showPreviewUrl: showPreviewUrl,
                 versions: newVersions, chosenVersionId: versionId)
}
```

(Adjust the memberwise `init` param order/labels to match Task 14.)

- [ ] **Step 4: Run test, verify it passes**

Run: `cd ios/PatataTubeKit && swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/APIClient.swift ios/PatataTubeKit/Sources/PatataTubeKit/VideoStore.swift ios/PatataTubeKit/Sources/PatataTubeKit/Video.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoStoreTests.swift
git commit -m "feat(ios): chooseVersion in APIClient and VideoStore"
```

---

### Task 17: VideoCell picker + version-aware wiring (app target)

**Files:**
- Modify: `ios/PatataTube/Sources/VideoCell.swift`, `VideoGridView.swift`, `ShowsView.swift`, `EpisodesView.swift`
- No unit test (no iOS app test target). Verify with `xcodegen generate` + a build, and the manual checklist in `ios/README.md`.

- [ ] **Step 1: Add the version picker + callback to `VideoCell`**

In `VideoCell.swift`, add a new closure property:

```swift
    let onChooseVersion: (Int) -> Void
```

In the `Menu`, before the classifications `Divider()`, add a version section shown only when there's more than one:

```swift
                    if video.versions.count > 1 {
                        ForEach(video.versions) { v in
                            Button {
                                onChooseVersion(v.id)
                            } label: {
                                Label(v.label ?? "Version \(v.id)",
                                      systemImage: v.isChosen ? "checkmark" : "")
                            }
                        }
                        Divider()
                    }
```

The download button already renders from the injected `cacheState`; because `VideoGridView` computes that state from the chosen version (next step), switching versions re-renders the cell and the icon flips automatically. No change needed to `downloadButton` itself.

- [ ] **Step 2: Wire version-aware cache state + choose in `VideoGridView`**

In `VideoGridView.swift`, update the `VideoCell(...)` call:

```swift
                            VideoCell(
                                video: video,
                                cacheState: model.cache.state(videoId: video.id, versionId: video.chosenVersionId),
                                cachedPreviewURL: model.cache.cachedPreviewURL(for: video.id),
                                classifications: classifications,
                                onPlay: { play(video) },
                                onDownload: { await download(video) },
                                onMoveUp: { Task { await store.move(id: video.id, direction: "up") } },
                                onMoveDown: { Task { await store.move(id: video.id, direction: "down") } },
                                onClassify: { c in Task { await store.classify(id: video.id, to: c) } },
                                onChooseVersion: { vid in Task { await store.chooseVersion(id: video.id, versionId: vid) } },
                                onDelete: { Task { await store.delete(id: video.id) } }
                            )
```

Update the three other `model.cache` call sites in this file to pass `versionId: video.chosenVersionId`:
- `play(_:)` — the `.cached` check.
- `download(_:)` — the `model.cache.download(...)` call becomes `download(videoId: target.id, versionId: target.chosenVersionId, from: url, preview: preview, bearerToken:)`.
- `downloadAll()` — the `state(...)` filter.

- [ ] **Step 3: Update `ShowsView` / `EpisodesView` call sites**

These render library episodes and also call `model.cache.state(...)` / `download(...)` and construct `VideoCell` (for `EpisodesView`) or forward `onDownload`. Update every `cache.state(for: v.id)` → `cache.state(videoId: v.id, versionId: v.chosenVersionId)`, every `cache.download(id:...)` → `cache.download(videoId:versionId:...)`, and pass an `onChooseVersion` closure to any `VideoCell` they build (episodes are single-version, so the picker stays hidden, but the parameter is required). Read each file first and mirror the `VideoGridView` pattern exactly.

- [ ] **Step 4: Regenerate the project and build**

Run:
```bash
cd ios/PatataTube && xcodegen generate
xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO | tail -20
```
Expected: BUILD SUCCEEDED (or, if signing/toolchain blocks it locally, at least no Swift compile errors — resolve any before continuing).

Also re-run the kit tests to be safe: `cd ios/PatataTubeKit && swift test`.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTube/Sources/VideoCell.swift ios/PatataTube/Sources/VideoGridView.swift ios/PatataTube/Sources/ShowsView.swift ios/PatataTube/Sources/EpisodesView.swift
git commit -m "feat(ios): version picker in VideoCell and version-aware caching"
```

---

## Final verification

- [ ] `python -m pytest tests/ -q` — full backend suite green.
- [ ] `cd ios/PatataTubeKit && swift test` — kit tests green.
- [ ] `cd ios/PatataTube && xcodegen generate && xcodebuild ... build` — app compiles.
- [ ] Manual smoke against a real Plex movie with two versions (see `ios/README.md` checklist): scan → card shows one movie → three-dots shows both versions → pick 4K → download icon tracks 4K → switch to 1080p → icon reflects 1080p's separate cache state → play uses chosen version.
- [ ] Update `CLAUDE.md` "Plex library" section to note the `video_versions` table and chosen-version resolution (small doc edit; commit separately).

## Notes on edge cases (already covered by tasks)

- **Single-version movie / any episode:** exactly one version row, picker hidden (`versions.count > 1` guard), everything flows through the sole `chosen_version_id`.
- **Version removed from Plex:** `_sync_versions` prunes it; `_ensure_chosen_version` re-points the chosen id to the first remaining version.
- **Switching to an already-converted version:** its `converted_path` persists, so `stream`/`prepare` see `status == "done"` immediately — no reconversion, and iOS finds its separately-cached file.
