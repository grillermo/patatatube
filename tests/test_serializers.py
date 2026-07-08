from views.serializers import serialize_video


def test_serialize_video_full_shape():
    video = {
        "id": 7,
        "url": "https://youtu.be/dQw4w9WgXcQ",
        "title": "A Song",
        "platform": "youtube",
        "source_key": "dQw4w9WgXcQ",
        "preview_url": "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
        "classification": "children",
        "position": 3,
        "status": "done",
        "error_msg": None,
        "filename": "7.mp4",
        "created_at": "2026-07-02T00:00:00+00:00",
    }
    assert serialize_video(video) == {
        "id": 7,
        "url": "https://youtu.be/dQw4w9WgXcQ",
        "title": "A Song",
        "platform": "youtube",
        "source_key": "dQw4w9WgXcQ",
        "preview_url": "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
        "classification": "children",
        "position": 3,
        "status": "done",
        "error_msg": None,
        "stream_path": "/videos/7/stream",
        "source": "download",
        "show_title": None,
        "season": None,
        "episode": None,
        "summary": None,
        "show_preview_url": None,
        "subtitle_tracks": [],
        "hls_path": "/videos/7/hls/master.m3u8",
    }


def test_done_download_row_exposes_hls_path():
    row = {"id": 4, "url": "https://x.com/s/1", "status": "done"}
    data = serialize_video(row)
    assert data["hls_path"] == "/videos/4/hls/master.m3u8"
    assert data["subtitle_tracks"] == []


def test_unready_row_omits_hls_path():
    row = {"id": 5, "url": "https://x.com/s/1", "status": "queued"}
    data = serialize_video(row)
    assert "hls_path" not in data


def test_injected_subtitle_tracks_are_passed_through():
    row = {
        "id": 8, "url": "/vol/tv/ep.mkv", "status": "done", "source": "library",
        "converted_path": "/vol/tv/ep.mp4",
        "subtitle_tracks": [{"language": "en", "name": "English", "default": True, "forced": False}],
    }
    data = serialize_video(row)
    assert data["subtitle_tracks"][0]["language"] == "en"
    assert data["hls_path"] == "/videos/8/hls/master.m3u8"


def test_serialize_video_defaults_classification_and_omits_internal_fields():
    video = {
        "id": 1,
        "url": "https://twitter.com/x/status/1",
        "status": "queued",
        "filename": None,
    }
    result = serialize_video(video)
    assert result["classification"] == "children"
    assert result["title"] is None
    assert result["stream_path"] == "/videos/1/stream"
    assert "filename" not in result


def test_serialize_library_episode():
    row = {
        "id": 7, "url": "/vol/tv/ep.mkv", "title": "System", "platform": None,
        "source_key": None, "preview_url": None, "classification": "tv",
        "position": 3, "status": "unconverted", "error_msg": None,
        "source": "library", "show_title": "The Bear", "season": 1, "episode": 1,
        "summary": "Carmy.", "plex_rating_key": "1264", "show_rating_key": "1262",
    }
    data = serialize_video(row)
    assert data["source"] == "library"
    assert data["show_title"] == "The Bear"
    assert data["season"] == 1 and data["episode"] == 1
    assert data["summary"] == "Carmy."
    assert data["preview_url"] == "/videos/7/preview"
    assert data["show_preview_url"] == "/videos/7/preview?kind=show"
    assert data["stream_path"] == "/videos/7/stream"
    assert data["url"] == ""


def test_serialize_download_row_defaults():
    row = {"id": 1, "url": "https://x.com/s/1", "status": "done"}
    data = serialize_video(row)
    assert data["source"] == "download"
    assert data["show_title"] is None and data["show_preview_url"] is None


def test_serialize_library_video_redacts_source_path_from_url():
    """`url` holds the raw filesystem source_path for library rows (db.upsert_library_video).

    It must never reach API consumers verbatim: redact it. We use "" rather
    than None because the iOS client's Video.url is a non-optional String —
    a null would break decoding of the whole /api/videos response.
    """
    row = {
        "id": 9,
        "url": "/Volumes/Media/media/tv/The.Bear.S01/The.Bear.S01E01.mkv",
        "title": "System",
        "status": "unconverted",
        "source": "library",
    }
    data = serialize_video(row)
    assert data["url"] == ""
    assert data["url"] is not None


def test_serialize_download_video_keeps_url_unchanged():
    row = {
        "id": 2,
        "url": "https://twitter.com/x/status/123",
        "status": "done",
    }
    data = serialize_video(row)
    assert data["url"] == "https://twitter.com/x/status/123"
