"""Unit tests for sidecar subtitle discovery and WebVTT conversion."""

from pathlib import Path

import pytest

from subtitles import (
    SubtitleTrack,
    convert_to_webvtt,
    discover_subtitles,
)

VTT_HEADER = "WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:0\n"


# --- Discovery -------------------------------------------------------------


def _touch(path: Path, content: str = "") -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return path


def _by_lang(tracks):
    return {t.language: t for t in tracks}


def test_stem_sidecar_srt_next_to_video(tmp_path):
    # movies/The.Gorge.2025.../The.Gorge.2025...srt
    video = _touch(tmp_path / "The.Gorge.2025.1080p.WEBRip.x264.AAC5.1-[YTS.MX].mp4")
    _touch(tmp_path / "The.Gorge.2025.1080p.WEBRip.x264.AAC5.1-[YTS.MX].srt")

    tracks = discover_subtitles(video)
    assert len(tracks) == 1
    assert tracks[0].language == "und"
    assert tracks[0].format == "srt"


def test_srt_next_to_differently_suffixed_video(tmp_path):
    # El.Secreto...WORLD.srt sits next to El.Secreto...WORLD-subtitled.m4v
    video = _touch(tmp_path / "El.Secreto.2020.AAC-WORLD-subtitled.m4v")
    _touch(tmp_path / "El.Secreto.2020.AAC-WORLD.srt")

    tracks = discover_subtitles(video)
    assert len(tracks) == 1


def test_subs_folder_iso639_2_codes(tmp_path):
    # movies/<Movie>/Subs/{ger,jpn,vie,fre}.srt
    video = _touch(tmp_path / "movie.mkv")
    for code in ("ger", "jpn", "vie", "fre", "spa"):
        _touch(tmp_path / "Subs" / f"{code}.srt")

    tracks = _by_lang(discover_subtitles(video))
    assert set(tracks) == {"de", "ja", "vi", "fr", "es"}
    assert tracks["de"].name == "German"


def test_subs_folder_descriptor_and_region_names(tmp_path):
    video = _touch(tmp_path / "movie.mkv")
    _touch(tmp_path / "Subs" / "Latin American.spa.srt")
    _touch(tmp_path / "Subs" / "European.spa.srt")
    _touch(tmp_path / "Subs" / "SDH.eng.HI.srt")
    _touch(tmp_path / "Subs" / "Canadian (Forced).fre.srt")
    _touch(tmp_path / "Subs" / "English.srt")

    tracks = discover_subtitles(video)
    langs = sorted(t.language for t in tracks)
    # two Spanish (region variants), plus en (SDH), en (plain), fr (forced)
    assert langs == ["en", "en", "es", "es", "fr"]

    spanish_names = sorted(t.name for t in tracks if t.language == "es")
    assert spanish_names == ["Spanish (European)", "Spanish (Latin American)"]

    forced = [t for t in tracks if t.forced]
    assert len(forced) == 1 and forced[0].language == "fr"

    sdh = next(t for t in tracks if "SDH" in t.name)
    assert sdh.language == "en"


def test_tv_per_episode_subs_folder(tmp_path):
    # tv/<Show>/<Season>/Subs/<episode_stem>/3_English.srt — only the matching
    # episode's subtitles attach to that episode.
    season = tmp_path / "Rick.and.Morty.S05.1080p.BluRay.x265-RARBG"
    e01 = "Rick.and.Morty.S05E01.1080p.BluRay.x265-RARBG"
    e02 = "Rick.and.Morty.S05E02.1080p.BluRay.x265-RARBG"
    video = _touch(season / f"{e01}.mp4")
    _touch(season / f"{e02}.mp4")
    _touch(season / "Subs" / e01 / "3_English.srt")
    _touch(season / "Subs" / e02 / "3_English.srt")

    tracks = discover_subtitles(video)
    assert len(tracks) == 1
    assert tracks[0].language == "en"
    assert tracks[0].source_path.name == "3_English.srt"
    assert e01 in str(tracks[0].source_path)


def test_nested_srt_bucket_and_vobsub_rejected(tmp_path):
    # Dragon Ball: Subtitles/srt/English.srt (kept) + Subtitles/VobSub/x.idx+.sub (rejected)
    video = _touch(tmp_path / "movie.mkv")
    _touch(tmp_path / "Subtitles" / "srt" / "English.srt")
    _touch(tmp_path / "Subtitles" / "VobSub" / "jp.idx")
    _touch(tmp_path / "Subtitles" / "VobSub" / "jp.sub")

    tracks = discover_subtitles(video)
    assert [t.language for t in tracks] == ["en"]


