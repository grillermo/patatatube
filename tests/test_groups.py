import importlib
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
