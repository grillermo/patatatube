"""Sidecar subtitle discovery and WebVTT normalization.

Only text subtitle formats are supported: SRT, WebVTT, and text ``.sub``
(SubViewer/timestamp and MicroDVD frame-based). Image-based VobSub (an
``.idx`` + binary ``.sub`` pair) is rejected because it is not text.

Sidecars only exist for library rows, whose source lives on the real
filesystem next to potential ``.srt``/``.vtt``/``.sub`` siblings. Download
rows (``videos/{id}.mp4``) never have sidecars, so discovery returns ``[]``.
"""

import os
import re
from dataclasses import dataclass
from pathlib import Path

SUBTITLE_EXTENSIONS = {".srt", ".vtt", ".sub"}

# Minimal ISO-639-1 → display name map; unknown codes fall back to upper-case.
_LANG_NAMES = {
    "en": "English",
    "es": "Spanish",
    "fr": "French",
    "de": "German",
    "pt": "Portuguese",
    "it": "Italian",
    "ja": "Japanese",
    "zh": "Chinese",
    "ru": "Russian",
    "nl": "Dutch",
    "und": "Unknown",
}

_VTT_HEADER = "WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:0\n"

_MICRODVD_RE = re.compile(r"^\{(\d+)\}\{(\d+)\}(.*)$")
_SUBVIEWER_RE = re.compile(
    r"^(\d{2}:\d{2}:\d{2})[.,](\d{2,3})\s*,\s*(\d{2}:\d{2}:\d{2})[.,](\d{2,3})\s*$"
)
_SRT_TS_RE = re.compile(
    r"(\d{2}:\d{2}:\d{2}),(\d{3})\s*-->\s*(\d{2}:\d{2}:\d{2}),(\d{3})"
)


class UnsupportedSubtitleError(ValueError):
    """Raised for inputs that are not text subtitles (e.g. VobSub)."""


@dataclass
class SubtitleTrack:
    source_path: Path
    language: str
    name: str
    format: str
    default: bool = False
    forced: bool = False


def _language_name(language: str) -> str:
    return _LANG_NAMES.get(language, language.upper())


def _is_vobsub(sub_path: Path) -> bool:
    """A ``.sub`` with a sibling ``.idx`` is a binary VobSub image track."""
    return sub_path.suffix.lower() == ".sub" and sub_path.with_suffix(".idx").exists()


def discover_subtitles(video_path) -> list[SubtitleTrack]:
    """Return supported text subtitle sidecars next to ``video_path``.

    Matches ``{stem}.<ext>`` (language ``und``) and ``{stem}.{lang}.<ext>``
    where ``lang`` is the trailing dotted component when it is 2–8 letters.
    VobSub and unsupported extensions are ignored. Tracks are ordered by
    ``(language, name)``; the first non-forced track is marked ``default``.
    """
    video_path = Path(video_path)
    directory = video_path.parent
    video_stem = video_path.stem
    if not directory.exists():
        return []

    tracks: list[SubtitleTrack] = []
    for entry in directory.iterdir():
        if not entry.is_file():
            continue
        ext = entry.suffix.lower()
        if ext not in SUBTITLE_EXTENSIONS:
            continue
        full_stem = entry.name[: -len(entry.suffix)]

        if full_stem == video_stem:
            language = "und"
        elif full_stem.startswith(video_stem + "."):
            suffix = full_stem[len(video_stem) + 1 :]
            language = suffix.lower() if 2 <= len(suffix) <= 8 and suffix.isalpha() else "und"
        else:
            continue

        if _is_vobsub(entry):
            continue

        tracks.append(
            SubtitleTrack(
                source_path=entry,
                language=language,
                name=_language_name(language),
                format=ext.lstrip("."),
                forced="forced" in full_stem.lower(),
            )
        )

    tracks.sort(key=lambda t: (t.language, t.name, t.source_path.name))
    for track in tracks:
        if not track.forced:
            track.default = True
            break
    return tracks


def _format_ts(total_seconds: float) -> str:
    if total_seconds < 0:
        total_seconds = 0.0
    millis = int(round(total_seconds * 1000))
    hours, millis = divmod(millis, 3_600_000)
    minutes, millis = divmod(millis, 60_000)
    seconds, millis = divmod(millis, 1000)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}.{millis:03d}"


