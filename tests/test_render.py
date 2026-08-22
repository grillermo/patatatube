from views.render import build_videos_page


GROUPS = [
    {"id": 1, "name": "children", "label": "Children", "emoji": None, "position": 0},
    {"id": 2, "name": "adults", "label": "Adults", "emoji": "🍷", "position": 1},
]


def _video(**kw):
    base = {
        "id": 1,
        "url": "https://x.com/user/status/1234567890",
        "title": None,
        "status": "done",
        "platform": "twitter",
        "source": "download",
        "group_id": 1,
        "error_msg": None,
        "preview_url": None,
    }
    base.update(kw)
    return base


def test_renders_done_card():
    html = build_videos_page([_video()], GROUPS, 1, None)

    assert 'class="card"' in html
    assert "/videos/1/stream" in html


def test_status_variants():
    videos = [
        _video(id=1, status="done"),
        _video(id=2, status="error", error_msg="boom"),
        _video(id=3, status="queued"),
    ]

    html = build_videos_page(videos, GROUPS, 1, None)

    assert "Error: boom" in html
    assert "Video is queued" in html


def test_named_title_used_for_youtube():
    html = build_videos_page(
        [_video(platform="youtube", title="My Clip")],
        GROUPS,
        1,
        None,
    )

    assert "My Clip" in html


def test_empty_state():
    html = build_videos_page([], GROUPS, None, None)

    assert "No videos yet." in html


def test_no_delimiter_leaks():
    html = build_videos_page([_video()], GROUPS, 1, None)

    assert "{{" not in html
    assert "{%" not in html


def test_dialog_and_assets_present():
    html = build_videos_page([], GROUPS, None, None)

    assert 'id="upload-dialog"' in html
    assert "/assets/app/videos.css" in html
    assert "/assets/app/videos.js" in html
    assert "window.UPLOAD_TOKEN" in html


def test_page_renders_group_labels_not_names():
    html = build_videos_page([_video()], GROUPS, 1, None)

    assert "Children" in html
    assert "?group_id=1" in html


def test_page_marks_the_current_group_active():
    html = build_videos_page([_video()], GROUPS, 2, None)

    assert 'class="nav-link active"' in html


def test_page_offers_plex_links():
    html = build_videos_page([], GROUPS, None, None)

    assert "?plex_kind=tv" in html
    assert "?plex_kind=movies" in html


def test_plex_feed_does_not_redirect_to_preferred_group():
    html = build_videos_page([], GROUPS, None, "tv")

    assert "window.location.replace" not in html


def test_card_menu_posts_to_the_group_endpoint():
    html = build_videos_page([_video()], GROUPS, 1, None)

    assert "/group" in html
    assert "/promote" in html


def test_plex_card_does_not_offer_group_or_promote_actions():
    html = build_videos_page([_video(group_id=None, plex_kind="tv")], GROUPS, None, "tv")

    assert "/group" not in html
    assert "/promote" not in html


def test_title_overlay_is_absent_when_the_group_has_it_off():
    html = build_videos_page([_video(platform="youtube", title="My Clip")], GROUPS, 1, None)

    assert "title-overlay" not in html


def test_title_overlay_renders_for_a_group_with_display_titles_on():
    groups = [dict(GROUPS[0], display_titles=1), GROUPS[1]]

    html = build_videos_page(
        [_video(platform="youtube", title="My Clip")], groups, 1, None
    )

    assert '<div class="title-overlay">My Clip</div>' in html


def test_title_overlay_is_absent_on_a_plex_feed():
    """Plex kinds are not groups, so no group's setting applies to them."""
    groups = [dict(GROUPS[0], display_titles=1), GROUPS[1]]

    html = build_videos_page(
        [_video(group_id=None, plex_kind="tv", title="Some Show")], groups, None, "tv"
    )

    assert "title-overlay" not in html


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


def test_done_card_offers_a_replay_forever_toggle():
    html = build_videos_page([_video()], GROUPS, 1, None)

    assert 'class="loop-btn" data-video-id="1"' in html
    assert 'aria-label="Replay forever"' in html


def test_unfinished_card_has_no_replay_forever_toggle():
    html = build_videos_page([_video(status="queued")], GROUPS, 1, None)

    assert "loop-btn" not in html


def test_app_assets_are_cache_busted_by_mtime():
    """Assets ship with max-age=3600, so an edit needs a changing URL."""
    import re as _re

    html = build_videos_page([], GROUPS, None, None)

    for asset in ("videos.css", "videos.js"):
        match = _re.search(rf"/assets/app/{asset}\?v=(\d+)", html)
        assert match, f"{asset} is not cache-busted"
        assert int(match.group(1)) > 0


def test_login_page_renders_the_form():
    from views.render import build_login_page

    html = build_login_page()

    assert '<form method="post" action="/login">' in html
    assert 'name="token"' in html
    assert 'value="/"' in html
    assert "Wrong token" not in html


def test_login_page_carries_the_next_target():
    from views.render import build_login_page

    html = build_login_page(next_url="/videos?group_id=2")

    assert 'name="next" value="/videos?group_id=2"' in html


def test_login_page_shows_an_error_when_asked():
    from views.render import build_login_page

    html = build_login_page(error=True)

    assert "Wrong token" in html


def test_login_page_never_contains_the_token():
    import os

    from views.render import build_login_page

    os.environ["UPLOAD_TOKEN"] = "super-secret-value"
    try:
        html = build_login_page()
    finally:
        os.environ.pop("UPLOAD_TOKEN", None)

    assert "super-secret-value" not in html
