"""HLS VOD packaging with WebVTT subtitle sidecars.

Segments are fMP4. Video/audio are stream-copied when the source is already
iPad/HLS-compatible (H.264/AAC per ``library.plan_conversion``); incompatible
library sources transcode only the offending stream(s). Subtitle sidecars are
normalized to WebVTT and exposed as an ``EXT-X-MEDIA:TYPE=SUBTITLES`` group.

All output for a video is constrained under ``HLS_DIR / str(video_id)``.
"""

import math
import os
import shutil
import subprocess
import traceback
from dataclasses import dataclass, field
from pathlib import Path

import db
from library import audio_track_list, plan_conversion, probe_source, select_audio_indices
from subtitles import (
    SubtitleTrack,
    UnsupportedSubtitleError,
    convert_to_webvtt,
    discover_subtitles,
)

HLS_DIR = Path(os.getenv("HLS_DIR", "data/hls"))
FFMPEG_BIN = os.getenv("FFMPEG_BIN", "ffmpeg")
HLS_TIME = int(os.getenv("HLS_TIME", "6"))
SUBTITLE_GROUP = "subs"
DEFAULT_BANDWIDTH = 2_000_000


@dataclass
class HlsPackage:
    video_id: int
    out_dir: Path
    master_path: Path
    tracks: list[SubtitleTrack] = field(default_factory=list)


def hls_dir_for(video_id, output_root: Path | None = None) -> Path:
    return (output_root or HLS_DIR) / str(video_id)


def invalidate(video_id) -> None:
    """Drop stale HLS output so the next play repackages the current choice."""
    shutil.rmtree(hls_dir_for(video_id), ignore_errors=True)
    db.set_hls_status(video_id, "none")


def _first_stream(probe: dict, kind: str) -> dict | None:
    for stream in probe.get("streams", []):
        if stream.get("codec_type") == kind:
            return stream
    return None


def _duration(probe: dict) -> float:
    try:
        return float(probe.get("format", {}).get("duration") or 0.0)
    except (TypeError, ValueError):
        return 0.0


def _frame_rate(probe: dict) -> float:
    video = _first_stream(probe, "video") or {}
    rate = video.get("r_frame_rate") or video.get("avg_frame_rate") or ""
    if "/" in rate:
        num, _, den = rate.partition("/")
        try:
            den_f = float(den)
            return float(num) / den_f if den_f else 0.0
        except ValueError:
            return 0.0
    try:
        return float(rate)
    except ValueError:
        return 0.0


def _bandwidth(probe: dict) -> int:
    fmt_rate = probe.get("format", {}).get("bit_rate")
    video = _first_stream(probe, "video") or {}
    for candidate in (fmt_rate, video.get("bit_rate")):
        try:
            value = int(candidate)
            if value > 0:
                return value
        except (TypeError, ValueError):
            continue
    return DEFAULT_BANDWIDTH


def build_ffmpeg_command(source: Path, out_dir: Path, plan) -> list[str]:
    """Construct the fMP4 HLS ffmpeg command for a conversion ``plan``.

    Passthrough sources use a global ``-c copy``; otherwise the per-stream
    args from ``plan_conversion`` (which transcode only incompatible streams).
    Audio maps come from the plan, which limits HLS output to one track.
    """
    if plan.passthrough:
        codec_args = ["-c", "copy"]
    else:
        codec_args = [*plan.video_args, *plan.audio_args]
    map_args = ["-map", "0:v:0"]
    for index in plan.audio_maps:
        map_args += ["-map", f"0:a:{index}"]
    return [
        FFMPEG_BIN, "-hide_banner", "-loglevel", "error", "-y",
        "-i", str(source),
        *map_args,
        *codec_args,
        "-f", "hls",
        "-hls_playlist_type", "vod",
        "-hls_time", str(HLS_TIME),
        "-hls_segment_type", "fmp4",
        "-hls_fmp4_init_filename", "init.mp4",
        "-hls_segment_filename", str(out_dir / "segment_%05d.m4s"),
        str(out_dir / "video.m3u8"),
    ]


def _run_ffmpeg(cmd: list[str]) -> None:
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if proc.returncode != 0:
        raise RuntimeError((proc.stdout or "").strip() or "ffmpeg failed while packaging HLS")