def _clock_to_seconds(clock: str, fraction: str) -> float:
    hours, minutes, seconds = (int(part) for part in clock.split(":"))
    frac = int(fraction) / (1000 if len(fraction) == 3 else 100)
    return hours * 3600 + minutes * 60 + seconds + frac


def _srt_body_to_vtt(text: str) -> str:
    lines: list[str] = []
    for raw in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        stripped = raw.strip()
        # Drop standalone SRT sequence numbers; they are meaningless in VTT.
        if stripped.isdigit():
            continue
        match = _SRT_TS_RE.search(raw)
        if match:
            start = _clock_to_seconds(match.group(1), match.group(2))
            end = _clock_to_seconds(match.group(3), match.group(4))
            lines.append(f"{_format_ts(start)} --> {_format_ts(end)}")
        else:
            lines.append(raw.rstrip())
    return "\n".join(lines).strip("\n")


def _subviewer_body_to_vtt(text: str) -> str:
    cues: list[str] = []
    block: list[str] = []

    def flush() -> None:
        if not block:
            return
        header = _SUBVIEWER_RE.match(block[0])
        if header:
            start = _clock_to_seconds(header.group(1), header.group(2))
            end = _clock_to_seconds(header.group(3), header.group(4))
            body = "\n".join(block[1:]).strip("\n")
            cue = f"{_format_ts(start)} --> {_format_ts(end)}"
            cues.append(f"{cue}\n{body}" if body else cue)
        block.clear()

    for raw in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if raw.strip() == "":
            flush()
        else:
            block.append(raw.rstrip())
    flush()
    return "\n\n".join(cues)


def _microdvd_body_to_vtt(text: str, fps: float) -> str:
    cues: list[str] = []
    for raw in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        match = _MICRODVD_RE.match(raw.strip())
        if not match:
            continue
        start = int(match.group(1)) / fps
        end = int(match.group(2)) / fps
        body = match.group(3).replace("|", "\n").strip("\n")
        cue = f"{_format_ts(start)} --> {_format_ts(end)}"
        cues.append(f"{cue}\n{body}" if body else cue)
    return "\n\n".join(cues)


def _detect_sub_kind(text: str) -> str:
    for raw in text.splitlines():
        stripped = raw.strip()
        if not stripped:
            continue
        if _MICRODVD_RE.match(stripped):
            return "microdvd"
        if _SUBVIEWER_RE.match(stripped):
            return "subviewer"
        break
    return "unknown"


def convert_to_webvtt(track: SubtitleTrack, output_path, fps: float | None = None) -> Path:
    """Write ``track`` as a normalized WebVTT file at ``output_path``.

    The output always begins with the WEBVTT header and an
    ``X-TIMESTAMP-MAP`` line so Apple's HLS player aligns cue times with the
    media timeline. The write is atomic (temp file + rename in the same dir).
    """
    output_path = Path(output_path)
    raw = _is_vobsub(track.source_path)
    if raw:
        raise UnsupportedSubtitleError(f"VobSub is not a text subtitle: {track.source_path}")

    text = track.source_path.read_text(encoding="utf-8", errors="replace")
    fmt = track.format.lower()

    if fmt == "vtt":
        body = text.replace("\r\n", "\n").replace("\r", "\n")
        # Strip any pre-existing header; we re-emit a canonical one below.
        body = re.sub(r"^\s*WEBVTT[^\n]*\n?", "", body, count=1)
        body = re.sub(r"^X-TIMESTAMP-MAP[^\n]*\n?", "", body, count=1)
        body = body.strip("\n")
    elif fmt == "srt":
        body = _srt_body_to_vtt(text)
    elif fmt == "sub":
        kind = _detect_sub_kind(text)
        if kind == "microdvd":
            if not fps:
                raise ValueError("MicroDVD .sub conversion requires fps")
            body = _microdvd_body_to_vtt(text, fps)
        elif kind == "subviewer":
            body = _subviewer_body_to_vtt(text)
        else:
            raise UnsupportedSubtitleError(f"Unrecognized .sub format: {track.source_path}")
    else:
        raise UnsupportedSubtitleError(f"Unsupported subtitle format: {fmt}")

    content = _VTT_HEADER + ("\n" + body + "\n" if body else "")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = output_path.with_name("." + output_path.name + ".tmp")
    tmp.write_text(content, encoding="utf-8", newline="\n")
    os.replace(tmp, output_path)
    return output_path
