# Video Groups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hardcoded `CLASSIFICATIONS` list with a first-class `groups` table so new video groups can be added by INSERT and appear in the iOS Videos tab, while Plex TV/Movies become an explicitly separate axis.

**Architecture:** A `groups` table (name, label, emoji, position) owns group identity; `videos.group_id` is an FK to it and `videos.plex_kind` is a separate nullable column for Plex items. The two are mutually exclusive and `videos.classification` is dropped. On the client, the stringly-typed `VideoStore.filter: String?` becomes a `Feed` enum (`.all` / `.group(id:)` / `.plex(_:)`), and a `GroupStore` mirrors the server's group list into UserDefaults so the Videos tab stays offline-first.

**Tech Stack:** Python 3.13, FastAPI, SQLite (stdlib `sqlite3`), Jinja2, pytest; Swift 5.9+, SwiftUI, SwiftPM (`PatataTubeKit`), XcodeGen.

**Spec:** `docs/superpowers/specs/2026-08-03-video-groups-design.md`

## Global Constraints

- **Working directory is the repo root** `/Users/grillermo/c/patatatube` for all Python work; `ios/PatataTubeKit` for Swift package work.
- **Python tests:** `python -m pytest tests/` from the repo root. There is no `pytest.ini`/`pyproject.toml`. Async tests need an explicit `@pytest.mark.asyncio` marker.
- **Integration tests reload modules.** `db` and `main` read env at import time, so tests set `DB_PATH`/`UPLOAD_TOKEN` then `importlib.reload(db)` and `importlib.reload(main)`. Follow the existing `client` fixture in `tests/test_api.py`.
- **Swift tests:** run **both** `swift test` and `swift test -c release` from `ios/PatataTubeKit` when touching anything the `DEVLOG` flag gates. A full parallel run has pre-existing unrelated failures (a `Fatal error: Index out of range` from swift-testing, occasional `VideoStoreTests` flakes) — re-run the specific test filtered before concluding you broke something.
- **`docs/` is in `.gitignore` but prior plans/specs are tracked.** Committing a doc needs `git add -f`.
- **`./serve --reload` does not restart the converter child process.** After any schema change, do a full `./serve` restart.
- **Back up the database before Task 3 runs against real data:** `cp data/watch_later.sqlite data/watch_later.sqlite.pre-groups`. Dropping `videos.classification` is irreversible.
- **Group name/label values, verbatim:** `("children", "Children", 0)`, `("adults", "Adults", 1)`, `("anabel", "Anabel", 2)`, `("asmr", "ASMR", 3)`.
- **Plex kinds, verbatim:** `"tv"`, `"movies"`. These are never group names.
- **No group delete endpoint.** Out of scope (see spec non-goals).
- **No backward-compatible API aliases.** Old endpoints are removed, not deprecated.
- `GroupPosterStore` **does not exist** — it was deleted in commit `99b8289`. Ignore any reference to it in `CLAUDE.md`; Task 15 removes those.
- **`services.py` imports the `promote` module.** Do not name a function `promote` there — it would shadow the import and break `promote.promote_to_plex`. Task 4 aliases the import.

---

## File Structure

**Created**
- `ios/PatataTubeKit/Sources/PatataTubeKit/Feed.swift` — the `Feed` and `PlexKind` enums; the single place that knows the wire and persistence spellings of a feed.
- `ios/PatataTubeKit/Sources/PatataTubeKit/VideoGroup.swift` — the `VideoGroup` value type.
- `ios/PatataTubeKit/Sources/PatataTubeKit/GroupStore.swift` — UserDefaults mirror of the server's group list.
- `ios/PatataTubeKit/Tests/PatataTubeKitTests/FeedTests.swift`
- `ios/PatataTubeKit/Tests/PatataTubeKitTests/GroupStoreTests.swift`
- `tests/test_groups.py` — group table, accessors, migration.

**Deleted**
- `ios/PatataTubeKit/Sources/PatataTubeKit/GroupCoverStore.swift` and `ios/PatataTubeKit/Tests/PatataTubeKitTests/GroupCoverStoreTests.swift` — the emoji is a `VideoGroup` field now.

**Modified (with the responsibility that changes)**
- `db.py` — gains the `groups` table, its accessors, and the migration; loses `CLASSIFICATIONS`/`VIDEO_GROUPS`/`get_group_covers`/`set_group_cover`/`set_video_classification`.
- `services.py` — `apply_classification` splits into `set_group` and `promote`.
- `promote.py` — renamed to kind vocabulary.
- `router.py` — group CRUD endpoints, the `/group` and `/promote` video endpoints, new query params.
- `views/serializers.py` — emits `group_id`/`plex_kind`.
- `views/render.py`, `views/templates/_macros.html`, `views/templates/videos_page.html`, `assets/app/videos.js` — SSR port.
- `plex.py` — scan rows set `plex_kind`.
- `ios/PatataTubeKit/Sources/PatataTubeKit/`: `APIClient.swift`, `Video.swift`, `VideoStore.swift`, `VideoListCache.swift`, `MediaTab.swift`, `ResumeDecision.swift`, `RestorationState.swift`.
- `ios/PatataTube/Sources/`: `GroupsView.swift`, `VideoGridView.swift`, `VideoCell.swift`, `AppModel.swift`.
- `CLAUDE.md` — the classification/group/promote/cover paragraphs.

---

# Phase 1 — Database

### Task 1: The `groups` table and its accessors

**Files:**
- Modify: `db.py` (add near the other `CREATE TABLE IF NOT EXISTS` blocks in `init_db`, around `db.py:196-206`; accessors near the current `get_group_covers` at `db.py:557`)
- Test: `tests/test_groups.py` (create)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `db.PLEX_KINDS: tuple[str, ...] = ("tv", "movies")`
  - `db.DEFAULT_GROUPS: list[tuple[str, str, int]]` — the seed rows
  - `db.list_groups() -> list[dict]` — ordered by `position` ASC then `id` ASC; each dict has keys `id, name, label, emoji, position, created_at, updated_at`
  - `db.get_group(group_id: int) -> dict | None`
  - `db.get_group_by_name(name: str) -> dict | None`
  - `db.create_group(name: str, label: str, emoji: str | None = None, position: int | None = None) -> dict` — `position` defaults to `max(position) + 1`; raises `sqlite3.IntegrityError` on a duplicate name
  - `db.update_group(group_id: int, *, label: str | None = None, emoji: str | None = None, clear_emoji: bool = False, position: int | None = None) -> dict | None` — returns `None` if the id does not exist

- [ ] **Step 1: Write the failing tests**

Create `tests/test_groups.py`:

```python
import importlib
import os
import sqlite3

import pytest


@pytest.fixture
def fresh_db(tmp_path, monkeypatch):
    """A brand-new database with init_db() already run."""
    monkeypatch.setenv("DB_PATH", str(tmp_path / "test.sqlite"))
    import db as db_module

    importlib.reload(db_module)
    db_module.init_db()
    return db_module


def test_fresh_db_seeds_the_four_default_groups(fresh_db):
    groups = fresh_db.list_groups()
    assert [(g["name"], g["label"], g["position"]) for g in groups] == [
        ("children", "Children", 0),
        ("adults", "Adults", 1),
        ("anabel", "Anabel", 2),
        ("asmr", "ASMR", 3),
    ]
    assert all(g["emoji"] is None for g in groups)


def test_init_db_twice_does_not_reseed(fresh_db):
    fresh_db.init_db()
    assert len(fresh_db.list_groups()) == 4


def test_get_group_and_get_group_by_name(fresh_db):
    by_name = fresh_db.get_group_by_name("asmr")
    assert by_name["label"] == "ASMR"
    assert fresh_db.get_group(by_name["id"])["name"] == "asmr"
    assert fresh_db.get_group(9999) is None
    assert fresh_db.get_group_by_name("nope") is None


def test_create_group_appends_at_the_end(fresh_db):
    created = fresh_db.create_group("cooking", "Cooking")
    assert created["position"] == 4
    assert created["emoji"] is None
    assert [g["name"] for g in fresh_db.list_groups()][-1] == "cooking"


def test_create_group_rejects_a_duplicate_name(fresh_db):
    with pytest.raises(sqlite3.IntegrityError):
        fresh_db.create_group("asmr", "Whatever")


def test_update_group_sets_label_emoji_and_position(fresh_db):
    gid = fresh_db.get_group_by_name("children")["id"]
    updated = fresh_db.update_group(gid, label="Kids", emoji="🧒", position=9)
    assert (updated["label"], updated["emoji"], updated["position"]) == ("Kids", "🧒", 9)


def test_update_group_clears_the_emoji(fresh_db):
    gid = fresh_db.get_group_by_name("children")["id"]
    fresh_db.update_group(gid, emoji="🧒")
    assert fresh_db.update_group(gid, clear_emoji=True)["emoji"] is None


def test_update_group_returns_none_for_an_unknown_id(fresh_db):
    assert fresh_db.update_group(9999, label="x") is None


def test_plex_kinds_are_not_groups(fresh_db):
    assert fresh_db.PLEX_KINDS == ("tv", "movies")
    assert not {g["name"] for g in fresh_db.list_groups()} & set(fresh_db.PLEX_KINDS)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m pytest tests/test_groups.py -v`
Expected: FAIL — `AttributeError: module 'db' has no attribute 'list_groups'`.

- [ ] **Step 3: Add the table and the seed to `init_db`**

In `db.py`, replace the `group_covers` `executescript` block (currently `db.py:196-206`) with the `groups` table. Leave `group_covers` in place for now — Task 3 drops it, so it must still exist for that migration to read.

```python
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS group_covers (
                name TEXT PRIMARY KEY,
                emoji TEXT NOT NULL,
                updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
            );

            CREATE TABLE IF NOT EXISTS groups (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL UNIQUE,
                label TEXT NOT NULL,
                emoji TEXT,
                position INTEGER NOT NULL,
                created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
            );
            """
        )
        _seed_default_groups(conn)
```

At the top of `db.py`, delete the `CLASSIFICATIONS` and `VIDEO_GROUPS` lines (`db.py:9-12`) and put this in their place:

```python
# Plex media types. Deliberately NOT groups: they have their own tabs, their own
# scan source (plex.py), their own directories, and their own playback rules.
PLEX_KINDS = ("tv", "movies")

# Seeded into `groups` on a fresh database. After that the table is the truth —
# this list is not consulted again and must never be imported as "the groups".
DEFAULT_GROUPS = [
    ("children", "Children", 0),
    ("adults", "Adults", 1),
    ("anabel", "Anabel", 2),
    ("asmr", "ASMR", 3),
]
```

Deleting `CLASSIFICATIONS` breaks imports in `services.py`, `router.py` and several test modules. That is expected and gets fixed in Tasks 3–7; `tests/test_groups.py` does not import them, so it passes in isolation. Run the targeted file, not the suite, until Task 7.

- [ ] **Step 4: Write the accessors**

Add to `db.py`, replacing `get_group_covers`/`set_group_cover` at `db.py:557-575`:

