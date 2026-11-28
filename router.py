import asyncio
import math
import os
import re
import secrets
import sqlite3
import subprocess
import tempfile
from collections.abc import AsyncIterator
from pathlib import Path
from urllib.parse import parse_qs, quote, urlencode, urlparse

from email.utils import formatdate

import anyio
from fastapi import APIRouter, BackgroundTasks, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, RedirectResponse, Response, StreamingResponse
from pydantic import BaseModel, FiniteFloat, field_validator

import db
import devlog
import pixellab
import sd
import services
import yosubee
from downloader import (
    backfill_channels,
    download_video,
    import_playlist,
    process_uploaded_video,
)
from paths import VIDEOS_DIR
from views.serializers import serialize_video
from views.render import _display_name, build_login_page, build_sd_page, build_videos_page

router = APIRouter()

PREVIEWS_DIR = Path("data/previews")
# Longest-edge cap for posters grabbed out of a download's mp4. Full-resolution
# frames bloated the iPad's memory when decoded across a whole grid (Sentry
# PATATATUBE-6 OOM). 1200px stays crisp on iPad mini 6 (@2x)
# and iPhone 16e (@3x) for both grid and detail views. The suffix versions the
# cache so previously-cached full-size files regenerate at the new size.
PREVIEW_MAX_EDGE = 1200
PREVIEW_CACHE_SUFFIX = f"r{PREVIEW_MAX_EDGE}"
# Seconds into the file to grab a download's poster frame from. Frame 0 is
# black in most Twitter clips and screen recordings.
PREVIEW_FRAME_OFFSET = 3.0
FFMPEG_BIN = os.getenv("FFMPEG_BIN", "ffmpeg")
VIDEO_CHUNK_SIZE = 1024 * 1024
# A group emoji is one emoji, but "one emoji" can be many code points — a ZWJ
# family or a flag is several scalars. Cap on characters, not on scalar count.
MAX_GROUP_EMOJI_CHARS = 16
DEFAULT_VIDEO_STREAM_LIMIT = 16
VIDEO_CACHE_CONTROL = "public, max-age=31536000, immutable"
SPLASH_DIR = Path("assets/splash")
SPLASH_ICON = "icon.png"
SPLASH_MIME_TYPES = {
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png": "image/png",
}
VENDOR_DIR = Path("assets/vendor")
VENDOR_MIME_TYPES = {
    ".js": "application/javascript",
    ".css": "text/css",
}
APP_DIR = Path("assets/app")
APP_MIME_TYPES = {".css": "text/css", ".js": "text/javascript"}

ROOT_STATIC_ASSETS = {
    "favicon.ico": ("favicon.ico", "image/x-icon"),
    "apple-touch-icon.png": ("apple-touch-icon.png", "image/png"),
}
_static_asset_cache: dict[str, bytes] = {}


# The web page authenticates with a cookie holding the raw UPLOAD_TOKEN, set by
# POST /login. It is HttpOnly: the page's own JS gets the token from the
# server-rendered window.UPLOAD_TOKEN instead, so nothing needs to read it back.
LOGIN_COOKIE = "upload_token"
LOGIN_COOKIE_MAX_AGE = 31536000  # one year


def _positive_int_env(name: str, default: int) -> int:
    try:
        return max(1, int(os.getenv(name, str(default))))
    except ValueError:
        return default


VIDEO_STREAM_LIMIT = _positive_int_env("VIDEO_STREAM_LIMIT", DEFAULT_VIDEO_STREAM_LIMIT)
_video_stream_slots = asyncio.Semaphore(VIDEO_STREAM_LIMIT)
# Permits held right now. A permit is held for the *entire* response body, so a
# handful of stalled multi-GB transfers can hold all of them indefinitely and
# every later request queues behind them. This gauge is what confirms (or rules
# out) that starvation: compare it against the app's own concurrency-gate counts
# in log/ios.jsonl. See docs/ios-devlog-instrumentation-plan.md.
_video_stream_active = 0

YOUTUBE_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")
# Playlist ids are not fixed-width like video ids (PL…, OLAK5uy_…, RD…), so
# this is a charset + minimum-length check, not an exact-length one.
YOUTUBE_PLAYLIST_ID_RE = re.compile(r"^[A-Za-z0-9_-]{10,}$")
# Single-segment YouTube paths that are pages, not video ids.
YOUTUBE_RESERVED_PATHS = {
    "account",
    "feed",
    "gaming",
    "hashtag",
    "live",
    "movies",
    "music",
    "premium",
    "results",
    "shorts",
    "source",
    "subscriptions",
    "trending",
    "watch",
}


def _tokens_match(candidate: str, expected: str) -> bool:
    """compare_digest on bytes: its str overload raises TypeError on non-ASCII,
    which a login form can receive from anyone."""
    return secrets.compare_digest(candidate.encode(), expected.encode())


def _cookie_token_valid(request: Request) -> bool:
    expected = os.getenv("UPLOAD_TOKEN", "")
    candidate = request.cookies.get(LOGIN_COOKIE, "")
    return bool(expected) and bool(candidate) and _tokens_match(candidate, expected)


def _check_token(request: Request):
    token = os.getenv("UPLOAD_TOKEN", "")
    if not token:
        raise HTTPException(status_code=503, detail="Upload not configured")
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer ") or not _tokens_match(auth[7:], token):
        raise HTTPException(status_code=401, detail="Unauthorized")


