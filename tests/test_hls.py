"""Unit tests for HLS packaging: codec policy, playlists, path safety."""

from pathlib import Path

import hls
import pytest
import library
from subtitles import SubtitleTrack


# H.264/AAC in an mp4 container -> passthrough (stream copy).
COMPAT_PROBE = {
    "format": {"format_name": "mov,mp4,m4a", "duration": "12.0", "bit_rate": "1500000"},
    "streams": [
        {"codec_type": "video", "codec_name": "h264", "width": 1280, "height": 720,
         "r_frame_rate": "24/1"},
        {"codec_type": "audio", "codec_name": "aac"},
    ],
}

# mpeg4 video + mp3 audio -> both incompatible -> transcode.
INCOMPAT_PROBE = {
    "format": {"format_name": "avi", "duration": "12.0"},
    "streams": [
        {"codec_type": "video", "codec_name": "mpeg4", "width": 640, "height": 480},
        {"codec_type": "audio", "codec_name": "mp3"},
    ],
}


def _capture(cmds):
    def fake(cmd, *, duration=None, on_progress=None):
        cmds.append(cmd)
        # Emulate ffmpeg producing the media playlist so master gen can proceed.
        out_dir = Path(cmd[-1]).parent
        out_dir.mkdir(parents=True, exist_ok=True)
        Path(cmd[-1]).write_text("#EXTM3U\n", encoding="utf-8")
    return fake


def test_compatible_source_uses_stream_copy(tmp_path):
    cmds = []
    hls.build_hls_package(1, tmp_path / "movie.mp4", tmp_path / "hls",
                          probe=COMPAT_PROBE, subtitles=[], run_ffmpeg=_capture(cmds))
    cmd = cmds[0]
    assert "-c" in cmd and cmd[cmd.index("-c") + 1] == "copy"
    assert "libx264" not in cmd
    assert "aac" not in cmd
    assert "-hls_playlist_type" in cmd and "vod" in cmd
    assert "-hls_segment_type" in cmd and "fmp4" in cmd
    assert "-hls_segment_filename" in cmd


def test_incompatible_source_transcodes(tmp_path):
    cmds = []
    hls.build_hls_package(2, tmp_path / "movie.avi", tmp_path / "hls",
                          probe=INCOMPAT_PROBE, subtitles=[], run_ffmpeg=_capture(cmds))
    cmd = cmds[0]
    assert "libx264" in cmd
    assert "aac" in cmd
    assert ["-c", "copy"] != cmd[cmd.index("-i") + 2: cmd.index("-i") + 4]
    assert "-hls_segment_type" in cmd and "fmp4" in cmd


def test_output_constrained_to_video_dir(tmp_path):
    pkg = hls.build_hls_package(7, tmp_path / "movie.mp4", tmp_path / "hls",
                                probe=COMPAT_PROBE, subtitles=[], run_ffmpeg=_capture([]))
    assert pkg.out_dir == tmp_path / "hls" / "7"
    assert pkg.master_path == tmp_path / "hls" / "7" / "master.m3u8"


def test_default_root_is_hls_dir():
    assert hls.hls_dir_for(9) == hls.HLS_DIR / "9"


def test_master_playlist_declares_subtitle_group(tmp_path):
    track = SubtitleTrack(source_path=tmp_path / "movie.en.srt", language="en",
                          name="English", format="srt", default=True, forced=False)
    (tmp_path / "movie.en.srt").write_text("1\n00:00:01,000 --> 00:00:02,000\nHi\n")
    pkg = hls.build_hls_package(3, tmp_path / "movie.mp4", tmp_path / "hls",
                                probe=COMPAT_PROBE, subtitles=[track], run_ffmpeg=_capture([]))
    master = pkg.master_path.read_text(encoding="utf-8")
    assert master.startswith("#EXTM3U")
    assert "#EXT-X-INDEPENDENT-SEGMENTS" in master
    assert ('#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",LANGUAGE="en",NAME="English",'
            'DEFAULT=YES,AUTOSELECT=YES,FORCED=NO,URI="subtitles/en.m3u8"') in master
    assert 'SUBTITLES="subs"' in master
    assert "video.m3u8" in master


def test_master_omits_subtitle_group_when_no_tracks(tmp_path):
    pkg = hls.build_hls_package(4, tmp_path / "movie.mp4", tmp_path / "hls",
                                probe=COMPAT_PROBE, subtitles=[], run_ffmpeg=_capture([]))
    master = pkg.master_path.read_text(encoding="utf-8")
    assert "TYPE=SUBTITLES" not in master
    assert 'SUBTITLES="subs"' not in master


