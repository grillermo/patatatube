import importlib
import sqlite3
import threading

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


def test_init_db_does_not_resurrect_deleted_groups(fresh_db):
    with fresh_db._conn() as conn:
        conn.execute("DELETE FROM groups")

    fresh_db.init_db()

    assert fresh_db.list_groups() == []


def test_concurrent_default_seed_is_atomic(tmp_path, monkeypatch):
    path = tmp_path / "concurrent.sqlite"
    monkeypatch.setenv("DB_PATH", str(path))
    import db as db_module

    importlib.reload(db_module)
    with sqlite3.connect(path) as conn:
        conn.execute(
            "CREATE TABLE groups (id INTEGER PRIMARY KEY AUTOINCREMENT, "
            "name TEXT NOT NULL UNIQUE, label TEXT NOT NULL, emoji TEXT, "
            "position INTEGER NOT NULL, created_at TEXT, updated_at TEXT)"
        )

    barrier = threading.Barrier(2)
    errors = []

    class PausingCursor:
        def __init__(self, cursor, serialized):
            self.cursor = cursor
            self.serialized = serialized

        def fetchone(self):
            row = self.cursor.fetchone()
            if not self.serialized:
                barrier.wait(timeout=2)
            return row

    class Connection:
        def __init__(self):
            self.raw = sqlite3.connect(path, timeout=2)
            self.serialized = False

        def execute(self, sql, parameters=()):
            if sql == "BEGIN IMMEDIATE":
                self.serialized = True
            cursor = self.raw.execute(sql, parameters)
            if sql == "SELECT 1 FROM groups LIMIT 1":
                return PausingCursor(cursor, self.serialized)
            return cursor

        def executemany(self, sql, parameters):
            return self.raw.executemany(sql, parameters)

        def close(self):
            self.raw.close()

    def seed():
        conn = Connection()
        try:
            db_module._seed_default_groups(conn)
            conn.raw.commit()
        except Exception as exc:
            errors.append(exc)
        finally:
            conn.close()

    threads = [threading.Thread(target=seed) for _ in range(2)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=3)

    assert not errors
    with sqlite3.connect(path) as conn:
        assert conn.execute("SELECT COUNT(*) FROM groups").fetchone()[0] == 4


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


def test_groups_start_with_display_titles_off(fresh_db):
    assert all(g["display_titles"] == 0 for g in fresh_db.list_groups())
    assert fresh_db.create_group("cooking", "Cooking")["display_titles"] == 0


def test_update_group_toggles_display_titles(fresh_db):
    gid = fresh_db.get_group_by_name("children")["id"]
    assert fresh_db.update_group(gid, display_titles=True)["display_titles"] == 1
    assert fresh_db.update_group(gid, display_titles=False)["display_titles"] == 0


def test_update_group_display_titles_leaves_the_emoji_alone(fresh_db):
    gid = fresh_db.get_group_by_name("children")["id"]
    fresh_db.update_group(gid, emoji="🧒")
    assert fresh_db.update_group(gid, display_titles=True)["emoji"] == "🧒"


def test_update_group_returns_none_for_an_unknown_id(fresh_db):
    assert fresh_db.update_group(9999, label="x") is None


def test_plex_kinds_are_not_groups(fresh_db):
    assert fresh_db.PLEX_KINDS == ("tv", "movies")
    assert not {g["name"] for g in fresh_db.list_groups()} & set(fresh_db.PLEX_KINDS)


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


def test_video_group_and_plex_kind_writes_are_mutually_exclusive(fresh_db):
    kids = fresh_db.get_group_by_name("children")["id"]
    vid = fresh_db.add_video("https://example.com/exclusive", platform="upload")

    fresh_db.set_video_plex_kind(vid, "tv")
    fresh_db.set_video_group(vid, kids)
    assert (fresh_db.get_video(vid)["group_id"], fresh_db.get_video(vid)["plex_kind"]) == (
        kids,
        None,
    )

    fresh_db.set_video_plex_kind(vid, "movies")
    assert (fresh_db.get_video(vid)["group_id"], fresh_db.get_video(vid)["plex_kind"]) == (
        None,
        "movies",
    )


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


def test_migration_adds_display_titles_to_an_existing_groups_table(tmp_path, monkeypatch):
    """A groups table created before the column exists gets it, defaulted off."""
    path = tmp_path / "pre-display-titles.sqlite"
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        CREATE TABLE groups (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE,
            label TEXT NOT NULL,
            emoji TEXT,
            position INTEGER NOT NULL,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        );
        INSERT INTO groups (name, label, position) VALUES ('children', 'Children', 0);
        """
    )
    conn.commit()
    conn.close()

    monkeypatch.setenv("DB_PATH", str(path))
    import db as db_module

    importlib.reload(db_module)
    db_module.init_db()

    assert db_module.get_group_by_name("children")["display_titles"] == 0


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
