import asyncio
import multiprocessing
import os
import re
import secrets
from collections.abc import AsyncIterator
from html import escape
from pathlib import Path
from contextlib import asynccontextmanager
from urllib.parse import parse_qs, urlparse

import anyio
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Request, BackgroundTasks
from fastapi.middleware.trustedhost import TrustedHostMiddleware
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, Response, StreamingResponse
from pydantic import BaseModel
from setproctitle import setproctitle

import db
from downloader import download_video

load_dotenv()

PROCESS_NAME = "[PatataTube]"
VIDEOS_DIR = Path("videos")
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

# filename, CSS device width, CSS device height, pixel ratio, orientation
SPLASH_STARTUP_IMAGES = (
    ("4__iPhone_SE__iPod_touch_5th_generation_and_later_portrait.png", 320, 568, 2, "portrait"),
    ("4__iPhone_SE__iPod_touch_5th_generation_and_later_landscape.png", 320, 568, 2, "landscape"),
    ("iPhone_8__iPhone_7__iPhone_6s__iPhone_6__4.7__iPhone_SE_portrait.png", 375, 667, 2, "portrait"),
    ("iPhone_8__iPhone_7__iPhone_6s__iPhone_6__4.7__iPhone_SE_landscape.png", 375, 667, 2, "landscape"),
    ("iPhone_8_Plus__iPhone_7_Plus__iPhone_6s_Plus__iPhone_6_Plus_portrait.png", 414, 736, 3, "portrait"),
    ("iPhone_8_Plus__iPhone_7_Plus__iPhone_6s_Plus__iPhone_6_Plus_landscape.png", 414, 736, 3, "landscape"),
    ("iPhone_13_mini__iPhone_12_mini__iPhone_11_Pro__iPhone_XS__iPhone_X_portrait.png", 375, 812, 3, "portrait"),
    ("iPhone_13_mini__iPhone_12_mini__iPhone_11_Pro__iPhone_XS__iPhone_X_landscape.png", 375, 812, 3, "landscape"),
    ("iPhone_11__iPhone_XR_portrait.png", 414, 896, 2, "portrait"),
    ("iPhone_11__iPhone_XR_landscape.png", 414, 896, 2, "landscape"),
    ("iPhone_11_Pro_Max__iPhone_XS_Max_portrait.png", 414, 896, 3, "portrait"),
    ("iPhone_11_Pro_Max__iPhone_XS_Max_landscape.png", 414, 896, 3, "landscape"),
    ("iPhone_17e__iPhone_16e__iPhone_14__iPhone_13_Pro__iPhone_13__iPhone_12_Pro__iPhone_12_portrait.png", 390, 844, 3, "portrait"),
    ("iPhone_17e__iPhone_16e__iPhone_14__iPhone_13_Pro__iPhone_13__iPhone_12_Pro__iPhone_12_landscape.png", 390, 844, 3, "landscape"),
    ("iPhone_14_Plus__iPhone_13_Pro_Max__iPhone_12_Pro_Max_portrait.png", 428, 926, 3, "portrait"),
    ("iPhone_14_Plus__iPhone_13_Pro_Max__iPhone_12_Pro_Max_landscape.png", 428, 926, 3, "landscape"),
    ("iPhone_16__iPhone_15_Pro__iPhone_15__iPhone_14_Pro_portrait.png", 393, 852, 3, "portrait"),
    ("iPhone_16__iPhone_15_Pro__iPhone_15__iPhone_14_Pro_landscape.png", 393, 852, 3, "landscape"),
    ("iPhone_16_Plus__iPhone_15_Pro_Max__iPhone_15_Plus__iPhone_14_Pro_Max_portrait.png", 430, 932, 3, "portrait"),
    ("iPhone_16_Plus__iPhone_15_Pro_Max__iPhone_15_Plus__iPhone_14_Pro_Max_landscape.png", 430, 932, 3, "landscape"),
    ("iPhone_Air_landscape.png", 420, 912, 3, "landscape"),
    ("iPhone_17_Pro__iPhone_17__iPhone_16_Pro_portrait.png", 402, 874, 3, "portrait"),
    ("iPhone_17_Pro__iPhone_17__iPhone_16_Pro_landscape.png", 402, 874, 3, "landscape"),
    ("iPhone_17_Pro_Max__iPhone_16_Pro_Max_portrait.png", 440, 956, 3, "portrait"),
    ("iPhone_17_Pro_Max__iPhone_16_Pro_Max_landscape.png", 440, 956, 3, "landscape"),
    ("9.7__iPad_Pro__7.9__iPad_mini__9.7__iPad_Air__9.7__iPad_portrait.png", 768, 1024, 2, "portrait"),
    ("9.7__iPad_Pro__7.9__iPad_mini__9.7__iPad_Air__9.7__iPad_landscape.png", 768, 1024, 2, "landscape"),
    ("10.2__iPad_portrait.png", 810, 1080, 2, "portrait"),
    ("10.2__iPad_landscape.png", 810, 1080, 2, "landscape"),
    ("10.5__iPad_Air_portrait.png", 834, 1112, 2, "portrait"),
    ("10.5__iPad_Air_landscape.png", 834, 1112, 2, "landscape"),
    ("10.9__iPad_Air_portrait.png", 820, 1180, 2, "portrait"),
    ("10.9__iPad_Air_landscape.png", 820, 1180, 2, "landscape"),
    ("8.3__iPad_Mini_portrait.png", 744, 1133, 2, "portrait"),
    ("8.3__iPad_Mini_landscape.png", 744, 1133, 2, "landscape"),
    ("11__iPad_Pro__10.5__iPad_Pro_portrait.png", 834, 1194, 2, "portrait"),
    ("11__iPad_Pro__10.5__iPad_Pro_landscape.png", 834, 1194, 2, "landscape"),
    ("11__iPad_Pro_M4_portrait.png", 834, 1210, 2, "portrait"),
    ("11__iPad_Pro_M4_landscape.png", 834, 1210, 2, "landscape"),
    ("12.9__iPad_Pro_portrait.png", 1024, 1366, 2, "portrait"),
    ("12.9__iPad_Pro_landscape.png", 1024, 1366, 2, "landscape"),
    ("13__iPad_Pro_M4_portrait.png", 1032, 1376, 2, "portrait"),
    ("13__iPad_Pro_M4_landscape.png", 1032, 1376, 2, "landscape"),
    ("iphone-16-pro-max.jpg", 440, 956, 3, "portrait"),
    ("iphone-15-pro-max.jpg", 430, 932, 3, "portrait"),
    ("iphone-15-14-pro.jpg", 393, 852, 3, "portrait"),
    ("iphone-13-12-pro.jpg", 390, 844, 3, "portrait"),
    ("iphone-14-plus.jpg", 428, 926, 3, "portrait"),
    ("iphone-11-pro-max-xs-max.jpg", 414, 896, 3, "portrait"),
    ("iphone-11-xr.jpg", 414, 896, 2, "portrait"),
    ("iphone-8-plus.jpg", 414, 736, 3, "portrait"),
)

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


