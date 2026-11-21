from views.serializers import serialize_video


def test_serialize_video_full_shape():
    video = {
        "id": 7,
        "url": "https://youtu.be/dQw4w9WgXcQ",
        "title": "A Song",
        "platform": "youtube",
        "source_key": "dQw4w9WgXcQ",
        "preview_url": "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
        "group_id": 3,
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
        "group_id": 3,
        "position": 3,
        "resume_secs": 0,
        "status": "done",
        "unwatched": False,
        "error_msg": None,
        "stream_path": "/videos/7/stream",
        "channel": None,
    }


def test_serialized_video_never_has_hls_path():
    for status in ("done", "queued", "downloading"):
        data = serialize_video({"id": 4, "url": "https://x.com/s/1", "status": status})
        assert "hls_path" not in data


def test_serialize_video_emits_group_id():
    data = serialize_video({"id": 1, "url": "u", "status": "done", "group_id": 3})
    assert data["group_id"] == 3
    assert "classification" not in data


def test_serialize_video_leaves_an_unsorted_video_null():
    data = serialize_video({"id": 1, "url": "u", "status": "done"})
    assert data["group_id"] is None


def test_serialize_video_omits_internal_fields():
    video = {
        "id": 1,
        "url": "https://twitter.com/x/status/1",
        "status": "queued",
        "filename": None,
    }
    result = serialize_video(video)
    assert result["group_id"] is None
    assert result["title"] is None
    assert result["stream_path"] == "/videos/1/stream"
    assert "filename" not in result


def test_serialize_download_video_keeps_url_unchanged():
    row = {
        "id": 2,
        "url": "https://twitter.com/x/status/123",
        "status": "done",
    }
    data = serialize_video(row)
    assert data["url"] == "https://twitter.com/x/status/123"


def test_serialize_upload_video_redacts_tmp_path_from_url():
    row = {
        "id": 12,
        "url": "/tmp/tmpabc123.mp4",
        "title": "My Upload",
        "platform": "upload",
        "status": "queued",
        "group_id": 1,
    }
    data = serialize_video(row)
    assert data["url"] == ""
    assert data["title"] == "My Upload"
    assert data["platform"] == "upload"


def test_serialize_download_without_thumbnail_uses_generated_preview():
    """Twitter/upload rows have no external thumbnail — point at our own
    frame-grab endpoint instead of leaving the client with a black poster."""
    row = {
        "id": 28,
        "url": "https://x.com/Rasmic/status/2069967490575192401",
        "platform": "twitter",
        "status": "done",
        "preview_url": None,
    }
    assert serialize_video(row)["preview_url"] == "/videos/28/preview"


def test_serialize_download_keeps_external_thumbnail():
    row = {
        "id": 9,
        "url": "https://youtu.be/dQw4w9WgXcQ",
        "platform": "youtube",
        "status": "done",
        "preview_url": "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
    }
    assert serialize_video(row)["preview_url"] == (
        "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"
    )


def test_serialize_download_not_done_has_no_preview():
    """Nothing to grab a frame from until the file exists."""
    row = {"id": 30, "url": "https://x.com/a/status/1", "status": "queued"}
    assert serialize_video(row)["preview_url"] is None


def test_serialize_video_exposes_resume_secs():
    from views.serializers import serialize_video

    data = serialize_video({
        "id": 7,
        "url": "https://x.com/i/status/7",
        "status": "done",
        "resume_secs": 61.25,
    })
    assert data["resume_secs"] == 61.25


def test_serialize_video_resume_secs_defaults_to_zero():
    from views.serializers import serialize_video

    data = serialize_video({"id": 8, "url": "u", "status": "done"})
    assert data["resume_secs"] == 0


def test_serialize_exposes_the_channel():
    data = serialize_video({
        "id": 7, "url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ", "status": "done",
        "platform": "youtube", "channel": "Veritasium",
    })
    assert data["channel"] == "Veritasium"


def test_serialize_channel_is_null_when_unknown():
    data = serialize_video({
        "id": 7, "url": "https://twitter.com/user/status/1", "status": "done",
        "platform": "twitter",
    })
    assert data["channel"] is None


def test_serialize_video_marks_only_announced_never_played_videos_unwatched():
    base = {"id": 1, "url": "u", "status": "done"}
    assert serialize_video({**base, "play_count": 0})["unwatched"] is True
    assert serialize_video({**base, "play_count": 2})["unwatched"] is False
    # NULL is "not announced yet", not "never played".
    assert serialize_video({**base, "play_count": None})["unwatched"] is False
    assert serialize_video({**base, "status": "downloading", "play_count": 0})["unwatched"] is False


def test_serialized_video_has_no_library_fields():
    data = serialize_video({"id": 1, "url": "https://x/y", "status": "done", "play_count": 0})
    for key in ("plex_kind", "source", "show_title", "season", "episode", "summary",
                "show_preview_url", "subtitle_tracks", "versions", "chosen_version_id",
                "audio_lang", "subtitle_lang", "source_filename"):
        assert key not in data
    assert data["unwatched"] is True
    assert "hls_path" not in data
