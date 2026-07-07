from pathlib import Path

import pytest

import library


def probe(container="matroska,webm", vcodec="hevc", width=1920, tag="[0][0][0][0]",
          acodec="eac3", with_audio=True):
    streams = [{
        "codec_type": "video",
        "codec_name": vcodec,
        "width": width,
        "codec_tag_string": tag,
    }]
    if with_audio:
        streams.append({"codec_type": "audio", "codec_name": acodec, "channels": 6})
    return {"streams": streams, "format": {"format_name": container}}


def test_passthrough_compatible_mp4():
    p = probe(container="mov,mp4,m4a,3gp,3g2,mj2", vcodec="h264", acodec="aac")
    plan = library.plan_conversion(p)
    assert plan.passthrough


def test_passthrough_hevc_requires_hvc1_tag():
    good = probe(container="mov,mp4,m4a,3gp,3g2,mj2", vcodec="hevc", tag="hvc1")
    assert library.plan_conversion(good).passthrough
    bad = probe(container="mov,mp4,m4a,3gp,3g2,mj2", vcodec="hevc", tag="hev1")
    assert not library.plan_conversion(bad).passthrough


def test_no_passthrough_above_ipad_width():
    p = probe(container="mov,mp4,m4a,3gp,3g2,mj2", vcodec="h264", acodec="aac", width=3840)
    assert not library.plan_conversion(p).passthrough


def test_mkv_hevc_remuxes_with_hvc1():
    plan = library.plan_conversion(probe())
    assert not plan.passthrough
    assert plan.video_args == ["-c:v", "copy", "-tag:v", "hvc1"]
    assert plan.audio_args == ["-c:a", "copy"]


def test_mkv_h264_remuxes_with_avc1():
    plan = library.plan_conversion(probe(vcodec="h264"))
    assert plan.video_args == ["-c:v", "copy", "-tag:v", "avc1"]


def test_4k_downscales_and_reencodes():
    plan = library.plan_conversion(probe(width=3840))
    assert plan.video_args == [
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
        "-pix_fmt", "yuv420p", "-profile:v", "high", "-tag:v", "avc1",
        "-vf", "scale='min(2266,iw)':-2",
    ]


def test_unsupported_codecs_reencode():
    plan = library.plan_conversion(probe(vcodec="vp9", acodec="dts"))
    assert plan.video_args[0:2] == ["-c:v", "libx264"]
    assert plan.audio_args == ["-c:a", "aac", "-b:a", "128k", "-ac", "2"]


def test_no_audio_stream():
    plan = library.plan_conversion(probe(with_audio=False))
    assert plan.audio_args == ["-an"]


def test_conversion_target_swaps_extension(tmp_path):
    src = tmp_path / "movie.mkv"
    src.touch()
    assert library.conversion_target(src) == tmp_path / "movie.mp4"


def test_conversion_target_collision_falls_back(tmp_path):
    src = tmp_path / "movie.mp4"
    src.touch()
    assert library.conversion_target(src) == tmp_path / "movie.ios.mp4"

    other = tmp_path / "film.mkv"
    other.touch()
    (tmp_path / "film.mp4").touch()  # pre-existing sibling from another release
    assert library.conversion_target(other) == tmp_path / "film.ios.mp4"


def test_width_exactly_2266_passthrough():
    """Width exactly at IPAD_MAX_WIDTH boundary should passthrough when conditions met."""
    p = probe(container="mov,mp4,m4a,3gp,3g2,mj2", vcodec="h264", acodec="aac", width=2266)
    plan = library.plan_conversion(p)
    assert plan.passthrough


def test_no_video_stream_raises_error():
    """Probe with no video stream should raise RuntimeError."""
    p = {"streams": [{"codec_type": "audio", "codec_name": "aac"}], "format": {"format_name": "mov,mp4"}}
    with pytest.raises(RuntimeError, match="No video stream"):
        library.plan_conversion(p)


import importlib


