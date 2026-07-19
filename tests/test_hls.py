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
    def fake(cmd):
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
        run_ffmpeg=commands.append,
        audio_lang="spa",
    )
    assert "0:a:1" in commands[0]


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