def _check_token_or_query(request: Request):
    """Bearer auth, with a ?token= fallback for HTML <video> tags (which can't
    send headers) and a login-cookie fallback for the browser session."""
    token = os.getenv("UPLOAD_TOKEN", "")
    if not token:
        raise HTTPException(status_code=503, detail="Upload not configured")
    auth = request.headers.get("Authorization", "")
    if auth.startswith("Bearer ") and _tokens_match(auth[7:], token):
        return
    query_token = request.query_params.get("token", "")
    if query_token and _tokens_match(query_token, token):
        return
    if _cookie_token_valid(request):
        return
    raise HTTPException(status_code=401, detail="Unauthorized")


class UploadRequest(BaseModel):
    url: str
    group_id: int | None = None


class SetGroupRequest(BaseModel):
    group_id: int


class PositionRequest(BaseModel):
    secs: FiniteFloat

    @field_validator("secs", mode="before")
    @classmethod
    def make_non_finite_validation_input_json_safe(cls, value):
        # Starlette serializes Pydantic's rejected input into the 422 body.
        # Non-standard JSON numeric NaN/Infinity would otherwise make that
        # error response itself fail JSON encoding. A string still fails the
        # FiniteFloat constraint while remaining safe to report.
        if isinstance(value, float) and not math.isfinite(value):
            return str(value)
        return value


class GroupCreateRequest(BaseModel):
    name: str
    label: str
    emoji: str | None = None


class IconGenerateRequest(BaseModel):
    prompt: str


class GroupIconRequest(BaseModel):
    icon: str | None = None


class GroupUpdateRequest(BaseModel):
    label: str | None = None
    emoji: str | None = None
    position: int | None = None
    display_titles: bool | None = None
    remember_position: bool | None = None
    description: str | None = None


def _print_bad_request_details(request: Request, body: UploadRequest):
    print("400 Bad Request details:", flush=True)
    print(f"  method={request.method}", flush=True)
    print(f"  url={request.url}", flush=True)
    print(f"  path_params={dict(request.path_params)}", flush=True)
    print(f"  query_params={dict(request.query_params)}", flush=True)
    print(f"  headers={dict(request.headers)}", flush=True)
    print(f"  body={body.model_dump()}", flush=True)
    print(f"  url={body.url}", flush=True)


def _normalize_twitter_url(raw_url: str) -> tuple[str, str | None]:
    parsed = urlparse(raw_url)
    host = parsed.netloc.lower().removeprefix("www.")
    if host not in {"twitter.com", "x.com", "mobile.twitter.com", "mobile.x.com"}:
        raise ValueError("Unsupported URL")

    match = re.search(r"/status/(\d+)", parsed.path)
    if not match:
        raise ValueError("Unsupported URL")

    canonical_host = "x.com" if host.endswith("x.com") else "twitter.com"
    canonical_url = f"https://{canonical_host}{parsed.path}"
    if parsed.query:
        canonical_url = f"{canonical_url}?{parsed.query}"
    return canonical_url, None


def _extract_youtube_id(raw_url: str) -> str:
    parsed = urlparse(raw_url)
    host = parsed.netloc.lower().removeprefix("www.")

    if host == "youtu.be":
        video_id = parsed.path.strip("/").split("/")[0]
    elif host in {"youtube.com", "m.youtube.com", "music.youtube.com"}:
        path = parsed.path.rstrip("/")
        query = parse_qs(parsed.query)
        if path == "/watch":
            video_id = query.get("v", [""])[0]
        elif path.startswith("/shorts/"):
            video_id = path.split("/")[2]
        elif path.startswith("/embed/"):
            video_id = path.split("/")[2]
        elif path.startswith(("/channel/", "/c/", "/user/", "/@")) or path in {"", "/playlist"}:
            raise ValueError("Unsupported YouTube URL")
        elif path.count("/") == 1 and path[1:] not in YOUTUBE_RESERVED_PATHS:
            # Bare /<id> — not a canonical share URL, but users paste it. Legacy
            # usernames live in the same namespace, so only ids that survive
            # YOUTUBE_ID_RE below get through.
            video_id = path[1:]
        else:
            raise ValueError("Unsupported YouTube URL")
    else:
        raise ValueError("Unsupported URL")

    if not YOUTUBE_ID_RE.fullmatch(video_id):
        raise ValueError("Unsupported YouTube URL")
    return video_id


def _normalize_youtube_url(raw_url: str) -> tuple[str, str]:
    video_id = _extract_youtube_id(raw_url)
    normalized_url = f"https://www.youtube.com/watch?v={video_id}"
    return normalized_url, video_id


def _extract_youtube_playlist_id(raw_url: str) -> str:
    """The list id of a /playlist page.

    Deliberately narrow: `watch?v=X&list=Y` is *not* a playlist upload. Shared
    watch links routinely carry a Mix/RD list the sender never meant to hand
    over, and expanding those would import hundreds of unwanted videos.
    """
    parsed = urlparse(raw_url)
    host = parsed.netloc.lower().removeprefix("www.")
    if host not in {"youtube.com", "m.youtube.com", "music.youtube.com"}:
        raise ValueError("Unsupported URL")
    if parsed.path.rstrip("/") != "/playlist":
        raise ValueError("Unsupported YouTube URL")

    list_id = parse_qs(parsed.query).get("list", [""])[0]
    if not YOUTUBE_PLAYLIST_ID_RE.fullmatch(list_id):
        raise ValueError("Unsupported YouTube playlist URL")
    return list_id


def _normalize_youtube_playlist_url(raw_url: str) -> tuple[str, str]:
    list_id = _extract_youtube_playlist_id(raw_url)
    return f"https://www.youtube.com/playlist?list={list_id}", list_id


