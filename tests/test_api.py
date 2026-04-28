# tests/test_api.py
import pytest
import importlib
from fastapi.testclient import TestClient

@pytest.fixture()
def client(monkeypatch, tmp_path):
    monkeypatch.setenv("DB_PATH", str(tmp_path / "test.db"))
    monkeypatch.setenv("UPLOAD_TOKEN", "test-secret")
    # Reload db first so DB_PATH env var is picked up
    import db
    importlib.reload(db)
    # Then reload main so it gets the reloaded db module
    import main
    importlib.reload(main)
    # Use context manager so lifespan runs (calls db.init_db())
    with TestClient(main.app) as c:
        yield c

def test_upload_missing_token(client):
    resp = client.post("/upload", json={"url": "https://twitter.com/x/status/1"})
    assert resp.status_code == 401

def test_upload_wrong_token(client):
    resp = client.post(
        "/upload",
        json={"url": "https://twitter.com/x/status/1"},
        headers={"Authorization": "Bearer wrong-token"},
    )
    assert resp.status_code == 401

def test_upload_missing_url(client):
    resp = client.post(
        "/upload",
        json={},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 422

def test_upload_success(client, monkeypatch):
    # Patch background task so it doesn't actually download
    monkeypatch.setattr("main.download_video", lambda *a, **kw: None)
    resp = client.post(
        "/upload",
        json={"url": "https://twitter.com/x/status/123"},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 202
    data = resp.json()
    assert "id" in data
    assert data["status"] == "queued"

def test_stream_not_found(client):
    resp = client.get("/videos/999/stream")
    assert resp.status_code == 404

def test_stream_not_done(client):
    import db
    vid_id = db.add_video("https://twitter.com/x/status/1")
    resp = client.get(f"/videos/{vid_id}/stream")
    assert resp.status_code == 404

def test_stream_returns_video(client):
    import db
    from pathlib import Path

    fake_video = Path("videos") / "1.mp4"
    fake_video.parent.mkdir(exist_ok=True)
    fake_video.write_bytes(b"FAKEVIDEOCONTENT")
    try:
        vid_id = db.add_video("https://twitter.com/x/status/1")
        db.update_video(vid_id, status="done", filename="1.mp4")
        resp = client.get(f"/videos/{vid_id}/stream")
        assert resp.status_code in (200, 206)
        assert b"FAKEVIDEOCONTENT" in resp.content
    finally:
        fake_video.unlink(missing_ok=True)

def test_save_progress(client):
    import db
    vid_id = db.add_video("https://twitter.com/x/status/1")
    resp = client.post(f"/videos/{vid_id}/progress", json={"position_seconds": 37.5})
    assert resp.status_code == 200
    assert db.get_progress(vid_id) == 37.5

def test_save_progress_video_not_found(client):
    resp = client.post("/videos/999/progress", json={"position_seconds": 10.0})
    assert resp.status_code == 404

def test_videos_page_returns_html(client):
    resp = client.get("/videos")
    assert resp.status_code == 200
    assert "text/html" in resp.headers["content-type"]

def test_videos_page_shows_video(client):
    import db
    vid_id = db.add_video("https://twitter.com/x/status/123")
    db.update_video(vid_id, status="done", filename="1.mp4")
    resp = client.get("/videos")
    assert resp.status_code == 200
    assert f"/videos/{vid_id}/stream" in resp.text

def test_videos_page_sets_resume_time(client):
    import db
    vid_id = db.add_video("https://twitter.com/x/status/123")
    db.update_video(vid_id, status="done", filename="1.mp4")
    db.upsert_progress(vid_id, 55.0)
    resp = client.get("/videos")
    assert "55.0" in resp.text
