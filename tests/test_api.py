# tests/test_api.py
import importlib
import itertools
import json
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
    assert queued == [((data["id"],), {})]


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


def test_upload_without_group_uses_first_group(client, monkeypatch):
    import db

    monkeypatch.setattr("router.download_video", lambda *a, **kw: None)
    first_group_id = db.list_groups()[0]["id"]

    resp = client.post(
        "/upload",
        json={"url": "https://twitter.com/x/status/125"},
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
    assert queued == [((data["id"],), {})]

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


def test_upload_reused_legacy_plex_youtube_video_returns_conflict(client, monkeypatch):
    queued = []
    monkeypatch.setattr("router.download_video", lambda *a, **kw: queued.append((a, kw)))

    import db

    existing_id = db.add_video(
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        platform="youtube",
        source_key="dQw4w9WgXcQ",
    )
    db.update_video(existing_id, status="done", filename="existing.mp4")
    db.set_video_plex_kind(existing_id, "movies")

    resp = client.post(
        "/upload",
        json={"url": "https://youtu.be/dQw4w9WgXcQ"},
        headers={"Authorization": "Bearer test-secret"},
    )

    assert resp.status_code == 409
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
    from views.render import SPLASH_STARTUP_IMAGES

    splash_files = {
        p.name
        for p in Path("assets/splash").iterdir()
        if p.is_file() and p.suffix.lower() in router.SPLASH_MIME_TYPES
    }
    startup_files = {image[0] for image in SPLASH_STARTUP_IMAGES}

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
        "id", "name", "label", "emoji", "position", "display_titles",
    }
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


def test_create_group_rejects_a_duplicate_or_plex_name(client, auth_headers):
    assert client.post(
        "/api/groups", json={"name": "asmr", "label": "x"}, headers=auth_headers
    ).status_code == 400
    assert client.post(
        "/api/groups", json={"name": "tv", "label": "x"}, headers=auth_headers
    ).status_code == 400
    assert client.post(
        "/api/groups", json={"name": "  ", "label": "x"}, headers=auth_headers
    ).status_code == 400


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


def test_promote_endpoint_rejects_an_unknown_kind(client, auth_headers):
    import db
    vid = db.add_video("https://example.com/v3")
    resp = client.post(
        f"/api/videos/{vid}/promote", json={"kind": "podcasts"}, headers=auth_headers
    )
    assert resp.status_code == 400


def test_promote_requires_token(client):
    import db
    vid = db.add_video("https://twitter.com/x/status/1")
    assert client.post(f"/api/videos/{vid}/promote", json={"kind": "tv"}).status_code == 401


def test_promote_endpoint_returns_409_on_promotion_error(client, auth_headers, monkeypatch):
    import db
    import promote

    def boom(video, kind):
        raise promote.PromotionError("volume not mounted")

    monkeypatch.setattr(promote, "promote_to_plex", boom)
    vid = db.add_video("https://example.com/v4")
    resp = client.post(f"/api/videos/{vid}/promote", json={"kind": "tv"}, headers=auth_headers)
    assert resp.status_code == 409
    assert "volume not mounted" in resp.json()["detail"]


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
    "title": "System", "plex_kind": "tv", "show_title": "The Bear",
    "season": 1, "episode": 1, "summary": "Carmy.",
    "plex_rating_key": "1264", "show_rating_key": "1262",
}


def make_library_row(tmp_path, name="ep.mkv"):
    import db
    src = tmp_path / name
    src.write_bytes(b"fake")
    vid, _ = db.upsert_library_video({**LIB_ITEM_API, "source_path": str(src)})
    return vid, src


_queued_library_ids = itertools.count()


def _queued_library_row(tmp_path):
    import db

    item_id = next(_queued_library_ids)
    src = tmp_path / f"queued-{item_id}.mkv"
    src.write_bytes(b"fake")
    vid, _ = db.upsert_library_video({
        **LIB_ITEM_API,
        "source_path": str(src),
        "plex_rating_key": f"queued-{item_id}",
    })
    return vid