```python
def _seed_default_groups(conn: sqlite3.Connection) -> None:
    """Seed the four starting groups, once, on a database that has none.

    Gated on emptiness rather than on the old `classification` column, so a
    brand-new install gets them too. Never re-runs: a user who deletes a group
    by hand does not get it resurrected on the next boot.
    """
    if conn.execute("SELECT 1 FROM groups LIMIT 1").fetchone():
        return
    conn.executemany(
        "INSERT INTO groups (name, label, position) VALUES (?, ?, ?)",
        DEFAULT_GROUPS,
    )


def list_groups() -> list[dict]:
    with _conn() as conn:
        rows = conn.execute(
            "SELECT * FROM groups ORDER BY position ASC, id ASC"
        ).fetchall()
        return [dict(r) for r in rows]


def get_group(group_id: int) -> dict | None:
    with _conn() as conn:
        row = conn.execute("SELECT * FROM groups WHERE id = ?", (group_id,)).fetchone()
        return dict(row) if row else None


def get_group_by_name(name: str) -> dict | None:
    with _conn() as conn:
        row = conn.execute("SELECT * FROM groups WHERE name = ?", (name,)).fetchone()
        return dict(row) if row else None


def create_group(
    name: str, label: str, emoji: str | None = None, position: int | None = None
) -> dict:
    """Raises sqlite3.IntegrityError when `name` is taken."""
    with _conn() as conn:
        if position is None:
            row = conn.execute("SELECT MAX(position) AS m FROM groups").fetchone()
            position = 0 if row["m"] is None else row["m"] + 1
        cur = conn.execute(
            "INSERT INTO groups (name, label, emoji, position) VALUES (?, ?, ?, ?)",
            (name, label, emoji, position),
        )
        row = conn.execute("SELECT * FROM groups WHERE id = ?", (cur.lastrowid,)).fetchone()
        return dict(row)


def update_group(
    group_id: int,
    *,
    label: str | None = None,
    emoji: str | None = None,
    clear_emoji: bool = False,
    position: int | None = None,
) -> dict | None:
    """Partial update. `clear_emoji` is how a caller sets the emoji to NULL —
    `emoji=None` means "leave it alone", since that is what an omitted JSON
    field decodes to."""
    sets: list[str] = []
    params: list = []
    if label is not None:
        sets.append("label = ?")
        params.append(label)
    if clear_emoji:
        sets.append("emoji = NULL")
    elif emoji is not None:
        sets.append("emoji = ?")
        params.append(emoji)
    if position is not None:
        sets.append("position = ?")
        params.append(position)
    with _conn() as conn:
        if not conn.execute("SELECT 1 FROM groups WHERE id = ?", (group_id,)).fetchone():
            return None
        if sets:
            sets.append("updated_at = CURRENT_TIMESTAMP")
            params.append(group_id)
            conn.execute(f"UPDATE groups SET {', '.join(sets)} WHERE id = ?", params)
        row = conn.execute("SELECT * FROM groups WHERE id = ?", (group_id,)).fetchone()
        return dict(row)
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `python -m pytest tests/test_groups.py -v`
Expected: PASS, 9 tests.

- [ ] **Step 6: Commit**

```bash
git add db.py tests/test_groups.py
git commit -m "feat(db): add a groups table with accessors and default seed"
```

---

### Task 2: `group_id` and `plex_kind` columns with video accessors

**Files:**
- Modify: `db.py` (column guards inside `init_db` near the other `if "x" not in columns` checks around `db.py:140-155`; `get_all_videos` at `db.py:590-604`; `set_video_classification` at `db.py:642-644`)
- Test: `tests/test_groups.py`

**Interfaces:**
- Consumes: `db.list_groups`, `db.get_group_by_name`, `db.create_group` (Task 1).
- Produces:
  - `db.set_video_group(video_id: int, group_id: int | None) -> None`
  - `db.set_video_plex_kind(video_id: int, kind: str | None) -> None`
  - `db.get_all_videos(group_id: int | None = None, plex_kind: str | None = None) -> list[dict]` — passing neither returns everything not soft-deleted, as today
  - `videos.group_id` and `videos.plex_kind` columns

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_groups.py`:

```python
def test_video_columns_exist(fresh_db):
    with fresh_db._conn() as conn:
        columns = {r["name"] for r in conn.execute("PRAGMA table_info(videos)")}
    assert {"group_id", "plex_kind"} <= columns


def test_set_video_group_and_filtered_read(fresh_db):
    kids = fresh_db.get_group_by_name("children")["id"]
    adults = fresh_db.get_group_by_name("adults")["id"]
    a = fresh_db.add_video("https://example.com/a", platform="twitter")
    b = fresh_db.add_video("https://example.com/b", platform="twitter")
    fresh_db.set_video_group(a, kids)
    fresh_db.set_video_group(b, adults)

    assert [v["id"] for v in fresh_db.get_all_videos(group_id=kids)] == [a]
    assert {v["id"] for v in fresh_db.get_all_videos()} == {a, b}


def test_set_video_group_to_none_unsorts_it(fresh_db):
    kids = fresh_db.get_group_by_name("children")["id"]
    vid = fresh_db.add_video("https://example.com/c", platform="twitter")
    fresh_db.set_video_group(vid, kids)
    fresh_db.set_video_group(vid, None)
    assert fresh_db.get_video(vid)["group_id"] is None
    assert fresh_db.get_all_videos(group_id=kids) == []


def test_plex_kind_filter_is_separate_from_groups(fresh_db):
    kids = fresh_db.get_group_by_name("children")["id"]
    show = fresh_db.add_video("https://example.com/s", platform="upload")
    kid = fresh_db.add_video("https://example.com/k", platform="upload")
    fresh_db.set_video_plex_kind(show, "tv")
    fresh_db.set_video_group(kid, kids)

    assert [v["id"] for v in fresh_db.get_all_videos(plex_kind="tv")] == [show]
    assert [v["id"] for v in fresh_db.get_all_videos(group_id=kids)] == [kid]
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m pytest tests/test_groups.py -v -k "video_columns or set_video_group or plex_kind_filter"`
Expected: FAIL — the `PRAGMA` assertion fails first, then `AttributeError: … 'set_video_group'`.

- [ ] **Step 3: Add the columns**

In `db.py`'s `init_db`, alongside the existing `if "resume_secs" not in columns:` guard (`db.py:154`), add:

```python
        # A video is either in a group or is a Plex item — never both, never
        # neither-but-meaningful. Nullability is the discriminator; there is no
        # `kind` column.
        if "group_id" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN group_id INTEGER REFERENCES groups(id)")
        if "plex_kind" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN plex_kind TEXT")
```

These guards must run **after** the `groups` table exists, because of the `REFERENCES` clause. Move the `groups` `executescript` from Task 1 above this block if it is not already, or leave the `ALTER`s where the other column guards are and confirm the `CREATE TABLE` runs first — check by reading `init_db` top to bottom.

- [ ] **Step 4: Write the accessors**

Replace `set_video_classification` (`db.py:642-644`) with:

```python
def set_video_group(video_id: int, group_id: int | None) -> None:
    """Put a video in a group, or (with None) leave it unsorted.

    Never touches plex_kind: promoting into Plex deletes the row entirely
    (see promote.py), so a row cannot end up carrying both.
    """
    with _conn() as conn:
        conn.execute("UPDATE videos SET group_id = ? WHERE id = ?", (group_id, video_id))


def set_video_plex_kind(video_id: int, kind: str | None) -> None:
    with _conn() as conn:
        conn.execute("UPDATE videos SET plex_kind = ? WHERE id = ?", (kind, video_id))
```

Replace `get_all_videos` (`db.py:590-604`) with:

```python
def get_all_videos(group_id: int | None = None, plex_kind: str | None = None) -> list[dict]:
    clauses = ["deleted_at IS NULL"]
    params: list = []
    if group_id is not None:
        clauses.append("group_id = ?")
        params.append(group_id)
    if plex_kind is not None:
        clauses.append("plex_kind = ?")
        params.append(plex_kind)
    sql = (
        f"SELECT * FROM videos WHERE {' AND '.join(clauses)}"
        " ORDER BY position DESC, created_at DESC"
    )
    with _conn() as conn:
        videos = [dict(r) for r in conn.execute(sql, params).fetchall()]
        _attach_versions(conn, videos)
    return videos
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `python -m pytest tests/test_groups.py -v`
Expected: PASS, 13 tests.

- [ ] **Step 6: Commit**

```bash
git add db.py tests/test_groups.py
git commit -m "feat(db): add videos.group_id and videos.plex_kind with accessors"
```

---

### Task 3: Migrate and drop `classification` and `group_covers`

**Files:**
- Modify: `db.py` (a new `_migrate_classifications_to_groups(conn)` called from `init_db` after `_seed_default_groups`)
- Test: `tests/test_groups.py`

**Interfaces:**
- Consumes: everything from Tasks 1–2.
- Produces: `db._migrate_classifications_to_groups(conn: sqlite3.Connection) -> int` — returns the number of rows whose old classification matched no group and no Plex kind (they are left unsorted). Callers log it; nothing branches on it.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_groups.py`. These build a pre-migration database by hand, because a migrated one no longer has the old shape:

```python
@pytest.fixture
def legacy_db(tmp_path, monkeypatch):
    """A database in the pre-groups shape: `classification` text, group_covers."""
    path = tmp_path / "legacy.sqlite"
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        CREATE TABLE videos (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            url TEXT NOT NULL,
            platform TEXT,
            title TEXT,
            classification TEXT,
            status TEXT NOT NULL DEFAULT 'queued',
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        );
        CREATE TABLE group_covers (
            name TEXT PRIMARY KEY,
            emoji TEXT NOT NULL,
            updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        );
        INSERT INTO videos (url, classification) VALUES
            ('u1', 'children'),
            ('u2', 'asmr'),
            ('u3', 'tv'),
            ('u4', 'movies'),
            ('u5', 'ancient-typo'),
            ('u6', NULL);
        INSERT INTO group_covers (name, emoji) VALUES ('asmr', '🎧'), ('adults', '🍷');
        """
    )
    conn.commit()
    conn.close()

    monkeypatch.setenv("DB_PATH", str(path))
    import db as db_module

    importlib.reload(db_module)
    return db_module


def _by_url(db_module):
    with db_module._conn() as conn:
        return {
            r["url"]: dict(r)
            for r in conn.execute("SELECT * FROM videos").fetchall()
        }


def test_migration_backfills_group_id_from_classification(legacy_db):
    legacy_db.init_db()
    groups = {g["name"]: g["id"] for g in legacy_db.list_groups()}
    rows = _by_url(legacy_db)
    assert rows["u1"]["group_id"] == groups["children"]
    assert rows["u2"]["group_id"] == groups["asmr"]


def test_migration_backfills_plex_kind_and_leaves_group_null(legacy_db):
    legacy_db.init_db()
    rows = _by_url(legacy_db)
    assert (rows["u3"]["plex_kind"], rows["u3"]["group_id"]) == ("tv", None)
    assert (rows["u4"]["plex_kind"], rows["u4"]["group_id"]) == ("movies", None)


def test_migration_leaves_unmatched_and_null_rows_unsorted(legacy_db):
    legacy_db.init_db()
    rows = _by_url(legacy_db)
    for url in ("u5", "u6"):
        assert rows[url]["group_id"] is None
        assert rows[url]["plex_kind"] is None


def test_migration_folds_group_covers_into_groups(legacy_db):
    legacy_db.init_db()
    covers = {g["name"]: g["emoji"] for g in legacy_db.list_groups()}
    assert covers["asmr"] == "🎧"
    assert covers["adults"] == "🍷"
    assert covers["children"] is None


def test_migration_drops_the_old_column_and_table(legacy_db):
    legacy_db.init_db()
    with legacy_db._conn() as conn:
        columns = {r["name"] for r in conn.execute("PRAGMA table_info(videos)")}
        tables = {
            r["name"]
            for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")
        }
    assert "classification" not in columns
    assert "group_covers" not in tables


def test_migration_is_idempotent(legacy_db):
    legacy_db.init_db()
    first = _by_url(legacy_db)
    legacy_db.init_db()
    assert _by_url(legacy_db) == first
    assert len(legacy_db.list_groups()) == 4
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m pytest tests/test_groups.py -v -k migration`
Expected: FAIL — `sqlite3.OperationalError: no such column: group_id` or the `classification` column still present.

- [ ] **Step 3: Write the migration**

Add to `db.py`, and call it from `init_db` immediately after `_seed_default_groups(conn)` — the seed must land first so the backfill join has rows to match:

