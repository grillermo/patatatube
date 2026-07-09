import asyncio
import os
import re
import secrets
import tempfile
from collections.abc import AsyncIterator
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import anyio
from fastapi import APIRouter, BackgroundTasks, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, RedirectResponse, Response, StreamingResponse
from pydantic import BaseModel

import db
import hls
import library
import plex
import services
from db import CLASSIFICATIONS
from downloader import download_video, process_uploaded_video
from views.serializers import serialize_video
from views.render import build_videos_page

router = APIRouter()

VIDEOS_DIR = Path("videos")
PREVIEWS_DIR = Path("data/previews")
VIDEO_CHUNK_SIZE = 64 * 1024
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
    "apple-splash.png": ("apple-splash.png", "image/png"),
    "apple-splash-optimized.jpg": ("apple-splash-optimized.jpg", "image/jpeg"),
}
_static_asset_cache: dict[str, bytes] = {}


def _positive_int_env(name: str, default: int) -> int:
    try:
        return max(1, int(os.getenv(name, str(default))))
    except ValueError:
        return default


_video_stream_slots = asyncio.Semaphore(_positive_int_env("VIDEO_STREAM_LIMIT", DEFAULT_VIDEO_STREAM_LIMIT))

YOUTUBE_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")


def _check_token(request: Request):
    token = os.getenv("UPLOAD_TOKEN", "")
    if not token:
        raise HTTPException(status_code=503, detail="Upload not configured")
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer ") or not secrets.compare_digest(auth[7:], token):
        raise HTTPException(status_code=401, detail="Unauthorized")


def _check_token_or_query(request: Request):
    """Bearer auth with a ?token= fallback for HTML <video> tags, which can't send headers."""
    token = os.getenv("UPLOAD_TOKEN", "")
    if not token:
        raise HTTPException(status_code=503, detail="Upload not configured")
    auth = request.headers.get("Authorization", "")
    if auth.startswith("Bearer ") and secrets.compare_digest(auth[7:], token):
        return
    query_token = request.query_params.get("token", "")
    if query_token and secrets.compare_digest(query_token, token):
        return
    raise HTTPException(status_code=401, detail="Unauthorized")


class UploadRequest(BaseModel):
    url: str


class MoveRequest(BaseModel):
    direction: str


class ClassifyRequest(BaseModel):
    classification: str


class VersionRequest(BaseModel):
    version_id: int


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
    elif host in {"youtube.com", "m.youtube.com"}:
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


def _youtube_preview_url(video_id: str) -> str:
    return f"https://i.ytimg.com/vi/{video_id}/hqdefault.jpg"


def _classify_url(raw_url: str) -> dict:
    try:
        normalized_url, source_key = _normalize_twitter_url(raw_url)
        return {"platform": "twitter", "source_key": source_key, "normalized_url": normalized_url}
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
    _check_token(request)
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

    if source["platform"] == "youtube":
        existing = db.get_completed_video_by_source("youtube", source["source_key"])
        if existing:
            return {"id": existing["id"], "status": "queued"}

    video_id = db.add_video(
        source["normalized_url"] if source["platform"] == "youtube" else body.url,
        platform=source["platform"],
        source_key=source["source_key"],
        preview_url=_youtube_preview_url(source["source_key"]) if source["platform"] == "youtube" else None,
    )
    background_tasks.add_task(download_video, video_id)
    return {"id": video_id, "status": "queued"}


@router.post("/upload/file", status_code=202)
async def upload_file(
    request: Request,
    background_tasks: BackgroundTasks,
    file: UploadFile = File(...),
    classification: str = Form(...),
):
    _check_token(request)
    if classification not in CLASSIFICATIONS:
        raise HTTPException(status_code=400, detail="Invalid classification")

    suffix = Path(file.filename or "").suffix or ".mp4"
    with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
        tmp_path = Path(tmp.name)
        while chunk := await file.read(1024 * 1024):
            tmp.write(chunk)
    await file.close()

    title = Path(file.filename or "").stem or None
    video_id = db.add_video(str(tmp_path), platform="upload", title=title)
    services.apply_classification(video_id, classification)
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
    async with _video_stream_slots:
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

    # Reached here only if the whole requested range was streamed without the
    # client disconnecting. When it was the final byte of the file, the video
    # finished downloading to the client.
    if completion_title is not None:
        print(f"video {completion_title} uploaded", flush=True)