def _library_row_needing_conversion(tmp_path, monkeypatch):
    import library

    monkeypatch.setattr(library, "probe_source", lambda p: {
        "streams": [{
            "codec_type": "video", "codec_name": "hevc", "width": 1920,
            "codec_tag_string": "[0][0][0][0]",
        }],
        "format": {"format_name": "matroska,webm"},
    })
    return _queued_library_row(tmp_path)


def _library_row_that_passes_through(tmp_path, monkeypatch):
    import library

    monkeypatch.setattr(library, "probe_source", lambda p: {
        "streams": [
            {
                "codec_type": "video", "codec_name": "h264", "width": 1920,
                "codec_tag_string": "avc1",
            },
            {"codec_type": "audio", "codec_name": "aac", "channels": 2},
        ],
        "format": {"format_name": "mov,mp4,m4a,3gp,3g2,mj2"},
    })
    return _queued_library_row(tmp_path)


def _ready_library_row(tmp_path):
    import db

    vid = _queued_library_row(tmp_path)
    db.set_library_state(vid, "done")
    return vid


def _seed_multi_audio_movie(tmp_path, converted_langs='["eng", "spa"]', status="done"):
    import db

    src = tmp_path / "m.mkv"
    src.write_bytes(b"x")
    vid, _ = db.upsert_library_video({
        "source_path": str(src), "title": "M", "plex_kind": "movies",
        "show_title": None, "season": None, "episode": None, "summary": None,
        "plex_rating_key": "m1", "show_rating_key": None,
    })
    version = db.get_video_versions(vid)[0]
    db.set_version_audio_langs(version["id"], json.dumps([
        {"lang": "cat", "title": ""}, {"lang": "eng", "title": ""},
        {"lang": "spa", "title": ""},
    ]))
    db.set_library_state(
        vid, status, converted_path=str(tmp_path / "m.mp4"),
        converted_langs=converted_langs, version_id=version["id"],
    )
    return vid, version["id"]


def test_choose_audio_requires_token(client, tmp_path):
    vid, _ = _seed_multi_audio_movie(tmp_path)

    resp = client.post(f"/api/videos/{vid}/audio", json={"lang": "spa"})

    assert resp.status_code in (401, 403)


def test_choose_audio_sets_lang(client, tmp_path):
    import db

    vid, _ = _seed_multi_audio_movie(tmp_path)
    resp = client.post(f"/api/videos/{vid}/audio", json={"lang": "spa"}, headers=AUTH)

    assert resp.status_code == 200
    assert resp.json() == {"ok": True}
    assert db.get_video(vid)["audio_lang"] == "spa"
    assert db.get_video(vid)["status"] == "done"


def test_choose_audio_rejects_unknown_lang(client, tmp_path):
    vid, _ = _seed_multi_audio_movie(tmp_path)

    assert client.post(
        f"/api/videos/{vid}/audio", json={"lang": "jpn"}, headers=AUTH
    ).status_code == 400
    assert client.post(
        f"/api/videos/{vid}/audio", json={"lang": "cat"}, headers=AUTH
    ).status_code == 400


def test_choose_audio_triggers_reconvert_when_missing(client, tmp_path, monkeypatch):
    import db
    import library

    vid, version_id = _seed_multi_audio_movie(tmp_path, converted_langs='["cat"]')
    spawned = []
    monkeypatch.setattr(library, "convert_library_video", spawned.append)

    resp = client.post(f"/api/videos/{vid}/audio", json={"lang": "spa"}, headers=AUTH)

    assert resp.status_code == 200
    assert db.get_video(vid)["status"] == "converting"
    assert spawned == []
    job = db.claim_job()
    assert job["kind"] == "convert"
    assert job["video_id"] == vid
    assert job["version_id"] == version_id


def test_choose_audio_legacy_null_converted_langs_reconverts(client, tmp_path, monkeypatch):
    import db
    import library

    vid, _ = _seed_multi_audio_movie(tmp_path, converted_langs=None)
    monkeypatch.setattr(library, "convert_library_video", lambda video_id: None)

    client.post(f"/api/videos/{vid}/audio", json={"lang": "spa"}, headers=AUTH)

    assert db.get_video(vid)["status"] == "converting"
    assert db.queued_job_count() == 1


