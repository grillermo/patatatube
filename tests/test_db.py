# tests/test_db.py
import pytest

@pytest.fixture(autouse=True)
def tmp_db(monkeypatch, tmp_path):
    monkeypatch.setenv("DB_PATH", str(tmp_path / "test.db"))
    import db
    db.init_db()
    yield db

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
    tmp_db.upsert_progress(vid_id, 12.0)
    tmp_db.update_video(vid_id, status="error", error_msg="Download failed")
    assert tmp_db.get_video(vid_id) is None
    assert tmp_db.get_progress(vid_id) == 0.0


def test_init_db_deletes_legacy_error_videos(tmp_db):
    good_id = tmp_db.add_video("https://twitter.com/x/status/123")
    bad_id = tmp_db.add_video("https://twitter.com/x/status/789")
    tmp_db.upsert_progress(bad_id, 12.0)

    with tmp_db._conn() as conn:
        conn.execute(
            "UPDATE videos SET status = ?, error_msg = ? WHERE id = ?",
            ("error", "Download failed", bad_id),
        )

    tmp_db.init_db()

    assert tmp_db.get_video(good_id) is not None
    assert tmp_db.get_video(bad_id) is None
    assert tmp_db.get_progress(bad_id) == 0.0

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

def test_progress_upsert_and_get(tmp_db):
    vid_id = tmp_db.add_video("https://twitter.com/x/status/999")
    assert tmp_db.get_progress(vid_id) == 0.0
    tmp_db.upsert_progress(vid_id, 42.5)
    assert tmp_db.get_progress(vid_id) == 42.5
    tmp_db.upsert_progress(vid_id, 100.0)
    assert tmp_db.get_progress(vid_id) == 100.0


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
