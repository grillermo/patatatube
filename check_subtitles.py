#!/usr/bin/env python3
"""Prove a video's subtitles actually render, by burning one onto a frame.

    python check_subtitles.py 43
    python check_subtitles.py 43 --lang en --at 00:18:30 --keep

For each language it resolves a WebVTT track the way the server does — the
packaged ``subtitles/{key}.vtt`` when the HLS package exists, otherwise a fresh
``subtitles.convert_to_webvtt`` of the discovered track — picks a real cue out
of it, and renders that moment twice with ffmpeg: once with ``-vf subtitles``
and once without. Identical PNGs mean nothing was drawn, which is the failure
the DB and the manifest both happily hide (a track can be listed, packaged, and
still render empty).

Writes the burned frames to --out-dir so the text can be eyeballed against the
cue it printed. Exits non-zero if any checked language failed to render.
"""

import argparse
import hashlib
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import db
import hls
from library import probe_source
from paths import VIDEOS_DIR
from subtitles import UnsupportedSubtitleError, convert_to_webvtt, discover_subtitles

FFMPEG_BIN = os.getenv("FFMPEG_BIN", "ffmpeg")

_CUE_RE = re.compile(
    r"(?P<start>(?:\d+:)?\d+:\d+[.,]\d+)\s+-->\s+(?P<end>(?:\d+:)?\d+:\d+[.,]\d+)"
)


def _seconds(stamp: str) -> float:
    parts = stamp.replace(",", ".").split(":")
    secs = float(parts[-1])
    if len(parts) > 1:
        secs += int(parts[-2]) * 60
    if len(parts) > 2:
        secs += int(parts[-3]) * 3600
    return secs


def _cues(vtt_path: Path) -> list[tuple[float, float, str]]:
    """(start, end, text) for every cue with visible text."""
    lines = vtt_path.read_text(encoding="utf-8", errors="replace").splitlines()
    cues = []
    for i, line in enumerate(lines):
        match = _CUE_RE.search(line)
        if not match:
            continue
        text_lines = []
        for following in lines[i + 1:]:
            if not following.strip() or _CUE_RE.search(following):
                break
            text_lines.append(following.strip())
        text = re.sub(r"<[^>]+>", "", " ".join(text_lines)).strip()
        if len(text) >= 2:
            cues.append((_seconds(match["start"]), _seconds(match["end"]), text))
    return cues