```python
def _migrate_classifications_to_groups(conn: sqlite3.Connection) -> int:
    """Fold the old `classification` text column into `groups` + `plex_kind`.

    One-shot and self-disarming: every step is guarded on the old shape still
    being present, so the second run does nothing. A classification value that
    matches no group and no Plex kind leaves the row unsorted rather than
    failing the migration — the column was never constrained, so a typo from
    2026 must not block boot. The count of those is returned so the caller can
    say so out loud.
    """
    columns = {row["name"] for row in conn.execute("PRAGMA table_info(videos)").fetchall()}
    if "classification" not in columns:
        return 0

    placeholders = ",".join("?" for _ in PLEX_KINDS)
    conn.execute(
        "UPDATE videos SET group_id = ("
        "  SELECT groups.id FROM groups WHERE groups.name = videos.classification"
        f") WHERE classification IS NOT NULL AND classification NOT IN ({placeholders})",
        PLEX_KINDS,
    )
    conn.execute(
        f"UPDATE videos SET plex_kind = classification WHERE classification IN ({placeholders})",
        PLEX_KINDS,
    )
    unmatched = conn.execute(
        "SELECT COUNT(*) AS n FROM videos"
        " WHERE classification IS NOT NULL AND group_id IS NULL AND plex_kind IS NULL"
    ).fetchone()["n"]

    tables = {
        row["name"]
        for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()
    }
    if "group_covers" in tables:
        conn.execute(
            "UPDATE groups SET emoji = ("
            "  SELECT emoji FROM group_covers WHERE group_covers.name = groups.name"
            ") WHERE EXISTS (SELECT 1 FROM group_covers WHERE group_covers.name = groups.name)"
        )
        conn.execute("DROP TABLE group_covers")

    # SQLite 3.35+ (Python 3.13 ships far past it) can drop a column in place,
    # so no 12-step table rebuild is needed.
    conn.execute("ALTER TABLE videos DROP COLUMN classification")

    if unmatched:
        print(f"[migrate] {unmatched} video(s) had an unknown classification and are now unsorted")
    return unmatched
```

Then, in `init_db`, delete the `group_covers` `CREATE TABLE IF NOT EXISTS` block entirely (it was kept alive only for this migration to read, and re-creating it after the drop would resurrect it every boot). Order inside `init_db` must be: video column guards → `groups` table → `_seed_default_groups(conn)` → `_migrate_classifications_to_groups(conn)`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m pytest tests/test_groups.py -v`
Expected: PASS, 19 tests.

- [ ] **Step 5: Back up and migrate the real database**

```bash
cp data/watch_later.sqlite data/watch_later.sqlite.pre-groups
python -c "import db; db.init_db()"
sqlite3 data/watch_later.sqlite "SELECT name, label, emoji, position FROM groups ORDER BY position;"
sqlite3 data/watch_later.sqlite "SELECT plex_kind, COUNT(*) FROM videos GROUP BY plex_kind;"
sqlite3 data/watch_later.sqlite "SELECT group_id, COUNT(*) FROM videos GROUP BY group_id;"
```

Expected: four groups with the covers you had; every previously-classified row accounted for; the `[migrate] N video(s)…` line either absent or explaining a count you recognise.

- [ ] **Step 6: Commit**

```bash
git add db.py tests/test_groups.py
git commit -m "feat(db): migrate classification into groups and drop the old column"
```

---

# Phase 2 — Backend

### Task 4: Split `apply_classification` into `set_group` and `promote`

**Files:**
- Modify: `services.py` (whole file is 38 lines; `apply_classification` at `services.py:19-32`)
- Modify: `promote.py` (`PROMOTED_CLASSIFICATIONS` at `:28`, `dest_dir` at `:38-43`, `_refresh_plex` at `:67-74`, `promote_to_plex` at `:77-114`)
- Test: `tests/test_services.py`, `tests/test_promote.py`

**Interfaces:**
- Consumes: `db.set_video_group`, `db.get_group` (Tasks 1–2).
- Produces:
  - `services.set_group(video_id: int, group_id: int) -> bool` — `False` when the group id does not exist; nothing is written then
  - `services.promote(video_id: int, kind: str) -> bool` — `False` for an unknown kind or a missing/library video; `True` when the file moved and the row was deleted; raises `promote.PromotionError` on a failed move
  - `promote.PLEX_KINDS: frozenset[str]` (renamed from `PROMOTED_CLASSIFICATIONS`)
  - `promote.dest_dir(kind: str) -> Path`
  - `services.ClassificationResult` is **deleted** — the two verbs return plain bools now

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_services.py` (keep the existing fixtures; if it has none, use the `fresh_db` pattern from `tests/test_groups.py`):

```python
def test_set_group_writes_the_column(fresh_db, monkeypatch):
    import services

    importlib.reload(services)
    gid = fresh_db.get_group_by_name("adults")["id"]
    vid = fresh_db.add_video("https://example.com/x", platform="twitter")
    assert services.set_group(vid, gid) is True
    assert fresh_db.get_video(vid)["group_id"] == gid


def test_set_group_rejects_an_unknown_group(fresh_db):
    import services

    importlib.reload(services)
    vid = fresh_db.add_video("https://example.com/y", platform="twitter")
    assert services.set_group(vid, 9999) is False
    assert fresh_db.get_video(vid)["group_id"] is None


def test_promote_rejects_an_unknown_kind(fresh_db):
    import services

    importlib.reload(services)
    vid = fresh_db.add_video("https://example.com/z", platform="twitter")
    assert services.promote(vid, "podcasts") is False


def test_promote_hands_a_download_to_plex(fresh_db, monkeypatch):
    import promote
    import services

    importlib.reload(services)
    calls = []
    monkeypatch.setattr(promote, "promote_to_plex", lambda v, k: calls.append((v["id"], k)))
    vid = fresh_db.add_video("https://example.com/w", platform="twitter")
    assert services.promote(vid, "tv") is True
    assert calls == [(vid, "tv")]


def test_promote_skips_library_rows(fresh_db, monkeypatch):
    import promote
    import services

    importlib.reload(services)
    monkeypatch.setattr(
        promote, "promote_to_plex", lambda v, k: pytest.fail("library rows never move")
    )
    vid = fresh_db.add_video("https://example.com/l", platform="upload")
    fresh_db.update_video(vid, source="library")
    assert services.promote(vid, "movies") is False
```

In `tests/test_promote.py`, replace the assertion at `:28`:

```python
def test_plex_kinds():
    assert promote.PLEX_KINDS == frozenset({"tv", "movies"})
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m pytest tests/test_services.py tests/test_promote.py -v`
Expected: FAIL — `AttributeError: module 'services' has no attribute 'set_group'` and `… no attribute 'PLEX_KINDS'`.

- [ ] **Step 3: Rewrite `services.py`**

Replace `services.py:1-32` (keep `choose_version` untouched at the bottom):

```python
"""Mutation logic shared by the SSR form endpoints and the JSON API."""

import db
import hls
# Aliased: this module defines a function called `promote`, which would
# otherwise shadow the import and break every `promote.…` reference below.
import promote as plex_promote


def set_group(video_id: int, group_id: int) -> bool:
    """Put a video in a group. False when the group does not exist.

    This is a pure column write. Handing a download to Plex is `promote()` —
    a different verb with different consequences (the file moves, the row is
    deleted), and it used to be spelled as a value of this same call.
    """
    if db.get_group(group_id) is None:
        return False
    db.set_video_group(video_id, group_id)
    return True


def promote(video_id: int, kind: str) -> bool:
    """Move a downloaded file into Plex. The row is deleted on success.

    False for an unknown kind, a missing video, or a library row (those already
    live in Plex and never move). Raises promote.PromotionError when the move
    itself fails — nothing is written then.
    """
    if kind not in plex_promote.PLEX_KINDS:
        return False
    video = db.get_video(video_id)
    if not video or video.get("source") == "library":
        return False
    plex_promote.promote_to_plex(video, kind)
    return True
```

Delete the `ClassificationResult` dataclass and the `from db import CLASSIFICATIONS` import. `choose_version` at the bottom of the file calls `hls.invalidate` and is untouched.

- [ ] **Step 4: Rename `promote.py`'s vocabulary**

In `promote.py`, rename with no behavior change:
- `PROMOTED_CLASSIFICATIONS` → `PLEX_KINDS` (line 28)
- `dest_dir(classification)` → `dest_dir(kind)`; the error message becomes `f"not a Plex kind: {kind}"` (lines 38-43)
- `_refresh_plex(classification)` → `_refresh_plex(kind)`; `"movie" if kind == "movies" else "show"` (lines 67-74)
- `promote_to_plex(video, classification)` → `promote_to_plex(video, kind)` and its internal uses (lines 77-114)
- Its docstring line "the row stays, and no classification is written" → "the row stays, and no group is written"

Leave `_DEST_ENV` and the `LIBRARY_TV_DIR`/`LIBRARY_MOVIES_DIR` env names alone.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `python -m pytest tests/test_services.py tests/test_promote.py -v`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add services.py promote.py tests/test_services.py tests/test_promote.py
git commit -m "refactor: split apply_classification into set_group and promote"
```

---

### Task 5: Group CRUD endpoints

**Files:**
- Modify: `router.py` (replace `/api/classifications` at `:830-832` and the two `/api/group-covers` endpoints at `:845-861`; the `GroupCoverRequest` model and `MAX_GROUP_COVER_CHARS` live near `router.py:48`)
- Test: `tests/test_api.py`

**Interfaces:**
- Consumes: `db.list_groups`, `db.get_group`, `db.create_group`, `db.update_group` (Task 1).
- Produces:
  - `GET /api/groups` → `{"groups": [{"id": int, "name": str, "label": str, "emoji": str | null, "position": int}]}` — ungated, like the list endpoint it replaces
  - `POST /api/groups` `{"name": str, "label": str, "emoji": str | null}` → `201` with the group object; `400` on a blank name or a name that collides, or that is `"tv"`/`"movies"`; token-gated
  - `PATCH /api/groups/{group_id}` `{"label"?: str, "emoji"?: str | null, "position"?: int}` → the updated group object; `404` unknown id; `400` on an over-long emoji; token-gated
  - `router.serialize_group(group: dict) -> dict` — trims the DB row to the five wire fields

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_api.py`, using the existing `client` fixture and its auth header helper:

```python
def test_get_groups_lists_the_defaults(client):
    resp = client.get("/api/groups")
    assert resp.status_code == 200
    groups = resp.json()["groups"]
    assert [g["name"] for g in groups] == ["children", "adults", "anabel", "asmr"]
    assert set(groups[0]) == {"id", "name", "label", "emoji", "position"}


def test_create_group_requires_a_token(client):
    resp = client.post("/api/groups", json={"name": "cooking", "label": "Cooking"})
    assert resp.status_code == 401


def test_create_group_appends_it(client, auth_headers):
    resp = client.post(
        "/api/groups", json={"name": "cooking", "label": "Cooking", "emoji": "🍳"},
        headers=auth_headers,
    )
    assert resp.status_code == 201
    assert resp.json()["name"] == "cooking"
    assert resp.json()["position"] == 4
    assert [g["name"] for g in client.get("/api/groups").json()["groups"]][-1] == "cooking"


def test_create_group_rejects_a_duplicate_or_plex_name(client, auth_headers):
    assert client.post(
        "/api/groups", json={"name": "asmr", "label": "x"}, headers=auth_headers
    ).status_code == 400
    assert client.post(
        "/api/groups", json={"name": "tv", "label": "x"}, headers=auth_headers
    ).status_code == 400
    assert client.post(
        "/api/groups", json={"name": "  ", "label": "x"}, headers=auth_headers
    ).status_code == 400


def test_patch_group_sets_the_emoji(client, auth_headers):
    gid = client.get("/api/groups").json()["groups"][0]["id"]
    resp = client.patch(f"/api/groups/{gid}", json={"emoji": "🧒"}, headers=auth_headers)
    assert resp.status_code == 200
    assert resp.json()["emoji"] == "🧒"


def test_patch_group_clears_the_emoji_with_null(client, auth_headers):
    gid = client.get("/api/groups").json()["groups"][0]["id"]
    client.patch(f"/api/groups/{gid}", json={"emoji": "🧒"}, headers=auth_headers)
    resp = client.patch(f"/api/groups/{gid}", json={"emoji": None}, headers=auth_headers)
    assert resp.json()["emoji"] is None


def test_patch_unknown_group_is_404(client, auth_headers):
    assert client.patch(
        "/api/groups/9999", json={"label": "x"}, headers=auth_headers
    ).status_code == 404


def test_old_classification_and_cover_endpoints_are_gone(client):
    assert client.get("/api/classifications").status_code == 404
    assert client.get("/api/group-covers").status_code == 404
```