def _youtube_preview_url(video_id: str) -> str:
    return f"https://i.ytimg.com/vi/{video_id}/hqdefault.jpg"


def _classify_url(raw_url: str) -> dict:
    try:
        normalized_url, source_key = _normalize_twitter_url(raw_url)
        return {"platform": "twitter", "source_key": source_key, "normalized_url": normalized_url}
    except ValueError:
        pass

    try:
        normalized_url, list_id = _normalize_youtube_playlist_url(raw_url)
        return {
            "platform": "youtube_playlist",
            "source_key": list_id,
            "normalized_url": normalized_url,
        }
    except ValueError:
        pass

    try:
        normalized_url, video_id = _normalize_youtube_url(raw_url)
        return {
            "platform": "youtube",
            "source_key": video_id,
            "normalized_url": normalized_url,
        }
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@router.get("/check-auth")
async def check_auth(request: Request):
    # Accepts ?token= too: Caddy's forward_auth re-sends stream requests
    # here (uri /check-auth?{query}), and <video> tags can't send headers.
    _check_token_or_query(request)
    return {"ok": True}


@router.post("/upload", status_code=202)
async def upload(body: UploadRequest, request: Request, background_tasks: BackgroundTasks):
    _check_token(request)
    try:
        source = _classify_url(body.url)
    except HTTPException as exc:
        if exc.status_code == 400:
            _print_bad_request_details(request, body)
        raise

    if source["platform"] == "youtube_playlist":
        # No row and no group yet: both need the playlist's title, which costs a
        # yt-dlp round trip. The client polls /api/groups for it to appear.
        # body.group_id is deliberately ignored — the playlist names the group.
        background_tasks.add_task(import_playlist, source["normalized_url"])
        return {"status": "queued", "playlist": source["source_key"]}

    group_id = body.group_id
    if group_id is None:
        default = db.get_group_by_name(db.DEFAULT_UPLOAD_GROUP)
        if default is None:
            groups = db.list_groups()
            if not groups:
                raise HTTPException(status_code=409, detail="No video groups configured")
            default = groups[0]
        group_id = default["id"]
    elif db.get_group(group_id) is None:
        raise HTTPException(status_code=400, detail="No such group")

    if source["platform"] == "youtube":
        existing = db.get_completed_video_by_source("youtube", source["source_key"])
        if existing:
            if not services.set_group(existing["id"], group_id):
                raise HTTPException(status_code=409, detail="Existing video cannot be moved to this group")
            return {"id": existing["id"], "status": "queued"}

    video_id = db.add_video(
        source["normalized_url"] if source["platform"] == "youtube" else body.url,
        platform=source["platform"],
        source_key=source["source_key"],
        preview_url=_youtube_preview_url(source["source_key"]) if source["platform"] == "youtube" else None,
        group_id=group_id,
    )
    # Only a caller who named no group gets the classifier's opinion; a named
    # group (even the inbox) is a decision already made.
    background_tasks.add_task(download_video, video_id, classify=body.group_id is None)
    return {"id": video_id, "status": "queued"}


@router.post("/upload/file", status_code=202)
async def upload_file(
    request: Request,
    background_tasks: BackgroundTasks,
    file: UploadFile = File(...),
    group_id: int = Form(...),
):
    _check_token(request)
    if db.get_group(group_id) is None:
        raise HTTPException(status_code=400, detail="No such group")

    suffix = Path(file.filename or "").suffix or ".mp4"
    with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
        tmp_path = Path(tmp.name)
        while chunk := await file.read(1024 * 1024):
            tmp.write(chunk)
    await file.close()

    title = Path(file.filename or "").stem or None
    video_id = db.add_video(str(tmp_path), platform="upload", title=title)
    services.set_group(video_id, group_id)
    background_tasks.add_task(process_uploaded_video, video_id)
    return {"id": video_id, "status": "queued"}


def _guess_mime(filename: str) -> str:
    ext = Path(filename).suffix.lower()
    return {"mp4": "video/mp4", "m4v": "video/mp4", "webm": "video/webm", "mov": "video/quicktime"}.get(ext[1:], "video/mp4")


def _load_static_asset_cache() -> None:
    for cache_key, (filename, _media_type) in ROOT_STATIC_ASSETS.items():
        try:
            _static_asset_cache[cache_key] = Path(filename).read_bytes()
        except FileNotFoundError:
            _static_asset_cache.pop(cache_key, None)


def _static_asset_response(cache_key: str) -> Response:
    filename, media_type = ROOT_STATIC_ASSETS[cache_key]
    content = _static_asset_cache.get(cache_key)
    if content is None:
        try:
            content = Path(filename).read_bytes()
        except FileNotFoundError:
            raise HTTPException(status_code=404, detail="Not found")
        _static_asset_cache[cache_key] = content

    return Response(
        content=content,
        media_type=media_type,
        headers={"Cache-Control": "public, max-age=3600"},
    )


def _stream_validators(stat: os.stat_result) -> tuple[str, str]:
    """Strong ETag + Last-Modified for a video file. URLSession only emits
    resume data when the initial response carried one of these validators,
    so without them an interrupted iOS download always restarts from zero."""
    etag = f'"{stat.st_mtime_ns:x}-{stat.st_size:x}"'
    last_modified = formatdate(stat.st_mtime, usegmt=True)
    return etag, last_modified


def _if_range_matches(if_range: str | None, etag: str, last_modified: str) -> bool:
    if if_range is None:
        return True
    return if_range.strip() in (etag, last_modified)