@router.get("/videos/{video_id}/preview")
async def video_preview(video_id: int, request: Request, kind: str = "item"):
    _check_token_or_query(request)
    video = db.get_video(video_id)
    if not video or video.get("source") != "library" or video.get("deleted_at"):
        raise HTTPException(status_code=404, detail="No preview")
    rating_key = video.get("show_rating_key") if kind == "show" else video.get("plex_rating_key")
    if not rating_key:
        raise HTTPException(status_code=404, detail="No preview")

    cache_file = PREVIEWS_DIR / f"{rating_key}.jpg"
    if not cache_file.exists():
        try:
            content = await asyncio.to_thread(plex.fetch_thumb, rating_key)
        except plex.PlexError as exc:
            raise HTTPException(status_code=502, detail=str(exc)) from exc
        PREVIEWS_DIR.mkdir(parents=True, exist_ok=True)
        cache_file.write_bytes(content)

    return Response(
        content=cache_file.read_bytes(),
        media_type="image/jpeg",
        headers={"Cache-Control": "public, max-age=86400"},
    )


@router.get("/videos/{video_id}/stream")
async def stream_video(video_id: int, request: Request):
    _check_token_or_query(request)
    video = db.get_video(video_id)
    if not video or video.get("deleted_at"):
        raise HTTPException(status_code=404, detail="Video not found or not ready")

    if video.get("source") == "library":
        requested_version = request.query_params.get("version_id")
        try:
            version_id = int(requested_version) if requested_version else None
        except ValueError:
            raise HTTPException(status_code=404, detail="Version not found")
        version = db.get_video_version(video_id, version_id)
        if not version:
            raise HTTPException(status_code=404, detail="Version not found")
        if version["status"] != "done":
            raise HTTPException(status_code=409, detail="Video not prepared yet")
        file_path = Path(version["converted_path"] or version["source_path"])
        mime = _guess_mime(file_path.name)
    else:
        if video["status"] != "done" or not video["filename"]:
            raise HTTPException(status_code=404, detail="Video not found or not ready")
        file_path = VIDEOS_DIR / video["filename"]
        mime = _guess_mime(video["filename"])

    if not file_path.exists():
        raise HTTPException(status_code=404, detail="Video file missing")

    file_size = file_path.stat().st_size
    range_header = request.headers.get("Range")

    if range_header:
        start, end = _parse_byte_range(range_header, file_size)
        chunk_size = end - start + 1
        is_last = end == file_size - 1

        return StreamingResponse(
            _iter_file_range(
                file_path,
                start,
                chunk_size,
                completion_title=video.get("title") if is_last else None,
            ),
            status_code=206,
            media_type=mime,
            headers={
                "Content-Range": f"bytes {start}-{end}/{file_size}",
                "Accept-Ranges": "bytes",
                "Content-Length": str(chunk_size),
                "Cache-Control": VIDEO_CACHE_CONTROL,
            },
        )

    return StreamingResponse(
        _iter_file_range(file_path, completion_title=video.get("title")),
        media_type=mime,
        headers={
            "Accept-Ranges": "bytes",
            "Content-Length": str(file_size),
            "Cache-Control": VIDEO_CACHE_CONTROL,
        },
    )


def _resolve_hls_source(video: dict, request: Request) -> Path:
    """Resolve the on-disk source for HLS exactly as /videos/{id}/stream does.

    Raises 409 when the resolved source is not ready (there is no 'completed'
    status: download rows gate on video status 'done', library rows on the
    chosen version's status 'done').
    """
    if video.get("source") == "library":
        requested_version = request.query_params.get("version_id")
        try:
            version_id = int(requested_version) if requested_version else None
        except ValueError:
            raise HTTPException(status_code=404, detail="Version not found")
        version = db.get_video_version(video["id"], version_id)
        if not version:
            raise HTTPException(status_code=404, detail="Version not found")
        if version["status"] != "done":
            raise HTTPException(status_code=409, detail="Video not prepared yet")
        return Path(version["converted_path"] or version["source_path"])

    if video["status"] != "done" or not video["filename"]:
        raise HTTPException(status_code=409, detail="Video not ready")
    return VIDEOS_DIR / video["filename"]


