# tests/test_api.py
import pytest
import importlib
from pathlib import Path
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
    monkeypatch.setattr("router.download_video", lambda *a, **kw: queued.append((a, kw)))
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


def test_upload_file_missing_token(client):
    resp = client.post(
        "/upload/file",
        files={"file": ("video.mp4", b"bytes", "video/mp4")},
        data={"classification": "children"},
    )
    assert resp.status_code == 401


def test_upload_file_invalid_classification(client):
    resp = client.post(
        "/upload/file",
        files={"file": ("video.mp4", b"bytes", "video/mp4")},
        data={"classification": "not-a-real-one"},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 400


def test_upload_file_success(client, monkeypatch):
    import db

    queued = []
    monkeypatch.setattr("router.process_uploaded_video", lambda *a, **kw: queued.append((a, kw)), raising=False)
    classification = db.CLASSIFICATIONS[0]

    resp = client.post(
        "/upload/file",
        files={"file": ("my video.mp4", b"fake-video-bytes", "video/mp4")},
        data={"classification": classification},
        headers={"Authorization": "Bearer test-secret"},
    )

    assert resp.status_code == 202
    data = resp.json()
    assert data["status"] == "queued"
    assert queued == [((data["id"],), {})]

    video = db.get_video(data["id"])
    assert video["platform"] == "upload"
    assert video["title"] == "my video"
    assert video["classification"] == classification
    assert Path(video["url"]).exists()
    assert Path(video["url"]).read_bytes() == b"fake-video-bytes"


def test_upload_youtube_success(client, monkeypatch):
    queued = []
    monkeypatch.setattr("router.download_video", lambda *a, **kw: queued.append((a, kw)))
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
    monkeypatch.setattr("router.download_video", lambda *a, **kw: queued.append((a, kw)))
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
    monkeypatch.setattr("router.download_video", lambda *a, **kw: None)
    resp = client.post(
        "/upload",
        json={"url": url},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 400


def test_upload_reuses_completed_youtube_video(client, monkeypatch):
    queued = []
    monkeypatch.setattr("router.download_video", lambda *a, **kw: queued.append((a, kw)))

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
    resp = client.get("/videos/999/stream", headers=AUTH)
    assert resp.status_code == 404

def test_stream_not_done(client):
    import db
    vid_id = db.add_video("https://twitter.com/x/status/1")
    resp = client.get(f"/videos/{vid_id}/stream", headers=AUTH)
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
        resp = client.get(f"/videos/{vid_id}/stream", headers=AUTH)
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
        resp = client.get(f"/videos/{vid_id}/stream", headers={**AUTH, "Range": "bytes=4-7"})
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
        resp = client.get(f"/videos/{vid_id}/stream", headers={**AUTH, "Range": "bytes=-4"})
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
        resp = client.get(f"/videos/{vid_id}/stream", headers={**AUTH, "Range": "bytes=4-99"})
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
        resp = client.get(f"/videos/{vid_id}/stream", headers={**AUTH, "Range": "bytes=20-30"})
        assert resp.status_code == 416
        assert resp.headers["content-range"] == "bytes */10"
    finally:
        fake_video.unlink(missing_ok=True)


@pytest.mark.asyncio
async def test_stream_iterator_limits_concurrent_open_files(tmp_path, monkeypatch):
    import asyncio
    import main
    import router

    fake_video = tmp_path / "video.mp4"
    fake_video.write_bytes(b"abcdef")
    real_open_file = router.anyio.open_file
    open_calls = 0

    async def counting_open_file(*args, **kwargs):
        nonlocal open_calls
        open_calls += 1
        return await real_open_file(*args, **kwargs)

    monkeypatch.setattr(router.anyio, "open_file", counting_open_file)
    monkeypatch.setattr(router, "_video_stream_slots", asyncio.Semaphore(1))

    first = router._iter_file_range(fake_video, 0, 3)
    second = router._iter_file_range(fake_video, 3, 3)
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
    import router

    assert router._static_asset_cache["favicon.ico"]

    real_open = builtins.open

    def open_with_favicon_failure(file, *args, **kwargs):
        if str(file).endswith("favicon.ico"):
            raise OSError(errno.EMFILE, "Too many open files", str(file))
        return real_open(file, *args, **kwargs)

    monkeypatch.setattr(builtins, "open", open_with_favicon_failure)

    resp = client.get("/favicon.ico")
    assert resp.status_code == 200
    assert resp.content == router._static_asset_cache["favicon.ico"]


def test_progress_endpoint_removed(client):
    import db
    vid_id = db.add_video("https://twitter.com/x/status/1")
    resp = client.post(f"/videos/{vid_id}/progress", json={"position_seconds": 37.5})
    assert resp.status_code == 404

def test_videos_page_returns_html(client):
    resp = client.get("/videos")
    assert resp.status_code == 200
    assert "text/html" in resp.headers["content-type"]


def test_videos_page_has_upload_button_and_dialog(client):
    resp = client.get("/videos")
    assert resp.status_code == 200
    assert 'id="upload-fab"' in resp.text
    assert 'id="upload-dialog"' in resp.text
    assert 'id="upload-form"' in resp.text
    assert '<option value="children">children</option>' in resp.text
    assert '<option value="tv">tv</option>' in resp.text


def test_videos_page_loads_vendored_nprogress(client):
    resp = client.get("/videos")
    assert "/assets/vendor/nprogress.js" in resp.text
    assert "/assets/vendor/nprogress.css" in resp.text


def test_videos_page_exposes_upload_token_for_xhr(client):
    resp = client.get("/videos")
    assert 'var UPLOAD_TOKEN = "test-secret";' in resp.text


def test_upload_platform_video_shows_filename_title_not_tmp_path(client):
    import db

    video_id = db.add_video("/private/tmp/tmpabc123.mp4", platform="upload", title="Birthday Clip")
    db.update_video(video_id, status="done", filename=f"{video_id}.mp4")

    resp = client.get("/videos")

    assert "Birthday Clip" in resp.text
    assert "tmpabc123" not in resp.text


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


def test_videos_page_shows_library_title_not_filesystem_path(client, tmp_path):
    import db

    vid_id, src = make_library_row(tmp_path)
    db.set_library_state(vid_id, "done", converted_path=str(tmp_path / "ep.mp4"))
    resp = client.get("/videos")
    assert resp.status_code == 200
    # LIB_ITEM_API's title is "System" — must appear as the rendered card
    # title, not merely as a substring of unrelated page chrome (e.g. the
    # CSS "-apple-system" font stack, which also contains "System").
    assert '<div class="name-overlay">System</div>' in resp.text
    assert str(src) not in resp.text


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
    assert f'<source src="/videos/{vid_id}/stream?token=test-secret" type="video/mp4">' in resp.text
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
    import router

    splash_files = {
        p.name
        for p in Path("assets/splash").iterdir()
        if p.is_file() and p.suffix.lower() in router.SPLASH_MIME_TYPES
    }
    startup_files = {image[0] for image in router.SPLASH_STARTUP_IMAGES}

    assert splash_files == startup_files | {router.SPLASH_ICON}

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
    import router

    resp = client.get("/manifest.webmanifest")
    assert resp.status_code == 200
    icons = resp.json()["icons"]
    assert {
        "src": f"/assets/splash/{router.SPLASH_ICON}",
        "sizes": "512x512",
        "type": "image/png",
        "purpose": "any maskable",
    } in icons


def test_splash_asset_serves_png_files(client):
    resp = client.get("/assets/splash/iPhone_17_Pro_Max__iPhone_16_Pro_Max_portrait.png")
    assert resp.status_code == 200
    assert resp.headers["content-type"] == "image/png"


def test_vendor_asset_serves_nprogress_js(client):
    resp = client.get("/assets/vendor/nprogress.js")
    assert resp.status_code == 200
    assert resp.headers["content-type"] == "application/javascript"


def test_vendor_asset_serves_nprogress_css(client):
    resp = client.get("/assets/vendor/nprogress.css")
    assert resp.status_code == 200
    assert resp.headers["content-type"] == "text/css; charset=utf-8"


def test_vendor_asset_404_for_unknown_file(client):
    resp = client.get("/assets/vendor/does-not-exist.js")
    assert resp.status_code == 404


def test_vendor_asset_rejects_path_traversal(client):
    resp = client.get("/assets/vendor/..%2Fmain.py")
    assert resp.status_code == 404


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
    target_classification = next(cls for cls in db.CLASSIFICATIONS if cls != "children")
    a = db.add_video("https://twitter.com/x/status/1")
    b = db.add_video("https://twitter.com/x/status/2")
    db.set_video_classification(a, target_classification)
    db.set_video_classification(b, "children")
    resp = client.get("/api/videos", params={"classification": target_classification})
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
    import db

    resp = client.get("/api/classifications")
    assert resp.status_code == 200
    assert resp.json() == {"classifications": db.CLASSIFICATIONS}


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
    resp = client.post(f"/api/videos/{vid}/classify", json={"classification": "children"})
    assert resp.status_code == 401


def test_api_classify_sets_and_returns_ok(client):
    import db
    target_classification = next(cls for cls in db.CLASSIFICATIONS if cls != "children")
    vid = db.add_video("https://twitter.com/x/status/1")
    resp = client.post(
        f"/api/videos/{vid}/classify",
        json={"classification": target_classification},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 200
    assert resp.json() == {"ok": True}
    assert db.get_video(vid)["classification"] == target_classification


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
    import router
    import db
    vid = db.add_video("https://twitter.com/x/status/1")
    db.update_video(vid, status="done", filename=f"{vid}.mp4")
    path = router.VIDEOS_DIR / f"{vid}.mp4"
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


def test_get_single_video(client, tmp_path):
    vid, _ = make_library_row(tmp_path)
    assert client.get(f"/api/videos/{vid}").status_code == 401
    resp = client.get(f"/api/videos/{vid}", headers=AUTH)
    assert resp.status_code == 200
    assert resp.json()["id"] == vid
    assert client.get("/api/videos/99999", headers=AUTH).status_code == 404


def make_versioned_movie(tmp_path):
    import db

    src_1080 = tmp_path / "movie.1080p.mkv"
    src_4k = tmp_path / "movie.4k.mkv"
    src_1080.write_bytes(b"1080-bytes")
    src_4k.write_bytes(b"4k-bytes")
    vid, _ = db.upsert_library_video(
        {
            **LIB_ITEM_API,
            "source_path": str(src_1080),
            "title": "Movie",
            "classification": "movies",
            "show_title": None,
            "season": None,
            "episode": None,
            "plex_rating_key": "4242",
            "show_rating_key": None,
            "versions": [
                {"source_path": str(src_1080), "label": "1080p"},
                {"source_path": str(src_4k), "label": "4K"},
            ],
        }
    )
    return vid, src_1080, src_4k


def test_api_video_serializes_versions(client, tmp_path):
    import db

    vid, _, _ = make_versioned_movie(tmp_path)
    versions = db.get_video_versions(vid)
    assert db.set_chosen_version(vid, versions[1]["id"]) is True

    resp = client.get(f"/api/videos/{vid}", headers=AUTH)

    assert resp.status_code == 200
    data = resp.json()
    assert data["chosen_version_id"] == versions[1]["id"]
    assert data["versions"] == [
        {"id": versions[0]["id"], "label": "1080p", "status": "unconverted", "is_chosen": False},
        {"id": versions[1]["id"], "label": "4K", "status": "unconverted", "is_chosen": True},
    ]


def test_choose_version_endpoint_updates_selection(client, tmp_path):
    import db

    vid, _, _ = make_versioned_movie(tmp_path)
    versions = db.get_video_versions(vid)

    resp = client.post(
        f"/api/videos/{vid}/version",
        json={"version_id": versions[1]["id"]},
        headers=AUTH,
    )

    assert resp.status_code == 200
    assert resp.json() == {"ok": True}
    assert db.get_video(vid)["chosen_version_id"] == versions[1]["id"]


def test_stream_library_supports_version_override(client, tmp_path):
    import db

    vid, _, src_4k = make_versioned_movie(tmp_path)
    versions = db.get_video_versions(vid)
    db.set_library_state(vid, "done", version_id=versions[1]["id"])

    resp = client.get(
        f"/videos/{vid}/stream?version_id={versions[1]['id']}",
        headers=AUTH,
    )

    assert resp.status_code == 200
    assert resp.content == src_4k.read_bytes()


def test_prepare_passthrough_returns_done(client, tmp_path, monkeypatch):
    import library
    vid, _ = make_library_row(tmp_path, name="ep.mp4")
    monkeypatch.setattr(library, "probe_source", lambda p: {
        "streams": [
            {"codec_type": "video", "codec_name": "h264", "width": 1920,
             "codec_tag_string": "avc1"},
            {"codec_type": "audio", "codec_name": "aac", "channels": 2},
        ],
        "format": {"format_name": "mov,mp4,m4a,3gp,3g2,mj2"},
    })
    resp = client.post(f"/api/videos/{vid}/prepare", headers=AUTH)
    assert resp.status_code == 200
    assert resp.json() == {"status": "done"}
    import db
    assert db.get_video(vid)["status"] == "done"


def test_prepare_queues_conversion(client, tmp_path, monkeypatch):
    import library
    vid, _ = make_library_row(tmp_path)
    monkeypatch.setattr(library, "probe_source", lambda p: {
        "streams": [{"codec_type": "video", "codec_name": "hevc", "width": 1920,
                     "codec_tag_string": "[0][0][0][0]"}],
        "format": {"format_name": "matroska,webm"},
    })
    converted = []
    monkeypatch.setattr("router.library.convert_library_video",
                        lambda video_id: converted.append(video_id))
    resp = client.post(f"/api/videos/{vid}/prepare", headers=AUTH)
    assert resp.status_code == 202
    assert resp.json() == {"status": "converting"}
    assert converted == [vid]  # TestClient runs background tasks before returning
    import db
    assert db.get_video(vid)["status"] == "converting"


def test_prepare_while_converting_is_noop_202(client, tmp_path, monkeypatch):
    import db
    vid, _ = make_library_row(tmp_path)
    db.set_library_state(vid, "converting")
    called = []
    monkeypatch.setattr("router.library.convert_library_video", lambda v: called.append(v))
    resp = client.post(f"/api/videos/{vid}/prepare", headers=AUTH)
    assert resp.status_code == 202 and called == []


def test_prepare_download_row_is_400(client, monkeypatch):
    import db
    monkeypatch.setattr("router.download_video", lambda *a, **kw: None)
    up = client.post("/upload", json={"url": "https://twitter.com/x/status/9"}, headers=AUTH)
    resp = client.post(f"/api/videos/{up.json()['id']}/prepare", headers=AUTH)
    assert resp.status_code == 400


def test_prepare_while_done_is_noop_200(client, tmp_path, monkeypatch):
    import db
    vid, _ = make_library_row(tmp_path)
    db.set_library_state(vid, "done")
    called = []
    monkeypatch.setattr("router.library.convert_library_video", lambda v: called.append(v))
    resp = client.post(f"/api/videos/{vid}/prepare", headers=AUTH)
    assert resp.status_code == 200
    assert resp.json() == {"status": "done"}
    assert called == []


def test_prepare_missing_source_is_404(client, tmp_path):
    import db
    vid, src = make_library_row(tmp_path)
    src.unlink()
    resp = client.post(f"/api/videos/{vid}/prepare", headers=AUTH)
    assert resp.status_code == 404
    assert "missing" in db.get_video(vid)["error_msg"]


def test_prepare_probe_failure_is_500(client, tmp_path, monkeypatch):
    import db
    import library
    vid, _ = make_library_row(tmp_path)

    def boom(p):
        raise RuntimeError("ffprobe exploded")

    monkeypatch.setattr(library, "probe_source", boom)
    resp = client.post(f"/api/videos/{vid}/prepare", headers=AUTH)
    assert resp.status_code == 500
    assert "ffprobe exploded" in db.get_video(vid)["error_msg"]


def test_get_single_video_tombstoned_is_404(client, tmp_path):
    import db
    vid, _ = make_library_row(tmp_path)
    db.tombstone_video(vid)
    resp = client.get(f"/api/videos/{vid}", headers=AUTH)
    assert resp.status_code == 404


def make_done_download_video(tmp_path):
    """A completed download row whose mp4 exists under videos/."""
    import db
    from pathlib import Path
    vid = db.add_video("https://twitter.com/x/status/55", platform="twitter")
    Path("videos").mkdir(exist_ok=True)
    f = Path("videos") / f"{vid}.mp4"
    f.write_bytes(b"\x00" * 100)
    db.update_video(vid, "done", filename=f"{vid}.mp4")
    return vid, f


def test_stream_requires_token(client, tmp_path):
    vid, f = make_done_download_video(tmp_path)
    try:
        assert client.get(f"/videos/{vid}/stream").status_code == 401
        assert client.get(f"/videos/{vid}/stream", headers=AUTH).status_code == 200
        assert client.get(f"/videos/{vid}/stream?token=test-secret").status_code == 200
        assert client.get(f"/videos/{vid}/stream?token=wrong").status_code == 401
    finally:
        f.unlink(missing_ok=True)


def test_stream_rejects_wrong_bearer_token(client, tmp_path):
    vid, f = make_done_download_video(tmp_path)
    try:
        resp = client.get(f"/videos/{vid}/stream", headers={"Authorization": "Bearer wrong-token"})
        assert resp.status_code == 401
    finally:
        f.unlink(missing_ok=True)


def test_stream_tombstoned_library_row_is_404(client, tmp_path):
    import db
    vid, src = make_library_row(tmp_path)
    converted = tmp_path / "ep.mp4"
    converted.write_bytes(b"converted-bytes")
    db.set_library_state(vid, "done", converted_path=str(converted))
    db.tombstone_video(vid)
    resp = client.get(f"/videos/{vid}/stream", headers=AUTH)
    assert resp.status_code == 404


def test_stream_library_serves_converted_copy(client, tmp_path):
    import db
    vid, src = make_library_row(tmp_path)
    converted = tmp_path / "ep.mp4"
    converted.write_bytes(b"converted-bytes")
    db.set_library_state(vid, "done", converted_path=str(converted))
    resp = client.get(f"/videos/{vid}/stream", headers=AUTH)
    assert resp.status_code == 200
    assert resp.content == b"converted-bytes"


def test_stream_library_passthrough_serves_original(client, tmp_path):
    import db
    vid, src = make_library_row(tmp_path, name="ep.mp4")
    db.set_library_state(vid, "done")  # passthrough: no converted_path
    resp = client.get(f"/videos/{vid}/stream", headers=AUTH)
    assert resp.status_code == 200
    assert resp.content == b"fake"


def test_stream_unprepared_library_is_409(client, tmp_path):
    vid, _ = make_library_row(tmp_path)
    assert client.get(f"/videos/{vid}/stream", headers=AUTH).status_code == 409


def test_ssr_page_appends_stream_token(client, tmp_path):
    vid, f = make_done_download_video(tmp_path)
    try:
        html = client.get("/videos").text
        assert f"/videos/{vid}/stream?token=test-secret" in html
    finally:
        f.unlink(missing_ok=True)


def test_preview_proxies_and_caches(client, tmp_path, monkeypatch):
    import plex
    vid, _ = make_library_row(tmp_path)
    calls = []

    def fake_thumb(rating_key):
        calls.append(rating_key)
        return b"jpegbytes"

    monkeypatch.setattr(plex, "fetch_thumb", fake_thumb)
    monkeypatch.setattr("router.PREVIEWS_DIR", tmp_path / "previews")

    assert client.get(f"/videos/{vid}/preview").status_code == 401

    resp = client.get(f"/videos/{vid}/preview", headers=AUTH)
    assert resp.status_code == 200
    assert resp.content == b"jpegbytes"
    assert resp.headers["content-type"] == "image/jpeg"
    assert calls == ["1264"]

    resp = client.get(f"/videos/{vid}/preview", headers=AUTH)  # served from disk cache
    assert resp.status_code == 200 and calls == ["1264"]

    resp = client.get(f"/videos/{vid}/preview?kind=show", headers=AUTH)
    assert resp.status_code == 200 and calls == ["1264", "1262"]


def test_preview_404_for_download_rows(client, monkeypatch):
    import db
    vid = db.add_video("https://twitter.com/x/status/77", platform="twitter")
    assert client.get(f"/videos/{vid}/preview", headers=AUTH).status_code == 404


# --- HLS subtitle routes ---------------------------------------------------


def _seed_done_download(status_num="900", filename="900.mp4"):
    import db
    from pathlib import Path

    p = Path("videos") / filename
    p.parent.mkdir(exist_ok=True)
    p.write_bytes(b"FAKEMP4")
    vid = db.add_video(f"https://twitter.com/x/status/{status_num}")
    db.update_video(vid, status="done", filename=filename)
    return vid, p


def _fake_build(video_id, source_path, *a, **k):
    """Stand in for ffmpeg packaging: lay down a full HLS tree on disk."""
    import hls

    out = hls.hls_dir_for(video_id)
    (out / "subtitles").mkdir(parents=True, exist_ok=True)
    (out / "master.m3u8").write_text(
        "#EXTM3U\n#EXT-X-INDEPENDENT-SEGMENTS\n"
        '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",LANGUAGE="en",NAME="English",'
        'DEFAULT=YES,AUTOSELECT=YES,FORCED=NO,URI="subtitles/en.m3u8"\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=1500000,SUBTITLES="subs"\nvideo.m3u8\n'
    )
    (out / "video.m3u8").write_text("#EXTM3U\n")
    (out / "segment_00000.m4s").write_bytes(b"SEG")
    (out / "subtitles" / "en.m3u8").write_text("#EXTM3U\n")
    (out / "subtitles" / "en.vtt").write_text("WEBVTT\n")


def test_hls_master_requires_auth(client):
    resp = client.get("/videos/1/hls/master.m3u8")
    assert resp.status_code == 401


def test_hls_master_404_for_missing_video(client):
    resp = client.get("/videos/999/hls/master.m3u8", headers=AUTH)
    assert resp.status_code == 404


def test_hls_master_409_when_source_not_ready(client):
    import db

    vid = db.add_video("https://twitter.com/x/status/901")  # queued, no file
    resp = client.get(f"/videos/{vid}/hls/master.m3u8", headers=AUTH)
    assert resp.status_code == 409


def test_hls_master_prepares_then_serves_tree(client, monkeypatch, tmp_path):
    import hls

    monkeypatch.setattr(hls, "HLS_DIR", tmp_path / "hls")
    monkeypatch.setattr(hls, "build_hls_package", _fake_build)
    vid, p = _seed_done_download()
    try:
        # First hit: source ready but no package -> schedules prep, 409.
        first = client.get(f"/videos/{vid}/hls/master.m3u8", headers=AUTH)
        assert first.status_code == 409

        # Background prep has now run (TestClient runs tasks post-response).
        master = client.get(f"/videos/{vid}/hls/master.m3u8", headers=AUTH)
        assert master.status_code == 200
        assert master.headers["content-type"].startswith("application/vnd.apple.mpegurl")
        assert "TYPE=SUBTITLES" in master.text

        assert client.get(f"/videos/{vid}/hls/video.m3u8", headers=AUTH).status_code == 200
        seg = client.get(f"/videos/{vid}/hls/segment_00000.m4s", headers=AUTH)
        assert seg.status_code == 200
        assert client.get(f"/videos/{vid}/hls/subtitles/en.m3u8", headers=AUTH).status_code == 200

        vtt = client.get(f"/videos/{vid}/hls/subtitles/en.vtt", headers=AUTH)
        assert vtt.status_code == 200
        assert vtt.headers["content-type"].startswith("text/vtt")
    finally:
        p.unlink(missing_ok=True)


def test_hls_rejects_path_traversal(client, monkeypatch, tmp_path):
    import hls

    monkeypatch.setattr(hls, "HLS_DIR", tmp_path / "hls")
    vid, p = _seed_done_download(status_num="902", filename="902.mp4")
    try:
        resp = client.get(f"/videos/{vid}/hls/../../secret", headers=AUTH)
        # httpx normalizes ../ in the client, so hit the encoded form too.
        assert resp.status_code in (404, 409)
        resp2 = client.get(f"/videos/{vid}/hls/%2e%2e%2f%2e%2e%2fsecret", headers=AUTH)
        assert resp2.status_code == 404
    finally:
        p.unlink(missing_ok=True)