Delete the existing test at `tests/test_api.py:764` that asserts `{"classifications": db.CLASSIFICATIONS}`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m pytest tests/test_api.py -v -k "group"`
Expected: FAIL — 404s on `/api/groups`, and collection may error on `db.CLASSIFICATIONS` imports until Task 6 finishes. If collection errors, fix only the import in the test file and re-run.

- [ ] **Step 3: Write the endpoints**

In `router.py`, replace the `GroupCoverRequest` model near line 48 with:

```python
# A group emoji is one emoji, but "one emoji" can be many code points — a ZWJ
# family or a flag is several scalars. Cap on characters, not on scalar count.
MAX_GROUP_EMOJI_CHARS = 16


class GroupCreateRequest(BaseModel):
    name: str
    label: str
    emoji: str | None = None


class GroupUpdateRequest(BaseModel):
    label: str | None = None
    emoji: str | None = None
    position: int | None = None
```

Replace `/api/classifications` and both `/api/group-covers` endpoints with:

```python
def serialize_group(group: dict) -> dict:
    return {
        "id": group["id"],
        "name": group["name"],
        "label": group["label"],
        "emoji": group["emoji"],
        "position": group["position"],
    }


@router.get("/api/groups")
async def api_groups():
    """Every video group, in display order. The iOS Videos tab mirrors this
    into UserDefaults so its cards still render offline."""
    return {"groups": [serialize_group(g) for g in db.list_groups()]}


@router.post("/api/groups", status_code=201)
async def api_create_group(body: GroupCreateRequest, request: Request):
    _check_token(request)
    name = body.name.strip()
    label = body.label.strip()
    if not name or not label:
        raise HTTPException(status_code=400, detail="Name and label are required")
    if name in db.PLEX_KINDS:
        raise HTTPException(status_code=400, detail="tv and movies are Plex kinds, not groups")
    emoji = _validated_emoji(body.emoji)
    try:
        group = db.create_group(name, label, emoji)
    except sqlite3.IntegrityError:
        raise HTTPException(status_code=400, detail="That group name is taken") from None
    return serialize_group(group)


@router.patch("/api/groups/{group_id}")
async def api_update_group(group_id: int, body: GroupUpdateRequest, request: Request):
    _check_token(request)
    fields = body.model_dump(exclude_unset=True)
    emoji = _validated_emoji(body.emoji) if "emoji" in fields else None
    group = db.update_group(
        group_id,
        label=body.label.strip() if body.label else None,
        emoji=emoji,
        # An explicit `"emoji": null` clears it; an omitted key leaves it alone.
        clear_emoji="emoji" in fields and not emoji,
        position=body.position,
    )
    if group is None:
        raise HTTPException(status_code=404, detail="No such group")
    return serialize_group(group)


def _validated_emoji(raw: str | None) -> str | None:
    emoji = (raw or "").strip()
    if len(emoji) > MAX_GROUP_EMOJI_CHARS:
        raise HTTPException(status_code=400, detail="Cover must be a single emoji")
    return emoji or None
```

Add `import sqlite3` to `router.py`'s imports if absent, and drop `CLASSIFICATIONS`/`VIDEO_GROUPS`/`MAX_GROUP_COVER_CHARS` from its imports and body.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m pytest tests/test_api.py -v -k "group"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add router.py tests/test_api.py
git commit -m "feat(api): add group CRUD endpoints, drop classifications and group-covers"
```

---

### Task 6: Video endpoints, serializer, and `plex.py`

**Files:**
- Modify: `router.py` (`/api/videos` at `:835-842`, `/api/videos/{id}/classify` at `:864+`, `/videos/{id}/classify` SSR form at `:814-820`, `/videos/{id}/version` at `:824-827`, `/upload/file` at `:303-331`)
- Modify: `views/serializers.py:81`
- Modify: `plex.py:93,114`
- Test: `tests/test_api.py`, `tests/test_serializers.py`, `tests/test_plex.py`

**Interfaces:**
- Consumes: `services.set_group`, `services.promote` (Task 4); `db.get_all_videos(group_id=, plex_kind=)` (Task 2); `db.get_group_by_name` (Task 1).
- Produces:
  - `GET /api/videos?group_id=<int>` and `?plex_kind=tv|movies` — an unknown value returns an empty list rather than everything
  - `POST /api/videos/{id}/group` `{"group_id": int}` → `{"ok": true}`; `400` unknown group; token-gated
  - `POST /api/videos/{id}/promote` `{"kind": "tv"|"movies"}` → `{"ok": true, "promoted": true}`; `400` unknown kind or library row; `409` on `PromotionError`; token-gated
  - `serialize_video` emits `"group_id": int | null` and `"plex_kind": str | null`, and no longer emits `"classification"`

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_api.py`:

```python
def test_set_group_endpoint(client, auth_headers):
    gid = client.get("/api/groups").json()["groups"][1]["id"]
    vid = client.post(
        "/api/videos", json={"url": "https://example.com/v"}, headers=auth_headers
    ).json()["id"]
    resp = client.post(f"/api/videos/{vid}/group", json={"group_id": gid}, headers=auth_headers)
    assert resp.status_code == 200 and resp.json()["ok"] is True
    assert client.get(f"/api/videos?group_id={gid}").json()[0]["id"] == vid


def test_set_group_rejects_an_unknown_group(client, auth_headers):
    vid = client.post(
        "/api/videos", json={"url": "https://example.com/v2"}, headers=auth_headers
    ).json()["id"]
    resp = client.post(f"/api/videos/{vid}/group", json={"group_id": 9999}, headers=auth_headers)
    assert resp.status_code == 400


def test_promote_endpoint_rejects_an_unknown_kind(client, auth_headers):
    vid = client.post(
        "/api/videos", json={"url": "https://example.com/v3"}, headers=auth_headers
    ).json()["id"]
    resp = client.post(f"/api/videos/{vid}/promote", json={"kind": "podcasts"}, headers=auth_headers)
    assert resp.status_code == 400


def test_promote_endpoint_returns_409_on_promotion_error(client, auth_headers, monkeypatch):
    import promote

    def boom(video, kind):
        raise promote.PromotionError("volume not mounted")

    monkeypatch.setattr(promote, "promote_to_plex", boom)
    vid = client.post(
        "/api/videos", json={"url": "https://example.com/v4"}, headers=auth_headers
    ).json()["id"]
    resp = client.post(f"/api/videos/{vid}/promote", json={"kind": "tv"}, headers=auth_headers)
    assert resp.status_code == 409
    assert "volume not mounted" in resp.json()["detail"]


def test_unknown_group_id_filter_returns_nothing(client, auth_headers):
    client.post("/api/videos", json={"url": "https://example.com/v5"}, headers=auth_headers)
    assert client.get("/api/videos?group_id=9999").json() == []


def test_upload_file_no_longer_rejects_plex_kinds(client, auth_headers):
    """tv/movies are not group values any more, so the case cannot arise."""
    gid = client.get("/api/groups").json()["groups"][0]["id"]
    resp = client.post(
        "/upload/file",
        files={"file": ("clip.mp4", b"\x00\x00", "video/mp4")},
        data={"group_id": str(gid)},
        headers=auth_headers,
    )
    assert resp.status_code == 202
```

In `tests/test_serializers.py`, replace any `"classification"` assertion with:

```python
def test_serialize_video_emits_group_id_and_plex_kind():
    data = serialize_video({"id": 1, "url": "u", "status": "done", "group_id": 3})
    assert data["group_id"] == 3
    assert data["plex_kind"] is None
    assert "classification" not in data


def test_serialize_video_leaves_an_unsorted_video_null():
    data = serialize_video({"id": 1, "url": "u", "status": "done"})
    assert data["group_id"] is None
```

In `tests/test_plex.py`, change the two assertions that expect `"classification": "movies"`/`"tv"` to `"plex_kind"`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m pytest tests/test_api.py tests/test_serializers.py tests/test_plex.py -v`
Expected: FAIL — 404s on the new endpoints, `KeyError`/`assert` on the serializer keys.

- [ ] **Step 3: Rewrite the video endpoints**

In `router.py`, replace `/api/videos` (`:835-842`) and the `/api/videos/{id}/classify` endpoint:

```python
@router.get("/api/videos")
async def api_videos(group_id: int | None = None, plex_kind: str | None = None):
    if plex_kind is not None and plex_kind not in db.PLEX_KINDS:
        return []
    videos = db.get_all_videos(group_id=group_id, plex_kind=plex_kind)
    return [serialize_video(v) for v in videos]


class SetGroupRequest(BaseModel):
    group_id: int


class PromoteRequest(BaseModel):
    kind: str


@router.post("/api/videos/{video_id}/group")
async def api_set_video_group(video_id: int, body: SetGroupRequest, request: Request):
    _check_token(request)
    if not await asyncio.to_thread(services.set_group, video_id, body.group_id):
        raise HTTPException(status_code=400, detail="No such group")
    return {"ok": True}


@router.post("/api/videos/{video_id}/promote")
async def api_promote_video(video_id: int, body: PromoteRequest, request: Request):
    """Hand a downloaded file to Plex. On success the file moves and the row is
    deleted; it comes back later as a library row via scan_library."""
    _check_token(request)
    try:
        promoted = await asyncio.to_thread(services.promote, video_id, body.kind)
    except promote.PromotionError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    if not promoted:
        raise HTTPException(status_code=400, detail="Not a promotable video or kind")
    return {"ok": True, "promoted": True}
```

Replace the SSR form endpoints (`:814-827`):

```python
@router.post("/videos/{video_id}/group")
async def set_video_group_endpoint(
    video_id: int, group_id: int = Form(...), current_group_id: int | None = Form(default=None)
):
    await asyncio.to_thread(services.set_group, video_id, group_id)
    redirect_url = f"/?group_id={current_group_id}" if current_group_id else "/"
    return RedirectResponse(url=redirect_url, status_code=303)


@router.post("/videos/{video_id}/promote")
async def promote_video_endpoint(
    video_id: int, kind: str = Form(...), current_group_id: int | None = Form(default=None)
):
    try:
        await asyncio.to_thread(services.promote, video_id, kind)
    except promote.PromotionError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    redirect_url = f"/?group_id={current_group_id}" if current_group_id else "/"
    return RedirectResponse(url=redirect_url, status_code=303)


@router.post("/videos/{video_id}/version")
async def choose_video_version_endpoint(
    video_id: int, version_id: int = Form(...), group_id: int | None = Form(default=None)
):
    services.choose_version(video_id, version_id)
    redirect_url = f"/?group_id={group_id}" if group_id else "/"
    return RedirectResponse(url=redirect_url, status_code=303)
```

Rewrite `/upload/file`'s signature and body (`:303-331`) — the two `HTTPException`s at the top go away entirely:

```python
async def upload_file(
    request: Request,
    background_tasks: BackgroundTasks,
    file: UploadFile = File(...),
    group_id: int = Form(...),
):
    _check_token(request)
    if db.get_group(group_id) is None:
        raise HTTPException(status_code=400, detail="No such group")
    # …unchanged temp-file handling…
    video_id = db.add_video(str(tmp_path), platform="upload", title=title)
    services.set_group(video_id, group_id)
```

- [ ] **Step 4: Update the serializer and `plex.py`**

`views/serializers.py:81` — replace the one line with two:

```python
        # Unsorted is honestly null. The old `or "children"` fallback silently
        # filed every unclassified download under children.
        "group_id": video.get("group_id"),
        "plex_kind": video.get("plex_kind"),
```

`plex.py:93` and `:114` — change the dict keys `"classification": "movies"` and `"classification": "tv"` to `"plex_kind": "movies"` / `"plex_kind": "tv"`. Then follow those dicts to their consumer in `library.py`/`db.py` (`db.set_library_state` / `db.add_video`) and rename the parameter there too — grep for `classification` in `library.py` and `db.py` and fix every remaining hit.

- [ ] **Step 5: Run the whole backend suite**

Run: `python -m pytest tests/ -v`
Expected: PASS. Remaining failures should only be in `tests/test_render.py`, which Task 7 fixes — note them and move on.

- [ ] **Step 6: Commit**

```bash
git add router.py views/serializers.py plex.py library.py db.py tests/
git commit -m "feat(api): group and promote endpoints, group_id/plex_kind on the wire"
```

---

# Phase 3 — Server-rendered page

### Task 7: Port the SSR page to groups