def _range_not_satisfiable(file_size: int) -> HTTPException:
    return HTTPException(
        status_code=416,
        headers={"Content-Range": f"bytes */{file_size}"},
        detail="Range Not Satisfiable",
    )


def _parse_byte_range(range_header: str, file_size: int) -> tuple[int, int]:
    if file_size <= 0:
        raise _range_not_satisfiable(file_size)

    try:
        unit, ranges = range_header.split("=", 1)
        if unit.strip().lower() != "bytes" or "," in ranges:
            raise ValueError
        start_str, end_str = ranges.strip().split("-", 1)

        if start_str == "":
            suffix_length = int(end_str)
            if suffix_length <= 0:
                raise ValueError
            return max(file_size - suffix_length, 0), file_size - 1

        start = int(start_str)
        end = int(end_str) if end_str else file_size - 1
    except (ValueError, AttributeError):
        raise _range_not_satisfiable(file_size)

    if start < 0 or start >= file_size or start > end:
        raise _range_not_satisfiable(file_size)

    return start, min(end, file_size - 1)


async def _iter_file_range(
    file_path: Path,
    start: int = 0,
    byte_count: int | None = None,
    completion_title: str | None = None,
) -> AsyncIterator[bytes]:
    global _video_stream_active
    waiting = _video_stream_active >= VIDEO_STREAM_LIMIT
    if waiting:
        print(
            f"[stream] saturated: {_video_stream_active}/{VIDEO_STREAM_LIMIT} permits held, "
            f"queuing {file_path.name}",
            flush=True,
        )
    async with _video_stream_slots:
        _video_stream_active += 1
        print(
            f"[stream] +1 {file_path.name} active={_video_stream_active}/{VIDEO_STREAM_LIMIT}",
            flush=True,
        )
        try:
            async with await anyio.open_file(file_path, "rb") as f:
                if start:
                    await f.seek(start)

                remaining = byte_count
                while remaining is None or remaining > 0:
                    read_size = VIDEO_CHUNK_SIZE if remaining is None else min(VIDEO_CHUNK_SIZE, remaining)
                    chunk = await f.read(read_size)
                    if not chunk:
                        break
                    if remaining is not None:
                        remaining -= len(chunk)
                    yield chunk
        finally:
            _video_stream_active -= 1
            print(
                f"[stream] -1 {file_path.name} active={_video_stream_active}/{VIDEO_STREAM_LIMIT}",
                flush=True,
            )

    # Reached here only if the whole requested range was streamed without the
    # client disconnecting. When it was the final byte of the file, the video
    # finished downloading to the client.
    if completion_title is not None:
        print(f"video {completion_title} uploaded", flush=True)


def _grab_frame(path: Path, offset: float, max_edge: int) -> bytes:
    """One JPEG frame from `path`, taken `offset` seconds in and downscaled.

    Seeking matters: the opening frame of a Twitter clip or a screen recording
    is very often black, which is exactly the poster this replaces. A clip
    shorter than the offset seeks past the end and yields nothing, so that case
    retries from the start."""
    def run(seek: float) -> bytes:
        cmd = [FFMPEG_BIN, "-loglevel", "error"]
        if seek:
            cmd += ["-ss", str(seek)]
        cmd += [
            "-i", str(path), "-frames:v", "1",
            "-vf", (
                f"scale='min({max_edge},iw)':'min({max_edge},ih)':"
                "force_original_aspect_ratio=decrease"
            ),
            "-q:v", "3", "-f", "mjpeg", "pipe:1",
        ]
        try:
            proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        except OSError:
            return b""
        return proc.stdout if proc.returncode == 0 else b""

    return run(offset) or run(0)


async def _download_preview(video: dict) -> Response:
    """Poster for a download row, grabbed out of its own mp4 and cached to disk."""
    filename = video.get("filename")
    path = VIDEOS_DIR / filename if filename else None
    if video.get("status") != "done" or not path or not path.exists():
        raise HTTPException(status_code=404, detail="No preview")

    cache_file = PREVIEWS_DIR / f"dl{video['id']}.{PREVIEW_CACHE_SUFFIX}.jpg"
    if not cache_file.exists():
        content = await asyncio.to_thread(
            _grab_frame, path, PREVIEW_FRAME_OFFSET, PREVIEW_MAX_EDGE
        )
        if not content:
            raise HTTPException(status_code=502, detail="Preview extraction failed")
        PREVIEWS_DIR.mkdir(parents=True, exist_ok=True)
        tmp = cache_file.with_suffix(".jpg.tmp")
        tmp.write_bytes(content)
        tmp.replace(cache_file)

    return Response(
        content=cache_file.read_bytes(),
        media_type="image/jpeg",
        headers={"Cache-Control": "public, max-age=86400"},
    )


@router.get("/videos/{video_id}/preview")
async def video_preview(video_id: int, request: Request):
    _check_token_or_query(request)
    video = db.get_video(video_id)
    if not video:
        raise HTTPException(status_code=404, detail="No preview")
    return await _download_preview(video)


