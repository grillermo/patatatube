"""Unit tests for sidecar subtitle discovery and WebVTT conversion."""

import subprocess
from pathlib import Path

import pytest

import subtitles
from subtitles import (
    SubtitleTrack,
    UnsupportedSubtitleError,
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
    """Descriptor and region words survive into the display name.

    Only one track per language ships, so give each language a single file
    here; the collapse itself is covered by the dedup tests below.
    """
    video = _touch(tmp_path / "movie.mkv")
    _touch(tmp_path / "Subs" / "Latin American.spa.srt")
    _touch(tmp_path / "Subs" / "SDH.eng.HI.srt")
    _touch(tmp_path / "Subs" / "Canadian (Forced).fre.srt")

    tracks = _by_lang(discover_subtitles(video))
    assert set(tracks) == {"en", "es", "fr"}
    assert tracks["es"].name == "Spanish (Latin American)"
    assert tracks["en"].name == "English (SDH HI)"
    assert tracks["fr"].forced is True


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


# --- Embedded container tracks ---------------------------------------------


def _sub_stream(index, codec, language=None, title=None, forced=0):
    tags = {}
    if language:
        tags["language"] = language
    if title:
        tags["title"] = title
    return {
        "index": index,
        "codec_type": "subtitle",
        "codec_name": codec,
        "tags": tags,
        "disposition": {"forced": forced},
    }


# Breathless.1960.Criterion...mkv: an image PGS track and a text SRT track,
# both tagged eng. Only the text one is usable without OCR.
BREATHLESS_PROBE = {
    "streams": [
        {"index": 0, "codec_type": "video", "codec_name": "hevc"},
        {"index": 1, "codec_type": "audio", "codec_name": "aac", "tags": {"language": "fre"}},
        _sub_stream(3, "hdmv_pgs_subtitle", "eng", "PGS"),
        _sub_stream(4, "subrip", "eng", "SRT"),
    ],
}


def test_embedded_text_track_discovered_from_probe(tmp_path):
    video = _touch(tmp_path / "Breathless.1960.Criterion.mkv")

    tracks = discover_subtitles(video, probe=BREATHLESS_PROBE)

    assert len(tracks) == 1
    track = tracks[0]
    assert track.language == "en"
    assert track.stream_index == 4
    assert track.source_path == video
    assert track.default is True


def test_embedded_bitmap_tracks_are_rejected(tmp_path):
    video = _touch(tmp_path / "movie.mkv")
    probe = {"streams": [
        _sub_stream(2, "hdmv_pgs_subtitle", "eng"),
        _sub_stream(3, "dvd_subtitle", "spa"),
    ]}

    assert discover_subtitles(video, probe=probe) == []


def test_embedded_tracks_ignored_without_a_probe(tmp_path):
    """A caller with no probe dict gets sidecars only — never a hidden ffprobe."""
    video = _touch(tmp_path / "movie.mkv")

    assert discover_subtitles(video) == []


def test_sidecar_wins_over_embedded_track_of_same_language(tmp_path):
    video = _touch(tmp_path / "movie.mkv")
    _touch(tmp_path / "Subs" / "eng.srt")
    probe = {"streams": [_sub_stream(2, "subrip", "eng"), _sub_stream(3, "subrip", "spa")]}

    tracks = discover_subtitles(video, probe=probe)

    by_lang = _by_lang(tracks)
    assert set(by_lang) == {"en", "es"}
    assert by_lang["en"].stream_index is None  # the sidecar file
    assert by_lang["es"].stream_index == 3


def test_embedded_stream_titles_reach_the_display_name(tmp_path):
    video = _touch(tmp_path / "movie.mkv")
    probe = {"streams": [
        _sub_stream(2, "subrip", "eng", "SDH"),
        _sub_stream(3, "subrip", "fre", "Signs"),
    ]}

    names = sorted(t.name for t in discover_subtitles(video, probe=probe))
    assert names == ["English (SDH)", "French (Signs)"]


def test_embedded_forced_disposition_is_carried(tmp_path):
    video = _touch(tmp_path / "movie.mkv")
    probe = {"streams": [
        _sub_stream(2, "subrip", "fre", "Signs", forced=1),
        _sub_stream(3, "subrip", "eng"),
    ]}

    tracks = _by_lang(discover_subtitles(video, probe=probe))
    assert tracks["fr"].forced is True
    assert tracks["en"].forced is False
    # A forced track never becomes the default selection.
    assert [t.language for t in tracks.values() if t.default] == ["en"]


def test_embedded_track_without_language_tag_is_und(tmp_path):
    video = _touch(tmp_path / "movie.mkv")
    probe = {"streams": [_sub_stream(2, "mov_text")]}

    tracks = discover_subtitles(video, probe=probe)
    assert [(t.language, t.name) for t in tracks] == [("und", "Unknown")]


def test_embedded_track_is_extracted_with_ffmpeg(tmp_path, monkeypatch):
    video = _touch(tmp_path / "movie.mkv", "not really a movie")
    track = SubtitleTrack(source_path=video, language="en", name="English",
                          format="subrip", stream_index=4)
    seen = []

    def fake_run(cmd, **kwargs):
        seen.append(cmd)
        # ffmpeg writes its own WEBVTT header, which we must re-normalize.
        Path(cmd[-1]).write_text(
            "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHello\n", encoding="utf-8"
        )
        return subprocess.CompletedProcess(cmd, 0, "", "")

    monkeypatch.setattr(subtitles.subprocess, "run", fake_run)
    out = convert_to_webvtt(track, tmp_path / "en.vtt")

    cmd = seen[0]
    assert cmd[cmd.index("-i") + 1] == str(video)
    assert cmd[cmd.index("-map") + 1] == "0:4"
    assert cmd[cmd.index("-c:s") + 1] == "webvtt"

    text = out.read_text(encoding="utf-8")
    assert text.startswith(VTT_HEADER)
    assert text.count("WEBVTT") == 1
    assert "00:00:01.000 --> 00:00:02.000\nHello" in text


def test_failed_embedded_extraction_raises_unsupported(tmp_path, monkeypatch):
    video = _touch(tmp_path / "movie.mkv", "not really a movie")
    track = SubtitleTrack(source_path=video, language="en", name="English",
                          format="subrip", stream_index=4)

    def fake_run(cmd, **kwargs):
        return subprocess.CompletedProcess(cmd, 1, "", "Invalid data found")

    monkeypatch.setattr(subtitles.subprocess, "run", fake_run)
    with pytest.raises(UnsupportedSubtitleError):
        convert_to_webvtt(track, tmp_path / "en.vtt")


def test_vtt_cue_timestamps_get_the_hours_field(tmp_path):
    """ffmpeg's webvtt muxer emits mm:ss.mmm; emit hh:mm:ss.mmm regardless.

    Both are legal WebVTT, but every other path here produces the long form
    and Apple's HLS authoring guidance expects it, so normalize rather than
    ship two shapes.
    """
    src = _touch(tmp_path / "movie.vtt",
                 "WEBVTT\n\n00:33.492 --> 00:38.289 line:90%\nHi\n"
                 "\n01:02:03.400 --> 01:02:04.000\nLater\n")
    out = convert_to_webvtt(_track(src, "vtt"), tmp_path / "en.vtt")

    text = out.read_text(encoding="utf-8")
    # Cue settings after the timestamps survive untouched.
    assert "00:00:33.492 --> 00:00:38.289 line:90%" in text
    assert "01:02:03.400 --> 01:02:04.000" in text


def test_vtt_body_text_that_looks_like_a_timestamp_is_untouched(tmp_path):
    src = _touch(tmp_path / "movie.vtt",
                 "WEBVTT\n\n00:01.000 --> 00:02.000\nMeet me at 10:50.000 sharp\n")
    out = convert_to_webvtt(_track(src, "vtt"), tmp_path / "en.vtt")

    text = out.read_text(encoding="utf-8")
    assert "Meet me at 10:50.000 sharp" in text
    assert "00:00:01.000 --> 00:00:02.000" in text


# --- AppleDouble twins and one-track-per-language ---------------------------


def test_appledouble_resource_forks_are_not_subtitles(tmp_path):
    """macOS writes a `._X` binary twin for every X on a non-HFS volume.

    Nouvelle Vague shipped one beside each real .srt, so every track was
    discovered twice — and `._English.eng.srt` sorts before `English.eng.srt`,
    so the junk twin won the `en` key and became the DEFAULT rendition. Its
    content is an AppleDouble blob, not text.
    """
    video = _touch(tmp_path / "Nouvelle.Vague.2025.WORLD.mp4")
    _touch(tmp_path / "Nouvelle.Vague.2025.WORLD.srt")
    _touch(tmp_path / "._Nouvelle.Vague.2025.WORLD.srt")
    _touch(tmp_path / "Subs" / "English.eng.srt")
    _touch(tmp_path / "Subs" / "._English.eng.srt")

    tracks = discover_subtitles(video)
    assert [t.source_path.name for t in tracks] == ["English.eng.srt",
                                                    "Nouvelle.Vague.2025.WORLD.srt"]


def test_one_track_per_language_prefers_the_plain_variant(tmp_path):
    video = _touch(tmp_path / "movie.mkv")
    _touch(tmp_path / "Subs" / "English.eng.srt")
    _touch(tmp_path / "Subs" / "English SDH.eng.HI.srt")
    _touch(tmp_path / "Subs" / "Français.fre.srt")
    _touch(tmp_path / "Subs" / "Français SDH.fre.HI.srt")
    _touch(tmp_path / "Subs" / "Français Forced.fre.srt")

    tracks = discover_subtitles(video)
    assert [(t.language, t.name) for t in tracks] == [("en", "English"), ("fr", "French")]


def test_only_variant_of_a_language_is_kept_even_if_forced(tmp_path):
    """Collapsing to one per language must never drop a language entirely."""
    video = _touch(tmp_path / "movie.mkv")
    _touch(tmp_path / "Subs" / "Français Forced.fre.srt")
    _touch(tmp_path / "Subs" / "English SDH.eng.HI.srt")

    tracks = discover_subtitles(video)
    assert [(t.language, t.name) for t in tracks] == [
        ("en", "English (SDH HI)"), ("fr", "French (Forced)")]


def test_embedded_duplicates_collapse_to_one_per_language(tmp_path):
    video = _touch(tmp_path / "movie.mkv")
    probe = {"streams": [
        _sub_stream(2, "subrip", "eng", "Forced", forced=1),
        _sub_stream(3, "subrip", "eng", "SDH"),
        _sub_stream(4, "subrip", "eng"),
    ]}

    tracks = discover_subtitles(video, probe=probe)
    assert [(t.language, t.stream_index) for t in tracks] == [("en", 4)]


def test_decomposed_unicode_filenames_match_language_names(tmp_path):
    """macOS hands back NFD filenames: "Franc\u0327ais", not "Fran\u00e7ais".

    Without normalizing, the language word never matches _NAME_CODES, so it is
    mistaken for a descriptor: the track is named "French (Fran\u00e7ais)" instead
    of "French" and stops counting as the plain variant, which handed the
    per-language slot to the SDH file.
    """
    video = _touch(tmp_path / "movie.mkv")
    nfd = "Franc\u0327ais"
    assert nfd != "Fran\u00e7ais"
    _touch(tmp_path / "Subs" / f"{nfd}.fre.srt")
    _touch(tmp_path / "Subs" / f"{nfd} SDH.fre.HI.srt")
    _touch(tmp_path / "Subs" / f"{nfd} Forced.fre.srt")

    tracks = discover_subtitles(video)
    assert [(t.language, t.name) for t in tracks] == [("fr", "French")]
