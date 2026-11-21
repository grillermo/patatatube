# tests/test_api.py
import importlib
from pathlib import Path

import pytest
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
        # Set login cookie so tests can access the videos page
        c.cookies.set("upload_token", "test-secret")
        yield c


@pytest.fixture()
def auth_headers():
    return {"Authorization": "Bearer test-secret"}


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
    assert queued == [((data["id"],), {"classify": True})]


def test_upload_uses_requested_group(client, monkeypatch):
    import db

    monkeypatch.setattr("router.download_video", lambda *a, **kw: None)
    group_id = db.get_group_by_name("adults")["id"]

    resp = client.post(
        "/upload",
        json={"url": "https://twitter.com/x/status/124", "group_id": group_id},
        headers={"Authorization": "Bearer test-secret"},
    )

    assert resp.status_code == 202
    assert db.get_video(resp.json()["id"])["group_id"] == group_id


def test_upload_without_group_uses_inbox(client, monkeypatch):
    import db

    monkeypatch.setattr("router.download_video", lambda *a, **kw: None)
    inbox_id = db.create_group("inbox", "inbox")["id"]

    resp = client.post(
        "/upload",
        json={"url": "https://twitter.com/x/status/125"},
        headers={"Authorization": "Bearer test-secret"},
    )

    assert resp.status_code == 202
    assert db.get_video(resp.json()["id"])["group_id"] == inbox_id


def test_upload_without_group_falls_back_to_first_group_without_inbox(client, monkeypatch):
    import db

    monkeypatch.setattr("router.download_video", lambda *a, **kw: None)
    assert db.get_group_by_name("inbox") is None
    first_group_id = db.list_groups()[0]["id"]

    resp = client.post(
        "/upload",
        json={"url": "https://twitter.com/x/status/126"},
        headers={"Authorization": "Bearer test-secret"},
    )

    assert resp.status_code == 202
    assert db.get_video(resp.json()["id"])["group_id"] == first_group_id


def test_upload_file_missing_token(client):
    resp = client.post(
        "/upload/file",
        files={"file": ("video.mp4", b"bytes", "video/mp4")},
        data={"group_id": "1"},
    )
    assert resp.status_code == 401