def _seed_subtitle_movie(tmp_path, subtitle_langs=None):
    import db

    src = tmp_path / "m.mkv"
    src.write_bytes(b"x")
    vid, _ = db.upsert_library_video({
        "source_path": str(src), "title": "M", "plex_kind": "movies",
        "show_title": None, "season": None, "episode": None, "summary": None,
        "plex_rating_key": "sm1", "show_rating_key": None,
    })
    version = db.get_video_versions(vid)[0]
    if subtitle_langs is None:
        subtitle_langs = [
            {"language": "en", "name": "English", "default": True, "forced": False},
            {"language": "es", "name": "Spanish", "default": False, "forced": False},
        ]
    db.set_version_subtitle_langs(version["id"], json.dumps(subtitle_langs))
    db.set_library_state(vid, "done", converted_path=str(tmp_path / "m.mp4"), version_id=version["id"])
    return vid, version["id"]


def test_choose_subtitle_requires_token(client, tmp_path):
    vid, _ = _seed_subtitle_movie(tmp_path)

    resp = client.post(f"/api/videos/{vid}/subtitle", json={"lang": "es"})

    assert resp.status_code in (401, 403)


def test_choose_subtitle_sets_lang(client, tmp_path):
    import db

    vid, _ = _seed_subtitle_movie(tmp_path)
    resp = client.post(f"/api/videos/{vid}/subtitle", json={"lang": "es"}, headers=AUTH)

    assert resp.status_code == 200
    assert resp.json() == {"ok": True}
    assert db.get_video(vid)["subtitle_lang"] == "es"


def test_choose_subtitle_off_is_valid(client, tmp_path):
    import db

    vid, _ = _seed_subtitle_movie(tmp_path)
    resp = client.post(f"/api/videos/{vid}/subtitle", json={"lang": ""}, headers=AUTH)

    assert resp.status_code == 200
    assert db.get_video(vid)["subtitle_lang"] == ""


def test_choose_subtitle_rejects_unknown_lang(client, tmp_path):
    vid, _ = _seed_subtitle_movie(tmp_path)

    resp = client.post(f"/api/videos/{vid}/subtitle", json={"lang": "jp"}, headers=AUTH)

    assert resp.status_code == 400


def test_choose_subtitle_does_not_invalidate_hls(client, tmp_path, monkeypatch):
    import hls

    vid, _ = _seed_subtitle_movie(tmp_path)
    calls = []
    monkeypatch.setattr(hls, "invalidate", lambda video_id: calls.append(video_id))

    resp = client.post(f"/api/videos/{vid}/subtitle", json={"lang": "es"}, headers=AUTH)

    assert resp.status_code == 200
    assert calls == []