def test_release_prefixed_subtitles_folder(tmp_path):
    # Dragon Ball: the folder is "<release>.Subtitles", not plain "Subtitles".
    video = _touch(tmp_path / "Dragon.Ball.Z.Resurrection.F.mkv")
    _touch(tmp_path / "Dragon.Ball.Z.Resurrection.F.Subtitles" / "srt" / "English.srt")
    _touch(tmp_path / "Dragon.Ball.Z.Resurrection.F.Subtitles" / "VobSub" / "ja.idx")
    _touch(tmp_path / "Dragon.Ball.Z.Resurrection.F.Subtitles" / "VobSub" / "ja.sub")

    tracks = discover_subtitles(video)
    assert [t.language for t in tracks] == ["en"]


def test_english_marked_default_among_many(tmp_path):
    video = _touch(tmp_path / "movie.mkv")
    for code in ("ger", "jpn", "eng", "spa"):
        _touch(tmp_path / "Subs" / f"{code}.srt")

    tracks = discover_subtitles(video)
    defaults = [t for t in tracks if t.default]
    assert len(defaults) == 1
    assert defaults[0].language == "en"


def test_app_bundle_and_unrelated_files_ignored(tmp_path):
    video = _touch(tmp_path / "movie.mkv")
    _touch(tmp_path / "movie.txt")
    _touch(tmp_path / "movie.ass")  # not supported yet
    _touch(tmp_path / "Subler.app" / "Contents" / "en.strings")  # app bundle junk

    assert discover_subtitles(video) == []


def test_vobsub_idx_sub_pair_is_rejected(tmp_path):
    video = _touch(tmp_path / "movie.mp4")
    _touch(tmp_path / "movie.idx")
    _touch(tmp_path / "movie.sub")  # binary VobSub companion

    assert discover_subtitles(video) == []


# --- Conversion ------------------------------------------------------------


def _track(path: Path, fmt: str) -> SubtitleTrack:
    return SubtitleTrack(source_path=path, language="en", name="English", format=fmt)


def test_srt_converts_commas_to_dots(tmp_path):
    src = _touch(tmp_path / "movie.srt", "1\n00:00:01,000 --> 00:00:03,500\nHello\n")
    out = convert_to_webvtt(_track(src, "srt"), tmp_path / "en.vtt")

    text = out.read_text(encoding="utf-8")
    assert text.startswith(VTT_HEADER)
    assert "00:00:01.000 --> 00:00:03.500\nHello" in text
    assert "1\n00:00:01" not in text  # sequence number dropped


def test_subviewer_sub_conversion(tmp_path):
    src = _touch(tmp_path / "movie.sub", "00:00:01.00,00:00:03.50\nHello\n")
    out = convert_to_webvtt(_track(src, "sub"), tmp_path / "en.vtt")

    text = out.read_text(encoding="utf-8")
    assert text.startswith(VTT_HEADER)
    assert "00:00:01.000 --> 00:00:03.500\nHello" in text


def test_microdvd_sub_conversion_uses_fps(tmp_path):
    src = _touch(tmp_path / "movie.sub", "{24}{84}Hello\n")
    out = convert_to_webvtt(_track(src, "sub"), tmp_path / "en.vtt", fps=24)

    text = out.read_text(encoding="utf-8")
    assert text.startswith(VTT_HEADER)
    assert "00:00:01.000 --> 00:00:03.500\nHello" in text


def test_microdvd_requires_fps(tmp_path):
    src = _touch(tmp_path / "movie.sub", "{24}{84}Hello\n")
    with pytest.raises(ValueError):
        convert_to_webvtt(_track(src, "sub"), tmp_path / "en.vtt")


def test_existing_vtt_is_renormalized_with_header(tmp_path):
    src = _touch(tmp_path / "movie.vtt", "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHi\n")
    out = convert_to_webvtt(_track(src, "vtt"), tmp_path / "en.vtt")

    text = out.read_text(encoding="utf-8")
    assert text.startswith(VTT_HEADER)
    assert text.count("WEBVTT") == 1
    assert "00:00:01.000 --> 00:00:02.000\nHi" in text


def test_every_vtt_starts_with_timestamp_map(tmp_path):
    src = _touch(tmp_path / "movie.srt", "1\n00:00:00,500 --> 00:00:01,000\nA\n")
    out = convert_to_webvtt(_track(src, "srt"), tmp_path / "en.vtt")
    lines = out.read_text(encoding="utf-8").splitlines()
    assert lines[0] == "WEBVTT"
    assert lines[1] == "X-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:0"