@router.get("/videos/{video_id}/hls/{asset_path:path}")
async def hls_asset(
    video_id: int, asset_path: str, request: Request, background_tasks: BackgroundTasks
):
    _check_token_or_query(request)
    video = db.get_video(video_id)
    if not video or video.get("deleted_at"):
        raise HTTPException(status_code=404, detail="Video not found")

    source = _resolve_hls_source(video, request)
    if not source.exists():
        raise HTTPException(status_code=404, detail="Source file missing")

    target = hls.safe_asset_path(video_id, asset_path)
    if target is None:
        raise HTTPException(status_code=404, detail="Not found")

    if target.exists():
        media_type = hls.HLS_CONTENT_TYPES.get(target.suffix.lower(), "application/octet-stream")
        return FileResponse(target, media_type=media_type)

    # Nothing on disk yet. Only the master request triggers packaging; segment
    # and subtitle requests before readiness are simply 404. Packaging runs off
    # the event loop and the client polls the master URL until it is 200.
    #
    # Return a real 409 Response (not raise): FastAPI only runs the injected
    # BackgroundTasks when the endpoint *returns* a response — a raised
    # HTTPException drops them, so the prep task would never fire.
    if asset_path == "master.m3u8":
        if video.get("hls_status") != "converting":
            db.set_hls_status(video_id, "converting")
            background_tasks.add_task(hls.prepare, video_id, str(source))
        return JSONResponse({"detail": "HLS preparing"}, status_code=409)

    raise HTTPException(status_code=404, detail="Not found")


@router.get("/favicon.ico", include_in_schema=False)
async def favicon():
    return _static_asset_response("favicon.ico")


@router.get("/apple-touch-icon.png", include_in_schema=False)
async def apple_touch_icon():
    return _static_asset_response("apple-touch-icon.png")


@router.get("/apple-splash.png", include_in_schema=False)
async def apple_splash():
    return _static_asset_response("apple-splash.png")


@router.get("/apple-splash-optimized.jpg", include_in_schema=False)
async def apple_splash_optimized():
    return _static_asset_response("apple-splash-optimized.jpg")


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


@router.post("/videos/{video_id}/move")
async def move_video_endpoint(video_id: int, direction: str = Form(...), classification: str | None = Form(default=None)):
    services.apply_move(video_id, direction)
    redirect_url = f"/?classification={classification}" if classification else "/"
    return RedirectResponse(url=redirect_url, status_code=303)


@router.post("/videos/{video_id}/classify")
async def classify_video_endpoint(video_id: int, classification: str = Form(...), current_classification: str | None = Form(default=None)):
    services.apply_classification(video_id, classification)
    redirect_url = f"/?classification={current_classification}" if current_classification else "/"
    return RedirectResponse(url=redirect_url, status_code=303)


@router.post("/videos/{video_id}/version")
async def choose_video_version_endpoint(video_id: int, version_id: int = Form(...), classification: str | None = Form(default=None)):
    services.choose_version(video_id, version_id)
    redirect_url = f"/?classification={classification}" if classification else "/"
    return RedirectResponse(url=redirect_url, status_code=303)


@router.get("/api/classifications")
async def api_classifications():
    return {"classifications": CLASSIFICATIONS}


@router.get("/api/videos")
async def api_videos(classification: str | None = None):
    if classification and classification not in CLASSIFICATIONS:
        classification = None
    videos = db.get_all_videos(classification)
    return [serialize_video(v) for v in videos]


@router.post("/api/videos/{video_id}/move")
async def api_move_video(video_id: int, body: MoveRequest, request: Request):
    _check_token(request)
    ok = services.apply_move(video_id, body.direction)
    return {"ok": ok}


@router.post("/api/videos/{video_id}/classify")
async def api_classify_video(video_id: int, body: ClassifyRequest, request: Request):
    _check_token(request)
    ok = services.apply_classification(video_id, body.classification)
    return {"ok": ok}