**Files:**
- Modify: `views/render.py:98-106`
- Modify: `views/templates/_macros.html` (`nav` at `:8-15`, `classification_menu` at `:17-30`, `card` at `:32-35`)
- Modify: `views/templates/videos_page.html` (`:26-27`, `:41-46`, `:51`, `:54`)
- Modify: `assets/app/videos.js:246,254`
- Modify: `router.py` (the `GET /` handler that calls `build_videos_page` — grep for `build_videos_page`)
- Test: `tests/test_render.py`

**Interfaces:**
- Consumes: `db.list_groups` (Task 1), the `/videos/{id}/group` and `/videos/{id}/promote` form endpoints (Task 6).
- Produces: `views.render.build_videos_page(videos: list[dict], groups: list[dict], current_group_id: int | None, current_plex_kind: str | None) -> str`

- [ ] **Step 1: Write the failing tests**

Rewrite `tests/test_render.py`'s helpers. Replace the `from db import CLASSIFICATIONS` import at `:1` and every `CLASSIFICATIONS` argument with a literal group list, so the test does not depend on a live database:

```python
GROUPS = [
    {"id": 1, "name": "children", "label": "Children", "emoji": None, "position": 0},
    {"id": 2, "name": "adults", "label": "Adults", "emoji": "🍷", "position": 1},
]


def test_page_renders_group_labels_not_names():
    html = build_videos_page([_video()], GROUPS, 1, None)
    assert "Children" in html
    assert "?group_id=1" in html


def test_page_marks_the_current_group_active():
    html = build_videos_page([_video()], GROUPS, 2, None)
    assert 'class="nav-link active"' in html


def test_page_offers_plex_links():
    html = build_videos_page([], GROUPS, None, None)
    assert "?plex_kind=tv" in html
    assert "?plex_kind=movies" in html


def test_card_menu_posts_to_the_group_endpoint():
    html = build_videos_page([_video()], GROUPS, 1, None)
    assert "/group" in html
    assert "/promote" in html
```

Update `_video()` in that file so its dict has `"group_id": 1` instead of `"classification": "children"`. Keep the other existing tests, adjusting their arguments to `(videos, GROUPS, current_group_id, None)`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m pytest tests/test_render.py -v`
Expected: FAIL — `TypeError: build_videos_page() takes 3 positional arguments but 4 were given`.

- [ ] **Step 3: Update `render.py`**

Replace `views/render.py:98-106`:

```python
def build_videos_page(
    videos: list[dict],
    groups: list[dict],
    current_group_id: int | None,
    current_plex_kind: str | None,
) -> str:
    template = _env.get_template("videos_page.html")
    return template.render(
        videos=videos,
        groups=groups,
        current_group_id=current_group_id,
        current_plex_kind=current_plex_kind,
        upload_token=os.getenv("UPLOAD_TOKEN", ""),
        splash_images=SPLASH_STARTUP_IMAGES,
    )
```

- [ ] **Step 4: Update the templates**

`views/templates/_macros.html` — replace the `nav` and `classification_menu` macros:

```jinja
{% macro nav(groups, current_group_id, current_plex_kind) -%}
<nav class="nav">
{%- for g in groups -%}
<a href="/?group_id={{ g.id }}" class="nav-link{{ ' active' if g.id == current_group_id else '' }}">{{ g.emoji ~ ' ' if g.emoji }}{{ g.label }}</a>
{%- endfor -%}
<a href="/?plex_kind=tv" class="nav-link{{ ' active' if current_plex_kind == 'tv' else '' }}">TV</a>
<a href="/?plex_kind=movies" class="nav-link{{ ' active' if current_plex_kind == 'movies' else '' }}">Movies</a>
</nav>
{%- endmacro %}

{% macro group_menu(v, groups, current_group_id) -%}
<div class="cls-menu">
{%- for g in groups -%}
<form method="post" action="/videos/{{ v.id }}/group">
<input type="hidden" name="current_group_id" value="{{ current_group_id or '' }}">
<input type="hidden" name="group_id" value="{{ g.id }}">
<button type="submit" class="cls-btn{{ ' active-cls' if g.id == v.group_id else '' }}">{{ g.label }}</button>
</form>
{%- endfor -%}
{%- for kind, label in [('tv', 'Move to TV'), ('movies', 'Move to Movies')] -%}
<form method="post" action="/videos/{{ v.id }}/promote">
<input type="hidden" name="current_group_id" value="{{ current_group_id or '' }}">
<input type="hidden" name="kind" value="{{ kind }}">
<button type="submit" class="cls-btn promote-btn">{{ label }}</button>
</form>
{%- endfor -%}
</div>
{%- endmacro %}
```

Keep the surrounding markup of the originals — copy the real `<nav>`/`<div>` classes and structure out of the existing file rather than the shapes above, which show only the parts that change. Update the `card` macro at `:32-35` to take `(v, groups, current_group_id, upload_token)` and call `group_menu(v, groups, current_group_id)`.

`views/templates/videos_page.html`:
- `:26-27` — the upload `<select id="upload-group">` iterates `groups` and uses `value="{{ g.id }}"`, `{{ g.label }}` as text.
- `:41-46` — the cookie-preference script: rename the param to `group_id`, the cookie to `preferred_group_id`, and the redirect to `/?group_id='+m[1]`.
- `:51` — `{{ m.nav(groups, current_group_id, current_plex_kind) }}`
- `:54` — `{{ m.card(v, groups, current_group_id, upload_token) }}`

`assets/app/videos.js:246,254` — `getElementById('upload-group')` and `formData.append('group_id', groupSelect.value)`.

- [ ] **Step 5: Update the `GET /` handler**

In `router.py`, find the handler that calls `build_videos_page` and give it the new query params:

```python
@router.get("/", response_class=HTMLResponse)
async def index(group_id: int | None = None, plex_kind: str | None = None):
    if plex_kind is not None and plex_kind not in db.PLEX_KINDS:
        plex_kind = None
    videos = db.get_all_videos(group_id=group_id, plex_kind=plex_kind)
    return HTMLResponse(build_videos_page(videos, db.list_groups(), group_id, plex_kind))
```

Preserve whatever caching headers or response class the existing handler uses; only the arguments change.

- [ ] **Step 6: Run the full suite**

Run: `python -m pytest tests/ -v`
Expected: PASS, all of it.

- [ ] **Step 7: Verify the page by hand**

```bash
./serve
```

Open `http://localhost:3050/`. Confirm: nav shows the four group labels plus TV and Movies; clicking a group filters and highlights it; a card's menu lists the groups and two "Move to…" buttons; the upload modal's picker lists groups only. Check `log/backend.log` for tracebacks.

- [ ] **Step 8: Commit**

```bash
git add views/ assets/app/videos.js router.py tests/test_render.py
git commit -m "feat(web): port the server-rendered page to groups"
```

---

# Phase 4 — iOS logic package

All Phase 4 and 5 work happens in `ios/`. Build with `cd ios/PatataTubeKit && swift build`.

### Task 8: `Feed`, `PlexKind`, and `VideoGroup`

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/Feed.swift`
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/VideoGroup.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/FeedTests.swift` (create)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public enum PlexKind: String, Codable, Hashable, Sendable { case tv, movies }`
  - `public enum Feed: Codable, Hashable, Sendable { case all, group(id: Int), plex(PlexKind) }`
  - `Feed.queryItems: [URLQueryItem]` — `[]`, `[group_id=N]`, `[plex_kind=tv]`
  - `Feed.storageKey: String` — `"all"`, `"group:3"`, `"plex:tv"`
  - `Feed.init?(storageKey: String)`
  - `public struct VideoGroup: Codable, Identifiable, Hashable, Sendable` with `id: Int, name: String, label: String, emoji: String?, position: Int`. Every field is one word, so the synthesized `CodingKeys` already match the server's JSON — no custom keys needed.

- [ ] **Step 1: Write the failing tests**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/FeedTests.swift`:

```swift
import XCTest
@testable import PatataTubeKit

final class FeedTests: XCTestCase {
    func testQueryItemsForEachCase() {
        XCTAssertEqual(Feed.all.queryItems, [])
        XCTAssertEqual(Feed.group(id: 3).queryItems, [URLQueryItem(name: "group_id", value: "3")])
        XCTAssertEqual(Feed.plex(.tv).queryItems, [URLQueryItem(name: "plex_kind", value: "tv")])
    }

    func testStorageKeysRoundTrip() {
        for feed in [Feed.all, .group(id: 42), .plex(.movies)] {
            XCTAssertEqual(Feed(storageKey: feed.storageKey), feed)
        }
    }

    func testStorageKeySpellings() {
        XCTAssertEqual(Feed.all.storageKey, "all")
        XCTAssertEqual(Feed.group(id: 3).storageKey, "group:3")
        XCTAssertEqual(Feed.plex(.tv).storageKey, "plex:tv")
    }

    func testStorageKeyRejectsGarbage() {
        XCTAssertNil(Feed(storageKey: "group:notanumber"))
        XCTAssertNil(Feed(storageKey: "plex:podcasts"))
        XCTAssertNil(Feed(storageKey: ""))
    }

    func testCodableRoundTrip() throws {
        let feed = Feed.group(id: 7)
        let data = try JSONEncoder().encode(feed)
        XCTAssertEqual(try JSONDecoder().decode(Feed.self, from: data), feed)
    }

    func testVideoGroupDecodesServerJSON() throws {
        let json = #"{"id":2,"name":"adults","label":"Adults","emoji":"🍷","position":1}"#
        let group = try JSONDecoder().decode(VideoGroup.self, from: Data(json.utf8))
        XCTAssertEqual(group.id, 2)
        XCTAssertEqual(group.label, "Adults")
        XCTAssertEqual(group.emoji, "🍷")
    }

    func testVideoGroupDecodesANullEmoji() throws {
        let json = #"{"id":1,"name":"children","label":"Children","emoji":null,"position":0}"#
        XCTAssertNil(try JSONDecoder().decode(VideoGroup.self, from: Data(json.utf8)).emoji)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ios/PatataTubeKit && swift test --filter FeedTests`
Expected: FAIL — `cannot find 'Feed' in scope`.

- [ ] **Step 3: Write `Feed.swift`**

```swift
import Foundation

/// A Plex media type. Deliberately not a group: these have their own tabs,
/// their own directories on the server, and their own playback rules.
public enum PlexKind: String, Codable, Hashable, Sendable, CaseIterable {
    case tv
    case movies
}

/// What a grid is showing. Replaces the old `VideoStore.filter: String?`, which
/// was sometimes a group name, sometimes "tv", sometimes nil — the last place
/// the classification concept survived on the client.
///
/// This type is the single place that knows two spellings: the wire spelling
/// (`queryItems`) and the persistence spelling (`storageKey`). Nothing else
/// should build either by hand.
public enum Feed: Codable, Hashable, Sendable {
    case all
    case group(id: Int)
    case plex(PlexKind)

    public var queryItems: [URLQueryItem] {
        switch self {
        case .all: return []
        case .group(let id): return [URLQueryItem(name: "group_id", value: String(id))]
        case .plex(let kind): return [URLQueryItem(name: "plex_kind", value: kind.rawValue)]
        }
    }

    /// Key for anything persisted per-feed: the cached list file name, the
    /// per-feed autoplay/randomize/cell-size preferences, scroll anchors.
    public var storageKey: String {
        switch self {
        case .all: return "all"
        case .group(let id): return "group:\(id)"
        case .plex(let kind): return "plex:\(kind.rawValue)"
        }
    }

    public init?(storageKey: String) {
        if storageKey == "all" {
            self = .all
        } else if storageKey.hasPrefix("group:"), let id = Int(storageKey.dropFirst(6)) {
            self = .group(id: id)
        } else if storageKey.hasPrefix("plex:"), let kind = PlexKind(rawValue: String(storageKey.dropFirst(5))) {
            self = .plex(kind)
        } else {
            return nil
        }
    }
}
```

- [ ] **Step 4: Write `VideoGroup.swift`**

```swift
import Foundation

/// One row of the server's `groups` table. The Videos tab's cards are these,
/// in `position` order — the list is server data now, not a compiled-in array.
public struct VideoGroup: Codable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let label: String
    public let emoji: String?
    public let position: Int

    public init(id: Int, name: String, label: String, emoji: String?, position: Int) {
        self.id = id
        self.name = name
        self.label = label
        self.emoji = emoji
        self.position = position
    }

    public var feed: Feed { .group(id: id) }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd ios/PatataTubeKit && swift test --filter FeedTests`