def _set_process_name(name: str = PROCESS_NAME) -> None:
    multiprocessing.current_process().name = name
    setproctitle(name)


@asynccontextmanager
async def lifespan(app: FastAPI):
    _set_process_name()
    db.init_db()
    VIDEOS_DIR.mkdir(exist_ok=True)
    SPLASH_DIR.mkdir(parents=True, exist_ok=True)
    _load_static_asset_cache()
    yield


app = FastAPI(lifespan=lifespan)

allowed_hosts = [
    h.strip()
    for h in os.getenv(
        "ALLOWED_HOSTS",
        "videos.chiq.me,patatatube.chiq.me,localhost,127.0.0.1,testserver",
    ).split(",")
    if h.strip()
]
app.add_middleware(TrustedHostMiddleware, allowed_hosts=allowed_hosts)

YOUTUBE_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")


def _check_token(request: Request):
    token = os.getenv("UPLOAD_TOKEN", "")
    if not token:
        raise HTTPException(status_code=503, detail="Upload not configured")
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer ") or not secrets.compare_digest(auth[7:], token):
        raise HTTPException(status_code=401, detail="Unauthorized")


class UploadRequest(BaseModel):
    url: str


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


@app.post("/upload", status_code=202)
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


async def _iter_file_range(file_path: Path, start: int = 0, byte_count: int | None = None) -> AsyncIterator[bytes]:
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