def test_same_language_tracks_get_distinct_files(tmp_path):
    # Latin American + European Spanish both map to 'es'; keys must not collide.
    (tmp_path / "la.srt").write_text("1\n00:00:01,000 --> 00:00:02,000\nHola\n")
    (tmp_path / "eu.srt").write_text("1\n00:00:01,000 --> 00:00:02,000\nHola\n")
    tracks = [
        SubtitleTrack(tmp_path / "la.srt", "es", "Spanish (Latin American)", "srt", default=False),
        SubtitleTrack(tmp_path / "eu.srt", "es", "Spanish (European)", "srt", default=False),
    ]
    pkg = hls.build_hls_package(6, tmp_path / "movie.mp4", tmp_path / "hls",
                                probe=COMPAT_PROBE, subtitles=tracks, run_ffmpeg=_capture([]))
    subs = sorted(p.name for p in (pkg.out_dir / "subtitles").glob("*.vtt"))
    assert subs == ["es-2.vtt", "es.vtt"]
    master = pkg.master_path.read_text(encoding="utf-8")
    assert 'URI="subtitles/es.m3u8"' in master
    assert 'URI="subtitles/es-2.m3u8"' in master


def test_subtitle_media_playlist_is_vod(tmp_path):
    track = SubtitleTrack(source_path=tmp_path / "movie.en.srt", language="en",
                          name="English", format="srt", default=True)
    (tmp_path / "movie.en.srt").write_text("1\n00:00:01,000 --> 00:00:02,000\nHi\n")
    pkg = hls.build_hls_package(5, tmp_path / "movie.mp4", tmp_path / "hls",
                                probe=COMPAT_PROBE, subtitles=[track], run_ffmpeg=_capture([]))
    playlist = (pkg.out_dir / "subtitles" / "en.m3u8").read_text(encoding="utf-8")
    assert "#EXTM3U" in playlist
    assert "#EXT-X-TARGETDURATION:" in playlist
    assert "#EXT-X-PLAYLIST-TYPE:VOD" in playlist
    assert "#EXTINF:" in playlist
    assert "en.vtt" in playlist
    assert "#EXT-X-ENDLIST" in playlist
    vtt = (pkg.out_dir / "subtitles" / "en.vtt").read_text(encoding="utf-8")
    assert vtt.startswith("WEBVTT")


def test_build_command_maps_selected_audio(tmp_path):
    plan = library.ConversionPlan(
        passthrough=False,
        video_args=["-c:v", "copy", "-tag:v", "avc1"],
        audio_args=["-c:a:0", "copy"],
        audio_maps=[2],
        audio_langs=["spa"],
    )
    cmd = hls.build_ffmpeg_command(Path("in.mp4"), tmp_path, plan)
    assert ["-map", "0:v:0", "-map", "0:a:2"] == cmd[cmd.index("-map"):cmd.index("-map") + 4]


def test_build_command_no_audio(tmp_path):
    plan = library.ConversionPlan(
        passthrough=False,
        video_args=["-c:v", "copy"],
        audio_args=["-an"],
        audio_maps=[],
        audio_langs=[],
    )
    cmd = hls.build_ffmpeg_command(Path("in.mp4"), tmp_path, plan)
    assert "0:a:0?" not in cmd and cmd.count("-map") == 1


def test_build_package_selects_audio_lang(tmp_path):
    probe = {
        "streams": [
            {"codec_type": "video", "codec_name": "h264", "width": 1920},
            {"codec_type": "audio", "codec_name": "eac3", "tags": {"language": "cat"}},
            {"codec_type": "audio", "codec_name": "eac3", "tags": {"language": "spa"}},
        ],
        "format": {"format_name": "mov,mp4,m4a,3gp,3g2,mj2", "duration": "10"},
    }
    commands = []
    hls.build_hls_package(
        1,
        tmp_path / "in.mp4",
        output_root=tmp_path / "out",
        probe=probe,
        subtitles=[],
        run_ffmpeg=_capture(commands),
        audio_lang="spa",
    )
    assert "0:a:1" in commands[0]


def test_build_hls_package_passes_duration_and_progress(tmp_path):
    calls = {}

    def fake_run_ffmpeg(cmd, *, duration=None, on_progress=None):
        calls["duration"] = duration
        out_dir = Path(cmd[-1]).parent
        out_dir.mkdir(parents=True, exist_ok=True)
        Path(cmd[-1]).write_text("#EXTM3U\n", encoding="utf-8")
        if on_progress:
            on_progress(0.25)

    seen = []
    hls.build_hls_package(
        1, tmp_path / "source.mkv", tmp_path / "hls",
        probe=COMPAT_PROBE, subtitles=[], run_ffmpeg=fake_run_ffmpeg,
        on_progress=seen.append,
    )
    assert calls["duration"] == pytest.approx(hls._duration(COMPAT_PROBE))
    assert seen == [0.25]


@pytest.fixture()
def fresh_db(monkeypatch, tmp_path):
    import importlib
    monkeypatch.setenv("DB_PATH", str(tmp_path / "test.db"))
    import db
    importlib.reload(db)
    db.init_db()
    yield