def _pick_cue(cues: list[tuple[float, float, str]], at: float | None):
    """The cue to render: the one covering --at, else the middle one.

    The middle beats the first on purpose — opening cues are often a lone
    credit or a forced line, and a track whose only working cues sit at the
    front is exactly the kind of half-broken file worth catching.
    """
    if not cues:
        return None
    if at is None:
        return cues[len(cues) // 2]
    covering = [cue for cue in cues if cue[0] <= at <= cue[1]]
    if covering:
        return covering[0]
    return min(cues, key=lambda cue: abs(cue[0] - at))


def _render(source: Path, when: float, out_png: Path, vtt: Path | None) -> None:
    # -copyts keeps the input's own timestamps after the seek, which is what
    # lets the subtitles filter line its cue times up with the frame. Without
    # it the output restarts at 0 and every burn lands on the wrong cue.
    cmd = [FFMPEG_BIN, "-y", "-v", "error", "-ss", f"{when:.3f}", "-copyts", "-i", str(source)]
    if vtt is not None:
        escaped = str(vtt).replace("\\", "\\\\").replace(":", r"\:").replace("'", r"\'")
        cmd += ["-vf", f"subtitles='{escaped}'"]
    cmd += ["-frames:v", "1", "-an", "-sn", str(out_png)]
    subprocess.run(cmd, check=True)


def _digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()[:12]


def _stream_source(video: dict, version: dict | None) -> Path:
    """The file the player actually streams — same rule as router._resolve_hls_source."""
    if video.get("source") == "library":
        if not version:
            sys.exit("video has no version row")
        return Path(version["converted_path"] or version["source_path"])
    if not video.get("filename"):
        sys.exit("download row has no file yet")
    return VIDEOS_DIR / video["filename"]


def _subtitle_source(video: dict, version: dict | None) -> Path | None:
    """Where subtitles live, which for a library row is the original, not the mp4."""
    if video.get("source") == "library" and version:
        return Path(version["source_path"])
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("video_id", type=int)
    parser.add_argument("--lang", action="append", help="only these languages (repeatable); default all")
    parser.add_argument("--version-id", type=int, default=None)
    parser.add_argument("--at", help="prefer a cue near this time (SS or MM:SS or HH:MM:SS)")
    parser.add_argument("--out-dir", default="log/subtitle-checks")
    parser.add_argument("--no-discover", action="store_true",
                        help="skip the ffprobe-based track discovery (slow on a network volume)")
    args = parser.parse_args()

    video = db.get_video(args.video_id)
    if not video or video.get("deleted_at"):
        return print(f"video {args.video_id} not found") or 1
    version = db.get_video_version(args.video_id, args.version_id) if video.get("source") == "library" else None

    source = _stream_source(video, version)
    sub_source = _subtitle_source(video, version)
    at = _seconds(args.at) if args.at else None
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"video {video['id']}: {video.get('title')}")
    print(f"  streams   : {source}{'' if source.exists() else '   [MISSING]'}")
    if sub_source and sub_source != source:
        print(f"  subs from : {sub_source}{'' if sub_source.exists() else '   [MISSING]'}")
    print(f"  chosen    : subtitle_lang={video.get('subtitle_lang')!r}")
    if version:
        print(f"  db says   : subtitle_langs={version.get('subtitle_langs')}")
    packaged = hls.packaged_subtitle_languages(args.video_id)
    print(f"  packaged  : {'nothing packaged' if packaged is None else sorted(packaged) or 'none'}")

    # Discovery is what fills the DB at scan time; showing it next to the
    # packaged set is how a stale package (built before the tracks were known)
    # becomes visible.
    tracks = []
    if not args.no_discover:
        search = sub_source or source
        try:
            tracks = discover_subtitles(search, probe_source(search))
        except Exception as exc:  # noqa: BLE001 - discovery failing is a result, not a crash
            print(f"  discovery : failed: {exc}")
        else:
            print(f"  discovered: {[(t.language, t.name, t.stream_index) for t in tracks] or 'none'}")

    keys = hls._subtitle_keys(tracks) if tracks else []
    hls_dir = hls.hls_dir_for(args.video_id)

    # One vtt per language: the packaged file when it exists (that is the
    # artifact the app is served), else a fresh conversion of the track.
    candidates: dict[str, Path] = {}
    tmp = tempfile.TemporaryDirectory()
    for track, key in zip(tracks, keys):
        packaged_vtt = hls_dir / "subtitles" / f"{key}.vtt"
        if packaged_vtt.exists():
            candidates[key] = packaged_vtt
            continue
        fresh = Path(tmp.name) / f"{key}.vtt"
        try:
            convert_to_webvtt(track, fresh)
        except (UnsupportedSubtitleError, ValueError, OSError) as exc:
            print(f"  [{key}] convert_to_webvtt failed: {exc}")
            continue
        candidates[key] = fresh
    for vtt in sorted((hls_dir / "subtitles").glob("*.vtt")):
        # Skip AppleDouble twins: macOS leaves a binary ._X beside every X on a
        # non-HFS volume, and subtitles._list_files rejects them for the same reason.
        if vtt.name.startswith("."):
            continue
        candidates.setdefault(vtt.stem, vtt)

    if args.lang:
        wanted = set(args.lang)
        candidates = {k: v for k, v in candidates.items() if k.split("-")[0] in wanted or k in wanted}
    if not candidates:
        print("\nno subtitle track to check")
        return 1
    if not source.exists():
        print("\nsource file missing — cannot render")
        return 1

    failures = 0
    for key, vtt in sorted(candidates.items()):
        origin = "packaged" if vtt.is_relative_to(hls_dir) else "converted now"
        cues = _cues(vtt)
        cue = _pick_cue(cues, at)
        print(f"\n[{key}] {vtt}  ({origin}, {len(cues)} cues)")
        if cue is None:
            print("  FAIL: no cue with text in the track")
            failures += 1
            continue
        start, end, text = cue
        when = min(start + 0.5, (start + end) / 2)
        print(f"  cue @ {start:.2f}-{end:.2f}s: {text[:90]!r}")
        burned = out_dir / f"{args.video_id}-{key}.png"
        control = out_dir / f"{args.video_id}-{key}-nosubs.png"
        try:
            _render(source, when, burned, vtt)
            _render(source, when, control, None)
        except subprocess.CalledProcessError as exc:
            print(f"  FAIL: ffmpeg exited {exc.returncode}")
            failures += 1
            continue
        if _digest(burned) == _digest(control):
            print(f"  FAIL: frame identical with and without the track — nothing rendered\n"
                  f"        {burned}")
            failures += 1
        else:
            print(f"  OK: frame changed ({_digest(control)} -> {_digest(burned)})\n"
                  f"      {burned}   (compare: {control})")

    print(f"\n{len(candidates) - failures}/{len(candidates)} languages rendered")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
