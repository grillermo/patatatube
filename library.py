"""Library scanning and on-demand iPad conversion for /Volumes/Media files."""

import json
import os
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

import db
import plex
import version_namer
from downloader import _probe_media

# iPad mini 6th gen panel long edge; wider sources get downscaled.
IPAD_MAX_WIDTH = 2266
_COMPAT_VIDEO = {"h264", "hevc"}
_COMPAT_AUDIO = {"aac", "ac3", "eac3"}

_REENCODE_VIDEO_ARGS = [
    "-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
    "-pix_fmt", "yuv420p", "-profile:v", "high", "-tag:v", "avc1",
]
_SCALE_ARGS = ["-vf", f"scale='min({IPAD_MAX_WIDTH},iw)':-2"]


@dataclass
class ConversionPlan:
    passthrough: bool
    video_args: list[str] = field(default_factory=list)
    audio_args: list[str] = field(default_factory=list)
    audio_maps: list[int] = field(default_factory=list)
    audio_langs: list[str] = field(default_factory=list)


def _first_stream(probe: dict, stream_type: str) -> dict | None:
    for stream in probe.get("streams", []):
        if stream.get("codec_type") == stream_type:
            return stream
    return None


def allowed_audio_langs() -> list[str]:
    """Languages kept in conversions, read per-call for environment changes."""
    raw = os.getenv("LIBRARY_AUDIO_LANGS", "eng,spa")
    return [part.strip().lower() for part in raw.split(",") if part.strip()]


def _audio_streams(probe: dict) -> list[dict]:
    return [stream for stream in probe.get("streams", []) if stream.get("codec_type") == "audio"]


def audio_track_list(probe: dict) -> list[dict]:
    """Return language and title metadata for each audio stream in stream order."""
    tracks = []
    for stream in _audio_streams(probe):
        tags = stream.get("tags") or {}
        tracks.append({
            "lang": (tags.get("language") or "und").lower(),
            "title": tags.get("title") or "",
        })
    return tracks


def select_audio_indices(probe: dict, langs: list[str]) -> list[int]:
    """Select allowlisted audio-stream indices, falling back to the first stream."""
    streams = _audio_streams(probe)
    if not streams:
        return []
    selected = [
        index for index, track in enumerate(audio_track_list(probe))
        if track["lang"] in langs
    ]
    return selected or [0]


def plan_conversion(probe: dict, audio_indices: list[int] | None = None) -> ConversionPlan:
    video = _first_stream(probe, "video")
    audio = _first_stream(probe, "audio")
    if not video:
        raise RuntimeError("No video stream found")

    if audio_indices is None:
        audio_indices = select_audio_indices(probe, allowed_audio_langs())
    audio_streams = _audio_streams(probe)
    tracks = audio_track_list(probe)
    audio_langs = [tracks[index]["lang"] for index in audio_indices]

    container = probe.get("format", {}).get("format_name", "")
    is_mp4 = "mp4" in container
    vcodec = video.get("codec_name")
    width = int(video.get("width") or 0)
    fits = width <= IPAD_MAX_WIDTH
    video_compat = vcodec in _COMPAT_VIDEO and fits
    hevc_tagged = vcodec != "hevc" or video.get("codec_tag_string") == "hvc1"
    audio_compat = audio is None or audio.get("codec_name") in _COMPAT_AUDIO

    if is_mp4 and video_compat and hevc_tagged and audio_compat:
        return ConversionPlan(passthrough=True, audio_maps=audio_indices, audio_langs=audio_langs)

    if video_compat:
        tag = "hvc1" if vcodec == "hevc" else "avc1"
        video_args = ["-c:v", "copy", "-tag:v", tag]
    else:
        video_args = list(_REENCODE_VIDEO_ARGS)
        if not fits:
            video_args += _SCALE_ARGS

    if not audio_indices:
        audio_args = ["-an"]
    else:
        audio_args = []
        for output_index, input_index in enumerate(audio_indices):
            if audio_streams[input_index].get("codec_name") in _COMPAT_AUDIO:
                audio_args += [f"-c:a:{output_index}", "copy"]
            else:
                audio_args += [
                    f"-c:a:{output_index}", "aac",
                    f"-b:a:{output_index}", "128k",
                    f"-ac:a:{output_index}", "2",
                ]

    return ConversionPlan(
        passthrough=False,
        video_args=video_args,
        audio_args=audio_args,
        audio_maps=audio_indices,
        audio_langs=audio_langs,
    )


def conversion_target(source: Path) -> Path:
    """Sibling mp4 path for a converted file; .ios.mp4 on name collision."""
    target = source.with_suffix(".mp4")
    if target == source or target.exists():
        target = source.with_suffix(".ios.mp4")
    return target


FFMPEG_BIN = os.getenv("FFMPEG_BIN", "ffmpeg")


def probe_source(path: Path) -> dict:
    """Indirection point so tests can fake probes without ffprobe installed."""
    return _probe_media(path)


