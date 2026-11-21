import pytest

import media_probe


def probe(container="matroska,webm", vcodec="hevc", width=1920, tag="[0][0][0][0]",
          acodec="eac3", with_audio=True, audio=None):
    """audio optionally supplies (codec, language, title) tuples."""
    streams = [{
        "codec_type": "video",
        "codec_name": vcodec,
        "width": width,
        "codec_tag_string": tag,
    }]
    if audio is not None:
        for codec, lang, title in audio:
            streams.append({
                "codec_type": "audio", "codec_name": codec, "channels": 6,
                "tags": {"language": lang, "title": title},
            })
    elif with_audio:
        streams.append({"codec_type": "audio", "codec_name": acodec, "channels": 6})
    return {"streams": streams, "format": {"format_name": container}}


def test_passthrough_compatible_mp4():
    p = probe(container="mov,mp4,m4a,3gp,3g2,mj2", vcodec="h264", acodec="aac")
    plan = media_probe.plan_conversion(p)
    assert plan.passthrough


def test_passthrough_transcodes_a_selected_incompatible_audio_stream():
    plan = media_probe.plan_conversion(probe(
        container="mov,mp4,m4a,3gp,3g2,mj2", vcodec="h264",
        audio=[("aac", "eng", ""), ("dts", "spa", "")],
    ))

    assert not plan.passthrough
    assert plan.audio_args == [
        "-c:a:0", "copy",
        "-c:a:1", "aac", "-b:a:1", "128k", "-ac:a:1", "2",
    ]


def test_passthrough_hevc_requires_hvc1_tag():
    good = probe(container="mov,mp4,m4a,3gp,3g2,mj2", vcodec="hevc", tag="hvc1")
    assert media_probe.plan_conversion(good).passthrough
    bad = probe(container="mov,mp4,m4a,3gp,3g2,mj2", vcodec="hevc", tag="hev1")
    assert not media_probe.plan_conversion(bad).passthrough


def test_no_passthrough_above_ipad_width():
    p = probe(container="mov,mp4,m4a,3gp,3g2,mj2", vcodec="h264", acodec="aac", width=3840)
    assert not media_probe.plan_conversion(p).passthrough


def test_mkv_hevc_remuxes_with_hvc1():
    plan = media_probe.plan_conversion(probe())
    assert not plan.passthrough
    assert plan.video_args == ["-c:v", "copy", "-tag:v", "hvc1"]
    assert plan.audio_args == ["-c:a:0", "copy"]


def test_mkv_h264_remuxes_with_avc1():
    plan = media_probe.plan_conversion(probe(vcodec="h264"))
    assert plan.video_args == ["-c:v", "copy", "-tag:v", "avc1"]


def test_4k_downscales_and_reencodes():
    plan = media_probe.plan_conversion(probe(width=3840))
    assert plan.video_args == [
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
        "-pix_fmt", "yuv420p", "-profile:v", "high", "-tag:v", "avc1",
        "-vf", "scale='min(2266,iw)':-2",
    ]


def test_unsupported_codecs_reencode():
    plan = media_probe.plan_conversion(probe(vcodec="vp9", acodec="dts"))
    assert plan.video_args[0:2] == ["-c:v", "libx264"]
    assert plan.audio_args == ["-c:a:0", "aac", "-b:a:0", "128k", "-ac:a:0", "2"]


def test_no_audio_stream():
    plan = media_probe.plan_conversion(probe(with_audio=False))
    assert plan.audio_args == ["-an"]


def multi_probe():
    return probe(audio=[
        ("eac3", "cat", ""),
        ("eac3", "eng", ""),
        ("eac3", "spa", "Latin American"),
        ("dts", "spa", "European"),
    ])


def test_allowed_audio_langs_default(monkeypatch):
    monkeypatch.delenv("LIBRARY_AUDIO_LANGS", raising=False)
    assert media_probe.allowed_audio_langs() == ["eng", "spa"]
    monkeypatch.setenv("LIBRARY_AUDIO_LANGS", " ENG , jpn,")
    assert media_probe.allowed_audio_langs() == ["eng", "jpn"]


def test_audio_track_list():
    assert media_probe.audio_track_list(multi_probe()) == [
        {"lang": "cat", "title": ""},
        {"lang": "eng", "title": ""},
        {"lang": "spa", "title": "Latin American"},
        {"lang": "spa", "title": "European"},
    ]


def test_audio_track_list_untagged():
    assert media_probe.audio_track_list(probe()) == [{"lang": "und", "title": ""}]


def test_select_audio_indices_allowlist():
    assert media_probe.select_audio_indices(multi_probe(), ["eng", "spa"]) == [1, 2, 3]


def test_select_audio_indices_fallback_first():
    assert media_probe.select_audio_indices(multi_probe(), ["jpn"]) == [0]


def test_select_audio_indices_no_audio():
    assert media_probe.select_audio_indices(probe(with_audio=False), ["eng"]) == []


def test_plan_conversion_multi_track(monkeypatch):
    monkeypatch.delenv("LIBRARY_AUDIO_LANGS", raising=False)
    plan = media_probe.plan_conversion(multi_probe())
    assert not plan.passthrough
    assert plan.audio_maps == [1, 2, 3]
    assert plan.audio_langs == ["eng", "spa", "spa"]
    assert plan.audio_args == [
        "-c:a:0", "copy",
        "-c:a:1", "copy",
        "-c:a:2", "aac", "-b:a:2", "128k", "-ac:a:2", "2",
    ]


def test_plan_conversion_explicit_indices():
    plan = media_probe.plan_conversion(multi_probe(), audio_indices=[2])
    assert plan.audio_maps == [2]
    assert plan.audio_langs == ["spa"]
    assert plan.audio_args == ["-c:a:0", "copy"]


def test_plan_conversion_no_audio_keeps_an():
    plan = media_probe.plan_conversion(probe(with_audio=False))
    assert plan.audio_maps == []
    assert plan.audio_args == ["-an"]



def test_width_exactly_2266_passthrough():
    """Width exactly at IPAD_MAX_WIDTH boundary should passthrough when conditions met."""
    p = probe(container="mov,mp4,m4a,3gp,3g2,mj2", vcodec="h264", acodec="aac", width=2266)
    plan = media_probe.plan_conversion(p)
    assert plan.passthrough


def test_no_video_stream_raises_error():
    """Probe with no video stream should raise RuntimeError."""
    p = {"streams": [{"codec_type": "audio", "codec_name": "aac"}], "format": {"format_name": "mov,mp4"}}
    with pytest.raises(RuntimeError, match="No video stream"):
        media_probe.plan_conversion(p)