def _file_response(
    file_path: Path, mime: str, request: Request, title: str | None
) -> StreamingResponse:
    """Full or single-range body for a file on disk, via the stream semaphore."""
    stat = file_path.stat()
    file_size = stat.st_size
    etag, last_modified = _stream_validators(stat)
    range_header = request.headers.get("Range")

    # A stale If-Range validator means the file changed since the client's
    # partial copy (e.g. re-conversion); serve the full body instead of
    # letting a resumed download splice bytes from two different files.
    if range_header and _if_range_matches(request.headers.get("If-Range"), etag, last_modified):
        start, end = _parse_byte_range(range_header, file_size)
        chunk_size = end - start + 1
        is_last = end == file_size - 1

        return StreamingResponse(
            _iter_file_range(
                file_path,
                start,
                chunk_size,
                completion_title=title if is_last else None,
            ),
            status_code=206,
            media_type=mime,
            headers={
                "Content-Range": f"bytes {start}-{end}/{file_size}",
                "Accept-Ranges": "bytes",
                "Content-Length": str(chunk_size),
                "Cache-Control": VIDEO_CACHE_CONTROL,
                "ETag": etag,
                "Last-Modified": last_modified,
            },
        )

    return StreamingResponse(
        _iter_file_range(file_path, completion_title=title),
        media_type=mime,
        headers={
            "Accept-Ranges": "bytes",
            "Content-Length": str(file_size),
            "Cache-Control": VIDEO_CACHE_CONTROL,
            "ETag": etag,
            "Last-Modified": last_modified,
        },
    )


@router.get("/videos/{video_id}/stream")
async def stream_video(video_id: int, request: Request):
    _check_token_or_query(request)
    video = db.get_video(video_id)
    if not video:
        raise HTTPException(status_code=404, detail="Video not found or not ready")

    if video["status"] != "done" or not video["filename"]:
        raise HTTPException(status_code=404, detail="Video not found or not ready")
    file_path = VIDEOS_DIR / video["filename"]
    mime = _guess_mime(video["filename"])

    if not file_path.exists():
        raise HTTPException(status_code=404, detail="Video file missing")

    return _file_response(file_path, mime, request, video.get("title"))


@router.get("/videos/{video_id}/sd.mp4")
async def stream_sd_video(video_id: int, request: Request):
    """The iPad 1 rendition /sd plays. Caddy serves it from disk when it can;
    this is the fallback (and the only path when Caddy has no sd.mp4 rule)."""
    _check_token_or_query(request)
    video = db.get_video(video_id)
    if not video or not video.get("sd_ready"):
        raise HTTPException(status_code=404, detail="SD rendition not ready")
    file_path = VIDEOS_DIR / sd.sd_filename(video_id)
    if not file_path.exists():
        raise HTTPException(status_code=404, detail="SD file missing")
    return _file_response(file_path, "video/mp4", request, video.get("title"))


@router.get("/favicon.ico", include_in_schema=False)
async def favicon():
    return _static_asset_response("favicon.ico")


@router.get("/apple-touch-icon.png", include_in_schema=False)
async def apple_touch_icon():
    return _static_asset_response("apple-touch-icon.png")


@router.get("/assets/splash/{filename}", include_in_schema=False)
async def splash_asset(filename: str):
    safe_name = Path(filename).name
    if safe_name != filename:
        raise HTTPException(status_code=404, detail="Not found")
    target = SPLASH_DIR / safe_name
    media_type = SPLASH_MIME_TYPES.get(target.suffix.lower())
    if not target.exists() or media_type is None:
        raise HTTPException(status_code=404, detail="Not found")
    return FileResponse(target, media_type=media_type)


@router.get("/assets/vendor/{filename}", include_in_schema=False)
async def vendor_asset(filename: str):
    safe_name = Path(filename).name
    if safe_name != filename:
        raise HTTPException(status_code=404, detail="Not found")
    target = VENDOR_DIR / safe_name
    media_type = VENDOR_MIME_TYPES.get(target.suffix.lower())
    if not target.exists() or media_type is None:
        raise HTTPException(status_code=404, detail="Not found")
    return FileResponse(target, media_type=media_type)


@router.get("/assets/app/{filename}", include_in_schema=False)
async def app_asset(filename: str):
    safe_name = Path(filename).name
    if safe_name != filename:
        raise HTTPException(status_code=404, detail="Not found")
    target = APP_DIR / safe_name
    media_type = APP_MIME_TYPES.get(target.suffix.lower())
    if not target.exists() or media_type is None:
        raise HTTPException(status_code=404, detail="Not found")
    return FileResponse(target, media_type=media_type)


@router.get("/sw.js", include_in_schema=False)
async def service_worker():
    target = APP_DIR / "sw.js"
    if not target.exists():
        raise HTTPException(status_code=404, detail="Not found")
    return FileResponse(
        target,
        media_type="application/javascript",
        headers={
            # Root scope is otherwise refused by the browser.
            "Service-Worker-Allowed": "/",
            # The SW file itself must never be stale, or updates never ship.
            "Cache-Control": "no-cache",
        },
    )


@router.get("/manifest.webmanifest", include_in_schema=False)
async def manifest():
    return JSONResponse(
        {
            "name": "Twitter To Watch Later",
            "short_name": "Videos",
            "start_url": "/videos",
            "scope": "/",
            "display": "standalone",
            "background_color": "#111111",
            "theme_color": "#111111",
            "icons": [
                {
                    "src": "/apple-touch-icon.png",
                    "sizes": "256x256",
                    "type": "image/png",
                },
                {
                    "src": f"/assets/splash/{SPLASH_ICON}",
                    "sizes": "512x512",
                    "type": "image/png",
                    "purpose": "any maskable",
                },
                {
                    "src": "/favicon.ico",
                    "sizes": "48x48 32x32 16x16",
                    "type": "image/x-icon",
                },
            ],
        }
    )