def _write(path: Path, text: str) -> None:
    """Atomic write within the target directory."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name("." + path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8", newline="\n")
    os.replace(tmp, path)


def _subtitle_media_playlist(duration: float, vtt_name: str) -> str:
    target = max(1, math.ceil(duration)) if duration else 1
    return (
        "#EXTM3U\n"
        "#EXT-X-VERSION:7\n"
        f"#EXT-X-TARGETDURATION:{target}\n"
        "#EXT-X-MEDIA-SEQUENCE:0\n"
        "#EXT-X-PLAYLIST-TYPE:VOD\n"
        f"#EXTINF:{duration:.3f},\n"
        f"{vtt_name}\n"
        "#EXT-X-ENDLIST\n"
    )


def _subtitle_keys(tracks: list[SubtitleTrack]) -> list[str]:
    """Unique on-disk key per track. Multiple tracks can share a language
    (e.g. Latin American + European Spanish both 'es'), so key by language
    with a numeric suffix on collision to avoid clobbering playlist files."""
    keys: list[str] = []
    used: dict[str, int] = {}
    for track in tracks:
        base = track.language or "und"
        count = used.get(base, 0)
        used[base] = count + 1
        keys.append(base if count == 0 else f"{base}-{count + 1}")
    return keys


def _escape_attr(value: str) -> str:
    # Playlist quoted-string attributes cannot contain a double quote.
    return value.replace('"', "'")


def _master_playlist(probe: dict, tracks: list[SubtitleTrack], keys: list[str]) -> str:
    lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"]
    for track, key in zip(tracks, keys):
        lines.append(
            "#EXT-X-MEDIA:TYPE=SUBTITLES,"
            f'GROUP-ID="{SUBTITLE_GROUP}",'
            f'LANGUAGE="{track.language}",'
            f'NAME="{_escape_attr(track.name)}",'
            f"DEFAULT={'YES' if track.default else 'NO'},"
            "AUTOSELECT=YES,"
            f"FORCED={'YES' if track.forced else 'NO'},"
            f'URI="subtitles/{key}.m3u8"'
        )

    video = _first_stream(probe, "video") or {}
    width = int(video.get("width") or 0)
    height = int(video.get("height") or 0)
    attrs = [f"BANDWIDTH={_bandwidth(probe)}"]
    if width and height:
        attrs.append(f"RESOLUTION={width}x{height}")
    if tracks:
        attrs.append(f'SUBTITLES="{SUBTITLE_GROUP}"')
    lines.append("#EXT-X-STREAM-INF:" + ",".join(attrs))
    lines.append("video.m3u8")
    return "\n".join(lines) + "\n"


def build_hls_package(
    video_id: int,
    source_path,
    output_root: Path | None = None,
    *,
    probe: dict | None = None,
    subtitles: list[SubtitleTrack] | None = None,
    run_ffmpeg=_run_ffmpeg,
    audio_lang: str | None = None,
) -> HlsPackage:
    """Probe, segment, normalize subtitles, and write the multivariant playlist."""
    source = Path(source_path)
    out_dir = hls_dir_for(video_id, output_root)
    out_dir.mkdir(parents=True, exist_ok=True)

    probe = probe if probe is not None else probe_source(source)
    tracks = audio_track_list(probe)
    audio_indices: list[int] | None = None
    if audio_lang:
        match = next((index for index, track in enumerate(tracks) if track["lang"] == audio_lang), None)
        audio_indices = [match] if match is not None else None
    if audio_indices is None:
        audio_indices = select_audio_indices(probe, [])
    plan = plan_conversion(probe, audio_indices=audio_indices)
    run_ffmpeg(build_ffmpeg_command(source, out_dir, plan))

    discovered = subtitles if subtitles is not None else discover_subtitles(source)
    duration = _duration(probe)
    fps = _frame_rate(probe) or 24.0

    # Only tracks that actually convert reach the master playlist, so a
    # malformed sidecar among dozens never leaves a dangling URI reference.
    tracks: list[SubtitleTrack] = []
    keys: list[str] = []
    for track, key in zip(discovered, _subtitle_keys(discovered)):
        try:
            convert_to_webvtt(track, out_dir / "subtitles" / f"{key}.vtt", fps=fps)
        except (UnsupportedSubtitleError, ValueError, OSError):
            continue
        _write(
            out_dir / "subtitles" / f"{key}.m3u8",
            _subtitle_media_playlist(duration, f"{key}.vtt"),
        )
        tracks.append(track)
        keys.append(key)

    master_path = out_dir / "master.m3u8"
    _write(master_path, _master_playlist(probe, tracks, keys))
    return HlsPackage(video_id=video_id, out_dir=out_dir, master_path=master_path, tracks=tracks)


HLS_CONTENT_TYPES = {
    ".m3u8": "application/vnd.apple.mpegurl",
    ".vtt": "text/vtt",
    ".m4s": "video/iso.segment",
    ".mp4": "video/mp4",
}


def safe_asset_path(video_id, asset_path: str, output_root: Path | None = None) -> Path | None:
    """Resolve ``asset_path`` under the video's HLS dir, rejecting traversal."""
    out_dir = hls_dir_for(video_id, output_root).resolve()
    target = (out_dir / asset_path).resolve()
    if target != out_dir and out_dir not in target.parents:
        return None
    return target


def prepare(video_id: int, source_path) -> None:
    """Background task: build the HLS package and record readiness in the DB.

    Runs synchronously (FastAPI runs sync background tasks on a thread). On
    failure the status reverts to 'none' so a later request retries, mirroring
    the library-convert path which never leaves a row wedged in 'converting'.
    """
    try:
        video = db.get_video(video_id)
        audio_lang = video.get("audio_lang") if video else None
        build_hls_package(video_id, source_path, audio_lang=audio_lang)
        db.set_hls_status(video_id, "done")
    except Exception:  # noqa: BLE001 - background task, must not raise
        traceback.print_exc()
        db.set_hls_status(video_id, "none")
