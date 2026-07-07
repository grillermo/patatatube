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
