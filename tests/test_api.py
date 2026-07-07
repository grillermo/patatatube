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
    queued = []
    monkeypatch.setattr("main.download_video", lambda *a, **kw: queued.append((a, kw)))
    resp = client.post(
        "/upload",
        json={"url": "https://twitter.com/x/status/123"},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 202
    data = resp.json()
    assert "id" in data
    assert data["status"] == "queued"
    assert queued == [((data["id"],), {})]


def test_upload_youtube_success(client, monkeypatch):
    queued = []
    monkeypatch.setattr("main.download_video", lambda *a, **kw: queued.append((a, kw)))
    resp = client.post(
        "/upload",
        json={"url": "https://youtu.be/dQw4w9WgXcQ"},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 202
    data = resp.json()
    assert data["status"] == "queued"
    assert queued == [((data["id"],), {})]

    import db

    video = db.get_video(data["id"])
    assert video["platform"] == "youtube"
    assert video["source_key"] == "dQw4w9WgXcQ"
    assert video["preview_url"] == "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"


def test_upload_youtube_strips_non_video_query_params(client, monkeypatch):
    queued = []
    monkeypatch.setattr("main.download_video", lambda *a, **kw: queued.append((a, kw)))
    resp = client.post(
        "/upload",
        json={"url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PL123&t=60&foo=bar"},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 202
    data = resp.json()
    assert queued == [((data["id"],), {})]

    import db

    video = db.get_video(data["id"])
    assert video["url"] == "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    assert video["source_key"] == "dQw4w9WgXcQ"


@pytest.mark.parametrize(
    "url",
    [
        "https://example.com/video",
        "https://www.youtube.com/playlist?list=PL123",
        "https://www.youtube.com/@somechannel",
    ],
)
def test_upload_rejects_invalid_or_unsupported_urls(client, monkeypatch, url):
    monkeypatch.setattr("main.download_video", lambda *a, **kw: None)
    resp = client.post(
        "/upload",
        json={"url": url},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 400


def test_upload_reuses_completed_youtube_video(client, monkeypatch):
    queued = []
    monkeypatch.setattr("main.download_video", lambda *a, **kw: queued.append((a, kw)))

    import db

    existing_id = db.add_video(
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        platform="youtube",
        source_key="dQw4w9WgXcQ",
        title="Stored Title",
    )
    db.update_video(existing_id, status="done", filename="existing.mp4", title="Stored Title")

    resp = client.post(
        "/upload",
        json={"url": "https://youtu.be/dQw4w9WgXcQ"},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 202
    assert resp.json() == {"id": existing_id, "status": "queued"}
    assert queued == []

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
        assert resp.headers["cache-control"] == "public, max-age=31536000, immutable"
    finally:
        fake_video.unlink(missing_ok=True)


def test_stream_returns_requested_byte_range(client):
    import db
    from pathlib import Path

    fake_video = Path("videos") / "1.mp4"
    fake_video.parent.mkdir(exist_ok=True)
    fake_video.write_bytes(b"0123456789")
    try:
        vid_id = db.add_video("https://twitter.com/x/status/1")
        db.update_video(vid_id, status="done", filename="1.mp4")
        resp = client.get(f"/videos/{vid_id}/stream", headers={"Range": "bytes=4-7"})
        assert resp.status_code == 206
        assert resp.content == b"4567"
        assert resp.headers["content-range"] == "bytes 4-7/10"
        assert resp.headers["accept-ranges"] == "bytes"
        assert resp.headers["content-length"] == "4"
        assert resp.headers["cache-control"] == "public, max-age=31536000, immutable"
    finally:
        fake_video.unlink(missing_ok=True)


def test_stream_supports_suffix_byte_range(client):
    import db
    from pathlib import Path

    fake_video = Path("videos") / "1.mp4"
    fake_video.parent.mkdir(exist_ok=True)
    fake_video.write_bytes(b"0123456789")
    try:
        vid_id = db.add_video("https://twitter.com/x/status/1")
        db.update_video(vid_id, status="done", filename="1.mp4")
        resp = client.get(f"/videos/{vid_id}/stream", headers={"Range": "bytes=-4"})
        assert resp.status_code == 206
        assert resp.content == b"6789"
        assert resp.headers["content-range"] == "bytes 6-9/10"
    finally:
        fake_video.unlink(missing_ok=True)


def test_stream_clamps_range_end(client):
    import db
    from pathlib import Path

    fake_video = Path("videos") / "1.mp4"
    fake_video.parent.mkdir(exist_ok=True)
    fake_video.write_bytes(b"0123456789")
    try:
        vid_id = db.add_video("https://twitter.com/x/status/1")
        db.update_video(vid_id, status="done", filename="1.mp4")
        resp = client.get(f"/videos/{vid_id}/stream", headers={"Range": "bytes=4-99"})
        assert resp.status_code == 206
        assert resp.content == b"456789"
        assert resp.headers["content-range"] == "bytes 4-9/10"
    finally:
        fake_video.unlink(missing_ok=True)


def test_stream_rejects_unsatisfiable_range(client):
    import db
    from pathlib import Path

    fake_video = Path("videos") / "1.mp4"
    fake_video.parent.mkdir(exist_ok=True)
    fake_video.write_bytes(b"0123456789")
    try:
        vid_id = db.add_video("https://twitter.com/x/status/1")
        db.update_video(vid_id, status="done", filename="1.mp4")
        resp = client.get(f"/videos/{vid_id}/stream", headers={"Range": "bytes=20-30"})
        assert resp.status_code == 416
        assert resp.headers["content-range"] == "bytes */10"
    finally:
        fake_video.unlink(missing_ok=True)


@pytest.mark.asyncio
async def test_stream_iterator_limits_concurrent_open_files(tmp_path, monkeypatch):
    import asyncio
    import main

    fake_video = tmp_path / "video.mp4"
    fake_video.write_bytes(b"abcdef")
    real_open_file = main.anyio.open_file
    open_calls = 0

    async def counting_open_file(*args, **kwargs):
        nonlocal open_calls
        open_calls += 1
        return await real_open_file(*args, **kwargs)

    monkeypatch.setattr(main.anyio, "open_file", counting_open_file)
    monkeypatch.setattr(main, "_video_stream_slots", asyncio.Semaphore(1))

    first = main._iter_file_range(fake_video, 0, 3)
    second = main._iter_file_range(fake_video, 3, 3)
    second_read = None

    try:
        assert await anext(first) == b"abc"

        second_read = asyncio.create_task(anext(second))
        await asyncio.sleep(0.05)
        assert not second_read.done()
        assert open_calls == 1

        await first.aclose()
        assert await asyncio.wait_for(second_read, timeout=1) == b"def"
        assert open_calls == 2
    finally:
        await first.aclose()
        await second.aclose()
        if second_read is not None and not second_read.done():
            second_read.cancel()


def test_favicon_uses_cached_bytes_when_open_would_fail(client, monkeypatch):
    import builtins
    import errno
    import main

    assert main._static_asset_cache["favicon.ico"]

    real_open = builtins.open

    def open_with_favicon_failure(file, *args, **kwargs):
        if str(file).endswith("favicon.ico"):
            raise OSError(errno.EMFILE, "Too many open files", str(file))
        return real_open(file, *args, **kwargs)

    monkeypatch.setattr(builtins, "open", open_with_favicon_failure)

    resp = client.get("/favicon.ico")
    assert resp.status_code == 200
    assert resp.content == main._static_asset_cache["favicon.ico"]


def test_progress_endpoint_removed(client):
    import db
    vid_id = db.add_video("https://twitter.com/x/status/1")
    resp = client.post(f"/videos/{vid_id}/progress", json={"position_seconds": 37.5})
    assert resp.status_code == 404

def test_videos_page_returns_html(client):
    resp = client.get("/videos")
    assert resp.status_code == 200
    assert "text/html" in resp.headers["content-type"]


def test_root_page_returns_html(client):
    resp = client.get("/")
    assert resp.status_code == 200
    assert "text/html" in resp.headers["content-type"]


def test_patatatube_host_is_allowed(client):
    resp = client.get("/", headers={"host": "patatatube.chiq.me"})
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
    resp = client.get("/videos")
    assert 'onloadedmetadata="this.currentTime=0"' in resp.text


def test_videos_page_starts_youtube_at_zero(client):
    import db

    vid_id = db.add_video(
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=60",
        platform="youtube",
        source_key="dQw4w9WgXcQ",
    )
    db.update_video(vid_id, status="done", filename="yt.mp4")
    resp = client.get("/videos")
    assert 'onloadedmetadata="this.currentTime=0"' in resp.text


def test_videos_page_shows_youtube_title(client):
    import db

    vid_id = db.add_video(
        "https://youtu.be/dQw4w9WgXcQ",
        platform="youtube",
        source_key="dQw4w9WgXcQ",
        title="Saved YouTube Title",
    )
    db.update_video(vid_id, status="done", filename="yt.mp4", title="Saved YouTube Title")
    resp = client.get("/videos")
    assert resp.status_code == 200
    assert "Saved YouTube Title" in resp.text


def test_videos_page_shows_youtube_video_directly(client):
    import db

    vid_id = db.add_video(
        "https://youtu.be/dQw4w9WgXcQ",
        platform="youtube",
        source_key="dQw4w9WgXcQ",
        preview_url="https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
    )
    db.update_video(vid_id, status="done", filename="yt.mp4")
    resp = client.get("/videos")
    assert resp.status_code == 200
    assert f'<video id="v{vid_id}" controls playsinline webkit-playsinline preload="none"' in resp.text
    assert f'<source src="/videos/{vid_id}/stream" type="video/mp4">' in resp.text
    assert 'class="preview-button"' not in resp.text


def test_videos_page_uses_inline_ios_playback_recovery(client):
    import db

    vid_id = db.add_video("https://twitter.com/x/status/123")
    db.update_video(vid_id, status="done", filename="1.mp4")
    resp = client.get("/videos")
    assert resp.status_code == 200
    assert "webkit-playsinline" in resp.text


def test_videos_page_references_all_splash_startup_assets(client):
    from pathlib import Path
    import main

    splash_files = {
        p.name
        for p in Path("assets/splash").iterdir()
        if p.is_file() and p.suffix.lower() in main.SPLASH_MIME_TYPES
    }
    startup_files = {image[0] for image in main.SPLASH_STARTUP_IMAGES}

    assert splash_files == startup_files | {main.SPLASH_ICON}

    resp = client.get("/videos")
    assert resp.status_code == 200
    for filename in startup_files:
        assert f'href="/assets/splash/{filename}"' in resp.text

    assert (
        'media="(device-width: 440px) and (device-height: 956px) '
        'and (-webkit-device-pixel-ratio: 3) and (orientation: portrait)" '
        'href="/assets/splash/iPhone_17_Pro_Max__iPhone_16_Pro_Max_portrait.png"'
    ) in resp.text
    assert (
        'media="(device-width: 440px) and (device-height: 956px) '
        'and (-webkit-device-pixel-ratio: 3) and (orientation: landscape)" '
        'href="/assets/splash/iPhone_17_Pro_Max__iPhone_16_Pro_Max_landscape.png"'
    ) in resp.text


def test_manifest_references_splash_icon(client):
    import main

    resp = client.get("/manifest.webmanifest")
    assert resp.status_code == 200
    icons = resp.json()["icons"]
    assert {
        "src": f"/assets/splash/{main.SPLASH_ICON}",
        "sizes": "512x512",
        "type": "image/png",
        "purpose": "any maskable",
    } in icons


def test_splash_asset_serves_png_files(client):
    resp = client.get("/assets/splash/iPhone_17_Pro_Max__iPhone_16_Pro_Max_portrait.png")
    assert resp.status_code == 200
    assert resp.headers["content-type"] == "image/png"


def test_api_videos_returns_serialized_list(client):
    import db
    vid = db.add_video(
        "https://youtu.be/dQw4w9WgXcQ",
        platform="youtube",
        source_key="dQw4w9WgXcQ",
        title="Saved Title",
        preview_url="https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
    )
    db.update_video(vid, status="done", filename="yt.mp4", title="Saved Title")
    resp = client.get("/api/videos")
    assert resp.status_code == 200
    data = resp.json()
    assert isinstance(data, list)
    item = next(v for v in data if v["id"] == vid)
    assert item["title"] == "Saved Title"
    assert item["platform"] == "youtube"
    assert item["status"] == "done"
    assert item["stream_path"] == f"/videos/{vid}/stream"
    assert "filename" not in item


def test_api_videos_filters_by_classification(client):
    import db
    a = db.add_video("https://twitter.com/x/status/1")
    b = db.add_video("https://twitter.com/x/status/2")
    db.set_video_classification(a, "education")
    db.set_video_classification(b, "children")
    resp = client.get("/api/videos", params={"classification": "education"})
    assert resp.status_code == 200
    ids = {v["id"] for v in resp.json()}
    assert a in ids and b not in ids


def test_api_videos_ignores_unknown_classification(client):
    import db
    vid = db.add_video("https://twitter.com/x/status/1")
    resp = client.get("/api/videos", params={"classification": "bogus"})
    assert resp.status_code == 200
    assert any(v["id"] == vid for v in resp.json())


def test_api_classifications_lists_all(client):
    resp = client.get("/api/classifications")
    assert resp.status_code == 200
    assert resp.json() == {
        "classifications": ["children", "adults", "education", "tv", "movies"]
    }


def test_api_move_requires_token(client):
    import db
    vid = db.add_video("https://twitter.com/x/status/1")
    resp = client.post(f"/api/videos/{vid}/move", json={"direction": "up"})
    assert resp.status_code == 401


def test_api_move_swaps_and_returns_ok(client):
    import db
    first = db.add_video("https://twitter.com/x/status/1")
    second = db.add_video("https://twitter.com/x/status/2")
    resp = client.post(
        f"/api/videos/{second}/move",
        json={"direction": "down"},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 200
    assert resp.json() == {"ok": True}
    assert db.get_video(first)["position"] > db.get_video(second)["position"]


def test_api_move_invalid_direction_returns_not_ok(client):
    import db
    vid = db.add_video("https://twitter.com/x/status/1")
    resp = client.post(
        f"/api/videos/{vid}/move",
        json={"direction": "sideways"},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 200
    assert resp.json() == {"ok": False}


def test_api_classify_requires_token(client):
    import db
    vid = db.add_video("https://twitter.com/x/status/1")
    resp = client.post(f"/api/videos/{vid}/classify", json={"classification": "education"})
    assert resp.status_code == 401


def test_api_classify_sets_and_returns_ok(client):
    import db
    vid = db.add_video("https://twitter.com/x/status/1")
    resp = client.post(
        f"/api/videos/{vid}/classify",
        json={"classification": "education"},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 200
    assert resp.json() == {"ok": True}
    assert db.get_video(vid)["classification"] == "education"


def test_api_classify_invalid_returns_not_ok(client):
    import db
    vid = db.add_video("https://twitter.com/x/status/1")
    db.set_video_classification(vid, "children")
    resp = client.post(
        f"/api/videos/{vid}/classify",
        json={"classification": "bogus"},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 200
    assert resp.json() == {"ok": False}
    assert db.get_video(vid)["classification"] == "children"


def test_api_delete_requires_token(client):
    import db
    vid = db.add_video("https://twitter.com/x/status/1")
    resp = client.post(f"/api/video/{vid}/delete")
    assert resp.status_code == 401
    assert db.get_video(vid) is not None


def test_api_delete_removes_row_and_file(client):
    import main
    import db
    vid = db.add_video("https://twitter.com/x/status/1")
    db.update_video(vid, status="done", filename=f"{vid}.mp4")
    path = main.VIDEOS_DIR / f"{vid}.mp4"
    path.write_bytes(b"data")
    resp = client.post(
        f"/api/video/{vid}/delete",
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 200
    assert resp.json() == {"ok": True}
    assert db.get_video(vid) is None
    assert not path.exists()


AUTH = {"Authorization": "Bearer test-secret"}

LIB_ITEM_API = {
    "source_path": None,  # filled per-test with tmp file
    "title": "System", "classification": "tv", "show_title": "The Bear",
    "season": 1, "episode": 1, "summary": "Carmy.",
    "plex_rating_key": "1264", "show_rating_key": "1262",
}


def make_library_row(tmp_path, name="ep.mkv"):
    import db
    src = tmp_path / name
    src.write_bytes(b"fake")
    vid, _ = db.upsert_library_video({**LIB_ITEM_API, "source_path": str(src)})
    return vid, src


def test_scan_requires_token(client):
    assert client.post("/api/library/scan").status_code == 401


def test_scan_without_plex_token_is_503(client, monkeypatch):
    monkeypatch.delenv("PLEX_TOKEN", raising=False)
    resp = client.post("/api/library/scan", headers=AUTH)
    assert resp.status_code == 503


def test_scan_success(client, monkeypatch, tmp_path):
    monkeypatch.setenv("PLEX_TOKEN", "plex-token")
    src = tmp_path / "a.mkv"
    src.write_bytes(b"x")
    import plex
    monkeypatch.setattr(plex, "fetch_library_items", lambda: [
        {**LIB_ITEM_API, "source_path": str(src)},
    ])
    resp = client.post("/api/library/scan", headers=AUTH)
    assert resp.status_code == 200
    assert resp.json() == {"added": 1, "updated": 0, "skipped": 0}

    videos = client.get("/api/videos").json()
    lib = [v for v in videos if v["source"] == "library"]
    assert len(lib) == 1 and lib[0]["status"] == "unconverted"


def test_scan_plex_down_is_502(client, monkeypatch):
    monkeypatch.setenv("PLEX_TOKEN", "plex-token")
    import plex
    def boom():
        raise plex.PlexError("connection refused")
    monkeypatch.setattr(plex, "fetch_library_items", boom)
    resp = client.post("/api/library/scan", headers=AUTH)
    assert resp.status_code == 502


def test_delete_library_video_tombstones(client, tmp_path):
    import db
    vid, src = make_library_row(tmp_path)
    converted = tmp_path / "ep.mp4"
    converted.write_bytes(b"converted")
    db.set_library_state(vid, "done", converted_path=str(converted))

    resp = client.post(f"/api/video/{vid}/delete", headers=AUTH)
    assert resp.status_code == 200
    assert src.exists()                     # original never touched
    assert not converted.exists()           # our copy removed
    assert db.get_video(vid)["deleted_at"] is not None
    assert vid not in [v["id"] for v in client.get("/api/videos").json()]