Expected: PASS, 7 tests.

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/Feed.swift \
        ios/PatataTubeKit/Sources/PatataTubeKit/VideoGroup.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/FeedTests.swift
git commit -m "feat(ios): add Feed, PlexKind and VideoGroup"
```

---

### Task 9: `Video` decoding and `ResumeDecision`

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/Video.swift`
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/ResumeDecision.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoTests.swift`, `ResumeDecisionTests.swift`

**Interfaces:**
- Consumes: `PlexKind` (Task 8).
- Produces:
  - `Video.groupID: Int?` (JSON `group_id`) and `Video.plexKind: PlexKind?` (JSON `plex_kind`); `Video.classification` is removed
  - `Video.isPlexItem: Bool` — `plexKind != nil`
  - `ResumeDecision.decide(resumeSecs: Double, plexKind: PlexKind?) -> ResumeDecision` — replaces the `classification:` label; the `promptingClassifications` set is deleted

- [ ] **Step 1: Write the failing tests**

Add to `VideoTests.swift`:

```swift
func testDecodesGroupIDAndPlexKind() throws {
    let json = #"{"id":1,"url":"u","status":"done","group_id":3,"plex_kind":null,"subtitle_tracks":[]}"#
    let video = try JSONDecoder().decode(Video.self, from: Data(json.utf8))
    XCTAssertEqual(video.groupID, 3)
    XCTAssertNil(video.plexKind)
    XCTAssertFalse(video.isPlexItem)
}

func testDecodesAPlexItem() throws {
    let json = #"{"id":2,"url":"u","status":"done","group_id":null,"plex_kind":"tv","subtitle_tracks":[]}"#
    let video = try JSONDecoder().decode(Video.self, from: Data(json.utf8))
    XCTAssertEqual(video.plexKind, .tv)
    XCTAssertTrue(video.isPlexItem)
}

func testDecodesAnUnsortedVideo() throws {
    let json = #"{"id":3,"url":"u","status":"done","subtitle_tracks":[]}"#
    let video = try JSONDecoder().decode(Video.self, from: Data(json.utf8))
    XCTAssertNil(video.groupID)
    XCTAssertNil(video.plexKind)
}
```

In `ResumeDecisionTests.swift`, change every `classification:` argument to `plexKind:`, passing `.tv`/`.movies` where the old test passed `"tv"`/`"movies"` and `nil` where it passed a group name:

```swift
func testPromptsForAPlexItemPastSixtySeconds() {
    XCTAssertEqual(ResumeDecision.decide(resumeSecs: 120, plexKind: .tv), .prompt(120))
}