@router.post("/videos/{video_id}/group")
async def set_video_group_endpoint(
    video_id: int, group_id: int = Form(...), current_group_id: int | None = Form(default=None)
):
    await asyncio.to_thread(services.set_group, video_id, group_id)
    redirect_url = f"/?group_id={current_group_id}" if current_group_id else "/"
    return RedirectResponse(url=redirect_url, status_code=303)


def serialize_group(group: dict) -> dict:
    return {
        "id": group["id"],
        "name": group["name"],
        "label": group["label"],
        "emoji": group["emoji"],
        "position": group["position"],
        "display_titles": bool(group["display_titles"]),
        "remember_position": bool(group["remember_position"]),
        "description": group["description"],
        "icon_url": pixellab.icon_url(group.get("icon")),
        # Wire name kept from the days this was a boolean `unread` column; it
        # is the count of announced-but-never-played videos, `play_count = 0`.
        "unread_count": (
            group["unread_count"]
            if "unread_count" in group
            else db.unplayed_count(group["id"])
        ),
    }


@router.get("/api/groups")
async def api_groups():
    """Every video group, in display order. The iOS Videos tab mirrors this
    into UserDefaults so its cards still render offline."""
    return {"groups": [serialize_group(g) for g in db.list_groups()]}


@router.post("/api/groups", status_code=201)
async def api_create_group(body: GroupCreateRequest, request: Request):
    _check_token(request)
    name = body.name.strip()
    label = body.label.strip()
    if not name or not label:
        raise HTTPException(status_code=400, detail="Name and label are required")
    emoji = _validated_emoji(body.emoji)
    try:
        group = db.create_group(name, label, emoji)
    except sqlite3.IntegrityError:
        raise HTTPException(status_code=400, detail="That group name is taken") from None
    return serialize_group(group)


@router.patch("/api/groups/{group_id}")
async def api_update_group(group_id: int, body: GroupUpdateRequest, request: Request):
    _check_token(request)
    fields = body.model_dump(exclude_unset=True)
    emoji = _validated_emoji(body.emoji) if "emoji" in fields else None
    description = (body.description or "").strip()
    before = db.get_group(group_id)
    group = db.update_group(
        group_id,
        label=body.label.strip() if body.label else None,
        emoji=emoji,
        # An explicit `"emoji": null` clears it; an omitted key leaves it alone.
        clear_emoji="emoji" in fields and not emoji,
        position=body.position,
        display_titles=body.display_titles,
        remember_position=body.remember_position,
        description=description or None,
        # An explicit null or blank string clears it; an omitted key leaves it.
        clear_description="description" in fields and not description,
    )
    if group is None:
        raise HTTPException(status_code=404, detail="No such group")
    # The classifier files videos by these fields, so an edit that never lands
    # (or lands with different text than the app shows) must be visible here.
    changes = [
        f"{key} {before[key]!r} -> {group[key]!r}"
        for key in (
            "label", "emoji", "position", "display_titles", "remember_position", "description"
        )
        if before[key] != group[key]
    ]
    print(
        f"[groups] PATCH {group_id} ({group['name']}) sent={sorted(fields)}: "
        f"{'; '.join(changes) or 'no change'}",
        flush=True,
    )
    return serialize_group(group)


@router.delete("/api/groups/{group_id}")
async def api_delete_group(group_id: int, request: Request):
    """Delete a group. Its videos are not deleted: they move to the inbox, the
    same place an unfiled upload lands, so nothing disappears from the app.
    The inbox itself can't be deleted, since it is where they would go."""
    _check_token(request)
    group = db.get_group(group_id)
    if group is None:
        raise HTTPException(status_code=404, detail="No such group")
    inbox = db.get_group_by_name(db.DEFAULT_UPLOAD_GROUP)
    if inbox is None:
        raise HTTPException(status_code=409, detail="There is no inbox to move its videos to")
    if inbox["id"] == group_id:
        raise HTTPException(status_code=409, detail="The inbox can't be deleted")
    moved = db.delete_group(group_id, move_to=inbox["id"])
    print(
        f"[groups] DELETE {group_id} ({group['name']}): moved {moved} video(s) to inbox",
        flush=True,
    )
    return {"deleted": group_id, "moved": moved}


@router.post("/api/icons/generate")
async def api_generate_icon(body: IconGenerateRequest, request: Request):
    """Generate a pixel-art preview for a prompt. Nothing is attached to a
    group yet: the app shows the preview, may regenerate, and then PUTs the
    one it likes to /api/groups/{id}/icon. Takes ~30-40s (PixelLab)."""
    _check_token(request)
    prompt = body.prompt.strip()
    if not prompt:
        raise HTTPException(status_code=400, detail="Prompt is required")
    if len(prompt) > pixellab.MAX_PROMPT_CHARS:
        raise HTTPException(status_code=400, detail="Prompt is too long")
    try:
        name = await pixellab.generate(prompt)
    except pixellab.NotConfiguredError:
        raise HTTPException(status_code=503, detail="Icon generation not configured") from None
    except pixellab.QuotaExhaustedError as exc:
        print(f"[icons] {exc}", flush=True)
        raise HTTPException(status_code=429, detail="Out of PixelLab credits") from None
    except pixellab.PixelLabError as exc:
        print(f"[icons] generate failed prompt={prompt!r}: {exc}", flush=True)
        raise HTTPException(status_code=502, detail="Icon generation failed") from None
    print(f"[icons] generated {name} prompt={prompt!r}", flush=True)
    return {"icon": name, "icon_url": pixellab.icon_url(name)}


