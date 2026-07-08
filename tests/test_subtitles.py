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
    path.write_text(content, encoding="utf-8")
    return path


def test_discover_finds_supported_sidecars(tmp_path):
    video = _touch(tmp_path / "movie.mp4")
    _touch(tmp_path / "movie.en.srt")
    _touch(tmp_path / "movie.es.sub", "00:00:01.00,00:00:02.00\nHola\n")
    _touch(tmp_path / "movie.vtt")

    tracks = discover_subtitles(video)

    langs = [(t.language, t.name, t.format) for t in tracks]
    assert ("en", "English", "srt") in langs
    assert ("es", "Spanish", "sub") in langs
    assert ("und", "Unknown", "vtt") in langs


def test_discover_is_deterministically_ordered(tmp_path):
    video = _touch(tmp_path / "movie.mp4")
    _touch(tmp_path / "movie.es.srt")
    _touch(tmp_path / "movie.en.srt")

    tracks = discover_subtitles(video)

    assert [t.language for t in tracks] == sorted(t.language for t in tracks)


def test_first_non_forced_track_is_default(tmp_path):
    video = _touch(tmp_path / "movie.mp4")
    _touch(tmp_path / "movie.en.srt")
    _touch(tmp_path / "movie.es.srt")

    tracks = discover_subtitles(video)

    defaults = [t for t in tracks if t.default]
    assert len(defaults) == 1
    assert defaults[0].language == "en"


def test_unsupported_extensions_are_ignored(tmp_path):
    video = _touch(tmp_path / "movie.mp4")
    _touch(tmp_path / "movie.txt")
    _touch(tmp_path / "movie.ass")
    _touch(tmp_path / "other.srt")  # different stem, not a sidecar

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
