# tests/test_db.py
import importlib
import pytest

@pytest.fixture(autouse=True)
def tmp_db(monkeypatch, tmp_path):
    monkeypatch.setenv("DB_PATH", str(tmp_path / "test.db"))
    import db
    db.init_db()
    yield db


@pytest.fixture()
def fresh_db(monkeypatch, tmp_path):
    monkeypatch.setenv("DB_PATH", str(tmp_path / "test.db"))
    import db
    importlib.reload(db)
    db.init_db()
    yield

def test_add_and_get_video(tmp_db):
    vid_id = tmp_db.add_video("https://twitter.com/x/status/123")
    assert vid_id == 1
    video = tmp_db.get_video(1)
    assert video["url"] == "https://twitter.com/x/status/123"
    assert video["status"] == "queued"
    assert video["filename"] is None

def test_update_video_status(tmp_db):
    vid_id = tmp_db.add_video("https://twitter.com/x/status/456")
    tmp_db.update_video(vid_id, status="done", filename="456.mp4")
    video = tmp_db.get_video(vid_id)
    assert video["status"] == "done"
    assert video["filename"] == "456.mp4"

def test_update_video_error(tmp_db):
    vid_id = tmp_db.add_video("https://twitter.com/x/status/789")
    tmp_db.update_video(vid_id, status="error", error_msg="Download failed")
    assert tmp_db.get_video(vid_id) is None


def test_init_db_deletes_legacy_error_videos(tmp_db):
    good_id = tmp_db.add_video("https://twitter.com/x/status/123")
    bad_id = tmp_db.add_video("https://twitter.com/x/status/789")

    with tmp_db._conn() as conn:
        conn.execute(
            "UPDATE videos SET status = ?, error_msg = ? WHERE id = ?",
            ("error", "Download failed", bad_id),
        )

    tmp_db.init_db()

    assert tmp_db.get_video(good_id) is not None
    assert tmp_db.get_video(bad_id) is None

def test_get_all_videos(tmp_db):
    tmp_db.add_video("https://twitter.com/x/status/1")
    tmp_db.add_video("https://twitter.com/x/status/2")
    videos = tmp_db.get_all_videos()
    assert len(videos) == 2


def test_conn_closes_on_exit(tmp_db):
    import sqlite3
    with tmp_db._conn() as conn:
        pass
    # After the context exits the connection must be closed, not left open
    # for the garbage collector to reap (which leaks file descriptors).
    with pytest.raises(sqlite3.ProgrammingError):
        conn.execute("SELECT 1")


def test_get_all_videos_batches_version_queries(fresh_db, monkeypatch):
    import db
    for key, prefix in (("42", "/m/a"), ("43", "/m/b")):
        db.upsert_library_video(
            {
                **_versioned_movie_item(key),
                "source_path": f"{prefix}-1080.mkv",
                "versions": [
                    {"source_path": f"{prefix}-1080.mkv", "label": "1080p"},
                    {"source_path": f"{prefix}-4k.mkv", "label": "4K"},
                ],
            }
        )

    original_conn = db._conn
    opened = 0

    def counting_conn():
        nonlocal opened
        opened += 1
        return original_conn()

    monkeypatch.setattr(db, "_conn", counting_conn)
    videos = db.get_all_videos("movies")

    # Two library rows, each with two versions. The whole listing must use a
    # single connection — no per-row version fetch (the N+1 that leaked FDs).
    assert opened == 1
    for video in videos:
        assert len(video["versions"]) == 2


def test_video_metadata_fields_and_source_lookup(tmp_db):
    vid_id = tmp_db.add_video(
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        platform="youtube",
        source_key="dQw4w9WgXcQ",
        title="Original Title",
        preview_url="https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
    )
    tmp_db.update_video(
        vid_id,
        status="done",
        filename="1.mp4",
        title="Saved Title",
        preview_url="https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
    )
    video = tmp_db.get_video(vid_id)
    assert video["platform"] == "youtube"
    assert video["source_key"] == "dQw4w9WgXcQ"
    assert video["title"] == "Saved Title"
    assert video["preview_url"] == "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"

    existing = tmp_db.get_completed_video_by_source("youtube", "dQw4w9WgXcQ")
    assert existing is not None
    assert existing["id"] == vid_id
    assert existing["filename"] == "1.mp4"

def test_init_db_backfills_youtube_preview_urls(tmp_db):
    vid_id = tmp_db.add_video(
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        platform="youtube",
        source_key="dQw4w9WgXcQ",
    )

    with tmp_db._conn() as conn:
        conn.execute("UPDATE videos SET preview_url = NULL WHERE id = ?", (vid_id,))

    tmp_db.init_db()
    video = tmp_db.get_video(vid_id)
    assert video["preview_url"] == "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"


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
    assert db.CLASSIFICATIONS == ["children", "adults", "anabel", "tv", "movies"]


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


def test_upsert_same_path_new_rating_key_updates_not_collides(fresh_db):
    # Plex changed the ratingKey on rescan (or two items share a file). The
    # rating-key lookup misses, but source_path is globally UNIQUE, so a naive
    # INSERT hits "UNIQUE constraint failed: videos.source_path". Must UPDATE.
    import db
    vid, _ = db.upsert_library_video(LIB_ITEM)
    vid2, status = db.upsert_library_video({**LIB_ITEM, "plex_rating_key": "9999"})
    assert vid2 == vid and status == "updated"


def test_upsert_tombstoned_same_path_new_rating_key(fresh_db):
    # A tombstoned row still owns source_path; a rescan with a different rating
    # key must not INSERT-collide on it.
    import db
    vid, _ = db.upsert_library_video(LIB_ITEM)
    db.tombstone_video(vid)
    vid2, status = db.upsert_library_video({**LIB_ITEM, "plex_rating_key": "9999"})
    assert vid2 == vid and status == "tombstoned"


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