def test_invalidate_removes_dir_and_resets_status(fresh_db, tmp_path, monkeypatch):
    import db
    vid = db.add_video("http://x")
    db.set_hls_status(vid, "done")
    monkeypatch.setattr(hls, "HLS_DIR", tmp_path)
    directory = tmp_path / str(vid)
    directory.mkdir()
    (directory / "master.m3u8").write_text("x")
    hls.invalidate(vid)
    assert not directory.exists()
    assert db.get_video(vid)["hls_status"] == "none"


def test_prepare_failure_resets_status_without_raising_by_default(fresh_db, monkeypatch):
    import db

    video_id = db.add_video("https://example.com/video")
    db.set_hls_status(video_id, "converting")

    def fail_hls(*args, **kwargs):
        raise RuntimeError("hls exploded")

    monkeypatch.setattr(hls, "build_hls_package", fail_hls)

    hls.prepare(video_id, "/tmp/movie.mp4")

    assert db.get_video(video_id)["hls_status"] == "none"


def test_subtitles_read_from_original_when_streaming_a_converted_file(tmp_path):
    """The streamed mp4 is our own conversion, which carries no subtitles.

    library.convert_library_video passes -sn, so the converted sibling has no
    subtitle streams at all. Packaging must search the original source for
    them or an mkv's embedded tracks vanish at exactly the point they would
    have shipped.
    """
    original = tmp_path / "movie.mkv"
    original.write_bytes(b"x")
    converted = tmp_path / "movie.mp4"
    converted.write_bytes(b"x")

    original_probe = {
        "format": {"duration": "12.0"},
        "streams": [
            {"index": 0, "codec_type": "video", "codec_name": "hevc"},
            {"index": 2, "codec_type": "subtitle", "codec_name": "subrip",
             "tags": {"language": "eng"}},
        ],
    }

    extracted = []

    def fake_probe_source(path):
        assert Path(path) == original
        return original_probe

    def fake_convert(track, output_path, fps=None):
        extracted.append((Path(track.source_path), track.stream_index))
        Path(output_path).parent.mkdir(parents=True, exist_ok=True)
        Path(output_path).write_text("WEBVTT\n", encoding="utf-8")
        return Path(output_path)

    original_probe_source = hls.probe_source
    original_convert = hls.convert_to_webvtt
    hls.probe_source = fake_probe_source
    hls.convert_to_webvtt = fake_convert
    try:
        pkg = hls.build_hls_package(
            11, converted, tmp_path / "hls",
            probe=COMPAT_PROBE,           # the converted file: no subtitle streams
            subtitle_source=original,
            run_ffmpeg=_capture([]),
        )
    finally:
        hls.probe_source = original_probe_source
        hls.convert_to_webvtt = original_convert

    assert extracted == [(original, 2)]
    assert [t.language for t in pkg.tracks] == ["en"]
    assert 'LANGUAGE="en"' in pkg.master_path.read_text(encoding="utf-8")


def test_packaging_survives_an_unprobeable_subtitle_source(tmp_path):
    """A missing original costs subtitles, never the whole package."""
    converted = tmp_path / "movie.mp4"
    converted.write_bytes(b"x")

    def boom(path):
        raise RuntimeError("ffprobe failed")

    original_probe_source = hls.probe_source
    hls.probe_source = boom
    try:
        pkg = hls.build_hls_package(
            12, converted, tmp_path / "hls",
            probe=COMPAT_PROBE,
            subtitle_source=tmp_path / "gone.mkv",
            run_ffmpeg=_capture([]),
        )
    finally:
        hls.probe_source = original_probe_source

    assert pkg.tracks == []
    assert pkg.master_path.exists()


def test_packaged_subtitle_languages_reads_the_master(tmp_path):
    out = tmp_path / "hls" / "5"
    out.mkdir(parents=True)
    (out / "master.m3u8").write_text(
        '#EXTM3U\n'
        '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",LANGUAGE="en",NAME="English",'
        'DEFAULT=YES,AUTOSELECT=YES,FORCED=NO,URI="subtitles/en.m3u8"\n'
        '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",LANGUAGE="de",NAME="German"\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=1\nvideo.m3u8\n',
        encoding="utf-8")

    # Only SUBTITLES renditions count -- an audio LANGUAGE must not leak in.
    assert hls.packaged_subtitle_languages(5, tmp_path / "hls") == {"en"}


def test_packaged_subtitle_languages_is_none_without_a_package(tmp_path):
    """None means "nothing packaged" -- distinct from a package with no subtitles."""
    assert hls.packaged_subtitle_languages(6, tmp_path / "hls") is None

    out = tmp_path / "hls" / "7"
    out.mkdir(parents=True)
    (out / "master.m3u8").write_text("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nvideo.m3u8\n",
                                     encoding="utf-8")
    assert hls.packaged_subtitle_languages(7, tmp_path / "hls") == set()