@app.get("/videos/{video_id}/stream")
async def stream_video(video_id: int, request: Request):
    video = db.get_video(video_id)
    if not video or video["status"] != "done" or not video["filename"]:
        raise HTTPException(status_code=404, detail="Video not found or not ready")

    file_path = VIDEOS_DIR / video["filename"]
    if not file_path.exists():
        raise HTTPException(status_code=404, detail="Video file missing")

    file_size = file_path.stat().st_size
    mime = _guess_mime(video["filename"])
    range_header = request.headers.get("Range")

    if range_header:
        start, end = _parse_byte_range(range_header, file_size)
        chunk_size = end - start + 1

        return StreamingResponse(
            _iter_file_range(file_path, start, chunk_size),
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
        _iter_file_range(file_path),
        media_type=mime,
        headers={
            "Accept-Ranges": "bytes",
            "Content-Length": str(file_size),
            "Cache-Control": VIDEO_CACHE_CONTROL,
        },
    )


def _status_badge(status: str) -> str:
    colors = {"queued": "#888", "downloading": "#f90", "done": "#0a0", "error": "#c00"}
    return f'<span style="color:{colors.get(status,"#888")};font-size:0.8em">{status}</span>'


def _splash_startup_link(filename: str, width: int, height: int, scale: int, orientation: str) -> str:
    media = (
        f"(device-width: {width}px) and (device-height: {height}px) "
        f"and (-webkit-device-pixel-ratio: {scale}) and (orientation: {orientation})"
    )
    return (
        '<link rel="apple-touch-startup-image" '
        f'media="{media}" href="/assets/splash/{escape(filename, quote=True)}">'
    )


def _splash_startup_links() -> str:
    links = ['<link rel="apple-touch-startup-image" href="/apple-splash-optimized.jpg">']
    links.extend(_splash_startup_link(*image) for image in SPLASH_STARTUP_IMAGES)
    return "\n".join(links)