@pytest.fixture()
def fresh_db(monkeypatch, tmp_path):
    monkeypatch.setenv("DB_PATH", str(tmp_path / "test.db"))
    import db
    importlib.reload(db)
    db.init_db()
    yield


def lib_row(tmp_path, name="ep.mkv"):
    import db
    src = tmp_path / name
    src.write_bytes(b"fake")
    vid, _ = db.upsert_library_video({
        "source_path": str(src),
        "title": "Ep",
        "classification": "tv",
        "show_title": "Show",
        "season": 1,
        "episode": 1,
        "summary": None,
        "plex_rating_key": "1",
        "show_rating_key": "2",
    })
    return vid, src


def test_convert_passthrough_marks_done_no_copy(fresh_db, tmp_path, monkeypatch):
    import db
    vid, src = lib_row(tmp_path, "ep.mp4")
    monkeypatch.setattr(library, "probe_source", lambda p: probe(
        container="mov,mp4,m4a,3gp,3g2,mj2", vcodec="h264", acodec="aac"))
    library.convert_library_video(vid)
    row = db.get_video(vid)
    assert row["status"] == "done" and row["converted_path"] is None


def test_convert_runs_ffmpeg_and_records_sibling(fresh_db, tmp_path, monkeypatch):
    import db
    vid, src = lib_row(tmp_path)
    monkeypatch.setattr(library, "probe_source", lambda p: probe())
    calls = []

    def fake_run(cmd):
        calls.append(cmd)
        Path(cmd[-1]).write_bytes(b"converted")  # ffmpeg output file

    monkeypatch.setattr(library, "_run_ffmpeg", fake_run)
    library.convert_library_video(vid)
    row = db.get_video(vid)
    assert row["status"] == "done"
    assert row["converted_path"] == str(tmp_path / "ep.mp4")
    assert (tmp_path / "ep.mp4").read_bytes() == b"converted"
    cmd = calls[0]
    assert "-c:v" in cmd and "copy" in cmd and "+faststart" in cmd
    assert cmd[-1].startswith(str(tmp_path / "."))  # hidden temp file, atomic replace


def test_convert_failure_returns_to_unconverted(fresh_db, tmp_path, monkeypatch):
    import db
    vid, src = lib_row(tmp_path)
    monkeypatch.setattr(library, "probe_source", lambda p: probe())

    def boom(cmd):
        raise RuntimeError("ffmpeg exploded")

    monkeypatch.setattr(library, "_run_ffmpeg", boom)
    library.convert_library_video(vid)
    row = db.get_video(vid)
    assert row["status"] == "unconverted"
    assert "ffmpeg exploded" in row["error_msg"]
    assert not (tmp_path / "ep.mp4").exists()


def test_convert_missing_source(fresh_db, tmp_path):
    import db
    vid, src = lib_row(tmp_path)
    src.unlink()
    library.convert_library_video(vid)
    row = db.get_video(vid)
    assert row["status"] == "unconverted" and "missing" in row["error_msg"]


def test_scan_library(fresh_db, tmp_path, monkeypatch):
    import db
    import plex
    src = tmp_path / "a.mkv"
    src.write_bytes(b"x")
    gone = tmp_path / "gone.mkv"  # never created
    converted = tmp_path / "b.mp4"
    converted.write_bytes(b"x")

    def item(path):
        return {"source_path": str(path), "title": path.stem, "classification": "movies",
                "show_title": None, "season": None, "episode": None, "summary": None,
                "plex_rating_key": "1", "show_rating_key": None}

    monkeypatch.setattr(plex, "fetch_library_items",
                        lambda: [item(src), item(gone), item(converted)])
    # b.mp4 is a prior conversion output of some row: must be self-excluded
    vid, _ = db.upsert_library_video(item(tmp_path / "b.mkv"))
    (tmp_path / "b.mkv").write_bytes(b"x")
    db.set_library_state(vid, "done", converted_path=str(converted))

    result = library.scan_library()
    assert result == {"added": 1, "updated": 0, "skipped": 2}

    result = library.scan_library()
    assert result == {"added": 0, "updated": 1, "skipped": 2}
