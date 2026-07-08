"""Unit tests for HLS packaging: codec policy, playlists, path safety."""

from pathlib import Path

import hls
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