def test_upsert_library_video_uses_added_at_for_position(fresh_db):
    import db
    item = {**LIB_ITEM, "added_at": 1_700_000_000}
    vid, _ = db.upsert_library_video(item)
    row = db.get_video(vid)
    assert row["position"] == 1_700_000_000
    assert row["created_at"].startswith("2023-11-14")


def test_library_videos_sorted_newest_added_first(fresh_db):
    import db
    older, _ = db.upsert_library_video(
        {**LIB_ITEM, "source_path": "/m/old.mkv", "plex_rating_key": "old", "added_at": 1_600_000_000})
    newer, _ = db.upsert_library_video(
        {**LIB_ITEM, "source_path": "/m/new.mkv", "plex_rating_key": "new", "added_at": 1_700_000_000})
    ordered = [v["id"] for v in db.get_all_videos()]
    assert ordered.index(newer) < ordered.index(older)


def test_backfill_library_added_at_rewrites_legacy_rows(fresh_db, tmp_path):
    import db
    f = tmp_path / "clip.mkv"
    f.write_bytes(b"x")
    import os
    os.utime(f, (1_650_000_000, 1_650_000_000))
    # Legacy row: created via scan order (no added_at) -> small position.
    vid, _ = db.upsert_library_video({**LIB_ITEM, "source_path": str(f)})
    assert db.get_video(vid)["position"] < db._ADDED_AT_POSITION_FLOOR
    with db._conn() as conn:
        assert db._backfill_library_added_at(conn) == 1
    assert db.get_video(vid)["position"] == 1_650_000_000
    # Idempotent: unix-scale positions are left untouched on a second pass.
    with db._conn() as conn:
        assert db._backfill_library_added_at(conn) == 0


def _versioned_movie_item(rating_key="42", versions=None):
    return {
        "source_path": "/m/1080.mkv",
        "title": "Akira",
        "classification": "movies",
        "show_title": None,
        "season": None,
        "episode": None,
        "summary": "Neo-Tokyo.",
        "plex_rating_key": rating_key,
        "show_rating_key": None,
        "versions": versions
        or [
            {"source_path": "/m/1080.mkv", "label": "1080p"},
            {"source_path": "/m/4k.mkv", "label": "4K"},
        ],
    }


def test_video_versions_table_and_chosen_column_exist(fresh_db):
    import db

    with db._conn() as conn:
        video_columns = {row["name"] for row in conn.execute("PRAGMA table_info(videos)")}
        version_columns = {row["name"] for row in conn.execute("PRAGMA table_info(video_versions)")}

    assert "chosen_version_id" in video_columns
    assert {
        "id",
        "video_id",
        "source_path",
        "label",
        "status",
        "converted_path",
        "error_msg",
        "position",
    } <= version_columns


def test_backfill_creates_one_version_per_library_row(fresh_db):
    import db

    with db._conn() as conn:
        conn.execute(
            """
            INSERT INTO videos (
                url, title, status, classification, source, source_path,
                converted_path, plex_rating_key, created_at, position
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                "/m/a.mkv",
                "A",
                "done",
                "movies",
                "library",
                "/m/a.mkv",
                "/m/a.mp4",
                "42",
                "2026-01-01T00:00:00+00:00",
                1,
            ),
        )

    db.init_db()
    video = db.get_all_videos("movies")[0]
    versions = db.get_video_versions(video["id"])

    assert video["chosen_version_id"] == versions[0]["id"]
    assert versions[0]["source_path"] == "/m/a.mkv"
    assert versions[0]["converted_path"] == "/m/a.mp4"
    assert versions[0]["status"] == "done"


def test_version_helpers_update_chosen_version_and_paths(fresh_db):
    import db

    video_id, status = db.upsert_library_video(_versioned_movie_item())
    assert status == "created"
    versions = db.get_video_versions(video_id)
    assert [v["label"] for v in versions] == ["1080p", "4K"]
    assert versions[0]["is_chosen"] is True
    assert versions[1]["is_chosen"] is False

    assert db.set_chosen_version(video_id, versions[1]["id"]) is True
    assert db.set_chosen_version(video_id, 9999) is False
    chosen = db.get_video(video_id)
    assert chosen["chosen_version_id"] == versions[1]["id"]
    assert chosen["source_path"] == "/m/4k.mkv"

    db.set_library_state(video_id, "done", converted_path="/m/4k.mp4")
    refreshed = db.get_video_versions(video_id)
    converted = next(v for v in refreshed if v["label"] == "4K")
    assert converted["converted_path"] == "/m/4k.mp4"
    assert db.get_converted_paths() == {"/m/4k.mp4"}


def test_upsert_library_video_syncs_versions_by_rating_key(fresh_db):
    import db

    video_id, status = db.upsert_library_video(_versioned_movie_item())
    assert status == "created"
    versions = db.get_video_versions(video_id)
    assert db.set_chosen_version(video_id, versions[1]["id"]) is True

    video_id2, status2 = db.upsert_library_video(
        _versioned_movie_item(
            versions=[
                {"source_path": "/m/1080.mkv", "label": "1080p"},
                {"source_path": "/m/4k.mkv", "label": "4K Remux"},
            ]
        )
    )

    assert video_id2 == video_id
    assert status2 == "updated"
    refreshed = db.get_video_versions(video_id)
    assert [v["label"] for v in refreshed] == ["1080p", "4K Remux"]
    assert next(v for v in refreshed if v["source_path"] == "/m/4k.mkv")["is_chosen"] is True
