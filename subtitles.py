"""Sidecar subtitle discovery and WebVTT normalization.

Only text subtitle formats are supported: SRT, WebVTT, and text ``.sub``
(SubViewer/timestamp and MicroDVD frame-based). Image-based VobSub (an
``.idx`` + binary ``.sub`` pair) is rejected because it is not text.

Sidecars only exist for library rows (real filesystem media). Real scene
releases scatter subtitles several ways, all handled here:

* Same-directory siblings: ``Movie.2025.1080p...srt`` next to the video, or
  ``Movie.srt`` next to ``Movie-subtitled.m4v``.
* A ``Subs/`` (or ``Subtitles/``) folder holding one file per language, named
  by ISO-639-2/B code (``ger.srt``, ``jpn.srt``), full name (``English.srt``),
  or ``Descriptor.code`` (``Latin American.spa.srt``, ``SDH.eng.HI.srt``,
  ``Canadian (Forced).fre.srt``).
* Nested buckets inside that folder: ``Subtitles/srt/English.srt``,
  ``Subtitles/VobSub/...`` (rejected), and per-episode TV folders
  ``Subs/{episode_stem}/3_English.srt`` (matched to the right episode by stem).

Download rows (``videos/{id}.mp4``) never have sidecars, so discovery is ``[]``.
"""

import os
import re
from dataclasses import dataclass
from pathlib import Path

SUBTITLE_EXTENSIONS = {".srt", ".vtt", ".sub"}

# Folder names that hold subtitles beside a video.
_SUBTITLE_DIR_NAMES = {"subs", "subtitles"}
# Nested folders inside a Subs/ dir that are format/purpose buckets (not a
# per-episode folder) and should always be descended into.
_GENERIC_BUCKETS = {"srt", "vtt", "sub", "vobsub", "forced", "sdh", "cc", "subs", "subtitles"}

# Trailing markers that describe a track rather than name its language. 'hi'
# here means hearing-impaired, not Hindi — this library spells Hindi 'hin', so
# treating bare 'hi' as a descriptor is safe and avoids mislabeling SDH files.
_DESCRIPTORS = {"sdh", "hi", "cc", "forced", "hearing", "impaired", "foreign", "full"}

# ISO-639-2/B (and a few 639-1) codes seen across the library → (tag, name).
# `tag` is the short language tag emitted in the HLS LANGUAGE attribute.
_ISO_CODES = {
    "eng": ("en", "English"), "en": ("en", "English"),
    "spa": ("es", "Spanish"), "es": ("es", "Spanish"),
    "fre": ("fr", "French"), "fra": ("fr", "French"), "fr": ("fr", "French"),
    "ger": ("de", "German"), "deu": ("de", "German"), "de": ("de", "German"),
    "chi": ("zh", "Chinese"), "zho": ("zh", "Chinese"), "zh": ("zh", "Chinese"),
    "jpn": ("ja", "Japanese"), "ja": ("ja", "Japanese"),
    "por": ("pt", "Portuguese"), "pt": ("pt", "Portuguese"),
    "dut": ("nl", "Dutch"), "nld": ("nl", "Dutch"), "nl": ("nl", "Dutch"),
    "gre": ("el", "Greek"), "ell": ("el", "Greek"),
    "cze": ("cs", "Czech"), "ces": ("cs", "Czech"),
    "dan": ("da", "Danish"), "fin": ("fi", "Finnish"), "hun": ("hu", "Hungarian"),
    "ita": ("it", "Italian"), "it": ("it", "Italian"),
    "kor": ("ko", "Korean"), "may": ("ms", "Malay"), "msa": ("ms", "Malay"),
    "pol": ("pl", "Polish"), "swe": ("sv", "Swedish"), "tha": ("th", "Thai"),
    "tur": ("tr", "Turkish"), "vie": ("vi", "Vietnamese"), "ara": ("ar", "Arabic"),
    "heb": ("he", "Hebrew"), "hin": ("hi", "Hindi"), "ind": ("id", "Indonesian"),
    "nor": ("no", "Norwegian"), "nob": ("nb", "Norwegian Bokmal"),
    "rus": ("ru", "Russian"), "ukr": ("uk", "Ukrainian"), "tel": ("te", "Telugu"),
    "tam": ("ta", "Tamil"), "fil": ("fil", "Filipino"), "slv": ("sl", "Slovenian"),
    "slo": ("sk", "Slovak"), "slk": ("sk", "Slovak"), "rum": ("ro", "Romanian"),
    "ron": ("ro", "Romanian"), "glg": ("gl", "Galician"), "baq": ("eu", "Basque"),
    "eus": ("eu", "Basque"), "hrv": ("hr", "Croatian"), "mal": ("ml", "Malayalam"),
    "lit": ("lt", "Lithuanian"), "lav": ("lv", "Latvian"), "est": ("et", "Estonian"),
    "cat": ("ca", "Catalan"), "bul": ("bg", "Bulgarian"), "kan": ("kn", "Kannada"),
}

# Full language names → tag (for files named "English.srt", "Français.fre.srt").
_NAME_CODES = {
    "english": "en", "spanish": "es", "french": "fr", "français": "fr",
    "francais": "fr", "german": "de", "deutsch": "de", "chinese": "zh",
    "japanese": "ja", "portuguese": "pt", "dutch": "nl", "italian": "it",
    "russian": "ru", "korean": "ko", "arabic": "ar", "hebrew": "he",
    "español": "es", "espanol": "es",
}

_TAG_NAMES = {tag: name for tag, name in _ISO_CODES.values()}
_TAG_NAMES["und"] = "Unknown"

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


def _language_name(tag: str) -> str:
    return _TAG_NAMES.get(tag, tag.upper())


