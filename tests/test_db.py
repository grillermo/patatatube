# tests/test_db.py
import pytest
import tempfile
import os

# Override DB path before importing db
@pytest.fixture(autouse=True)
def tmp_db(monkeypatch, tmp_path):
    db_path = str(tmp_path / "test.db")
    monkeypatch.setenv("DB_PATH", db_path)
    import db
    import importlib
    importlib.reload(db)
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
    tmp_db.update_video(vid_id, status="error", error_msg="Download failed")
    video = tmp_db.get_video(vid_id)
    assert video["status"] == "error"
    assert video["error_msg"] == "Download failed"

def test_get_all_videos(tmp_db):
    tmp_db.add_video("https://twitter.com/x/status/1")
    tmp_db.add_video("https://twitter.com/x/status/2")
    videos = tmp_db.get_all_videos()
    assert len(videos) == 2

def test_progress_upsert_and_get(tmp_db):
    vid_id = tmp_db.add_video("https://twitter.com/x/status/999")
    assert tmp_db.get_progress(vid_id) == 0.0
    tmp_db.upsert_progress(vid_id, 42.5)
    assert tmp_db.get_progress(vid_id) == 42.5
    tmp_db.upsert_progress(vid_id, 100.0)
    assert tmp_db.get_progress(vid_id) == 100.0