@router.put("/api/groups/{group_id}/icon")
async def api_set_group_icon(group_id: int, body: GroupIconRequest, request: Request):
    """Use a generated icon as the group's cover; `{"icon": null}` goes back
    to the emoji."""
    _check_token(request)
    icon = body.icon
    if icon is not None and (
        not pixellab.is_icon_name(icon) or not pixellab.icon_path(icon).is_file()
    ):
        raise HTTPException(status_code=400, detail="Unknown icon")
    group = db.set_group_icon(group_id, icon)
    if group is None:
        raise HTTPException(status_code=404, detail="No such group")
    print(f"[groups] icon {group_id} ({group['name']}) -> {icon}", flush=True)
    return serialize_group(group)


@router.get("/group-icons/{filename}")
async def group_icon_file(filename: str):
    """Unauthenticated, like /api/groups: names are 128-bit random and the
    images are cartoon pixel art. Immutable — a new icon is a new name."""
    name, _, ext = filename.partition(".")
    if ext != "png" or not pixellab.is_icon_name(name):
        raise HTTPException(status_code=404)
    path = pixellab.icon_path(name)
    if not path.is_file():
        raise HTTPException(status_code=404)
    return FileResponse(path, media_type="image/png", headers={"Cache-Control": VIDEO_CACHE_CONTROL})


def _validated_emoji(raw: str | None) -> str | None:
    emoji = (raw or "").strip()
    if len(emoji) > MAX_GROUP_EMOJI_CHARS:
        raise HTTPException(status_code=400, detail="Cover must be a single emoji")
    return emoji or None


@router.get("/api/videos")
async def api_videos(group_id: int | None = None):
    return [serialize_video(v) for v in db.get_all_videos(group_id=group_id)]


@router.post("/api/videos/{video_id}/group")
async def api_set_video_group(video_id: int, body: SetGroupRequest, request: Request):
    _check_token(request)
    if not await asyncio.to_thread(services.set_group, video_id, body.group_id):
        raise HTTPException(status_code=400, detail="No such group")
    return {"ok": True}


@router.post("/api/videos/{video_id}/position", status_code=204)
async def api_save_position(video_id: int, body: PositionRequest, request: Request):
    """Where playback got to, reported by the iOS player.

    Fire-and-forget from the client's point of view: no body comes back, and a
    lost write only costs a few seconds of accuracy. 0 means "watched to the
    end" — the client sends it once playback reaches the final seconds.
    """
    _check_token(request)
    video = db.get_video(video_id)
    if not video:
        raise HTTPException(status_code=404, detail="Video not found")
    db.set_resume_secs(video_id, body.secs)
    return Response(status_code=204)


@router.post("/api/videos/{video_id}/played")
async def api_mark_played(video_id: int, request: Request):
    """Count one play of a video. Every playback start calls this.

    `videos.play_count` climbs on every call; only the first one takes the video
    out of its group's badge, and that is exactly what `changed` reports, so the
    iOS client refetches the group list once instead of on every replay.
    """
    _check_token(request)
    video = db.get_video(video_id)
    if not video:
        raise HTTPException(status_code=404, detail="Video not found")
    return {"changed": db.record_play(video_id)}


@router.post("/api/videos/{video_id}/yoto", status_code=202)
async def api_send_to_yoto(video_id: int, request: Request):
    """Send a finished video's audio to the Yoto card yosubee is configured for.

    Fire and forget: yosubee only enqueues (convert, upload, wait for an icon
    pick in its own UI), so a 202 here means "accepted", not "on the card".
    """
    _check_token(request)
    if not yosubee.configured():
        raise HTTPException(status_code=503, detail="Yoto not configured")
    video = db.get_video(video_id)
    if not video:
        raise HTTPException(status_code=404, detail="Video not found")
    if video.get("status") != "done" or not video.get("filename"):
        raise HTTPException(status_code=409, detail="Video isn't downloaded yet")
    path = (VIDEOS_DIR / video["filename"]).resolve()
    if not path.is_file():
        raise HTTPException(status_code=409, detail="Video file is missing")
    try:
        await yosubee.send(str(path), video.get("title") or path.stem)
    except yosubee.YosubeeError as e:
        raise HTTPException(status_code=502, detail=str(e))
    return {"status": "sent"}


@router.post("/api/video/{video_id}/delete")
async def api_delete_video(video_id: int, request: Request):
    _check_token(request)
    video = db.get_video(video_id)
    if video:
        # Row first: a download still running checks for it before writing
        # anything into videos/, and cleans up after itself once it is gone.
        db.delete_video(video_id)
        if video.get("filename"):
            (VIDEOS_DIR / video["filename"]).unlink(missing_ok=True)
        # Mid-download rows have no filename yet, but the mp4 may land between
        # the read above and the delete -- its name is fixed, so drop it anyway.
        (VIDEOS_DIR / f"{video_id}.mp4").unlink(missing_ok=True)
        (VIDEOS_DIR / sd.sd_filename(video_id)).unlink(missing_ok=True)
        # The generated poster is derived from that mp4 — drop it too.
        (PREVIEWS_DIR / f"dl{video_id}.{PREVIEW_CACHE_SUFFIX}.jpg").unlink(missing_ok=True)
        _remove_pending_upload(video)
    return {"ok": True}


def _remove_pending_upload(video: dict) -> None:
    """An upload not yet processed keeps its bytes in a temp file named by
    `url`. Only ever a path upload_file wrote into the temp dir: for every
    other platform `url` is a web address, not ours to touch."""
    if video.get("platform") != "upload" or video.get("status") == "done":
        return
    tmp = Path(video["url"]).resolve()
    if tmp.parent == Path(tempfile.gettempdir()).resolve():
        tmp.unlink(missing_ok=True)