@router.post("/api/videos/{video_id}/version")
async def api_choose_video_version(video_id: int, body: VersionRequest, request: Request):
    _check_token(request)
    ok = services.choose_version(video_id, body.version_id)
    return {"ok": ok}


@router.post("/api/video/{video_id}/delete")
async def api_delete_video(video_id: int, request: Request):
    _check_token(request)
    video = db.get_video(video_id)
    if video:
        if video.get("source") == "library":
            for version in video.get("versions", []):
                if version.get("converted_path"):
                    Path(version["converted_path"]).unlink(missing_ok=True)
            if video.get("converted_path"):
                Path(video["converted_path"]).unlink(missing_ok=True)
            db.tombstone_video(video_id)
        else:
            if video.get("filename"):
                (VIDEOS_DIR / video["filename"]).unlink(missing_ok=True)
            db.delete_video(video_id)
    return {"ok": True}


@router.post("/api/library/scan")
async def api_library_scan(request: Request):
    _check_token(request)
    if not os.getenv("PLEX_TOKEN"):
        raise HTTPException(status_code=503, detail="Plex not configured (set PLEX_TOKEN)")
    try:
        return await asyncio.to_thread(library.scan_library)
    except plex.PlexError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@router.get("/api/videos/{video_id}")
async def api_video(video_id: int, request: Request):
    _check_token(request)
    video = db.get_video(video_id)
    if not video or video.get("deleted_at"):
        raise HTTPException(status_code=404, detail="Video not found")
    # Single-row detail: a filesystem probe for sidecar subtitles is fine here
    # (unlike the list endpoint, which must stay allocation-cheap per row).
    if video.get("source") == "library":
        version = db.get_video_version(video_id)
        if version and version.get("source_path"):
            video = {
                **video,
                "subtitle_tracks": [
                    {
                        "language": track.language,
                        "name": track.name,
                        "default": track.default,
                        "forced": track.forced,
                    }
                    for track in hls.discover_subtitles(version["source_path"])
                ],
            }
    return serialize_video(video)


@router.post("/api/videos/{video_id}/prepare")
async def api_prepare_video(video_id: int, request: Request, background_tasks: BackgroundTasks):
    _check_token(request)
    video = db.get_video(video_id)
    if not video or video.get("deleted_at"):
        raise HTTPException(status_code=404, detail="Video not found")
    if video.get("source") != "library":
        raise HTTPException(status_code=400, detail="Only library videos need preparing")

    version = db.get_video_version(video_id)
    if not version:
        raise HTTPException(status_code=404, detail="Version not found")
    if version["status"] == "done":
        return {"status": "done"}
    if version["status"] == "converting":
        return JSONResponse({"status": "converting"}, status_code=202)

    source = Path(version["source_path"])
    if not source.exists():
        db.set_library_state(video_id, "unconverted", error_msg=f"source file missing: {source}", version_id=version["id"])
        raise HTTPException(status_code=404, detail="Source file missing")

    # Write "converting" now, before the first await, so a second concurrent
    # request for this same video reads "converting" on its own db.get_video
    # call above and takes the no-op 202 early-return instead of racing
    # through to a second probe + queued background task. (Not airtight
    # against two requests reading the old status in the exact same instant
    # before either writes, but this closes the practical window between
    # overlapping requests a few milliseconds apart.)
    db.set_library_state(video_id, "converting", version_id=version["id"])

    try:
        plan = await asyncio.to_thread(lambda: library.plan_conversion(library.probe_source(source)))
    except Exception as exc:  # ffprobe failure
        db.set_library_state(video_id, "unconverted", error_msg=str(exc), version_id=version["id"])
        raise HTTPException(status_code=500, detail=str(exc)) from exc

    if plan.passthrough:
        db.set_library_state(video_id, "done", version_id=version["id"])
        return {"status": "done"}

    background_tasks.add_task(library.convert_library_video, video_id)
    return JSONResponse({"status": "converting"}, status_code=202)


@router.get("/", response_class=HTMLResponse)
@router.get("/videos", response_class=HTMLResponse)
async def videos_page(classification: str | None = None):
    if classification and classification not in CLASSIFICATIONS:
        classification = None
    videos = db.get_all_videos(classification)
    return build_videos_page(videos, CLASSIFICATIONS, classification)
