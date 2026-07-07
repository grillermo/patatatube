"""Library scanning and on-demand iPad conversion for /Volumes/Media files."""

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


def _first_stream(probe: dict, stream_type: str) -> dict | None:
    for stream in probe.get("streams", []):
        if stream.get("codec_type") == stream_type:
            return stream
    return None


def plan_conversion(probe: dict) -> ConversionPlan:
    video = _first_stream(probe, "video")
    audio = _first_stream(probe, "audio")
    if not video:
        raise RuntimeError("No video stream found")

    container = probe.get("format", {}).get("format_name", "")
    is_mp4 = "mp4" in container
    vcodec = video.get("codec_name")
    width = int(video.get("width") or 0)
    fits = width <= IPAD_MAX_WIDTH
    video_compat = vcodec in _COMPAT_VIDEO and fits
    hevc_tagged = vcodec != "hevc" or video.get("codec_tag_string") == "hvc1"
    audio_compat = audio is None or audio.get("codec_name") in _COMPAT_AUDIO

    if is_mp4 and video_compat and hevc_tagged and audio_compat:
        return ConversionPlan(passthrough=True)

    if video_compat:
        tag = "hvc1" if vcodec == "hevc" else "avc1"
        video_args = ["-c:v", "copy", "-tag:v", tag]
    else:
        video_args = list(_REENCODE_VIDEO_ARGS)
        if not fits:
            video_args += _SCALE_ARGS

    if audio is None:
        audio_args = ["-an"]
    elif audio_compat:
        audio_args = ["-c:a", "copy"]
    else:
        audio_args = ["-c:a", "aac", "-b:a", "128k", "-ac", "2"]

    return ConversionPlan(passthrough=False, video_args=video_args, audio_args=audio_args)


def conversion_target(source: Path) -> Path:
    """Sibling mp4 path for a converted file; .ios.mp4 on name collision."""
    target = source.with_suffix(".mp4")
    if target == source or target.exists():
        target = source.with_suffix(".ios.mp4")
    return target