func testDoesNotPromptForAGroupVideo() {
    XCTAssertEqual(ResumeDecision.decide(resumeSecs: 120, plexKind: nil), .fromStart)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ios/PatataTubeKit && swift test --filter "VideoTests|ResumeDecisionTests"`
Expected: FAIL — `value of type 'Video' has no member 'groupID'`.

- [ ] **Step 3: Update `Video.swift`**

Read the file first. Replace the `classification` stored property and its `CodingKeys` entry with:

```swift
    /// The group this video is in, or nil when it is a Plex item or unsorted.
    public let groupID: Int?
    /// Set for Plex library rows; mutually exclusive with `groupID`.
    public let plexKind: PlexKind?

    /// Plex items get the resume prompt and the episode/movie chrome; group
    /// videos do not. This used to be a name comparison against "tv"/"movies".
    public var isPlexItem: Bool { plexKind != nil }
```

Add `case groupID = "group_id"` and `case plexKind = "plex_kind"` to `CodingKeys`, and decode both with `decodeIfPresent` so an unsorted row (both keys absent or null) decodes. Update the memberwise `init` and every call site inside the package that the compiler flags.

- [ ] **Step 4: Update `ResumeDecision.swift`**

Replace the signature at `ResumeDecision.swift:21-24` and delete `promptingClassifications`:

```swift
    /// Only Plex items prompt. That used to be a hardcoded list of two
    /// classification names; it is now literally "is this a Plex item".
    public static func decide(resumeSecs: Double, plexKind: PlexKind?) -> ResumeDecision {
        guard plexKind != nil else { return .fromStart }
        // …the existing 60s / last-30s logic, unchanged…
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd ios/PatataTubeKit && swift test --filter "VideoTests|ResumeDecisionTests"`
Expected: PASS. Other test files will not compile yet — Tasks 10-12 fix them.

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/Video.swift \
        ios/PatataTubeKit/Sources/PatataTubeKit/ResumeDecision.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/
git commit -m "feat(ios): decode group_id and plex_kind, key resume off plexKind"
```

---

### Task 10: `APIClient` and the `VideoAPI` protocol

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/APIClient.swift` (protocol at `:40-58`, defaults at `:60-72`, `videos` at `:107-120`, `classifications` at `:122-128`, `classify` at `:153-155`)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/APIClientReadTests.swift`

**Interfaces:**
- Consumes: `Feed`, `PlexKind`, `VideoGroup` (Task 8).
- Produces, on `VideoAPI` (all `APIClient` implementations and every test double must follow):
  - `func videos(feed: Feed) async throws -> [Video]` — replaces `videos(classification:)`
  - `func groups() async throws -> [VideoGroup]` — GET `/api/groups`, sorted by `position`
  - `func createGroup(name: String, label: String, emoji: String?) async throws -> VideoGroup`
  - `func updateGroup(id: Int, label: String?, emoji: String?) async throws -> VideoGroup` — an explicit `nil` emoji sends JSON `null`, which clears it
  - `func setGroup(id: Int, groupID: Int) async throws -> Bool` — POST `/api/videos/{id}/group`
  - `func promote(id: Int, kind: PlexKind) async throws -> Bool` — POST `/api/videos/{id}/promote`
  - Removed: `classifications()`, `classify(id:classification:)`, `groupCovers()`, `setGroupCover(_:for:)`, and the `ClassifyResult` type

- [ ] **Step 1: Write the failing tests**

Add to `APIClientReadTests.swift`, following the file's existing `URLProtocol` stub pattern (read it first and reuse its helper rather than inventing a new one):

```swift
func testVideosSendsTheGroupIDQuery() async throws {
    let (client, recorder) = makeClient(responding: "[]")
    _ = try await client.videos(feed: .group(id: 3))
    XCTAssertEqual(recorder.lastURL?.query, "group_id=3")
}

func testVideosSendsThePlexKindQuery() async throws {
    let (client, recorder) = makeClient(responding: "[]")
    _ = try await client.videos(feed: .plex(.movies))
    XCTAssertEqual(recorder.lastURL?.query, "plex_kind=movies")
}

func testVideosSendsNoQueryForAll() async throws {
    let (client, recorder) = makeClient(responding: "[]")
    _ = try await client.videos(feed: .all)
    XCTAssertNil(recorder.lastURL?.query)
}

func testGroupsDecodesAndSortsByPosition() async throws {
    let body = #"{"groups":[{"id":2,"name":"adults","label":"Adults","emoji":null,"position":1},"#
              + #"{"id":1,"name":"children","label":"Children","emoji":"🧒","position":0}]}"#
    let (client, _) = makeClient(responding: body)
    let groups = try await client.groups()
    XCTAssertEqual(groups.map(\.name), ["children", "adults"])
    XCTAssertEqual(groups[0].emoji, "🧒")
}

func testUpdateGroupSendsAnExplicitNullToClearTheEmoji() async throws {
    let body = #"{"id":1,"name":"children","label":"Children","emoji":null,"position":0}"#
    let (client, recorder) = makeClient(responding: body)
    _ = try await client.updateGroup(id: 1, label: nil, emoji: nil)
    let sent = try XCTUnwrap(recorder.lastBody)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: sent) as? [String: Any])
    XCTAssertTrue(json.keys.contains("emoji"))
    XCTAssertTrue(json["emoji"] is NSNull)
}

func testPromotePostsTheKind() async throws {
    let (client, recorder) = makeClient(responding: #"{"ok":true,"promoted":true}"#)
    XCTAssertTrue(try await client.promote(id: 5, kind: .tv))
    XCTAssertEqual(recorder.lastURL?.path, "/api/videos/5/promote")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ios/PatataTubeKit && swift test --filter APIClientReadTests`
Expected: FAIL — `incorrect argument label in call (have 'classification:', expected 'feed:')`.

- [ ] **Step 3: Update the protocol**

Replace `APIClient.swift:40-58`'s first three requirements and the two cover ones:

```swift
public protocol VideoAPI: Sendable {
    func videos(feed: Feed) async throws -> [Video]
    func groups() async throws -> [VideoGroup]
    func createGroup(name: String, label: String, emoji: String?) async throws -> VideoGroup
    func updateGroup(id: Int, label: String?, emoji: String?) async throws -> VideoGroup
    func setGroup(id: Int, groupID: Int) async throws -> Bool
    func promote(id: Int, kind: PlexKind) async throws -> Bool
    // …the remaining requirements unchanged…
}
```

Replace the `groupCovers`/`setGroupCover` defaults in the `public extension VideoAPI` block (`:60-72`) with defaults for the group calls, keeping the same rationale — most test doubles do not exercise them:

```swift
public extension VideoAPI {
    func groups() async throws -> [VideoGroup] { [] }
    func createGroup(name: String, label: String, emoji: String?) async throws -> VideoGroup {
        throw APIError.notConfigured
    }
    func updateGroup(id: Int, label: String?, emoji: String?) async throws -> VideoGroup {
        throw APIError.notConfigured
    }
    func setGroup(id: Int, groupID: Int) async throws -> Bool { false }
    func promote(id: Int, kind: PlexKind) async throws -> Bool { false }
    // …savePosition default unchanged…
}
```

- [ ] **Step 4: Implement them on `APIClient`**

Replace `videos(classification:)` (`:107-120`), `classifications()` (`:122-128`) and `classify` (`:153-155`):

```swift
    public func videos(feed: Feed = .all) async throws -> [Video] {
        var comps = URLComponents(
            url: try base().appendingPathComponent("api/videos"),
            resolvingAgainstBaseURL: false
        )!
        let items = feed.queryItems
        comps.queryItems = items.isEmpty ? nil : items
        // …reuse the existing request/decode tail of the old method verbatim…
    }

    public func groups() async throws -> [VideoGroup] {
        let url = try base().appendingPathComponent("api/groups")
        struct Envelope: Decodable { let groups: [VideoGroup] }
        let data = try await authedGet(url)   // use whatever helper the file already has
        return try JSONDecoder().decode(Envelope.self, from: data)
            .groups.sorted { $0.position < $1.position }
    }

    public func createGroup(name: String, label: String, emoji: String?) async throws -> VideoGroup {
        let data = try await authedPost(
            "api/groups", body: ["name": name, "label": label, "emoji": emoji as Any]
        )
        return try JSONDecoder().decode(VideoGroup.self, from: data)
    }

    public func updateGroup(id: Int, label: String?, emoji: String?) async throws -> VideoGroup {
        // An omitted key leaves the server's value alone; NSNull clears it. The
        // cover picker's "no emoji" result must clear, so it always sends the key.
        var body: [String: Any] = ["emoji": emoji as Any? ?? NSNull()]
        if let label { body["label"] = label }
        let data = try await authedRequest("api/groups/\(id)", method: "PATCH", body: body)
        return try JSONDecoder().decode(VideoGroup.self, from: data)
    }

    public func setGroup(id: Int, groupID: Int) async throws -> Bool {
        let data = try await authedPost("api/videos/\(id)/group", body: ["group_id": groupID])
        struct Envelope: Decodable { let ok: Bool }
        return try JSONDecoder().decode(Envelope.self, from: data).ok
    }

    public func promote(id: Int, kind: PlexKind) async throws -> Bool {
        let data = try await authedPost("api/videos/\(id)/promote", body: ["kind": kind.rawValue])
        struct Envelope: Decodable { let ok: Bool }
        return try JSONDecoder().decode(Envelope.self, from: data).ok
    }
```

`authedPost` exists (`APIClient.swift:154` uses it). `authedGet` and a method-taking `authedRequest` may not — read the file and either reuse what is there or add a small `authedRequest(_ path: String, method: String, body: [String: Any]?)` that the existing `authedPost` then delegates to. Do not duplicate the auth-header code.

Delete `ClassifyResult` (`APIClient.swift:20-38`) and the `groupCovers`/`setGroupCover` implementations.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd ios/PatataTubeKit && swift test --filter APIClientReadTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/APIClient.swift ios/PatataTubeKit/Tests/
git commit -m "feat(ios): APIClient speaks groups, feeds and promote"
```

---

### Task 11: `GroupStore` replaces `GroupCoverStore`

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/GroupStore.swift`
- Delete: `ios/PatataTubeKit/Sources/PatataTubeKit/GroupCoverStore.swift`, `ios/PatataTubeKit/Tests/PatataTubeKitTests/GroupCoverStoreTests.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/GroupStoreTests.swift` (create)

**Interfaces:**
- Consumes: `VideoGroup` (Task 8).
- Produces:
  - `public final class GroupStore: ObservableObject, @unchecked Sendable`
  - `init(defaults: UserDefaults = .standard)`
  - `@Published public private(set) var groups: [VideoGroup]` — loaded from the mirror at init, `[]` when there is none
  - `func apply(_ remote: [VideoGroup])` — replaces the mirror and republishes
  - `func group(id: Int) -> VideoGroup?`
  - `func group(named name: String) -> VideoGroup?`
  - `static let defaultsKey = "videoGroups"`

- [ ] **Step 1: Write the failing tests**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/GroupStoreTests.swift`:

```swift
import XCTest
@testable import PatataTubeKit

final class GroupStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "GroupStoreTests-\(UUID().uuidString)")!
        return suite
    }

    private let sample = [
        VideoGroup(id: 1, name: "children", label: "Children", emoji: "🧒", position: 0),
        VideoGroup(id: 2, name: "adults", label: "Adults", emoji: nil, position: 1),
    ]

    func testStartsEmptyWithNoMirror() {
        XCTAssertEqual(GroupStore(defaults: makeDefaults()).groups, [])
    }

    func testApplyPersistsAndRepublishes() {
        let defaults = makeDefaults()
        let store = GroupStore(defaults: defaults)
        store.apply(sample)
        XCTAssertEqual(store.groups.map(\.name), ["children", "adults"])
        XCTAssertEqual(GroupStore(defaults: defaults).groups, sample)
    }

    func testApplySortsByPosition() {
        let store = GroupStore(defaults: makeDefaults())
        store.apply([sample[1], sample[0]])
        XCTAssertEqual(store.groups.map(\.id), [1, 2])
    }

    func testApplyDropsGroupsTheServerNoLongerHas() {
        let defaults = makeDefaults()
        let store = GroupStore(defaults: defaults)
        store.apply(sample)
        store.apply([sample[0]])
        XCTAssertEqual(store.groups.map(\.id), [1])
    }

    func testLookupByIDAndName() {
        let store = GroupStore(defaults: makeDefaults())
        store.apply(sample)
        XCTAssertEqual(store.group(id: 2)?.name, "adults")
        XCTAssertEqual(store.group(named: "children")?.id, 1)
        XCTAssertNil(store.group(id: 99))
    }

    func testSurvivesACorruptMirror() {
        let defaults = makeDefaults()
        defaults.set(Data("not json".utf8), forKey: GroupStore.defaultsKey)
        XCTAssertEqual(GroupStore(defaults: defaults).groups, [])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ios/PatataTubeKit && swift test --filter GroupStoreTests`
Expected: FAIL — `cannot find 'GroupStore' in scope`.

- [ ] **Step 3: Write `GroupStore.swift`**

```swift
import Foundation
import Combine

/// The Videos tab's group list, mirrored into UserDefaults.
///
/// **The server owns these** (`GET /api/groups`) so a group added on one device
/// shows up on the others. UserDefaults is only a mirror, kept because the
/// group screen is offline-first by design: it renders from this before (or
/// entirely without) a fetch. Replaces `GroupCoverStore` — the emoji is a field
/// on the group now, not a parallel table keyed by name.
public final class GroupStore: ObservableObject, @unchecked Sendable {
    public static let defaultsKey = "videoGroups"

    @Published public private(set) var groups: [VideoGroup] = []

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([VideoGroup].self, from: data) {
            groups = decoded.sorted { $0.position < $1.position }
        }
    }

    /// Replaces the mirror with what the server has. A group the server no
    /// longer lists disappears here too — that is how a deletion made
    /// elsewhere propagates.
    public func apply(_ remote: [VideoGroup]) {
        groups = remote.sorted { $0.position < $1.position }
        if let data = try? JSONEncoder().encode(groups) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    public func group(id: Int) -> VideoGroup? { groups.first { $0.id == id } }

    public func group(named name: String) -> VideoGroup? { groups.first { $0.name == name } }
}
```

- [ ] **Step 4: Delete `GroupCoverStore`**

```bash
git rm ios/PatataTubeKit/Sources/PatataTubeKit/GroupCoverStore.swift \
       ios/PatataTubeKit/Tests/PatataTubeKitTests/GroupCoverStoreTests.swift
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd ios/PatataTubeKit && swift test --filter GroupStoreTests`
Expected: PASS, 6 tests.

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTubeKit/
git commit -m "feat(ios): GroupStore mirrors the server group list, replacing GroupCoverStore"
```

---

### Task 12: `VideoStore`, `VideoListCache`, `Route`, `MediaTab`

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/VideoStore.swift:17-18,28,44,52-55,82-92,102-115`
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/VideoListCache.swift:5-6,21-28`
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/RestorationState.swift:10,36,63-65`
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/MediaTab.swift`
- Test: `VideoStoreTests.swift`, `RestorationResolverTests.swift`, `MediaTabTests.swift`

**Interfaces:**
- Consumes: `Feed`, `VideoGroup` (Task 8); `api.videos(feed:)` (Task 10).
- Produces:
  - `VideoStore.feed: Feed` (replaces `filter: String?`), persisted under `"selectedFeed"` as a `Feed.storageKey` string, defaulting to `.all`
  - `VideoStore.switchFeed(to: Feed) async` (replaces `switchFilter(to:)`)
  - `VideoListCaching.save(_ videos: [Video], feed: Feed)` / `load(feed: Feed) -> [Video]?`
  - `Route.group(id: Int)` (replaces `group(name:)`)
  - `RestorationState.feed: Feed?` (replaces `filter: String?`), and `RestorationState.gridKey(feed: Feed) -> String`
  - `MediaTab.feed: Feed?` — `nil` for `.videos`, `.plex(.tv)`, `.plex(.movies)`. `MediaTab.videoGroups` and `MediaTab.label(forGroup:)` are **deleted**.

- [ ] **Step 1: Write the failing tests**

Add to `VideoStoreTests.swift` (reuse the file's existing fake-API helper):

```swift
func testDefaultsToAllWithNoPersistedFeed() {
    let store = VideoStore(api: FakeAPI(), defaults: makeDefaults())
    XCTAssertEqual(store.feed, .all)
}

func testPersistsAndRestoresTheFeed() async {
    let defaults = makeDefaults()
    let store = VideoStore(api: FakeAPI(), defaults: defaults)
    await store.switchFeed(to: .group(id: 7))
    XCTAssertEqual(VideoStore(api: FakeAPI(), defaults: defaults).feed, .group(id: 7))
}

func testSwitchFeedRequestsTheNewFeed() async {
    let api = FakeAPI()
    let store = VideoStore(api: api, defaults: makeDefaults())
    await store.switchFeed(to: .plex(.movies))
    XCTAssertEqual(api.lastFeed, .plex(.movies))
}
```

Add to `MediaTabTests.swift`:

```swift
func testTabFeeds() {
    XCTAssertNil(MediaTab.videos.feed)
    XCTAssertEqual(MediaTab.tv.feed, .plex(.tv))
    XCTAssertEqual(MediaTab.movies.feed, .plex(.movies))
}
```

Add to `RestorationResolverTests.swift`:

```swift
func testGroupRouteRoundTripsByID() throws {
    let state = RestorationState(
        feed: .group(id: 4), path: [.group(id: 4)], search: "",
        scrollAnchors: [:], player: nil, tab: .videos
    )
    let data = try JSONEncoder().encode(state)
    XCTAssertEqual(try JSONDecoder().decode(RestorationState.self, from: data), state)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ios/PatataTubeKit && swift test`
Expected: FAIL to compile — `value of type 'VideoStore' has no member 'feed'`.

- [ ] **Step 3: Update `VideoStore`**

Replace `VideoStore.swift:17-18`, `:28`, `:44`:

```swift
    @Published public var feed: Feed {
        didSet { defaults.set(feed.storageKey, forKey: Self.feedKey) }
    }
    …
    // New key spelling on purpose: the old "selectedClassification" holds a
    // group *name*, which means nothing now. Orphaning it is cheaper and safer
    // than translating it, and costs one launch on the Videos tab root.
    private static let feedKey = "selectedFeed"
    …
        self.feed = defaults.string(forKey: Self.feedKey).flatMap(Feed.init(storageKey:)) ?? .all
```

Replace `loadCache()` (`:50-56`), `switchFilter` (`:82-92`) and the two `filter` reads inside `load()` (`:102`, `:108`):

```swift
    private func loadCache() async -> [Video]? {
        guard let cache else { return nil }
        let feed = self.feed
        return await Task.detached(priority: .utility) {
            cache.load(feed: feed)
        }.value
    }

    public func switchFeed(to value: Feed) async {
        loadGeneration += 1
        let generation = loadGeneration
        feed = value
        videos = []
        isLoading = true
        let cached = await loadCache()
        guard generation == loadGeneration else { return }
        if let cached { videos = cached }
        await load()
    }
```

Inside `load()`: `let fetched = try await api.videos(feed: feed)` and, in the cache-save block, `let feed = self.feed` / `cache.save(toSave, feed: feed)`. Leave every comment about `loadGeneration` and the main-thread-hang rationale intact — those document real Sentry incidents.

- [ ] **Step 4: Update `VideoListCache`, `RestorationState`, `MediaTab`**

`VideoListCache.swift` — the protocol (`:5-6`) and both methods take `feed: Feed`; `fileURL` becomes:

```swift
    private func fileURL(_ feed: Feed) -> URL {
        root.appendingPathComponent("\(feed.storageKey).json")
    }
```

`RestorationState.swift`:
- `:10` — `case group(id: Int)  // VideoGroup.id`
- `:36` — `public var feed: Feed?`, with the doc comment updated: "`VideoStore` already persists the selected feed itself under `selectedFeed`."
- `:63-65` — `public static func gridKey(feed: Feed) -> String { "grid:\(feed.storageKey)" }`
- Update `empty` and the memberwise `init` accordingly.

`MediaTab.swift` — delete `videoGroups` and `label(forGroup:)`; replace `filter` with:

```swift
    /// The feed a tab loads. The Videos tab has none of its own — its feed is
    /// whichever group the user opened.
    public var feed: Feed? {
        switch self {
        case .videos: return nil
        case .tv: return .plex(.tv)
        case .movies: return .plex(.movies)
        }
    }
```

Also bump the restoration blob's UserDefaults key wherever it is written (grep the package and app for the key that stores `RestorationState`; rename it with a `V2` suffix) so a stale name-keyed blob is never decoded.

- [ ] **Step 5: Run both test configurations**

Run: `cd ios/PatataTubeKit && swift build && swift test`
Then: `cd ios/PatataTubeKit && swift test -c release`
Expected: PASS. Ignore the known pre-existing `Fatal error: Index out of range` from the parallel swift-testing suites; re-run any failing test filtered before treating it as a regression.

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTubeKit/
git commit -m "refactor(ios): replace the stringly-typed filter with Feed"
```

---

# Phase 5 — iOS app shell

### Task 13: `AppModel` and `GroupsView`

**Files:**
- Modify: `ios/PatataTube/Sources/AppModel.swift:37-91`
- Modify: `ios/PatataTube/Sources/GroupsView.swift` (whole file, 208 lines)
- Test: manual (no automated app-target tests exist for these; `ios/README.md` holds the checklist)

**Interfaces:**
- Consumes: `Feed`, `VideoGroup`, `GroupStore` (Tasks 8, 11); `api.groups()`, `api.updateGroup(id:label:emoji:)` (Task 10).
- Produces:
  - `AppModel.autoplay(for feed: Feed) -> Bool`, `autoplayBinding(for:)`, `randomize(for:)`, `randomizeBinding(for:)`, `cellSize(for:)`, `setCellSize(_:for:)` — all keyed by `Feed.storageKey`
  - `AppModel.groups: GroupStore` — created at init, shared by the views

- [ ] **Step 1: Update `AppModel`**

Rename the three dictionaries and rekey them. Replace `AppModel.swift:37-91`'s six accessors:

```swift
    /// Keyed by `Feed.storageKey` ("all" / "group:3" / "plex:tv"), so a
    /// preference set on one group leaves the others alone. New key names on
    /// purpose: the old dictionaries were keyed by classification name and
    /// their entries mean nothing now.
    ///
    /// The three dictionaries keep whatever storage mechanism they have today
    /// (read the file — only their names and key strings change here).
    func autoplay(for feed: Feed) -> Bool { autoplayByFeed[feed.storageKey] ?? false }

    func autoplayBinding(for feed: Feed) -> Binding<Bool> {
        Binding(
            get: { self.autoplay(for: feed) },
            set: { self.autoplayByFeed[feed.storageKey] = $0 }
        )
    }

    func randomize(for feed: Feed) -> Bool { randomizeByFeed[feed.storageKey] ?? false }

    func randomizeBinding(for feed: Feed) -> Binding<Bool> {
        Binding(
            get: { self.randomize(for: feed) },
            set: { self.randomizeByFeed[feed.storageKey] = $0 }
        )
    }

    func cellSize(for feed: Feed) -> Double { cellSizeByFeed[feed.storageKey] ?? legacyCellSize }

    func setCellSize(_ value: Double, for feed: Feed) { cellSizeByFeed[feed.storageKey] = value }
```

Read the file first — the three dictionaries' current storage mechanism (`@AppStorage`, `@Published`, or plain properties) must be preserved; only the key type and the property names change. Add `let groups = GroupStore()` as a stored property and pass it into the views.

- [ ] **Step 2: Rewrite `GroupsView`**

Replace the `covers` property and the `cover` state with the store, keeping every existing comment about why the cards issue no requests and why previews were removed:

```swift
struct GroupsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var groups: GroupStore

    @State private var saveError: String?
    @State private var editing: EditingGroup?

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 16)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(groups.groups) { group in
                card(for: group).id(group.id)
            }
        }
        .padding()
        .task {
            // Groups are server-owned; the mirror is what's on screen until
            // this lands (and all there is, offline).
            if let remote = try? await model.api.groups() {
                groups.apply(remote)
            }
        }
        .sheet(item: $editing) { item in
            CoverPickerView(group: item.group, current: item.group.emoji) { text in
                save(text, for: item.group)
                editing = nil
            }
        }
        .alert("Couldn't save cover", isPresented: .constant(saveError != nil)) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    /// Optimistic, like `VideoStore`'s group write: the card changes at once
    /// and the write follows. A failed write reverts rather than leaving this
    /// device showing a cover the others will never see.
    private func save(_ text: String?, for group: VideoGroup) {
        let emoji = Self.firstEmoji(in: text ?? "")
        let previous = groups.groups
        groups.apply(groups.groups.map {
            $0.id == group.id
                ? VideoGroup(id: $0.id, name: $0.name, label: $0.label, emoji: emoji, position: $0.position)
                : $0
        })
        Task {
            do {
                _ = try await model.api.updateGroup(id: group.id, label: nil, emoji: emoji)
            } catch {
                groups.apply(previous)
                saveError = error.localizedDescription
            }
        }
    }

    /// One grapheme cluster, so flags, skin-tone modifiers and ZWJ families
    /// (👩‍👩‍👧) each count as a single emoji rather than their parts. Moved here
    /// from the deleted GroupCoverStore.
    static func firstEmoji(in text: String) -> String? {
        text.first(where: { char in
            char.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0x238C }
        }).map(String.init)
    }
}
```

In `card(for:)`, the `NavigationLink` value becomes `Route.group(id: group.id)`, the title becomes `group.label`, and the art becomes `group.emoji`. Change `EditingGroup` to carry a `VideoGroup` and keep its `Identifiable` conformance (`var id: Int { group.id }`). Update `CoverPickerView`'s signature to take a `VideoGroup`.

- [ ] **Step 3: Build**

Run: `cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M4)' build`
Expected: build failures only in `VideoGridView.swift` and `VideoCell.swift` — Task 14 fixes those. If the destination name is wrong, list options with `xcrun simctl list devicetypes`.

