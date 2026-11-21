"""ffprobe → iPad-compatible conversion plan, shared by HLS packaging."""

import os
from dataclasses import dataclass, field
from pathlib import Path

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
    audio_compat = all(
        audio_streams[index].get("codec_name") in _COMPAT_AUDIO
        for index in audio_indices
    )

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


def probe_source(path: Path) -> dict:
    """Indirection point so tests can fake probes without ffprobe installed.

    Imported here, not at module top: downloader -> services -> hls imports
    this module, so a top-level import would be circular.
    """
    from downloader import _probe_media

    return _probe_media(path)