def _build_html(videos: list[dict]) -> str:
    cards = []
    for v in videos:
        badge = _status_badge(v["status"])
        short_url = escape(v["url"][:60]) + ("…" if len(v["url"]) > 60 else "")
        title = escape(v["title"]) if v.get("platform") == "youtube" and v.get("title") else None

        if v["status"] == "done":
            player = f"""
            <video id="v{v['id']}" controls playsinline webkit-playsinline preload="auto"
                   style="width:100%;border-radius:8px;background:#000;"
                   onloadedmetadata="this.currentTime=0">
              <source src="/videos/{v['id']}/stream" type="video/mp4">
            </video>"""
        elif v["status"] == "error":
            player = f'<p style="color:#c00;font-size:0.85em">Error: {escape(v.get("error_msg","unknown"))}</p>'
        else:
            player = f'<p style="color:#aaa;font-size:0.85em">Video is {v["status"]}…</p>'

        cards.append(f"""
        <div class="card">
          <div class="meta">
            {f'<div class="title">{title}</div>' if title else ''}
            <div>{badge} &nbsp;{short_url}</div>
          </div>
          {player}
        </div>""")

    cards_html = "\n".join(cards) if cards else '<p style="color:#aaa;text-align:center">No videos yet.</p>'
    splash_links = _splash_startup_links()

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover">
<title>Patata Videos</title>
<meta name="theme-color" content="#111111">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-title" content="Videos">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<link rel="icon" href="/favicon.ico" sizes="any">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
{splash_links}
<link rel="manifest" href="/manifest.webmanifest">
<style>
  *{{box-sizing:border-box;margin:0;padding:0}}
  body{{background:#111;color:#eee;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;padding:12px;padding-top:calc(12px + env(safe-area-inset-top));padding-bottom:calc(12px + env(safe-area-inset-bottom));padding-left:calc(12px + env(safe-area-inset-left));padding-right:calc(12px + env(safe-area-inset-right));}}
  @media (display-mode: standalone) {{
    body{{min-height:100dvh}}
  }}
  .card{{background:#1e1e1e;border-radius:10px;padding:12px;margin-bottom:14px;max-width:480px;margin-left:auto;margin-right:auto}}
  .meta{{font-size:0.78em;color:#aaa;margin-bottom:8px;word-break:break-all}}
  .title{{font-size:1.15em;color:#eee;margin-bottom:4px;word-break:break-word}}
  video{{display:block}}
</style>
</head>
<body>
<h2 style="text-align:center;margin-bottom:16px;font-size:1.1em;max-width:480px;margin-left:auto;margin-right:auto">Patata Videos</h2>
{cards_html}
<script>
var activePreloadController = null;
var activePreloadVideoId = null;
var completedPreloads = new Set();

function reloadUnreadyVideos(){{
  document.querySelectorAll('video[id]').forEach(function(v){{
    if(v.readyState === 0 || v.error) {{
      try {{ v.load(); }} catch (_err) {{}}
    }}
  }});
}}

function stopAllPreloads(){{
  if(!activePreloadController) return;
  try {{ activePreloadController.abort(); }} catch (_err) {{}}
  activePreloadController = null;
  activePreloadVideoId = null;
}}

function resolveVideoSource(video){{
  if(video.currentSrc) return video.currentSrc;
  if(video.src) return video.src;
  var source = video.querySelector('source[src]');
  return source ? source.getAttribute('src') : null;
}}

function pauseOtherVideos(activeVideo){{
  document.querySelectorAll('video[id]').forEach(function(v){{
    if(v === activeVideo || v.paused || v.ended) return;
    try {{ v.pause(); }} catch (_err) {{}}
  }});
}}

function preloadEntireVideo(video){{
  if(typeof fetch !== 'function' || typeof AbortController === 'undefined') return;

  var src = resolveVideoSource(video);
  if(!src) return;
  if(completedPreloads.has(video.id)) return;
  if(activePreloadVideoId === video.id && activePreloadController) return;

  stopAllPreloads();
  var controller = new AbortController();
  activePreloadController = controller;
  activePreloadVideoId = video.id;

  fetch(src, {{ signal: controller.signal, cache: 'force-cache', credentials: 'same-origin' }})
    .then(function(resp){{
      if(activePreloadVideoId !== video.id || activePreloadController !== controller) return;
      if(!resp.ok || !resp.body || typeof resp.body.getReader !== 'function') return;

      var reader = resp.body.getReader();
      function pump(){{
        return reader.read().then(function(step){{
          if(step.done) {{
            completedPreloads.add(video.id);
            return;
          }}
          if(activePreloadVideoId !== video.id || activePreloadController !== controller) {{
            try {{ reader.cancel(); }} catch (_err) {{}}
            return;
          }}
          return pump();
        }});
      }}
      return pump();
    }})
    .catch(function(err){{
      if(err && err.name === 'AbortError') return;
    }})
    .finally(function(){{
      if(activePreloadVideoId === video.id && activePreloadController === controller) {{
        activePreloadVideoId = null;
        activePreloadController = null;
      }}
    }});
}}

document.querySelectorAll('video[id]').forEach(function(v){{
  v.addEventListener('play', function(){{
    pauseOtherVideos(v);
    preloadEntireVideo(v);
  }});
  v.addEventListener('pause', function(){{
    if(activePreloadVideoId === v.id) {{
      stopAllPreloads();
    }}
  }});
  v.addEventListener('ended', function(){{
    if(activePreloadVideoId === v.id) {{
      stopAllPreloads();
    }}
  }});
}});

window.addEventListener('pageshow', reloadUnreadyVideos);
window.addEventListener('pagehide', stopAllPreloads);
document.addEventListener('visibilitychange', function(){{
  if(document.hidden) {{
    stopAllPreloads();
    return;
  }}
  reloadUnreadyVideos();
}});
</script>
</body>
</html>"""


@app.get("/favicon.ico", include_in_schema=False)
async def favicon():
    return _static_asset_response("favicon.ico")


@app.get("/apple-touch-icon.png", include_in_schema=False)
async def apple_touch_icon():
    return _static_asset_response("apple-touch-icon.png")


@app.get("/apple-splash.png", include_in_schema=False)
async def apple_splash():
    return _static_asset_response("apple-splash.png")


@app.get("/apple-splash-optimized.jpg", include_in_schema=False)
async def apple_splash_optimized():
    return _static_asset_response("apple-splash-optimized.jpg")


@app.get("/assets/splash/{filename}", include_in_schema=False)
async def splash_asset(filename: str):
    safe_name = Path(filename).name
    if safe_name != filename:
        raise HTTPException(status_code=404, detail="Not found")
    target = SPLASH_DIR / safe_name
    media_type = SPLASH_MIME_TYPES.get(target.suffix.lower())
    if not target.exists() or media_type is None:
        raise HTTPException(status_code=404, detail="Not found")
    return FileResponse(target, media_type=media_type)


@app.get("/manifest.webmanifest", include_in_schema=False)
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


@app.get("/", response_class=HTMLResponse)
@app.get("/videos", response_class=HTMLResponse)
async def videos_page():
    all_videos = db.get_all_videos()
    return _build_html(all_videos)