def _run_ffmpeg(cmd: list[str]) -> None:
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if proc.returncode != 0:
        raise RuntimeError((proc.stdout or "").strip() or "ffmpeg failed while converting")


def convert_library_video(video_id: int) -> None:
    """Convert a library row's source to an iPad-ready sibling mp4.

    Runs synchronously (FastAPI executes sync background tasks on a thread).
    Failures set status back to 'unconverted' with error_msg; the row is never deleted.
    """
    video = db.get_video(video_id)
    if not video or video.get("source") != "library":
        return
    version = db.get_video_version(video_id)
    if not version:
        return

    source = Path(version["source_path"])
    tmp = None
    try:
        if not source.exists():
            raise RuntimeError(f"source file missing: {source}")

        probe = probe_source(source)
        plan = plan_conversion(probe)
        if plan.passthrough:
            db.set_library_state(
                video_id, "done",
                converted_langs=json.dumps([t["lang"] for t in audio_track_list(probe)]),
                version_id=version["id"],
            )
            return

        target = conversion_target(source)
        # Hidden temp file in the same directory: invisible to Plex and our scans,
        # and os.replace stays atomic because it is on the same volume.
        tmp = target.with_name("." + target.name)
        map_args = ["-map", "0:v:0"]
        for index in plan.audio_maps:
            map_args += ["-map", f"0:a:{index}"]
        cmd = [
            FFMPEG_BIN, "-hide_banner", "-loglevel", "error", "-y",
            "-i", str(source),
            *map_args, "-sn", "-dn",
            *plan.video_args, *plan.audio_args,
            "-movflags", "+faststart",
            str(tmp),
        ]
        _run_ffmpeg(cmd)
        os.replace(tmp, target)
        db.set_library_state(
            video_id, "done",
            converted_path=str(target),
            converted_langs=json.dumps(plan.audio_langs),
            version_id=version["id"],
        )
        # The streamable file changed; any packaged HLS output is stale.
        # Function-level import avoids hls importing library at module load.
        import hls
        hls.invalidate(video_id)
    except Exception as exc:  # noqa: BLE001 - background task, must not raise
        if tmp is not None:
            Path(tmp).unlink(missing_ok=True)
        db.set_library_state(video_id, "unconverted", error_msg=str(exc), version_id=version["id"])


def _relabel_versions(versions: list[dict]) -> None:
    """Give a multi-version movie human-distinguishable labels via the LLM, in place.

    Single-version items keep their simple resolution label. Idempotent: if every
    version's source_path already has a stored label, reuse it instead of re-billing
    the LLM (and re-risking its hard-fail) on each rescan.
    """
    if len(versions) < 2:
        return
    source_paths = [v["source_path"] for v in versions]
    existing = db.get_version_labels(source_paths)
    if all(path in existing for path in source_paths):
        for v in versions:
            v["label"] = existing[v["source_path"]]
        return
    labels = version_namer.label_versions([Path(p).name for p in source_paths])
    for v, label in zip(versions, labels):
        v["label"] = label


def _probe_missing_audio_langs(video_id: int) -> None:
    """Fill missing per-version audio metadata without aborting a library scan."""
    for version in db.get_video_versions(video_id):
        if version.get("audio_langs") is not None:
            continue
        try:
            probe = probe_source(Path(version["source_path"]))
        except Exception:  # noqa: BLE001 - scan must survive a bad file
            continue
        db.set_version_audio_langs(version["id"], json.dumps(audio_track_list(probe)))


def scan_library() -> dict:
    """Upsert every Plex library item into the videos table. Metadata only, no ffmpeg.

    Versions are filtered per file: our own converted siblings (in
    get_converted_paths) and versions whose files are missing are dropped, so a
    rescan never re-imports a converted output as a selectable version. An item
    with no surviving version is skipped.
    """
    items = plex.fetch_library_items()
    converted = db.get_converted_paths()
    added = updated = skipped = 0
    for item in items:
        raw_versions = item.get("versions") or (
            [{"source_path": item["source_path"], "label": "Version 1"}]
            if item.get("source_path")
            else []
        )
        versions = [
            v
            for v in raw_versions
            if v.get("source_path")
            and v["source_path"] not in converted
            and Path(v["source_path"]).exists()
        ]
        if not versions:
            skipped += 1
            continue

        _relabel_versions(versions)
        item = {**item, "versions": versions, "source_path": versions[0]["source_path"]}
        if not item.get("added_at"):
            mtimes = []
            for v in versions:
                try:
                    mtimes.append(int(Path(v["source_path"]).stat().st_mtime))
                except OSError:
                    pass
            item["added_at"] = min(mtimes) if mtimes else None
        video_id, status = db.upsert_library_video(item)
        if status == "created":
            added += 1
        elif status == "updated":
            updated += 1
        else:  # tombstoned
            skipped += 1
            continue
        _probe_missing_audio_langs(video_id)
    return {"added": added, "updated": updated, "skipped": skipped}
