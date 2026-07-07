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
    }


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


def test_serialize_download_row_defaults():
    row = {"id": 1, "url": "https://x.com/s/1", "status": "done"}
    data = serialize_video(row)
    assert data["source"] == "download"
    assert data["show_title"] is None and data["show_preview_url"] is None