- [ ] **Step 4: Commit**

```bash
git add ios/PatataTube/Sources/AppModel.swift ios/PatataTube/Sources/GroupsView.swift
git commit -m "feat(ios): GroupsView renders the server group list"
```

---

### Task 14: `VideoGridView` and `VideoCell`

**Files:**
- Modify: `ios/PatataTube/Sources/VideoGridView.swift:169-170,192,205,442,607,685-695,799,901`
- Modify: `ios/PatataTube/Sources/VideoCell.swift:17,34,39,128,177`
- Test: `ios/PatataTube/Tests/VideoGridViewTests.swift`, `DownloadsViewTests.swift`, `EpisodesViewTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 8-13.
- Produces: no new public API — this is the last consumer update.

- [ ] **Step 1: Update `VideoGridView`**

- `:169-170` — delete the hardcoded `classifications` array and `classificationsLoaded`; take `@ObservedObject var groups: GroupStore` instead.
- `:685-695` — replace `loadClassifications()` with a `.task` that calls `model.api.groups()` and hands the result to `groups.apply(_:)`. Drop the `classificationsLoaded` guard: `GroupStore` is idempotent and the mirror already covers the cold-start case.
- `:442` — pass `groups: groups.groups` to `VideoCell` instead of `classifications:`.
- `:607` — the "Videos tab restored at its root has no classification to fetch" branch keys off `MediaTab.videos.feed == nil`; keep the behavior, update the comment to say "feed".
- `:799` — `ResumeDecision.decide(resumeSecs: secs, plexKind: video.plexKind)`.
- `:901` — the filter predicate `if let group, $0.classification != group { return false }` becomes `if let groupID, $0.groupID != groupID { return false }`; the surrounding parameter changes from `String?` to `Int?`.
- Every `store.switchFilter(to:)` call becomes `store.switchFeed(to:)` with a `Feed`; every `RestorationState.gridKey(filter:)` becomes `gridKey(feed:)`; every `Route.group(name:)` construction and pattern-match becomes `Route.group(id:)`.

Work through the compiler's errors — `swift build` on the app target enumerates them.

- [ ] **Step 2: Update `VideoCell`**

- `:17` — `let groups: [VideoGroup]` replaces `let classifications: [String]`.
- `:34` — `video.isPlexItem` replaces the `classification == "tv" || … == "movies"` comparison.
- `:39` — the children-only behavior becomes a name lookup against the resolved group, since ids are per-install but names are stable:

```swift
    /// Names stay stable even though ids are the wire identity, so this one
    /// behavioral special case still keys off the name.
    private var isChildrenVideo: Bool {
        groups.first { $0.id == video.groupID }?.name == "children" && video.status == "done"
    }
```

- `:128` — the menu's `ForEach(classifications, id: \.self)` becomes `ForEach(groups)` showing `group.label` and calling `store.setGroup(id:groupID:)`; below it, add a separate section:

```swift
                Section("Move to Plex") {
                    ForEach(PlexKind.allCases, id: \.self) { kind in
                        Button(kind == .tv ? "TV" : "Movies") { promote(kind) }
                    }
                }
```

- `:177` — the detail row `row("Classification", video.classification)` becomes `row("Group", groups.first { $0.id == video.groupID }?.label ?? "Unsorted")`.

Wire `promote(_:)` to `model.api.promote(id:kind:)` and, on success, remove the row from the store the same way the old promoted-result path did (read how `ClassifyResult.promoted` was handled and reuse that removal).

- [ ] **Step 2b: Update the app-target tests**

`ios/PatataTube/Tests/VideoGridViewTests.swift`, `DownloadsViewTests.swift`, `EpisodesViewTests.swift` construct `Video` values with `classification:`. Change those to `groupID:` / `plexKind:` and update any `classifications:` argument to `groups:`.

- [ ] **Step 3: Build and run the app**

```bash
cd ios/PatataTube && xcodegen generate
xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M4)' build
```
Expected: clean build.

- [ ] **Step 4: Manual verification**

Start the server (`./serve`), run the app in the simulator, and check:
1. Videos tab shows four cards with the right labels and any emoji covers you had before the migration.
2. Tapping a card opens that group's grid and loads its videos.
3. A card's `⋯` → cover picker sets an emoji; it survives an app restart and appears on the server (`curl localhost:3050/api/groups`).
4. TV and Movies tabs still load.
5. A video's menu shows the groups and a separate "Move to Plex" section; changing the group sticks.
6. Backgrounding and relaunching restores the same group screen.
7. Add a group by hand and confirm it appears after a pull-to-refresh:
   ```bash
   curl -X POST localhost:3050/api/groups -H "Authorization: Bearer $UPLOAD_TOKEN" \
        -H 'Content-Type: application/json' -d '{"name":"cooking","label":"Cooking","emoji":"🍳"}'
   ```
   This is the whole point of the refactor — if it does not appear, stop and fix it.

Check `log/ios.jsonl` and `log/backend.log` for errors.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTube/
git commit -m "feat(ios): grid and cell speak groups and promote"
```

---

# Phase 6 — Documentation

### Task 15: Update `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: the finished implementation.
- Produces: documentation matching the code.

- [ ] **Step 1: Rewrite the stale passages**

Every one of these is now wrong:

1. The "Layering" section's `CLASSIFICATIONS` paragraph — replace with: the `groups` table is the source of truth for video groups; `db.PLEX_KINDS` covers the separate Plex axis; the iOS Videos tab renders `GET /api/groups` and no longer hardcodes anything, so there is no list to keep in sync.
2. The iOS section's `GroupsView` paragraph — it describes "four classification cards" and `GroupPosterStore`. **`GroupPosterStore` was already deleted in `99b8289`** and this refactor deletes `GroupCoverStore` too; describe `GroupStore` as the single UserDefaults mirror of the server list, covering both the group list and its emoji.
3. The "Promoting downloads into Plex" section — classifying no longer triggers promotion. Describe `POST /api/videos/{id}/promote` as the trigger, and say that `/upload/file` takes a `group_id` (its tv/movies rejection is gone because the case is structurally impossible).
4. The Auth section's mention of `/videos/{id}/classify` — the SSR endpoints are `/videos/{id}/group` and `/videos/{id}/promote` now; the group one stays ungated, matching the old behavior.
5. The `resume_secs` paragraph — "only appears for `tv`/`movies` rows" becomes "only for Plex items (`plex_kind` non-null)".
6. Add a short note under "Layering": adding a group is `POST /api/groups`; there is deliberately no UI for it, and no delete endpoint.

- [ ] **Step 2: Verify the claims**

For each rewritten sentence, grep for the symbol it names and confirm it exists:

```bash
grep -rn "PLEX_KINDS\|list_groups\|GroupStore\|api/groups\|/promote" --include=*.py --include=*.swift . | grep -v ".build/" | head -40
grep -rn "CLASSIFICATIONS\|classification\|GroupCoverStore\|GroupPosterStore" --include=*.py --include=*.swift --include=*.html --include=*.js . | grep -v ".build/\|.claude/worktrees/"
```

The second command should return **nothing**. Anything it finds is a missed call site — fix it before committing.

- [ ] **Step 3: Run everything one last time**

```bash
python -m pytest tests/ -v
cd ios/PatataTubeKit && swift test && swift test -c release
```
Expected: PASS, modulo the documented pre-existing swift-testing flakes.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: describe groups instead of classifications"
```

---

## Rollback

The only irreversible step is Task 3's column drop. To undo the whole refactor:

```bash
git reset --hard <commit before Task 1>
cp data/watch_later.sqlite.pre-groups data/watch_later.sqlite
```

Delete `data/watch_later.sqlite.pre-groups` only once the app has run against the migrated database for a few days.
