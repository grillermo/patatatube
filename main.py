import os
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
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer ") or auth[7:] != token:
        raise HTTPException(status_code=401, detail="Unauthorized")


class UploadRequest(BaseModel):
    url: str


@app.post("/upload", status_code=202)
async def upload(body: UploadRequest, request: Request, background_tasks: BackgroundTasks):
    _check_token(request)
    video_id = db.add_video(body.url)
    background_tasks.add_task(download_video, video_id, body.url)
    return {"id": video_id, "status": "queued"}
