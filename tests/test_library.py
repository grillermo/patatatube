from pathlib import Path

import pytest

import library


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
    plan = library.plan_conversion(p)
    assert plan.passthrough


def test_passthrough_transcodes_a_selected_incompatible_audio_stream():
    plan = library.plan_conversion(probe(
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
    assert plan.audio_args == ["-c:a:0", "copy"]


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
    assert plan.audio_args == ["-c:a:0", "aac", "-b:a:0", "128k", "-ac:a:0", "2"]


def test_no_audio_stream():
    plan = library.plan_conversion(probe(with_audio=False))
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
    assert library.allowed_audio_langs() == ["eng", "spa"]
    monkeypatch.setenv("LIBRARY_AUDIO_LANGS", " ENG , jpn,")
    assert library.allowed_audio_langs() == ["eng", "jpn"]


def test_audio_track_list():
    assert library.audio_track_list(multi_probe()) == [
        {"lang": "cat", "title": ""},
        {"lang": "eng", "title": ""},
        {"lang": "spa", "title": "Latin American"},
        {"lang": "spa", "title": "European"},
    ]


def test_audio_track_list_untagged():
    assert library.audio_track_list(probe()) == [{"lang": "und", "title": ""}]


def test_select_audio_indices_allowlist():
    assert library.select_audio_indices(multi_probe(), ["eng", "spa"]) == [1, 2, 3]


def test_select_audio_indices_fallback_first():
    assert library.select_audio_indices(multi_probe(), ["jpn"]) == [0]


def test_select_audio_indices_no_audio():
    assert library.select_audio_indices(probe(with_audio=False), ["eng"]) == []


def test_plan_conversion_multi_track(monkeypatch):
    monkeypatch.delenv("LIBRARY_AUDIO_LANGS", raising=False)
    plan = library.plan_conversion(multi_probe())
    assert not plan.passthrough
    assert plan.audio_maps == [1, 2, 3]
    assert plan.audio_langs == ["eng", "spa", "spa"]
    assert plan.audio_args == [
        "-c:a:0", "copy",
        "-c:a:1", "copy",
        "-c:a:2", "aac", "-b:a:2", "128k", "-ac:a:2", "2",
    ]


def test_plan_conversion_explicit_indices():
    plan = library.plan_conversion(multi_probe(), audio_indices=[2])
    assert plan.audio_maps == [2]
    assert plan.audio_langs == ["spa"]
    assert plan.audio_args == ["-c:a:0", "copy"]


def test_plan_conversion_no_audio_keeps_an():
    plan = library.plan_conversion(probe(with_audio=False))
    assert plan.audio_maps == []
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


def test_reconversion_replaces_the_tracked_output(fresh_db, tmp_path, monkeypatch):
    import db

    vid, src = lib_row(tmp_path)
    monkeypatch.setattr(library, "probe_source", lambda p: probe())
    output = tmp_path / "ep.mp4"
    output.write_bytes(b"old")
    version = db.get_video_versions(vid)[0]
    db.set_library_state(vid, "done", converted_path=str(output), version_id=version["id"])

    def fake_run(cmd):
        Path(cmd[-1]).write_bytes(b"replacement")

    monkeypatch.setattr(library, "_run_ffmpeg", fake_run)
    library.convert_library_video(vid)

    assert output.read_bytes() == b"replacement"
    assert db.get_video_versions(vid)[0]["converted_path"] == str(output)
    assert not (tmp_path / "ep.ios.mp4").exists()


def test_convert_maps_allowlisted_tracks_and_records_langs(fresh_db, tmp_path, monkeypatch):
    import db
    monkeypatch.delenv("LIBRARY_AUDIO_LANGS", raising=False)
    vid, src = lib_row(tmp_path)
    monkeypatch.setattr(library, "probe_source", lambda p: multi_probe())
    calls = []

    def fake_run(cmd):
        calls.append(cmd)
        Path(cmd[-1]).write_bytes(b"converted")

    monkeypatch.setattr(library, "_run_ffmpeg", fake_run)
    invalidated = []
    import hls
    monkeypatch.setattr(hls, "invalidate", invalidated.append)
    library.convert_library_video(vid)

    cmd = calls[0]
    maps = [cmd[i + 1] for i, arg in enumerate(cmd) if arg == "-map"]
    assert maps == ["0:v:0", "0:a:1", "0:a:2", "0:a:3"]
    version = db.get_video_versions(vid)[0]
    assert version["converted_langs"] == '["eng", "spa", "spa"]'
    assert invalidated == [vid]


def test_convert_passthrough_records_all_source_langs(fresh_db, tmp_path, monkeypatch):
    import db
    vid, src = lib_row(tmp_path, "ep.mp4")
    monkeypatch.setattr(library, "probe_source", lambda p: probe(
        container="mov,mp4,m4a,3gp,3g2,mj2", vcodec="h264",
        audio=[("aac", "cat", ""), ("aac", "eng", "")]))
    library.convert_library_video(vid)
    version = db.get_video_versions(vid)[0]
    assert version["status"] == "done"
    assert version["converted_langs"] == '["cat", "eng"]'


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
                "plex_rating_key": path.stem, "show_rating_key": None}

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


def test_scan_library_filters_versions_per_file(fresh_db, tmp_path, monkeypatch):
    import db
    import plex
    real = tmp_path / "1080.mkv"
    real.write_bytes(b"x")
    converted = tmp_path / "1080.mp4"  # our own conversion output, must be excluded
    converted.write_bytes(b"x")
    missing = tmp_path / "4k.mkv"       # never created, must be excluded

    item = {
        "source_path": str(converted), "title": "Akira", "classification": "movies",
        "show_title": None, "season": None, "episode": None, "summary": None,
        "plex_rating_key": "42", "show_rating_key": None,
        "versions": [
            {"source_path": str(converted), "label": "1080p (converted)"},
            {"source_path": str(real), "label": "1080p"},
            {"source_path": str(missing), "label": "4K"},
        ],
    }
    monkeypatch.setattr(plex, "fetch_library_items", lambda: [item])
    # Register `converted` as a prior conversion output so it lands in get_converted_paths.
    seed_src = tmp_path / "seed.mkv"
    seed_src.write_bytes(b"x")
    vid0, _ = db.upsert_library_video(
        {"source_path": str(seed_src), "title": "seed", "classification": "movies",
         "show_title": None, "season": None, "episode": None, "summary": None,
         "plex_rating_key": "seed", "show_rating_key": None})
    db.set_library_state(vid0, "done", converted_path=str(converted))

    result = library.scan_library()
    assert result["added"] == 1
    movie = next(v for v in db.get_all_videos("movies") if v["plex_rating_key"] == "42")
    paths = [v["source_path"] for v in db.get_video_versions(movie["id"])]
    assert paths == [str(real)]  # converted sibling + missing file both dropped


def test_scan_probes_missing_audio_langs(fresh_db, tmp_path, monkeypatch):
    import db
    import plex
    src = tmp_path / "a.mkv"
    src.write_bytes(b"x")
    item = {"source_path": str(src), "title": "a", "classification": "movies",
            "show_title": None, "season": None, "episode": None, "summary": None,
            "plex_rating_key": "a", "show_rating_key": None}
    monkeypatch.setattr(plex, "fetch_library_items", lambda: [item])
    probes = []

    def fake_probe(path):
        probes.append(str(path))
        return multi_probe()

    monkeypatch.setattr(library, "probe_source", fake_probe)
    library.scan_library()
    movie = db.get_all_videos("movies")[0]
    version = db.get_video_versions(movie["id"])[0]
    import json
    assert [t["lang"] for t in json.loads(version["audio_langs"])] == ["cat", "eng", "spa", "spa"]
    assert probes == [str(src)]

    library.scan_library()  # second scan: already probed, no new ffprobe call
    assert probes == [str(src)]


def test_scan_survives_probe_failure(fresh_db, tmp_path, monkeypatch):
    import db
    import plex
    src = tmp_path / "a.mkv"
    src.write_bytes(b"x")
    item = {"source_path": str(src), "title": "a", "classification": "movies",
            "show_title": None, "season": None, "episode": None, "summary": None,
            "plex_rating_key": "a", "show_rating_key": None}
    monkeypatch.setattr(plex, "fetch_library_items", lambda: [item])

    def boom(path):
        raise RuntimeError("ffprobe missing")

    monkeypatch.setattr(library, "probe_source", boom)
    result = library.scan_library()
    assert result["added"] == 1  # scan not aborted
    movie = db.get_all_videos("movies")[0]
    assert db.get_video_versions(movie["id"])[0]["audio_langs"] is None  # retried next scan
