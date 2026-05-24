import os
import re
import secrets
from html import escape
from pathlib import Path
from contextlib import asynccontextmanager
from urllib.parse import parse_qs, urlparse

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Request, BackgroundTasks
from fastapi.middleware.trustedhost import TrustedHostMiddleware
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, StreamingResponse
from pydantic import BaseModel

import db
from downloader import download_video

load_dotenv()

VIDEOS_DIR = Path("videos")
SPLASH_DIR = Path("assets/splash")


@asynccontextmanager
async def lifespan(app: FastAPI):
    db.init_db()
    VIDEOS_DIR.mkdir(exist_ok=True)
    SPLASH_DIR.mkdir(parents=True, exist_ok=True)
    yield


app = FastAPI(lifespan=lifespan)

allowed_hosts = [h.strip() for h in os.getenv("ALLOWED_HOSTS", "videos.chiq.me,localhost,127.0.0.1,testserver").split(",") if h.strip()]
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
    return {"mp4": "video/mp4", "webm": "video/webm", "mov": "video/quicktime"}.get(ext[1:], "video/mp4")


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
        try:
            unit, ranges = range_header.split("=")
            if unit.strip() != "bytes":
                raise HTTPException(status_code=416, detail="Invalid Range header")
            start_str, end_str = ranges.split("-")
            start = int(start_str)
            end = int(end_str) if end_str else file_size - 1
        except (ValueError, AttributeError):
            raise HTTPException(status_code=416, detail="Invalid Range header")

        if start >= file_size or end >= file_size or start > end:
            raise HTTPException(
                status_code=416,
                headers={"Content-Range": f"bytes */{file_size}"},
                detail="Range Not Satisfiable",
            )

        chunk_size = end - start + 1

        def iter_chunk():
            with open(file_path, "rb") as f:
                f.seek(start)
                remaining = chunk_size
                while remaining > 0:
                    data = f.read(min(65536, remaining))
                    if not data:
                        break
                    remaining -= len(data)
                    yield data

        return StreamingResponse(
            iter_chunk(),
            status_code=206,
            media_type=mime,
            headers={
                "Content-Range": f"bytes {start}-{end}/{file_size}",
                "Accept-Ranges": "bytes",
                "Content-Length": str(chunk_size),
            },
        )

    def iter_full():
        with open(file_path, "rb") as f:
            while chunk := f.read(65536):
                yield chunk

    return StreamingResponse(
        iter_full(),
        media_type=mime,
        headers={
            "Accept-Ranges": "bytes",
            "Content-Length": str(file_size),
        },
    )


def _status_badge(status: str) -> str:
    colors = {"queued": "#888", "downloading": "#f90", "done": "#0a0", "error": "#c00"}
    return f'<span style="color:{colors.get(status,"#888")};font-size:0.8em">{status}</span>'


def _build_html(videos: list[dict]) -> str:
    cards = []
    for v in videos:
        badge = _status_badge(v["status"])
        short_url = escape(v["url"][:60]) + ("…" if len(v["url"]) > 60 else "")
        title = escape(v["title"]) if v.get("platform") == "youtube" and v.get("title") else None

        if v["status"] == "done":
            player = f"""
            <video id="v{v['id']}" controls playsinline preload="metadata"
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

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover">
<title>Videos</title>
<meta name="theme-color" content="#111111">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-title" content="Videos">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<link rel="icon" href="/favicon.ico" sizes="any">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="apple-touch-startup-image" href="/apple-splash-optimized.jpg">
<link rel="apple-touch-startup-image" media="(device-width: 440px) and (device-height: 956px) and (-webkit-device-pixel-ratio: 3) and (orientation: portrait)" href="/assets/splash/iphone-16-pro-max.jpg">
<link rel="apple-touch-startup-image" media="(device-width: 430px) and (device-height: 932px) and (-webkit-device-pixel-ratio: 3) and (orientation: portrait)" href="/assets/splash/iphone-15-pro-max.jpg">
<link rel="apple-touch-startup-image" media="(device-width: 393px) and (device-height: 852px) and (-webkit-device-pixel-ratio: 3) and (orientation: portrait)" href="/assets/splash/iphone-15-14-pro.jpg">
<link rel="apple-touch-startup-image" media="(device-width: 390px) and (device-height: 844px) and (-webkit-device-pixel-ratio: 3) and (orientation: portrait)" href="/assets/splash/iphone-13-12-pro.jpg">
<link rel="apple-touch-startup-image" media="(device-width: 428px) and (device-height: 926px) and (-webkit-device-pixel-ratio: 3) and (orientation: portrait)" href="/assets/splash/iphone-14-plus.jpg">
<link rel="apple-touch-startup-image" media="(device-width: 414px) and (device-height: 896px) and (-webkit-device-pixel-ratio: 3) and (orientation: portrait)" href="/assets/splash/iphone-11-pro-max-xs-max.jpg">
<link rel="apple-touch-startup-image" media="(device-width: 414px) and (device-height: 896px) and (-webkit-device-pixel-ratio: 2) and (orientation: portrait)" href="/assets/splash/iphone-11-xr.jpg">
<link rel="apple-touch-startup-image" media="(device-width: 414px) and (device-height: 736px) and (-webkit-device-pixel-ratio: 3) and (orientation: portrait)" href="/assets/splash/iphone-8-plus.jpg">
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
<h2 style="text-align:center;margin-bottom:16px;font-size:1.1em;max-width:480px;margin-left:auto;margin-right:auto">Videos</h2>
{cards_html}
<script>
var isIphone = /iPhone/i.test(navigator.userAgent);
function enterFullscreenOnIphone(video){{
  if(!isIphone || !video) return;
  if(typeof video.webkitEnterFullscreen === 'function') {{
    try {{ video.webkitEnterFullscreen(); }} catch (_err) {{}}
    return;
  }}
  if(video.requestFullscreen) {{
    var fsPromise = video.requestFullscreen();
    if(fsPromise && fsPromise.catch) fsPromise.catch(function(){{}});
  }}
}}

document.querySelectorAll('video[id]').forEach(function(v){{
  v.addEventListener('play',function(){{enterFullscreenOnIphone(v);}});
}});
</script>
</body>
</html>"""


@app.get("/favicon.ico", include_in_schema=False)
async def favicon():
    return FileResponse("favicon.ico", media_type="image/x-icon")


@app.get("/apple-touch-icon.png", include_in_schema=False)
async def apple_touch_icon():
    return FileResponse("apple-touch-icon.png", media_type="image/png")


@app.get("/apple-splash.png", include_in_schema=False)
async def apple_splash():
    return FileResponse("apple-splash.png", media_type="image/png")


@app.get("/apple-splash-optimized.jpg", include_in_schema=False)
async def apple_splash_optimized():
    return FileResponse("apple-splash-optimized.jpg", media_type="image/jpeg")


@app.get("/assets/splash/{filename}", include_in_schema=False)
async def splash_asset(filename: str):
    safe_name = Path(filename).name
    if safe_name != filename:
        raise HTTPException(status_code=404, detail="Not found")
    target = SPLASH_DIR / safe_name
    if not target.exists() or target.suffix.lower() != ".jpg":
        raise HTTPException(status_code=404, detail="Not found")
    return FileResponse(target, media_type="image/jpeg")


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
