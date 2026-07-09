from db import CLASSIFICATIONS
from views.render import build_videos_page


def _video(**kw):
    base = {
        "id": 1,
        "url": "https://x.com/user/status/1234567890",
        "title": None,
        "status": "done",
        "platform": "twitter",
        "source": "download",
        "classification": "children",
        "error_msg": None,
        "preview_url": None,
    }
    base.update(kw)
    return base


def test_renders_done_card():
    html = build_videos_page([_video()], CLASSIFICATIONS, "children")

    assert 'class="card"' in html
    assert "/videos/1/stream" in html


def test_status_variants():
    videos = [
        _video(id=1, status="done"),
        _video(id=2, status="error", error_msg="boom"),
        _video(id=3, status="queued"),
    ]

    html = build_videos_page(videos, CLASSIFICATIONS, "children")

    assert "Error: boom" in html
    assert "Video is queued" in html


def test_named_title_used_for_youtube():
    html = build_videos_page(
        [_video(platform="youtube", title="My Clip")],
        CLASSIFICATIONS,
        "children",
    )

    assert "My Clip" in html


def test_empty_state():
    html = build_videos_page([], CLASSIFICATIONS, None)

    assert "No videos yet." in html


def test_no_delimiter_leaks():
    html = build_videos_page([_video()], CLASSIFICATIONS, "children")

    assert "{{" not in html
    assert "{%" not in html


def test_dialog_and_assets_present():
    html = build_videos_page([], CLASSIFICATIONS, None)

    assert 'id="upload-dialog"' in html
    assert "/assets/app/videos.css" in html
    assert "/assets/app/videos.js" in html
    assert "window.UPLOAD_TOKEN" in html


def test_app_asset_route_serves_css_and_js(tmp_path, monkeypatch):
    monkeypatch.setenv("DB_PATH", str(tmp_path / "t.db"))
    monkeypatch.setenv("UPLOAD_TOKEN", "secret")

    import importlib

    import db as db_module
    import main as main_module
    import router as router_module
    from fastapi.testclient import TestClient

    importlib.reload(db_module)
    importlib.reload(router_module)
    importlib.reload(main_module)

    with TestClient(main_module.app) as client:
        css = client.get("/assets/app/videos.css")
        js = client.get("/assets/app/videos.js")
        missing = client.get("/assets/app/nope.txt")

    assert css.status_code == 200
    assert css.headers["content-type"].startswith("text/css")
    assert js.status_code == 200
    assert "text/javascript" in js.headers["content-type"]
    assert missing.status_code == 404
