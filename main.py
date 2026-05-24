import os
import secrets
from html import escape
from pathlib import Path
from contextlib import asynccontextmanager

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Request, BackgroundTasks
from fastapi.responses import HTMLResponse, StreamingResponse
from pydantic import BaseModel

import db
from downloader import download_video

load_dotenv()

VIDEOS_DIR = Path("videos")


@asynccontextmanager
async def lifespan(app: FastAPI):
    db.init_db()
    VIDEOS_DIR.mkdir(exist_ok=True)
    yield


app = FastAPI(lifespan=lifespan)


def _check_token(request: Request):
    token = os.getenv("UPLOAD_TOKEN", "")
    if not token:
        raise HTTPException(status_code=503, detail="Upload not configured")
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer ") or not secrets.compare_digest(auth[7:], token):
        raise HTTPException(status_code=401, detail="Unauthorized")


class UploadRequest(BaseModel):
    url: str


@app.post("/upload", status_code=202)
async def upload(body: UploadRequest, request: Request, background_tasks: BackgroundTasks):
    _check_token(request)
    video_id = db.add_video(body.url)
    background_tasks.add_task(download_video, video_id, body.url)
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


class ProgressRequest(BaseModel):
    position_seconds: float


@app.post("/videos/{video_id}/progress")
async def save_progress(video_id: int, body: ProgressRequest):
    if not db.get_video(video_id):
        raise HTTPException(status_code=404, detail="Video not found")
    db.upsert_progress(video_id, body.position_seconds)
    return {"ok": True}


def _status_badge(status: str) -> str:
    colors = {"queued": "#888", "downloading": "#f90", "done": "#0a0", "error": "#c00"}
    return f'<span style="color:{colors.get(status,"#888")};font-size:0.8em">{status}</span>'


def _build_html(videos: list[dict]) -> str:
    cards = []
    for v in videos:
        progress = db.get_progress(v["id"])
        badge = _status_badge(v["status"])
        short_url = escape(v["url"][:60]) + ("…" if len(v["url"]) > 60 else "")

        if v["status"] == "done":
            player = f"""
            <video id="v{v['id']}" controls playsinline preload="metadata"
                   style="width:100%;border-radius:8px;background:#000;"
                   onloadedmetadata="this.currentTime={progress}">
              <source src="/videos/{v['id']}/stream" type="video/mp4">
            </video>"""
        elif v["status"] == "error":
            player = f'<p style="color:#c00;font-size:0.85em">Error: {escape(v.get("error_msg","unknown"))}</p>'
        else:
            player = f'<p style="color:#aaa;font-size:0.85em">Video is {v["status"]}…</p>'

        cards.append(f"""
        <div class="card">
          <div class="meta">{badge} &nbsp;{short_url}</div>
          {player}
        </div>""")

    cards_html = "\n".join(cards) if cards else '<p style="color:#aaa;text-align:center">No videos yet.</p>'

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Watch Later</title>
<style>
  *{{box-sizing:border-box;margin:0;padding:0}}
  body{{background:#111;color:#eee;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;padding:12px}}
  .card{{background:#1e1e1e;border-radius:10px;padding:12px;margin-bottom:14px;max-width:480px;margin-left:auto;margin-right:auto}}
  .meta{{font-size:0.78em;color:#aaa;margin-bottom:8px;word-break:break-all}}
  video{{display:block}}
</style>
</head>
<body>
<h2 style="text-align:center;margin-bottom:16px;font-size:1.1em;max-width:480px;margin-left:auto;margin-right:auto">Watch Later</h2>
{cards_html}
<script>
document.querySelectorAll('video[id]').forEach(function(v){{
  var lastSaved=v.currentTime, timer=null;
  function save(){{
    if(v.currentTime===lastSaved) return;
    lastSaved=v.currentTime;
    fetch('/videos/'+v.id.slice(1)+'/progress',{{
      method:'POST',
      headers:{{'Content-Type':'application/json'}},
      body:JSON.stringify({{position_seconds:v.currentTime}})
    }});
  }}
  v.addEventListener('play',function(){{timer=setInterval(save,5000)}});
  v.addEventListener('pause',function(){{clearInterval(timer);save()}});
  v.addEventListener('ended',function(){{clearInterval(timer);save()}});
}});
</script>
</body>
</html>"""


@app.get("/", response_class=HTMLResponse)
@app.get("/videos", response_class=HTMLResponse)
async def videos_page():
    all_videos = db.get_all_videos()
    return _build_html(all_videos)