def test_upload_file_rejects_unknown_group(client):
    resp = client.post(
        "/upload/file",
        files={"file": ("video.mp4", b"bytes", "video/mp4")},
        data={"group_id": "9999"},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 400


def test_upload_file_success(client, monkeypatch):
    import db

    queued = []
    monkeypatch.setattr("router.process_uploaded_video", lambda *a, **kw: queued.append((a, kw)), raising=False)
    group_id = db.get_group_by_name("children")["id"]

    resp = client.post(
        "/upload/file",
        files={"file": ("my video.mp4", b"fake-video-bytes", "video/mp4")},
        data={"group_id": str(group_id)},
        headers={"Authorization": "Bearer test-secret"},
    )

    assert resp.status_code == 202
    data = resp.json()
    assert data["status"] == "queued"
    assert queued == [((data["id"],), {})]

    video = db.get_video(data["id"])
    assert video["platform"] == "upload"
    assert video["title"] == "my video"
    assert video["group_id"] == group_id
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
    assert queued == [((data["id"],), {"classify": True})]

    import db

    video = db.get_video(data["id"])
    assert video["platform"] == "youtube"
    assert video["source_key"] == "dQw4w9WgXcQ"
    assert video["preview_url"] == "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"


def test_upload_with_a_group_does_not_ask_for_classification(client, monkeypatch):
    import db

    queued = []
    monkeypatch.setattr("router.download_video", lambda *a, **kw: queued.append((a, kw)))
    inbox = db.create_group(db.DEFAULT_UPLOAD_GROUP, "Inbox")
    resp = client.post(
        "/upload",
        json={"url": "https://youtu.be/dQw4w9WgXcQ", "group_id": inbox["id"]},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 202
    assert queued == [((resp.json()["id"],), {"classify": False})]


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
    assert queued == [((data["id"],), {"classify": True})]

    import db

    video = db.get_video(data["id"])
    assert video["url"] == "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    assert video["source_key"] == "dQw4w9WgXcQ"


def test_upload_youtube_bare_path_id(client, monkeypatch):
    queued = []
    monkeypatch.setattr("router.download_video", lambda *a, **kw: queued.append((a, kw)))
    resp = client.post(
        "/upload",
        json={"url": "https://www.youtube.com/WARwCp2porU"},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 202
    data = resp.json()
    assert queued == [((data["id"],), {"classify": True})]

    import db

    video = db.get_video(data["id"])
    assert video["url"] == "https://www.youtube.com/watch?v=WARwCp2porU"
    assert video["source_key"] == "WARwCp2porU"


@pytest.mark.parametrize(
    "url",
    [
        "https://example.com/video",
        "https://www.youtube.com/playlist?list=PL123",
        "https://www.youtube.com/@somechannel",
        "https://www.youtube.com/feed/history",
        "https://www.youtube.com/results?search_query=cats",
        "https://www.youtube.com/shortname",
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


def test_stream_multiplex_ranges_recombine_to_original(client):
    import db

    payload = bytes(range(23))
    fake_video = Path("videos") / "1.mp4"
    fake_video.parent.mkdir(exist_ok=True)
    fake_video.write_bytes(payload)
    ranges = [(0, 4), (5, 10), (11, 16), (17, 22)]

    try:
        vid_id = db.add_video("https://twitter.com/x/status/1")
        db.update_video(vid_id, status="done", filename="1.mp4")

        responses = [
            client.get(
                f"/videos/{vid_id}/stream",
                headers={**AUTH, "Range": f"bytes={start}-{end}"},
            )
            for start, end in ranges
        ]

        etags = {response.headers["etag"] for response in responses}
        assert len(etags) == 1
        assert not next(iter(etags)).startswith("W/")
        assert b"".join(response.content for response in responses) == payload

        for response, (start, end) in zip(responses, ranges):
            assert response.status_code == 206
            assert response.headers["accept-ranges"] == "bytes"
            assert response.headers["content-range"] == f"bytes {start}-{end}/23"
            assert response.headers["content-length"] == str(end - start + 1)
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


def test_stream_sends_resume_validators(client):
    import db
    from pathlib import Path

    fake_video = Path("videos") / "1.mp4"
    fake_video.parent.mkdir(exist_ok=True)
    fake_video.write_bytes(b"0123456789")
    try:
        vid_id = db.add_video("https://twitter.com/x/status/1")
        db.update_video(vid_id, status="done", filename="1.mp4")

        full = client.get(f"/videos/{vid_id}/stream", headers=AUTH)
        assert full.status_code == 200
        assert "etag" in full.headers
        assert "last-modified" in full.headers
        # Strong ETag: URLSession refuses to resume against weak validators.
        assert not full.headers["etag"].startswith("W/")

        partial = client.get(f"/videos/{vid_id}/stream", headers={**AUTH, "Range": "bytes=4-7"})
        assert partial.status_code == 206
        assert partial.headers["etag"] == full.headers["etag"]
        assert partial.headers["last-modified"] == full.headers["last-modified"]
    finally:
        fake_video.unlink(missing_ok=True)


def test_stream_if_range_matching_returns_partial(client):
    import db
    from pathlib import Path

    fake_video = Path("videos") / "1.mp4"
    fake_video.parent.mkdir(exist_ok=True)
    fake_video.write_bytes(b"0123456789")
    try:
        vid_id = db.add_video("https://twitter.com/x/status/1")
        db.update_video(vid_id, status="done", filename="1.mp4")

        etag = client.get(f"/videos/{vid_id}/stream", headers=AUTH).headers["etag"]
        resp = client.get(
            f"/videos/{vid_id}/stream",
            headers={**AUTH, "Range": "bytes=4-7", "If-Range": etag},
        )
        assert resp.status_code == 206
        assert resp.content == b"4567"
    finally:
        fake_video.unlink(missing_ok=True)


def test_stream_if_range_stale_returns_full_body(client):
    import db
    from pathlib import Path

    fake_video = Path("videos") / "1.mp4"
    fake_video.parent.mkdir(exist_ok=True)
    fake_video.write_bytes(b"0123456789")
    try:
        vid_id = db.add_video("https://twitter.com/x/status/1")
        db.update_video(vid_id, status="done", filename="1.mp4")

        resp = client.get(
            f"/videos/{vid_id}/stream",
            headers={**AUTH, "Range": "bytes=4-7", "If-Range": '"stale-validator"'},
        )
        assert resp.status_code == 200
        assert resp.content == b"0123456789"
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
    assert '<option value="1">Children</option>' in resp.text


def test_videos_page_loads_vendored_nprogress(client):
    resp = client.get("/videos")
    assert "/assets/vendor/nprogress.js" in resp.text
    assert "/assets/vendor/nprogress.css" in resp.text


def test_videos_page_exposes_upload_token_for_xhr(client):
    resp = client.get("/videos")
    assert 'window.UPLOAD_TOKEN = "test-secret";' in resp.text
    assert "/assets/app/videos.js" in resp.text


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


def test_move_endpoints_removed(client):
    import db

    video_id = db.add_video("https://twitter.com/x/status/1")
    pwa = client.post(
        f"/videos/{video_id}/move",
        data={"direction": "up"},
        follow_redirects=False,
    )
    api = client.post(
        f"/api/videos/{video_id}/move",
        json={"direction": "up"},
        headers={"Authorization": "Bearer test-secret"},
    )

    assert pwa.status_code == 404
    assert api.status_code == 404


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


def test_videos_page_declares_no_startup_images(client):
    """iOS picked these by media query and got it wrong: on an iPad Mini 6 in
    landscape it matched the *portrait* entry and stretched it. With no
    apple-touch-startup-image at all, iOS composes the splash itself from the
    manifest's icon and background_color, correctly at any size or orientation."""
    resp = client.get("/videos")
    assert resp.status_code == 200
    assert "apple-touch-startup-image" not in resp.text


def test_splash_dir_holds_only_the_manifest_icon(client):
    from pathlib import Path
    import router

    assert {p.name for p in Path("assets/splash").iterdir() if p.is_file()} == {
        router.SPLASH_ICON
    }


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
    resp = client.get("/assets/splash/icon.png")
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


def test_service_worker_served_at_root(client):
    resp = client.get("/sw.js")
    assert resp.status_code == 200
    assert resp.headers["content-type"].startswith("application/javascript")
    # Root scope requires this header, else the browser rejects registration.
    assert resp.headers["service-worker-allowed"] == "/"
    # Must not be cached long-term or SW updates never ship.
    assert "no-cache" in resp.headers["cache-control"].lower()
    assert "addEventListener" in resp.text  # it's the real SW file


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


def test_api_videos_filters_by_group(client):
    import db
    group_id = db.get_group_by_name("adults")["id"]
    a = db.add_video("https://twitter.com/x/status/1")
    b = db.add_video("https://twitter.com/x/status/2")
    db.set_video_group(a, group_id)
    resp = client.get("/api/videos", params={"group_id": group_id})
    assert resp.status_code == 200
    ids = {v["id"] for v in resp.json()}
    assert a in ids and b not in ids


def test_unknown_group_id_filter_returns_nothing(client):
    import db
    db.add_video("https://twitter.com/x/status/1")
    resp = client.get("/api/videos", params={"group_id": 9999})
    assert resp.status_code == 200
    assert resp.json() == []


def test_get_groups_lists_the_defaults(client):
    resp = client.get("/api/groups")
    assert resp.status_code == 200
    groups = resp.json()["groups"]
    assert [g["name"] for g in groups] == ["children", "adults", "anabel", "asmr"]
    assert set(groups[0]) == {
        "id", "name", "label", "emoji", "position", "display_titles", "remember_position",
        "description", "unread_count",
    }
    assert all(g["description"] is None for g in groups)
    assert all(g["display_titles"] is False for g in groups)


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


def test_create_group_rejects_a_duplicate_or_blank_name(client, auth_headers):
    assert client.post(
        "/api/groups", json={"name": "asmr", "label": "x"}, headers=auth_headers
    ).status_code == 400
    assert client.post(
        "/api/groups", json={"name": "  ", "label": "x"}, headers=auth_headers
    ).status_code == 400


def test_delete_group_moves_its_videos_to_the_inbox(client, auth_headers):
    import db
    inbox = db.create_group(db.DEFAULT_UPLOAD_GROUP, "Inbox")
    doomed = db.create_group("cooking", "Cooking")
    vid = db.add_video("https://twitter.com/x/status/1", group_id=doomed["id"])
    db.save_sd_state(doomed["id"], vid, [vid])

    assert client.delete(f"/api/groups/{doomed['id']}").status_code == 401
    resp = client.delete(f"/api/groups/{doomed['id']}", headers=auth_headers)
    assert resp.status_code == 200
    assert resp.json() == {"deleted": doomed["id"], "moved": 1}
    assert db.get_group(doomed["id"]) is None
    assert db.get_video(vid)["group_id"] == inbox["id"]
    assert db.get_sd_state()["group_id"] is None


def test_delete_group_refuses_the_inbox_and_unknown_ids(client, auth_headers):
    import db
    gid = client.get("/api/groups").json()["groups"][0]["id"]
    # No inbox to move into: refused, nothing deleted.
    assert client.delete(f"/api/groups/{gid}", headers=auth_headers).status_code == 409
    assert db.get_group(gid) is not None
    inbox = db.create_group(db.DEFAULT_UPLOAD_GROUP, "Inbox")
    assert client.delete(f"/api/groups/{inbox['id']}", headers=auth_headers).status_code == 409
    assert client.delete("/api/groups/9999", headers=auth_headers).status_code == 404


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


def test_patch_group_sets_and_clears_the_description(client, auth_headers):
    gid = client.get("/api/groups").json()["groups"][0]["id"]
    resp = client.patch(
        f"/api/groups/{gid}", json={"description": "  Sleep songs  "}, headers=auth_headers
    )
    assert resp.status_code == 200
    assert resp.json()["description"] == "Sleep songs"

    # Patching something else leaves it alone.
    other = client.patch(f"/api/groups/{gid}", json={"emoji": "🧒"}, headers=auth_headers)
    assert other.json()["description"] == "Sleep songs"

    # An explicit null (or blank) clears it.
    cleared = client.patch(f"/api/groups/{gid}", json={"description": None}, headers=auth_headers)
    assert cleared.json()["description"] is None


def test_patch_group_description_requires_a_token(client):
    gid = client.get("/api/groups").json()["groups"][0]["id"]
    resp = client.patch(f"/api/groups/{gid}", json={"description": "x"})
    assert resp.status_code in (401, 503)


def test_patch_group_toggles_display_titles(client, auth_headers):
    gid = client.get("/api/groups").json()["groups"][0]["id"]
    resp = client.patch(
        f"/api/groups/{gid}", json={"display_titles": True}, headers=auth_headers
    )
    assert resp.status_code == 200
    assert resp.json()["display_titles"] is True
    listed = client.get("/api/groups").json()["groups"]
    assert next(g for g in listed if g["id"] == gid)["display_titles"] is True

    off = client.patch(
        f"/api/groups/{gid}", json={"display_titles": False}, headers=auth_headers
    )
    assert off.json()["display_titles"] is False


def test_patch_group_toggles_remember_position(client, auth_headers):
    gid = client.get("/api/groups").json()["groups"][0]["id"]
    resp = client.patch(
        f"/api/groups/{gid}", json={"remember_position": True}, headers=auth_headers
    )
    assert resp.status_code == 200
    assert resp.json()["remember_position"] is True
    listed = client.get("/api/groups").json()["groups"]
    assert next(g for g in listed if g["id"] == gid)["remember_position"] is True
    off = client.patch(
        f"/api/groups/{gid}", json={"remember_position": False}, headers=auth_headers
    )
    assert off.json()["remember_position"] is False


def test_the_per_video_remember_position_endpoint_is_gone(client, auth_headers):
    resp = client.post(
        "/api/videos/1/remember-position", json={"on": True}, headers=auth_headers
    )
    assert resp.status_code in (404, 405)


def test_patch_group_display_titles_keeps_the_emoji(client, auth_headers):
    """The iOS toggle PATCHes this field alone — it must not clear the cover."""
    gid = client.get("/api/groups").json()["groups"][0]["id"]
    client.patch(f"/api/groups/{gid}", json={"emoji": "🧒"}, headers=auth_headers)
    resp = client.patch(
        f"/api/groups/{gid}", json={"display_titles": True}, headers=auth_headers
    )
    assert resp.json()["emoji"] == "🧒"


def test_patch_group_display_titles_requires_a_token(client):
    assert client.patch("/api/groups/1", json={"display_titles": True}).status_code == 401


def test_patch_unknown_group_is_404(client, auth_headers):
    assert client.patch(
        "/api/groups/9999", json={"label": "x"}, headers=auth_headers
    ).status_code == 404


def test_old_classification_and_cover_endpoints_are_gone(client):
    assert client.get("/api/classifications").status_code == 404
    assert client.get("/api/group-covers").status_code == 404


def test_set_group_endpoint(client, auth_headers):
    import db
    gid = db.get_group_by_name("adults")["id"]
    vid = db.add_video("https://example.com/v")
    resp = client.post(
        f"/api/videos/{vid}/group", json={"group_id": gid}, headers=auth_headers
    )
    assert resp.status_code == 200 and resp.json()["ok"] is True
    assert client.get(f"/api/videos?group_id={gid}").json()[0]["id"] == vid


def test_set_group_rejects_an_unknown_group(client, auth_headers):
    import db
    vid = db.add_video("https://example.com/v2")
    resp = client.post(
        f"/api/videos/{vid}/group", json={"group_id": 9999}, headers=auth_headers
    )
    assert resp.status_code == 400


def test_set_group_requires_token(client):
    import db
    vid = db.add_video("https://twitter.com/x/status/1")
    resp = client.post(f"/api/videos/{vid}/group", json={"group_id": 1})
    assert resp.status_code == 401


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





def test_get_single_video(client, tmp_path):
    vid, _ = _seed_done_download()
    assert client.get(f"/api/videos/{vid}").status_code == 401
    resp = client.get(f"/api/videos/{vid}", headers=AUTH)
    assert resp.status_code == 200
    assert resp.json()["id"] == vid
    assert client.get("/api/videos/99999", headers=AUTH).status_code == 404


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
        del client.cookies["upload_token"]
        assert client.get(f"/videos/{vid}/stream").status_code == 401
        assert client.get(f"/videos/{vid}/stream", headers=AUTH).status_code == 200
        assert client.get(f"/videos/{vid}/stream?token=test-secret").status_code == 200
        assert client.get(f"/videos/{vid}/stream?token=wrong").status_code == 401
    finally:
        f.unlink(missing_ok=True)


def test_stream_rejects_wrong_bearer_token(client, tmp_path):
    vid, f = make_done_download_video(tmp_path)
    try:
        # Clear the cookie to test that wrong bearer token is actually rejected
        del client.cookies["upload_token"]
        resp = client.get(f"/videos/{vid}/stream", headers={"Authorization": "Bearer wrong-token"})
        assert resp.status_code == 401
    finally:
        f.unlink(missing_ok=True)


def test_ssr_page_appends_stream_token(client, tmp_path):
    vid, f = make_done_download_video(tmp_path)
    try:
        html = client.get("/videos").text
        assert f"/videos/{vid}/stream" in html
        assert "?token=" not in html
    finally:
        f.unlink(missing_ok=True)


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


def test_upload_file_no_longer_rejects_plex_kinds(client, auth_headers, monkeypatch):
    import db

    # Without this the BackgroundTask polls converter.py forever: normalization
    # is a job now and no runner exists under the test client.
    monkeypatch.setattr("router.process_uploaded_video", lambda *a, **kw: None, raising=False)
    gid = db.get_group_by_name("children")["id"]
    resp = client.post(
        "/upload/file",
        files={"file": ("clip.mp4", b"\x00\x00", "video/mp4")},
        data={"group_id": str(gid)},
        headers=auth_headers,
    )
    assert resp.status_code == 202


def test_preview_grabs_frame_for_download_without_thumbnail(client, tmp_path, monkeypatch):
    """Twitter/upload rows carry no external thumb — serve a frame from the mp4."""
    import router
    previews = tmp_path / "previews"
    monkeypatch.setattr("router.PREVIEWS_DIR", previews)
    grabs = []

    def fake_grab(path, offset, max_edge):
        grabs.append((path, offset, max_edge))
        return b"FRAME"

    monkeypatch.setattr(router, "_grab_frame", fake_grab)
    vid, f = make_done_download_video(tmp_path)
    try:
        del client.cookies["upload_token"]
        assert client.get(f"/videos/{vid}/preview").status_code == 401

        resp = client.get(f"/videos/{vid}/preview", headers=AUTH)
        assert resp.status_code == 200
        assert resp.content == b"FRAME"
        assert resp.headers["content-type"] == "image/jpeg"
        # Frame taken a few seconds in — the first frame is routinely black.
        assert grabs == [(f, router.PREVIEW_FRAME_OFFSET, router.PREVIEW_MAX_EDGE)]

        client.get(f"/videos/{vid}/preview", headers=AUTH)  # disk cache
        assert len(grabs) == 1
    finally:
        f.unlink(missing_ok=True)


def test_preview_404s_when_download_file_is_missing(client, tmp_path, monkeypatch):
    import db
    monkeypatch.setattr("router.PREVIEWS_DIR", tmp_path / "previews")
    vid = db.add_video("https://x.com/a/status/9", platform="twitter")
    db.update_video(vid, "done", filename=f"{vid}.mp4")
    assert client.get(f"/videos/{vid}/preview", headers=AUTH).status_code == 404


def test_delete_removes_cached_download_preview(client, tmp_path, monkeypatch):
    import router
    previews = tmp_path / "previews"
    previews.mkdir()
    monkeypatch.setattr("router.PREVIEWS_DIR", previews)
    vid, f = make_done_download_video(tmp_path)
    poster = previews / f"dl{vid}.{router.PREVIEW_CACHE_SUFFIX}.jpg"
    poster.write_bytes(b"FRAME")
    try:
        assert client.post(f"/api/video/{vid}/delete", headers=AUTH).status_code == 200
        assert not poster.exists()
    finally:
        f.unlink(missing_ok=True)


def _make_done_video(client, monkeypatch, url="https://twitter.com/x/status/900"):
    """Insert a row directly; the API's own upload path schedules downloads."""
    import db
    return db.add_video(url, "twitter")


def test_position_requires_token(client):
    resp = client.post("/api/videos/1/position", json={"secs": 12.0})
    assert resp.status_code == 401


def test_position_saves_seconds(client, monkeypatch):
    import db
    video_id = _make_done_video(client, monkeypatch)
    resp = client.post(
        f"/api/videos/{video_id}/position",
        json={"secs": 91.5},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 204
    assert db.get_video(video_id)["resume_secs"] == 91.5


def test_position_clamps_negative(client, monkeypatch):
    import db
    video_id = _make_done_video(client, monkeypatch, "https://twitter.com/x/status/901")
    resp = client.post(
        f"/api/videos/{video_id}/position",
        json={"secs": -3},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 204
    assert db.get_video(video_id)["resume_secs"] == 0


def test_position_unknown_video_is_404(client):
    resp = client.post(
        "/api/videos/999999/position",
        json={"secs": 5},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 404


def test_position_requires_secs(client, monkeypatch):
    video_id = _make_done_video(client, monkeypatch, "https://twitter.com/x/status/902")
    resp = client.post(
        f"/api/videos/{video_id}/position",
        json={},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 422


@pytest.mark.parametrize("secs", [float("nan"), float("inf"), float("-inf")])
def test_position_rejects_non_finite_seconds(client, monkeypatch, secs):
    video_id = _make_done_video(
        client, monkeypatch, f"https://twitter.com/x/status/nonfinite-{repr(secs)}"
    )
    resp = client.post(
        f"/api/videos/{video_id}/position",
        json={"secs": secs},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 422


def test_video_list_includes_resume_secs(client, monkeypatch):
    import db
    video_id = _make_done_video(client, monkeypatch, "https://twitter.com/x/status/903")
    db.set_resume_secs(video_id, 42.0)
    resp = client.get("/api/videos", headers={"Authorization": "Bearer test-secret"})
    assert resp.status_code == 200
    row = next(v for v in resp.json() if v["id"] == video_id)
    assert row["resume_secs"] == 42.0


def test_jobs_requires_a_token(client):
    assert client.get("/api/jobs").status_code == 401


def test_jobs_is_empty_when_nothing_is_pending(client, auth_headers):
    body = client.get("/api/jobs", headers=auth_headers).json()
    assert body == {"running": [], "queued": [], "queued_total": 0}


def test_upload_accepts_youtube_music_watch_url(client, monkeypatch):
    monkeypatch.setattr("router.download_video", lambda *a, **kw: None)

    resp = client.post(
        "/upload",
        json={"url": "https://music.youtube.com/watch?v=dQw4w9WgXcQ&si=abc"},
        headers={"Authorization": "Bearer test-secret"},
    )

    assert resp.status_code == 202
    import db
    video = db.get_video(resp.json()["id"])
    assert video["platform"] == "youtube"
    assert video["source_key"] == "dQw4w9WgXcQ"
    assert video["url"] == "https://www.youtube.com/watch?v=dQw4w9WgXcQ"


@pytest.mark.parametrize(
    "url",
    [
        "https://www.youtube.com/playlist?list=PLVixkqSccxTvtXpNTlQPi7fSc3kzZ5EJa",
        "https://m.youtube.com/playlist?list=PLVixkqSccxTvtXpNTlQPi7fSc3kzZ5EJa",
        "https://music.youtube.com/playlist?list=PLVixkqSccxTvtXpNTlQPi7fSc3kzZ5EJa&si=eNDjY3nVNq-0D491",
    ],
)
def test_classify_url_recognizes_playlists(url):
    import router

    assert router._classify_url(url) == {
        "platform": "youtube_playlist",
        "source_key": "PLVixkqSccxTvtXpNTlQPi7fSc3kzZ5EJa",
        "normalized_url": "https://www.youtube.com/playlist?list=PLVixkqSccxTvtXpNTlQPi7fSc3kzZ5EJa",
    }


def test_classify_url_keeps_watch_with_list_a_single_video():
    import router

    assert router._classify_url(
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLVixkqSccxTvtXpNTlQPi7fSc3kzZ5EJa"
    ) == {
        "platform": "youtube",
        "source_key": "dQw4w9WgXcQ",
        "normalized_url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
    }


@pytest.mark.parametrize(
    "url",
    [
        "https://www.youtube.com/playlist",
        "https://www.youtube.com/playlist?list=",
        "https://www.youtube.com/playlist?list=a",
        "https://vimeo.com/playlist?list=PLVixkqSccxTvtXpNTlQPi7fSc3kzZ5EJa",
    ],
)
def test_classify_url_rejects_bad_playlist_urls(url):
    import router
    from fastapi import HTTPException

    with pytest.raises(HTTPException) as exc:
        router._classify_url(url)
    assert exc.value.status_code == 400


def test_upload_playlist_schedules_import_and_creates_no_video(client, monkeypatch):
    import db

    imported = []
    monkeypatch.setattr("router.import_playlist", lambda *a, **kw: imported.append((a, kw)))

    resp = client.post(
        "/upload",
        json={
            "url": "https://music.youtube.com/playlist?list=PLVixkqSccxTvtXpNTlQPi7fSc3kzZ5EJa&si=x"
        },
        headers={"Authorization": "Bearer test-secret"},
    )

    assert resp.status_code == 202
    assert resp.json() == {
        "status": "queued",
        "playlist": "PLVixkqSccxTvtXpNTlQPi7fSc3kzZ5EJa",
    }
    assert imported == [
        (("https://www.youtube.com/playlist?list=PLVixkqSccxTvtXpNTlQPi7fSc3kzZ5EJa",), {})
    ]
    assert db.get_all_videos() == []


def test_upload_playlist_ignores_explicit_group_id(client, monkeypatch):
    import db

    monkeypatch.setattr("router.import_playlist", lambda *a, **kw: None)
    group_id = db.get_group_by_name("adults")["id"]

    resp = client.post(
        "/upload",
        json={
            "url": "https://www.youtube.com/playlist?list=PLVixkqSccxTvtXpNTlQPi7fSc3kzZ5EJa",
            "group_id": group_id,
        },
        headers={"Authorization": "Bearer test-secret"},
    )

    assert resp.status_code == 202
    assert "id" not in resp.json()


def test_upload_playlist_requires_token(client):
    resp = client.post(
        "/upload",
        json={"url": "https://www.youtube.com/playlist?list=PLVixkqSccxTvtXpNTlQPi7fSc3kzZ5EJa"},
    )
    assert resp.status_code == 401


def test_check_auth_accepts_the_login_cookie(client):
    client.cookies.set("upload_token", "test-secret")
    resp = client.get("/check-auth")
    assert resp.status_code == 200


def test_check_auth_rejects_a_wrong_login_cookie(client):
    client.cookies.set("upload_token", "nope")
    resp = client.get("/check-auth")
    assert resp.status_code == 401


def test_check_auth_still_accepts_bearer_and_query_token(client):
    assert client.get("/check-auth", headers={"Authorization": "Bearer test-secret"}).status_code == 200
    assert client.get("/check-auth?token=test-secret").status_code == 200
    # Clear the cookie to test that auth fails without any credentials
    del client.cookies["upload_token"]
    assert client.get("/check-auth").status_code == 401


def test_login_page_is_reachable_without_credentials(client):
    # Clear the cookie to test that the login page is reachable without auth
    del client.cookies["upload_token"]
    resp = client.get("/login")
    assert resp.status_code == 200
    assert 'name="token"' in resp.text


def test_login_with_the_right_token_sets_the_cookie_and_redirects(client):
    resp = client.post(
        "/login",
        data={"token": "test-secret", "next": "/videos?group_id=2"},
        follow_redirects=False,
    )
    assert resp.status_code == 303
    assert resp.headers["location"] == "/videos?group_id=2"
    cookie = resp.headers["set-cookie"]
    assert "upload_token=test-secret" in cookie
    assert "HttpOnly" in cookie
    assert "samesite=strict" in cookie.lower()


def test_login_with_a_wrong_token_sets_nothing(client):
    resp = client.post("/login", data={"token": "nope", "next": "/"}, follow_redirects=False)
    assert resp.status_code == 401
    assert "Wrong token" in resp.text
    assert "set-cookie" not in resp.headers


def test_login_refuses_an_offsite_next(client):
    resp = client.post(
        "/login",
        data={"token": "test-secret", "next": "//evil.example.com/"},
        follow_redirects=False,
    )
    assert resp.status_code == 303
    assert resp.headers["location"] == "/"


def test_login_page_redirects_when_already_authenticated(client):
    client.cookies.set("upload_token", "test-secret")
    resp = client.get("/login?next=/videos", follow_redirects=False)
    assert resp.status_code == 303
    assert resp.headers["location"] == "/videos"


def test_logout_clears_the_cookie(client):
    client.cookies.set("upload_token", "test-secret")
    resp = client.get("/logout", follow_redirects=False)
    assert resp.status_code == 303
    assert resp.headers["location"] == "/login"
    assert "upload_token=" in resp.headers["set-cookie"]
    assert 'upload_token="";' in resp.headers["set-cookie"] or "upload_token=;" in resp.headers["set-cookie"]


def test_page_redirects_to_login_without_a_cookie(client):
    # Clear the cookie that the fixture sets, to test anonymous access
    del client.cookies["upload_token"]
    resp = client.get("/", follow_redirects=False)
    assert resp.status_code == 303
    assert resp.headers["location"] == "/login?next=%2F"


def test_page_redirect_preserves_the_query_string(client):
    # Clear the cookie that the fixture sets, to test anonymous access
    del client.cookies["upload_token"]
    resp = client.get("/videos?group_id=2", follow_redirects=False)
    assert resp.status_code == 303
    assert resp.headers["location"] == "/login?next=%2Fvideos%3Fgroup_id%3D2"


def test_page_redirect_strips_a_token_query_param(client):
    # Clear the cookie that the fixture sets, to test anonymous access
    del client.cookies["upload_token"]
    resp = client.get("/videos?token=test-secret&group_id=2", follow_redirects=False)
    assert resp.status_code == 303
    location = resp.headers["location"]
    assert location == "/login?next=%2Fvideos%3Fgroup_id%3D2"
    assert "test-secret" not in location
    assert "token=" not in location


def test_page_renders_with_a_valid_cookie(client):
    client.cookies.set("upload_token", "test-secret")
    resp = client.get("/")
    assert resp.status_code == 200
    assert "window.UPLOAD_TOKEN" in resp.text


def test_backfill_channels_requires_a_token(client):
    assert client.post("/api/videos/backfill-channels").status_code == 401


def test_backfill_channels_queues_the_walk(client, monkeypatch):
    import router
    started = []

    async def fake_backfill():
        started.append(True)
        return 0

    monkeypatch.setattr(router, "backfill_channels", fake_backfill)
    resp = client.post("/api/videos/backfill-channels", headers=AUTH)

    assert resp.status_code == 202
    assert resp.json() == {"status": "queued"}
    assert started == [True]


def _finished_video(client, group_id):
    import db
    video_id = db.add_video("https://x/v", platform="youtube", group_id=group_id)
    db.update_video(video_id, status="done", filename=f"{video_id}.mp4")
    db.mark_announced(video_id)
    return video_id


def test_groups_report_unread_count(client, auth_headers):
    import db
    group_id = db.list_groups()[0]["id"]
    _finished_video(client, group_id)

    groups = {g["id"]: g for g in client.get("/api/groups", headers=auth_headers).json()["groups"]}

    assert groups[group_id]["unread_count"] == 1
    assert all(g["unread_count"] == 0 for gid, g in groups.items() if gid != group_id)


def test_played_counts_every_play_and_reports_the_badge_change_once(client, auth_headers):
    import db
    group_id = db.list_groups()[0]["id"]
    video_id = _finished_video(client, group_id)

    first = client.post(f"/api/videos/{video_id}/played", headers=auth_headers)
    second = client.post(f"/api/videos/{video_id}/played", headers=auth_headers)
    client.post(f"/api/videos/{video_id}/played", headers=auth_headers)

    assert first.status_code == 200 and first.json() == {"changed": True}
    assert second.json() == {"changed": False}
    assert db.get_video(video_id)["play_count"] == 3
    groups = {g["id"]: g for g in client.get("/api/groups", headers=auth_headers).json()["groups"]}
    assert groups[group_id]["unread_count"] == 0


def test_played_requires_token(client):
    assert client.post("/api/videos/1/played").status_code == 401


def test_played_unknown_video_is_404(client, auth_headers):
    assert client.post("/api/videos/99999/played", headers=auth_headers).status_code == 404


def test_patching_a_group_still_reports_its_unread_count(client, auth_headers):
    import db
    group_id = db.list_groups()[0]["id"]
    _finished_video(client, group_id)

    resp = client.patch(f"/api/groups/{group_id}", json={"display_titles": True}, headers=auth_headers)

    assert resp.json()["unread_count"] == 1


# --- Send to Yoto ---------------------------------------------------------

@pytest.fixture()
def yoto_sent(monkeypatch, tmp_path):
    """Captures yosubee.send calls and points VIDEOS_DIR at tmp_path."""
    import router
    import yosubee

    calls = []

    async def fake_send(path, title, transport=None):
        calls.append((path, title))

    monkeypatch.setenv("YOSUBEE_LOCAL_URL", "http://localhost:3200/upload-from-video")
    monkeypatch.setattr(yosubee, "send", fake_send)
    monkeypatch.setattr(router, "VIDEOS_DIR", tmp_path)
    return calls


def _done_video(tmp_path, title="Song"):
    import db

    vid = db.add_video("https://youtube.com/watch?v=abc", title=title)
    db.update_video(vid, status="done", filename=f"{vid}.mp4")
    (tmp_path / f"{vid}.mp4").write_bytes(b"mp4")
    return vid


def test_send_to_yoto_posts_absolute_path_and_title(client, auth_headers, yoto_sent, tmp_path):
    vid = _done_video(tmp_path, title="Twinkle")
    resp = client.post(f"/api/videos/{vid}/yoto", headers=auth_headers)
    assert resp.status_code == 202
    assert resp.json() == {"status": "sent"}
    assert yoto_sent == [(str((tmp_path / f"{vid}.mp4").resolve()), "Twinkle")]


def test_send_to_yoto_requires_token(client, yoto_sent, tmp_path):
    vid = _done_video(tmp_path)
    assert client.post(f"/api/videos/{vid}/yoto").status_code == 401


def test_send_to_yoto_503_when_unconfigured(client, auth_headers, yoto_sent, tmp_path, monkeypatch):
    monkeypatch.delenv("YOSUBEE_LOCAL_URL")
    vid = _done_video(tmp_path)
    assert client.post(f"/api/videos/{vid}/yoto", headers=auth_headers).status_code == 503


def test_send_to_yoto_404_unknown(client, auth_headers, yoto_sent):
    assert client.post("/api/videos/999999/yoto", headers=auth_headers).status_code == 404


def test_send_to_yoto_409_while_downloading(client, auth_headers, yoto_sent):
    import db

    vid = db.add_video("https://youtube.com/watch?v=abc")
    assert client.post(f"/api/videos/{vid}/yoto", headers=auth_headers).status_code == 409
    assert yoto_sent == []


def test_send_to_yoto_409_when_file_missing(client, auth_headers, yoto_sent, tmp_path):
    vid = _done_video(tmp_path)
    (tmp_path / f"{vid}.mp4").unlink()
    assert client.post(f"/api/videos/{vid}/yoto", headers=auth_headers).status_code == 409


def test_send_to_yoto_502_when_yosubee_fails(client, auth_headers, yoto_sent, tmp_path, monkeypatch):
    import yosubee

    async def failing(path, title, transport=None):
        raise yosubee.YosubeeError("yosubee 422: No card named English")

    monkeypatch.setattr(yosubee, "send", failing)
    vid = _done_video(tmp_path)
    resp = client.post(f"/api/videos/{vid}/yoto", headers=auth_headers)
    assert resp.status_code == 502
    assert "No card named English" in resp.json()["detail"]


@pytest.mark.parametrize("method,path", [
    ("post", "/api/library/scan"),
    ("post", "/api/videos/1/version"),
    ("post", "/api/videos/1/audio"),
    ("post", "/api/videos/1/subtitle"),
    ("post", "/api/videos/1/prepare"),
    ("post", "/videos/1/version"),
])
def test_library_endpoints_are_gone(client, auth_headers, method, path):
    response = getattr(client, method)(path, headers=auth_headers, json={})
    assert response.status_code in (404, 405)


def test_group_named_tv_is_allowed_now(client, auth_headers):
    response = client.post("/api/groups", headers=auth_headers,
                           json={"name": "tv", "label": "TV"})
    assert response.status_code == 201


def test_hls_urls_are_gone(client):
    import db

    video_id, _ = _seed_done_download()
    resp = client.get(f"/videos/{video_id}/hls/master.m3u8", headers=AUTH)

    assert resp.status_code == 404
    assert db.claim_job() is None


def test_jobs_endpoint_always_reports_nothing(client, auth_headers):
    import db

    video_id, _ = _seed_done_download()
    db.enqueue_job("sd", video_id)
    body = client.get("/api/jobs", headers=auth_headers).json()
    assert body == {"running": [], "queued": [], "queued_total": 0}
