import httpx
import pytest

import plex


SECTIONS = {"MediaContainer": {"Directory": [
    {"key": "1", "type": "movie", "title": "Movies"},
    {"key": "2", "type": "show", "title": "TV Shows"},
]}}

MOVIES = {"MediaContainer": {"Metadata": [
    {
        "ratingKey": "42",
        "title": "Akira",
        "summary": "Neo-Tokyo.",
        "Media": [{"Part": [{"file": "/Volumes/Media/media/movies/Akira/Akira.mkv"}]}],
    },
]}}

SHOWS = {"MediaContainer": {"Metadata": [{"ratingKey": "1262", "title": "The Bear"}]}}

EPISODES = {"MediaContainer": {"Metadata": [
    {
        "ratingKey": "1264",
        "grandparentRatingKey": "1262",
        "grandparentTitle": "The Bear",
        "title": "System",
        "parentIndex": 1,
        "index": 1,
        "summary": "Carmy retrains the crew.",
        "Media": [{"Part": [{"file": "/Volumes/Media/media/tv/The.Bear/S01E01.mkv"}]}],
    },
]}}


def fake_get_json(path, params=None):
    if path == "/library/sections":
        return SECTIONS
    if path == "/library/sections/1/all":
        return MOVIES
    if path == "/library/sections/2/all":
        return SHOWS
    if path == "/library/metadata/1262/allLeaves":
        return EPISODES
    raise AssertionError(f"unexpected path {path}")


def test_fetch_library_items(monkeypatch):
    monkeypatch.setattr(plex, "_get_json", fake_get_json)
    items = plex.fetch_library_items()
    assert len(items) == 2

    movie = next(i for i in items if i["classification"] == "movies")
    assert movie == {
        "source_path": "/Volumes/Media/media/movies/Akira/Akira.mkv",
        "title": "Akira",
        "classification": "movies",
        "show_title": None,
        "season": None,
        "episode": None,
        "summary": "Neo-Tokyo.",
        "plex_rating_key": "42",
        "show_rating_key": None,
    }

    ep = next(i for i in items if i["classification"] == "tv")
    assert ep == {
        "source_path": "/Volumes/Media/media/tv/The.Bear/S01E01.mkv",
        "title": "System",
        "classification": "tv",
        "show_title": "The Bear",
        "season": 1,
        "episode": 1,
        "summary": "Carmy retrains the crew.",
        "plex_rating_key": "1264",
        "show_rating_key": "1262",
    }


def test_item_without_file_is_skipped(monkeypatch):
    broken = {"MediaContainer": {"Metadata": [{"ratingKey": "9", "title": "NoFile", "Media": []}]}}

    def fake(path, params=None):
        if path == "/library/sections":
            return SECTIONS
        if path == "/library/sections/1/all":
            return broken
        if path == "/library/sections/2/all":
            return {"MediaContainer": {"Metadata": []}}
        raise AssertionError(path)

    monkeypatch.setattr(plex, "_get_json", fake)
    assert plex.fetch_library_items() == []


def test_parse_json_tolerates_control_chars():
    # Plex responses contain raw control characters; strict parsing must be off.
    raw = '{"MediaContainer": {"summary": "line1\x01line2"}}'
    assert plex._parse_json(raw)["MediaContainer"]["summary"] == "line1\x01line2"


def test_get_json_wraps_connect_error(monkeypatch):
    """_get_json wraps httpx.ConnectError as plex.PlexError"""
    monkeypatch.setenv("PLEX_TOKEN", "test-token")

    def fake_get(*args, **kwargs):
        raise httpx.ConnectError("Connection refused")

    monkeypatch.setattr(httpx, "get", fake_get)

    with pytest.raises(plex.PlexError) as exc_info:
        plex._get_json("/test/path")
    assert "Plex request failed" in str(exc_info.value)


def test_get_json_wraps_http_status_error(monkeypatch):
    """_get_json wraps httpx.HTTPStatusError (non-2xx) as plex.PlexError"""
    monkeypatch.setenv("PLEX_TOKEN", "test-token")

    def fake_get(*args, **kwargs):
        request = httpx.Request("GET", "http://localhost:32400/test/path")
        resp = httpx.Response(401, request=request)
        return resp

    monkeypatch.setattr(httpx, "get", fake_get)

    with pytest.raises(plex.PlexError) as exc_info:
        plex._get_json("/test/path")
    assert "Plex request failed" in str(exc_info.value)


def test_get_json_missing_token(monkeypatch):
    """_get_json raises PlexError when PLEX_TOKEN is unset"""
    monkeypatch.delenv("PLEX_TOKEN", raising=False)

    with pytest.raises(plex.PlexError) as exc_info:
        plex._get_json("/test/path")
    assert "PLEX_TOKEN is not configured" in str(exc_info.value)


def test_get_json_successful_response(monkeypatch):
    """_get_json parses and returns JSON on successful response"""
    monkeypatch.setenv("PLEX_TOKEN", "test-token")

    def fake_get(*args, **kwargs):
        request = httpx.Request("GET", "http://localhost:32400/test/path")
        return httpx.Response(200, text='{"test": "data"}', request=request)

    monkeypatch.setattr(httpx, "get", fake_get)

    result = plex._get_json("/test/path")
    assert result == {"test": "data"}


def test_fetch_thumb_returns_bytes(monkeypatch):
    """fetch_thumb returns raw bytes on successful response"""
    monkeypatch.setenv("PLEX_TOKEN", "test-token")

    thumb_bytes = b"\x89PNG\r\n\x1a\n"

    def fake_get(*args, **kwargs):
        request = httpx.Request("GET", "http://localhost:32400/library/metadata/123/thumb")
        return httpx.Response(200, content=thumb_bytes, request=request)

    monkeypatch.setattr(httpx, "get", fake_get)

    result = plex.fetch_thumb("123")
    assert result == thumb_bytes
    assert isinstance(result, bytes)


def test_fetch_thumb_wraps_timeout_error(monkeypatch):
    """fetch_thumb wraps httpx.TimeoutException as plex.PlexError"""
    monkeypatch.setenv("PLEX_TOKEN", "test-token")

    def fake_get(*args, **kwargs):
        raise httpx.TimeoutException("Request timed out")

    monkeypatch.setattr(httpx, "get", fake_get)

    with pytest.raises(plex.PlexError) as exc_info:
        plex.fetch_thumb("123")
    assert "Plex thumb fetch failed" in str(exc_info.value)


def test_fetch_thumb_missing_token(monkeypatch):
    """fetch_thumb raises PlexError when PLEX_TOKEN is unset"""
    monkeypatch.delenv("PLEX_TOKEN", raising=False)

    with pytest.raises(plex.PlexError) as exc_info:
        plex.fetch_thumb("123")
    assert "PLEX_TOKEN is not configured" in str(exc_info.value)
