from pathlib import Path

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