def _is_vobsub(sub_path: Path) -> bool:
    """A ``.sub`` with a sibling ``.idx`` is a binary VobSub image track."""
    return sub_path.suffix.lower() == ".sub" and sub_path.with_suffix(".idx").exists()


_TOKEN_SPLIT = re.compile(r"[.\-_\s()\[\]]+")


def _tokenize(stem: str) -> list[str]:
    return [t for t in _TOKEN_SPLIT.split(stem) if t]


def _describe_from_name(stem: str) -> tuple[str, str, bool]:
    """Parse a Subs-folder filename stem into (tag, display_name, forced).

    Scans tokens right-to-left for a language code or name, skipping trailing
    descriptor markers (SDH/HI/Forced/region words). Leftover descriptor words
    are folded into the display name so same-language variants stay distinct
    (e.g. "Spanish (Latin American)" vs "Spanish (European)").
    """
    tokens = _tokenize(stem)
    lower = [t.lower() for t in tokens]
    forced = any(t == "forced" for t in lower)

    tag = "und"
    lang_index = None
    for i in range(len(tokens) - 1, -1, -1):
        t = lower[i]
        if t in _DESCRIPTORS or t.isdigit():
            continue
        if t in _ISO_CODES:
            tag, lang_index = _ISO_CODES[t][0], i
            break
        if t in _NAME_CODES:
            tag, lang_index = _NAME_CODES[t], i
            break

    # Descriptor/region words other than the language token, for a unique name.
    extras = [
        tokens[i]
        for i in range(len(tokens))
        if i != lang_index and not lower[i].isdigit()
        and lower[i] not in _NAME_CODES and lower[i] not in _ISO_CODES
    ]
    base = _language_name(tag)
    name = f"{base} ({' '.join(extras)})" if extras else base
    return tag, name, forced


def _sibling_tag(video_stem: str, sub_stem: str):
    """If ``sub_stem`` is a same-dir sidecar for ``video_stem``, return its tag.

    Handles exact match, ``{video}.{code}`` sidecars, and the ``X`` vs
    ``X-subtitled`` prefix relationship. Returns ``None`` when unrelated.
    """
    if sub_stem == video_stem:
        return "und"
    for longer, shorter in ((sub_stem, video_stem), (video_stem, sub_stem)):
        if longer.startswith(shorter) and len(longer) > len(shorter):
            rest = longer[len(shorter):]
            if rest[0] in "._- ":
                token = rest.lstrip("._- ").split(".")[0].lower()
                return _ISO_CODES.get(token, (None,))[0] or _NAME_CODES.get(token) or "und"
    return None


def _list_files(directory: Path):
    try:
        return [e for e in directory.iterdir() if e.is_file()]
    except OSError:
        return []


def _is_subtitle_dir(name: str) -> bool:
    lower = name.lower()
    # Exact "Subs"/"Subtitles", or a release-prefixed variant whose final
    # dotted token is one of those (e.g. "Dragon.Ball...F.Subtitles").
    return lower in _SUBTITLE_DIR_NAMES or lower.split(".")[-1] in _SUBTITLE_DIR_NAMES


def _subtitle_files(video_dir: Path, video_stem: str):
    """Yield subtitle files in ``Subs``/``Subtitles`` folders next to the video.

    Descends one level into generic buckets (``srt/``, ``VobSub/``) and into a
    per-episode folder whose name matches ``video_stem``.
    """
    for child in sorted(p for p in video_dir.iterdir() if p.is_dir()):
        if not _is_subtitle_dir(child.name):
            continue
        yield from _list_files(child)
        for nested in sorted(p for p in child.iterdir() if p.is_dir()):
            if nested.name == video_stem or nested.name.lower() in _GENERIC_BUCKETS:
                yield from _list_files(nested)


def discover_subtitles(video_path) -> list[SubtitleTrack]:
    """Return supported text subtitle tracks for ``video_path``.

    Searches same-directory siblings and adjacent ``Subs``/``Subtitles``
    folders (see module docstring). VobSub and unsupported extensions are
    ignored. Tracks are ordered by ``(tag, name)``; English (else the first
    non-forced track) is marked ``default``.
    """
    video_path = Path(video_path)
    video_dir = video_path.parent
    video_stem = video_path.stem
    if not video_dir.exists():
        return []

    seen: set[Path] = set()
    tracks: list[SubtitleTrack] = []

    def add(entry: Path, tag: str, name: str, forced: bool) -> None:
        if entry in seen or entry.suffix.lower() not in SUBTITLE_EXTENSIONS:
            return
        if _is_vobsub(entry):
            return
        seen.add(entry)
        tracks.append(SubtitleTrack(entry, tag, name, entry.suffix.lstrip("."), forced=forced))

    for entry in _list_files(video_dir):
        if entry.suffix.lower() not in SUBTITLE_EXTENSIONS:
            continue
        tag = _sibling_tag(video_stem, entry.name[: -len(entry.suffix)])
        if tag is None:
            continue
        name = _language_name(tag) if tag != "und" else "Subtitles"
        add(entry, tag, name, forced="forced" in entry.stem.lower())

    for entry in _subtitle_files(video_dir, video_stem):
        tag, name, forced = _describe_from_name(entry.name[: -len(entry.suffix)])
        add(entry, tag, name, forced)

    tracks.sort(key=lambda t: (t.language, t.name, t.source_path.name))
    _mark_default(tracks)
    return tracks


def _mark_default(tracks: list[SubtitleTrack]) -> None:
    for track in tracks:
        if track.language == "en" and not track.forced:
            track.default = True
            return
    for track in tracks:
        if not track.forced:
            track.default = True
            return


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