def test_get_video_exposes_subtitle_tracks_from_scan_cache(client, tmp_path):
    vid, _ = _seed_subtitle_movie(tmp_path)

    resp = client.get(f"/api/videos/{vid}", headers=AUTH)

    assert resp.status_code == 200
    body = resp.json()
    assert body["subtitle_tracks"] == [
        {"language": "en", "name": "English", "default": True, "forced": False},
        {"language": "es", "name": "Spanish", "default": False, "forced": False},
    ]


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
    assert resp.json() == {"added": 1, "updated": 0, "skipped": 0, "removed": 0}

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
            "plex_kind": "movies",
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
    assert data["audio_lang"] is None
    assert data["versions"] == [
        {
            "id": versions[0]["id"], "label": "1080p", "status": "unconverted",
            "is_chosen": False, "audio_tracks": [],
        },
        {
            "id": versions[1]["id"], "label": "4K", "status": "unconverted",
            "is_chosen": True, "audio_tracks": [],
        },
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
    import db
    assert converted == []
    assert db.queued_job_count() == 1
    assert db.get_video(vid)["status"] == "converting"


def test_prepare_enqueues_instead_of_spawning(client, tmp_path, monkeypatch):
    import db
    import library

    spawned = []
    monkeypatch.setattr(library, "convert_library_video", lambda vid: spawned.append(vid))
    video_id = _library_row_needing_conversion(tmp_path, monkeypatch)

    response = client.post(
        f"/api/videos/{video_id}/prepare", headers=AUTH, json={}
    )

    assert response.status_code == 202
    assert response.json()["status"] == "converting"
    assert spawned == []
    assert db.queued_job_count() == 1


def test_prepare_passthrough_creates_no_job(client, tmp_path, monkeypatch):
    import db

    video_id = _library_row_that_passes_through(tmp_path, monkeypatch)

    response = client.post(f"/api/videos/{video_id}/prepare", headers=AUTH, json={})

    assert response.json()["status"] == "done"
    assert db.queued_job_count() == 0


def test_bulk_prepare_is_queued_behind_interactive(client, tmp_path, monkeypatch):
    import db

    bulk_id = _library_row_needing_conversion(tmp_path, monkeypatch)
    interactive_id = _library_row_needing_conversion(tmp_path, monkeypatch)

    client.post(
        f"/api/videos/{bulk_id}/prepare", headers=AUTH, json={"priority": "bulk"}
    )
    client.post(f"/api/videos/{interactive_id}/prepare", headers=AUTH, json={})

    assert db.claim_job()["video_id"] == interactive_id
    assert db.claim_job()["video_id"] == bulk_id


def test_prepare_storm_spawns_no_ffmpeg(client, tmp_path, monkeypatch):
    """The incident, as a test: many prepares, zero ffmpeg from the web process."""
    import db
    import library

    spawned = []
    monkeypatch.setattr(library, "convert_library_video", lambda vid: spawned.append(vid))
    video_ids = [
        _library_row_needing_conversion(tmp_path, monkeypatch) for _ in range(25)
    ]

    for video_id in video_ids:
        client.post(
            f"/api/videos/{video_id}/prepare", headers=AUTH, json={"priority": "bulk"}
        )

    assert spawned == []
    assert db.queued_job_count() == 25


def test_repeated_prepare_for_one_video_queues_one_job(client, tmp_path, monkeypatch):
    import db

    video_id = _library_row_needing_conversion(tmp_path, monkeypatch)

    client.post(f"/api/videos/{video_id}/prepare", headers=AUTH, json={})
    client.post(f"/api/videos/{video_id}/prepare", headers=AUTH, json={})

    assert db.queued_job_count() == 1


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


def test_prepare_selects_allowlisted_source_audio_and_invalidates_hls(client, tmp_path, monkeypatch):
    import db
    import library

    vid, _ = make_library_row(tmp_path)
    version = db.get_video_versions(vid)[0]
    db.set_library_state(
        vid, "done", converted_path=str(tmp_path / "ep.mp4"),
        converted_langs='["eng", "spa"]', version_id=version["id"],
    )
    monkeypatch.setattr(library, "probe_source", lambda p: {
        "streams": [
            {"codec_type": "video", "codec_name": "h264", "width": 1920,
             "codec_tag_string": "avc1"},
            {"codec_type": "audio", "codec_name": "aac", "tags": {"language": "eng"}},
            {"codec_type": "audio", "codec_name": "aac", "tags": {"language": "spa"}},
        ],
        "format": {"format_name": "mov,mp4,m4a,3gp,3g2,mj2"},
    })
    invalidated = []
    monkeypatch.setattr("router.hls.invalidate", invalidated.append)

    resp = client.post(f"/api/videos/{vid}/prepare", json={"audio_lang": "spa"}, headers=AUTH)

    assert resp.status_code == 200
    assert resp.json() == {"status": "done"}
    assert db.get_video(vid)["audio_lang"] == "spa"
    assert invalidated == [vid]


def test_prepare_rejects_audio_outside_allowlist_or_source(client, tmp_path, monkeypatch):
    import library

    vid, _ = make_library_row(tmp_path)
    monkeypatch.setattr(library, "probe_source", lambda p: {
        "streams": [
            {"codec_type": "video", "codec_name": "h264", "width": 1920,
             "codec_tag_string": "avc1"},
            {"codec_type": "audio", "codec_name": "aac", "tags": {"language": "eng"}},
        ],
        "format": {"format_name": "mov,mp4,m4a,3gp,3g2,mj2"},
    })

    assert client.post(
        f"/api/videos/{vid}/prepare", json={"audio_lang": "jpn"}, headers=AUTH
    ).status_code == 400
    assert client.post(
        f"/api/videos/{vid}/prepare", json={"audio_lang": "spa"}, headers=AUTH
    ).status_code == 400


def test_prepare_reconverts_legacy_or_missing_selected_audio(client, tmp_path, monkeypatch):
    import db
    import library

    vid, _ = make_library_row(tmp_path)
    version = db.get_video_versions(vid)[0]
    db.set_library_state(vid, "done", converted_path=str(tmp_path / "ep.mp4"), version_id=version["id"])
    monkeypatch.setattr(library, "probe_source", lambda p: {
        "streams": [
            {"codec_type": "video", "codec_name": "hevc", "width": 1920,
             "codec_tag_string": "[0][0][0][0]"},
            {"codec_type": "audio", "codec_name": "aac", "tags": {"language": "eng"}},
            {"codec_type": "audio", "codec_name": "aac", "tags": {"language": "spa"}},
        ],
        "format": {"format_name": "matroska,webm"},
    })
    converted, invalidated = [], []
    monkeypatch.setattr("router.library.convert_library_video", converted.append)
    monkeypatch.setattr("router.hls.invalidate", invalidated.append)

    resp = client.post(f"/api/videos/{vid}/prepare", json={"audio_lang": "spa"}, headers=AUTH)

    assert resp.status_code == 202
    assert converted == []
    job = db.claim_job()
    assert job["kind"] == "convert"
    assert job["video_id"] == vid
    assert invalidated == [vid]
    assert db.get_video(vid)["audio_lang"] == "spa"


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
        # Clear the cookie to test that wrong bearer token is actually rejected
        del client.cookies["upload_token"]
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

    # Clear the cookie to test that access without auth is rejected
    del client.cookies["upload_token"]
    assert client.get(f"/videos/{vid}/preview").status_code == 401
    # Re-set the cookie for the authenticated requests
    client.cookies.set("upload_token", "test-secret")

    resp = client.get(f"/videos/{vid}/preview", headers=AUTH)
    assert resp.status_code == 200
    assert resp.content == b"jpegbytes"
    assert resp.headers["content-type"] == "image/jpeg"
    assert calls == ["1264"]

    resp = client.get(f"/videos/{vid}/preview", headers=AUTH)  # served from disk cache
    assert resp.status_code == 200 and calls == ["1264"]

    resp = client.get(f"/videos/{vid}/preview?kind=show", headers=AUTH)
    assert resp.status_code == 200 and calls == ["1264", "1262"]


async def _cache_miss(key):
    return None


async def _cache_noop(*args, **kwargs):
    return None


def test_preview_resizes_and_keys_cache_on_plex_version(client, tmp_path, monkeypatch):
    import db, plex, router
    # Disable the Redis response cache so we exercise the endpoint every request.
    monkeypatch.setattr("cache.get", _cache_miss)
    monkeypatch.setattr("cache.put", _cache_noop)
    src = tmp_path / "ep.mkv"
    src.write_bytes(b"fake")
    vid, _ = db.upsert_library_video({
        **LIB_ITEM_API, "source_path": str(src), "preview_version": "v1",
    })
    previews = tmp_path / "previews"
    monkeypatch.setattr("router.PREVIEWS_DIR", previews)
    monkeypatch.setattr(plex, "fetch_thumb", lambda rating_key: b"RAWTHUMB")
    resize_calls = []

    def fake_resize(content, max_edge):
        resize_calls.append((content, max_edge))
        return b"SMALL"

    monkeypatch.setattr(router, "_resize_jpeg", fake_resize)

    # The serializer publishes the version in the URL, so the client requests it.
    resp = client.get(f"/videos/{vid}/preview?v=v1", headers=AUTH)
    assert resp.status_code == 200
    assert resp.content == b"SMALL"                       # served the resized bytes
    assert resize_calls == [(b"RAWTHUMB", router.PREVIEW_MAX_EDGE)]
    # Cache filename carries the Plex thumb version.
    v1_file = previews / f"1264_v1.{router.PREVIEW_CACHE_SUFFIX}.jpg"
    assert v1_file.exists()

    # Same version → pure disk read, no refetch/resize.
    client.get(f"/videos/{vid}/preview?v=v1", headers=AUTH)
    assert len(resize_calls) == 1

    # Plex changes the art → new version → regenerate, and the stale file is purged.
    db.upsert_library_video({**LIB_ITEM_API, "source_path": str(src), "preview_version": "v2"})
    resp = client.get(f"/videos/{vid}/preview?v=v2", headers=AUTH)
    assert resp.status_code == 200 and len(resize_calls) == 2
    assert (previews / f"1264_v2.{router.PREVIEW_CACHE_SUFFIX}.jpg").exists()
    assert not v1_file.exists()


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
    # Clear the cookie to test that access without auth is rejected
    del client.cookies["upload_token"]
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


def test_cold_master_playlist_enqueues_an_hls_job(client, tmp_path, monkeypatch):
    import db
    import hls

    packaged = []
    monkeypatch.setattr(hls, "prepare", lambda vid, src: packaged.append(vid))
    video_id = _ready_library_row(tmp_path)

    response = client.get(f"/videos/{video_id}/hls/master.m3u8", headers=AUTH)

    assert response.status_code == 409
    assert packaged == []
    job = db.claim_job()
    assert job["kind"] == "hls"
    assert job["payload"]["source_path"]


def test_hls_master_prepares_then_serves_tree(client, monkeypatch, tmp_path):
    import db
    import hls

    monkeypatch.setattr(hls, "HLS_DIR", tmp_path / "hls")
    monkeypatch.setattr(hls, "build_hls_package", _fake_build)
    vid, p = _seed_done_download()
    try:
        # First hit: source ready but no package -> queues prep, 409.
        first = client.get(f"/videos/{vid}/hls/master.m3u8", headers=AUTH)
        assert first.status_code == 409

        job = db.claim_job()
        assert job["kind"] == "hls"
        hls.prepare(job["video_id"], job["payload"]["source_path"])

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


def test_promote_to_movies_moves_the_file(client, monkeypatch, tmp_path):
    import db
    import promote
    videos_dir = tmp_path / "videos"
    videos_dir.mkdir()
    movies_dir = tmp_path / "movies"
    movies_dir.mkdir()
    monkeypatch.setattr(promote, "VIDEOS_DIR", videos_dir)
    monkeypatch.setenv("LIBRARY_MOVIES_DIR", str(movies_dir))
    monkeypatch.setattr(promote, "_refresh_plex", lambda kind: None)
    video_id = db.add_video("https://youtu.be/abc", platform="youtube", title="Akira")
    (videos_dir / f"{video_id}.mp4").write_bytes(b"bytes")
    db.update_video(video_id, "done", filename=f"{video_id}.mp4")

    resp = client.post(
        f"/api/videos/{video_id}/promote",
        json={"kind": "movies"},
        headers={"Authorization": "Bearer test-secret"},
    )

    assert resp.status_code == 200
    assert resp.json() == {"ok": True, "promoted": True}
    assert (movies_dir / "Akira.mp4").exists()
    assert db.get_video(video_id) is None


def test_promote_returns_409_when_the_move_fails(client, monkeypatch, tmp_path):
    import db
    import promote
    videos_dir = tmp_path / "videos"
    videos_dir.mkdir()
    monkeypatch.setattr(promote, "VIDEOS_DIR", videos_dir)
    monkeypatch.setenv("LIBRARY_MOVIES_DIR", str(tmp_path / "not-mounted"))
    video_id = db.add_video("https://youtu.be/abc", platform="youtube", title="Akira")
    (videos_dir / f"{video_id}.mp4").write_bytes(b"bytes")
    db.update_video(video_id, "done", filename=f"{video_id}.mp4")
    resp = client.post(
        f"/api/videos/{video_id}/promote",
        json={"kind": "movies"},
        headers={"Authorization": "Bearer test-secret"},
    )

    assert resp.status_code == 409
    assert (videos_dir / f"{video_id}.mp4").exists()


def test_ssr_promote_returns_409_when_the_move_fails(client, monkeypatch, tmp_path):
    import db
    import promote
    videos_dir = tmp_path / "videos"
    videos_dir.mkdir()
    monkeypatch.setattr(promote, "VIDEOS_DIR", videos_dir)
    monkeypatch.setenv("LIBRARY_MOVIES_DIR", str(tmp_path / "not-mounted"))
    video_id = db.add_video("https://youtu.be/abc", platform="youtube", title="Akira")
    (videos_dir / f"{video_id}.mp4").write_bytes(b"bytes")
    db.update_video(video_id, "done", filename=f"{video_id}.mp4")

    resp = client.post(
        f"/videos/{video_id}/promote",
        data={"kind": "movies"},
        follow_redirects=False,
    )

    assert resp.status_code == 409
    assert db.get_video(video_id) is not None


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
    monkeypatch.setattr("cache.get", _cache_miss)
    monkeypatch.setattr("cache.put", _cache_noop)
    previews = tmp_path / "previews"
    monkeypatch.setattr("router.PREVIEWS_DIR", previews)
    grabs = []

    def fake_grab(path, offset, max_edge):
        grabs.append((path, offset, max_edge))
        return b"FRAME"

    monkeypatch.setattr(router, "_grab_frame", fake_grab)
    vid, f = make_done_download_video(tmp_path)
    try:
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
    monkeypatch.setattr("cache.get", _cache_miss)
    monkeypatch.setattr("cache.put", _cache_noop)
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


def test_jobs_returns_running_and_queued(client, auth_headers):
    import db
    running_id = db.enqueue_job("convert", video_id=1, version_id=1)
    db.claim_job()
    db.set_job_progress(running_id, 0.6)
    db.enqueue_job("convert", video_id=2, version_id=2)

    body = client.get("/api/jobs", headers=auth_headers).json()
    assert [job["id"] for job in body["running"]] == [running_id]
    assert body["running"][0]["progress"] == 0.6
    assert body["running"][0]["kind"] == "convert"
    assert [job["video_id"] for job in body["queued"]] == [2]
    assert body["queued"][0]["progress"] is None
    assert body["queued_total"] == 1


def test_jobs_caps_the_queued_list_at_twenty(client, auth_headers):
    import db
    for video_id in range(1, 26):
        db.enqueue_job("convert", video_id=video_id, version_id=video_id)
    body = client.get("/api/jobs", headers=auth_headers).json()
    assert len(body["queued"]) == 20
    assert body["queued_total"] == 25


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
    assert "samesite=lax" in cookie.lower()


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


def test_cached_pages_are_scoped_to_the_login_cookie(client):
    import middleware

    # The key derivation is what matters, and it is not otherwise observable,
    # so assert on it directly through a request-shaped stub.
    class _Req:
        def __init__(self, cookies, headers=None):
            self.method = "GET"
            self.cookies = cookies
            self.headers = headers or {}

            class _URL:
                path = "/"
                query = ""

            self.url = _URL()

    anon = middleware.cache_key_for(_Req({}))
    authed = middleware.cache_key_for(_Req({"upload_token": "test-secret"}))
    other = middleware.cache_key_for(_Req({"upload_token": "different"}))

    assert anon != authed
    assert authed != other
    assert "test-secret" not in authed


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


def test_page_renders_with_a_valid_cookie(client):
    client.cookies.set("upload_token", "test-secret")
    resp = client.get("/")
    assert resp.status_code == 200
    assert "window.UPLOAD_TOKEN" in resp.text