@router.post("/api/videos/backfill-channels", status_code=202)
async def api_backfill_channels(request: Request, background_tasks: BackgroundTasks):
    """Fill `channel` on YouTube rows that predate the column.

    One yt-dlp metadata lookup per row, so it runs in the background and the
    response says nothing about the outcome — watch `log/backend.log`. Rows
    whose video is gone stay NULL, and already-downloaded mp4s keep their
    untagged files; only the DB column is filled.
    """
    _check_token(request)
    background_tasks.add_task(backfill_channels)
    return {"status": "queued"}


class DevLogBatch(BaseModel):
    session: str
    records: list[dict]


@router.post("/api/devlog", status_code=204)
async def api_devlog(request: Request, batch: DevLogBatch):
    """Sink for the iOS app's DEVLOG instrumentation (device builds).

    Simulator runs write straight to the host file; a real iPad can't, so it
    batches records here and they land in the same ``log/ios.jsonl``. See
    devlog.py.
    """
    _check_token(request)

    if len(batch.records) > devlog.MAX_RECORDS_PER_REQUEST:
        raise HTTPException(status_code=413, detail="Too many records in batch")

    # This endpoint exists to observe the video endpoints, so it must never
    # compete with them: reject oversize bodies instead of buffering them, and
    # do the write off the event loop.
    content_length = request.headers.get("content-length")
    if content_length and content_length.isdigit() and int(content_length) > devlog.MAX_REQUEST_BYTES:
        raise HTTPException(status_code=413, detail="Batch too large")

    await asyncio.to_thread(devlog.append, batch.records)
    return Response(status_code=204)


@router.get("/api/videos/{video_id}")
async def api_video(video_id: int, request: Request):
    _check_token(request)
    video = db.get_video(video_id)
    if not video:
        raise HTTPException(status_code=404, detail="Video not found")
    return serialize_video(video)


def _safe_next(raw: str | None) -> str:
    """Same-site paths only. '//evil.example.com/' is a protocol-relative URL:
    it starts with '/' but browsers treat it as an absolute offsite address."""
    if not raw or not raw.startswith("/") or raw.startswith("//"):
        return "/"
    return raw


@router.get("/login", response_class=HTMLResponse)
async def login_page(request: Request, next: str | None = None):
    target = _safe_next(next)
    if _cookie_token_valid(request):
        return RedirectResponse(url=target, status_code=303)
    return HTMLResponse(build_login_page(next_url=target))


@router.post("/login")
async def login_submit(request: Request, token: str = Form(""), next: str = Form("/")):
    expected = os.getenv("UPLOAD_TOKEN", "")
    if not expected:
        raise HTTPException(status_code=503, detail="Upload not configured")
    target = _safe_next(next)
    if not _tokens_match(token, expected):
        return HTMLResponse(build_login_page(next_url=target, error=True), status_code=401)
    response = RedirectResponse(url=target, status_code=303)
    response.set_cookie(
        LOGIN_COOKIE,
        expected,
        max_age=LOGIN_COOKIE_MAX_AGE,
        path="/",
        httponly=True,
        samesite="strict",
        # The dev server answers plain HTTP on :3050; a Secure cookie would
        # never be stored there.
        secure=request.url.scheme == "https",
    )
    return response


@router.get("/logout")
async def logout():
    response = RedirectResponse(url="/login", status_code=303)
    response.delete_cookie(LOGIN_COOKIE, path="/")
    return response


@router.get("/", response_class=HTMLResponse)
@router.get("/videos", response_class=HTMLResponse)
async def videos_page(
    request: Request,
    group_id: int | None = None,
):
    if not _cookie_token_valid(request):
        target = request.url.path
        safe_params = [
            (key, value)
            for key, value in request.query_params.multi_items()
            if key != "token"
        ]
        if safe_params:
            target += "?" + urlencode(safe_params, doseq=True)
        return RedirectResponse(url=f"/login?next={quote(target, safe='')}", status_code=303)
    videos = db.get_all_videos(group_id=group_id)
    return build_videos_page(videos, db.list_groups(), group_id)


@router.get("/sd", response_class=HTMLResponse)
async def sd_page(request: Request):
    """Single-video shuffle player for an iPad 1 on iOS 5 (plain HTTP, LAN)."""
    if not _cookie_token_valid(request):
        return RedirectResponse(url=f"/login?next={quote('/sd', safe='')}", status_code=303)
    group_id = db.get_sd_state()["group_id"]
    video = sd.current_video() if group_id is not None else None
    total, ready = db.sd_counts(group_id) if group_id is not None else (0, 0)
    return build_sd_page(db.list_groups(), group_id, video, total, ready)


@router.post("/sd/group")
async def sd_select_group(request: Request, group_id: int = Form(...)):
    _check_token_or_query(request)
    if db.get_group(group_id) is None:
        raise HTTPException(status_code=404, detail="Group not found")
    sd.select_group(group_id)
    return RedirectResponse(url="/sd", status_code=303)


@router.post("/sd/next")
async def sd_next(request: Request):
    _check_token_or_query(request)
    video = sd.next_video()
    if "application/json" not in request.headers.get("Accept", ""):
        return RedirectResponse(url="/sd", status_code=303)
    if video is None:
        return Response(status_code=204)
    return {
        "id": video["id"],
        "title": _display_name(video),
        "src": f"/videos/{video['id']}/sd.mp4",
    }
