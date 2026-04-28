# Twitter Watch Later Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** FastAPI app that downloads Twitter videos in the background via pybalt, stores metadata in SQLite, and streams them on a mobile-optimized HTML page with resume support.

**Architecture:** Four-file Python app — `db.py` owns all SQLite access, `downloader.py` owns pybalt integration, `main.py` owns FastAPI routes. Background download uses FastAPI `BackgroundTasks` (no extra infra). Byte-range streaming implemented manually via `StreamingResponse`.

**Tech Stack:** Python 3.11+, FastAPI, uvicorn, pybalt, python-dotenv, pytest, httpx

---

## File Map

| File | Responsibility |
|------|----------------|
| `main.py` | FastAPI app, all routes, startup |
| `db.py` | SQLite init + all queries |
| `downloader.py` | pybalt download + file move + DB status updates |
| `requirements.txt` | Pinned deps |
| `.env.example` | Token template |
| `.gitignore` | Exclude videos/, data/, .env |
| `tests/test_db.py` | DB helper unit tests |
| `tests/test_api.py` | API integration tests via TestClient |

---

## Task 1: Project Scaffolding

**Files:**
- Create: `requirements.txt`
- Create: `.env.example`
- Create: `.gitignore`
- Create: `videos/.gitkeep`
- Create: `data/.gitkeep`

- [ ] **Step 1: Create requirements.txt**

```
fastapi==0.115.0
uvicorn==0.30.6
pybalt==0.4.0
python-dotenv==1.0.1
httpx==0.27.2
pytest==8.3.3
pytest-asyncio==0.24.0
```

> Note: run `pip install pybalt` first, then `pip show pybalt` to confirm the version and update above.

- [ ] **Step 2: Create .env.example**

```
UPLOAD_TOKEN=your-secret-token-here
```

- [ ] **Step 3: Create .gitignore**

```
.env
videos/
data/
__pycache__/
*.pyc
.pytest_cache/
```

- [ ] **Step 4: Create placeholder directories**

```bash
mkdir -p videos data tests
touch videos/.gitkeep data/.gitkeep tests/__init__.py
```

- [ ] **Step 5: Install dependencies**

```bash
pip install -r requirements.txt
```

Expected: all packages install without error.

- [ ] **Step 6: Commit**

```bash
git add requirements.txt .env.example .gitignore videos/.gitkeep data/.gitkeep tests/__init__.py
git commit -m "chore: project scaffolding"
```

---

## Task 2: Database Module

**Files:**
- Create: `db.py`
- Create: `tests/test_db.py`

- [ ] **Step 1: Write failing tests for db.py**

```python
# tests/test_db.py
import pytest
import tempfile
import os

# Override DB path before importing db
@pytest.fixture(autouse=True)
def tmp_db(monkeypatch, tmp_path):
    db_path = str(tmp_path / "test.db")
    monkeypatch.setenv("DB_PATH", db_path)
    import db
    import importlib
    importlib.reload(db)
    db.init_db()
    yield db

def test_add_and_get_video(tmp_db):
    vid_id = tmp_db.add_video("https://twitter.com/x/status/123")
    assert vid_id == 1
    video = tmp_db.get_video(1)
    assert video["url"] == "https://twitter.com/x/status/123"
    assert video["status"] == "queued"
    assert video["filename"] is None

def test_update_video_status(tmp_db):
    vid_id = tmp_db.add_video("https://twitter.com/x/status/456")
    tmp_db.update_video(vid_id, status="done", filename="456.mp4")
    video = tmp_db.get_video(vid_id)
    assert video["status"] == "done"
    assert video["filename"] == "456.mp4"

def test_update_video_error(tmp_db):
    vid_id = tmp_db.add_video("https://twitter.com/x/status/789")
    tmp_db.update_video(vid_id, status="error", error_msg="Download failed")
    video = tmp_db.get_video(vid_id)
    assert video["status"] == "error"
    assert video["error_msg"] == "Download failed"

def test_get_all_videos(tmp_db):
    tmp_db.add_video("https://twitter.com/x/status/1")
    tmp_db.add_video("https://twitter.com/x/status/2")
    videos = tmp_db.get_all_videos()
    assert len(videos) == 2

def test_progress_upsert_and_get(tmp_db):
    vid_id = tmp_db.add_video("https://twitter.com/x/status/999")
    assert tmp_db.get_progress(vid_id) == 0.0
    tmp_db.upsert_progress(vid_id, 42.5)
    assert tmp_db.get_progress(vid_id) == 42.5
    tmp_db.upsert_progress(vid_id, 100.0)
    assert tmp_db.get_progress(vid_id) == 100.0
```

- [ ] **Step 2: Run tests — verify they fail**

```bash
pytest tests/test_db.py -v
```

Expected: `ModuleNotFoundError: No module named 'db'`

- [ ] **Step 3: Implement db.py**

```python
import sqlite3
import os
from datetime import datetime, timezone

DB_PATH = os.getenv("DB_PATH", "data/watch_later.db")


def _conn():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    with _conn() as conn:
        conn.executescript("""
            CREATE TABLE IF NOT EXISTS videos (
                id        INTEGER PRIMARY KEY AUTOINCREMENT,
                url       TEXT NOT NULL,
                filename  TEXT,
                status    TEXT NOT NULL DEFAULT 'queued',
                error_msg TEXT,
                created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS progress (
                video_id         INTEGER PRIMARY KEY REFERENCES videos(id),
                position_seconds REAL NOT NULL DEFAULT 0
            );
        """)


def add_video(url: str) -> int:
    with _conn() as conn:
        cur = conn.execute(
            "INSERT INTO videos (url, created_at) VALUES (?, ?)",
            (url, datetime.now(timezone.utc).isoformat()),
        )
        return cur.lastrowid


def get_video(video_id: int) -> dict | None:
    with _conn() as conn:
        row = conn.execute("SELECT * FROM videos WHERE id = ?", (video_id,)).fetchone()
        return dict(row) if row else None


def get_all_videos() -> list[dict]:
    with _conn() as conn:
        rows = conn.execute("SELECT * FROM videos ORDER BY created_at DESC").fetchall()
        return [dict(r) for r in rows]


def update_video(video_id: int, status: str, filename: str | None = None, error_msg: str | None = None):
    with _conn() as conn:
        conn.execute(
            "UPDATE videos SET status=?, filename=?, error_msg=? WHERE id=?",
            (status, filename, error_msg, video_id),
        )


def get_progress(video_id: int) -> float:
    with _conn() as conn:
        row = conn.execute(
            "SELECT position_seconds FROM progress WHERE video_id = ?", (video_id,)
        ).fetchone()
        return row[0] if row else 0.0


def upsert_progress(video_id: int, position_seconds: float):
    with _conn() as conn:
        conn.execute(
            """INSERT INTO progress (video_id, position_seconds) VALUES (?, ?)
               ON CONFLICT(video_id) DO UPDATE SET position_seconds=excluded.position_seconds""",
            (video_id, position_seconds),
        )
```

- [ ] **Step 4: Run tests — verify they pass**

```bash
pytest tests/test_db.py -v
```

Expected: 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add db.py tests/test_db.py
git commit -m "feat: add SQLite database module with video and progress tracking"
```

---

## Task 3: Downloader Module

**Files:**
- Create: `downloader.py`

> No unit tests for this module — it calls pybalt which hits network. Tested via manual integration after full app is wired up.

- [ ] **Step 1: Create downloader.py**

```python
import shutil
from pathlib import Path

from pybalt import download as pybalt_download

import db

VIDEOS_DIR = Path("videos")


async def download_video(video_id: int, url: str):
    db.update_video(video_id, status="downloading")
    try:
        # pybalt downloads to a temp location and returns the file path
        downloaded_path = await pybalt_download(url)
        downloaded_path = Path(downloaded_path)

        dest = VIDEOS_DIR / f"{video_id}{downloaded_path.suffix}"
        shutil.move(str(downloaded_path), str(dest))

        db.update_video(video_id, status="done", filename=dest.name)
    except Exception as exc:
        db.update_video(video_id, status="error", error_msg=str(exc))
```

- [ ] **Step 2: Commit**

```bash
git add downloader.py
git commit -m "feat: add pybalt-based background downloader"
```

---

## Task 4: FastAPI App Skeleton + /upload Endpoint

**Files:**
- Create: `main.py`
- Create: `tests/test_api.py`

- [ ] **Step 1: Write failing tests for /upload**

```python
# tests/test_api.py
import pytest
import importlib
from fastapi.testclient import TestClient

@pytest.fixture()
def client(monkeypatch, tmp_path):
    monkeypatch.setenv("DB_PATH", str(tmp_path / "test.db"))
    monkeypatch.setenv("UPLOAD_TOKEN", "test-secret")
    # Reload db first so DB_PATH env var is picked up
    import db
    importlib.reload(db)
    # Then reload main so it gets the reloaded db module
    import main
    importlib.reload(main)
    # Use context manager so lifespan runs (calls db.init_db())
    with TestClient(main.app) as c:
        yield c

def test_upload_missing_token(client):
    resp = client.post("/upload", json={"url": "https://twitter.com/x/status/1"})
    assert resp.status_code == 401

def test_upload_wrong_token(client):
    resp = client.post(
        "/upload",
        json={"url": "https://twitter.com/x/status/1"},
        headers={"Authorization": "Bearer wrong-token"},
    )
    assert resp.status_code == 401

def test_upload_missing_url(client):
    resp = client.post(
        "/upload",
        json={},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 422

def test_upload_success(client, monkeypatch):
    # Patch background task so it doesn't actually download
    monkeypatch.setattr("main.download_video", lambda *a, **kw: None)
    resp = client.post(
        "/upload",
        json={"url": "https://twitter.com/x/status/123"},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 202
    data = resp.json()
    assert "id" in data
    assert data["status"] == "queued"
```

- [ ] **Step 2: Run tests — verify they fail**

```bash
pytest tests/test_api.py -v
```

Expected: `ModuleNotFoundError: No module named 'main'`

- [ ] **Step 3: Create main.py with /upload endpoint**

```python
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

UPLOAD_TOKEN = os.getenv("UPLOAD_TOKEN", "")
VIDEOS_DIR = Path("videos")


@asynccontextmanager
async def lifespan(app: FastAPI):
    db.init_db()
    VIDEOS_DIR.mkdir(exist_ok=True)
    yield


app = FastAPI(lifespan=lifespan)


def _check_token(request: Request):
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer ") or auth[7:] != UPLOAD_TOKEN:
        raise HTTPException(status_code=401, detail="Unauthorized")


class UploadRequest(BaseModel):
    url: str


@app.post("/upload", status_code=202)
async def upload(body: UploadRequest, request: Request, background_tasks: BackgroundTasks):
    _check_token(request)
    video_id = db.add_video(body.url)
    background_tasks.add_task(download_video, video_id, body.url)
    return {"id": video_id, "status": "queued"}
```

- [ ] **Step 4: Run tests — verify they pass**

```bash
pytest tests/test_api.py::test_upload_missing_token tests/test_api.py::test_upload_wrong_token tests/test_api.py::test_upload_missing_url tests/test_api.py::test_upload_success -v
```

Expected: 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add main.py tests/test_api.py
git commit -m "feat: add FastAPI app skeleton and /upload endpoint with token auth"
```

---

## Task 5: Video Streaming Endpoint

**Files:**
- Modify: `main.py`
- Modify: `tests/test_api.py`

- [ ] **Step 1: Add failing test for /videos/{id}/stream**

Append to `tests/test_api.py`:

```python
def test_stream_not_found(client):
    resp = client.get("/videos/999/stream")
    assert resp.status_code == 404

def test_stream_not_done(client):
    import db
    vid_id = db.add_video("https://twitter.com/x/status/1")
    resp = client.get(f"/videos/{vid_id}/stream")
    assert resp.status_code == 404

def test_stream_returns_video(client, tmp_path, monkeypatch):
    import db
    from pathlib import Path

    # Create a fake video file
    fake_video = Path("videos") / "1.mp4"
    fake_video.parent.mkdir(exist_ok=True)
    fake_video.write_bytes(b"FAKEVIDEOCONTENT")

    vid_id = db.add_video("https://twitter.com/x/status/1")
    db.update_video(vid_id, status="done", filename="1.mp4")

    resp = client.get(f"/videos/{vid_id}/stream")
    assert resp.status_code in (200, 206)
    assert b"FAKEVIDEOCONTENT" in resp.content

    fake_video.unlink()
```

- [ ] **Step 2: Run new tests — verify they fail**

```bash
pytest tests/test_api.py::test_stream_not_found tests/test_api.py::test_stream_not_done tests/test_api.py::test_stream_returns_video -v
```

Expected: FAIL with 404/422 (route not found).

- [ ] **Step 3: Add stream route to main.py**

Add after `/upload` route:

```python
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
```

- [ ] **Step 4: Run stream tests — verify they pass**

```bash
pytest tests/test_api.py::test_stream_not_found tests/test_api.py::test_stream_not_done tests/test_api.py::test_stream_returns_video -v
```

Expected: 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add main.py tests/test_api.py
git commit -m "feat: add byte-range video streaming endpoint"
```

---

## Task 6: Progress Endpoint

**Files:**
- Modify: `main.py`
- Modify: `tests/test_api.py`

- [ ] **Step 1: Add failing test for progress endpoint**

Append to `tests/test_api.py`:

```python
def test_save_progress(client):
    import db
    vid_id = db.add_video("https://twitter.com/x/status/1")
    resp = client.post(f"/videos/{vid_id}/progress", json={"position_seconds": 37.5})
    assert resp.status_code == 200
    assert db.get_progress(vid_id) == 37.5

def test_save_progress_video_not_found(client):
    resp = client.post("/videos/999/progress", json={"position_seconds": 10.0})
    assert resp.status_code == 404
```

- [ ] **Step 2: Run new tests — verify they fail**

```bash
pytest tests/test_api.py::test_save_progress tests/test_api.py::test_save_progress_video_not_found -v
```

Expected: FAIL (route not found).

- [ ] **Step 3: Add progress route to main.py**

Add after stream route:

```python
class ProgressRequest(BaseModel):
    position_seconds: float


@app.post("/videos/{video_id}/progress")
async def save_progress(video_id: int, body: ProgressRequest):
    if not db.get_video(video_id):
        raise HTTPException(status_code=404, detail="Video not found")
    db.upsert_progress(video_id, body.position_seconds)
    return {"ok": True}
```

- [ ] **Step 4: Run tests — verify they pass**

```bash
pytest tests/test_api.py::test_save_progress tests/test_api.py::test_save_progress_video_not_found -v
```

Expected: 2 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add main.py tests/test_api.py
git commit -m "feat: add progress tracking endpoint"
```

---

## Task 7: Mobile-Optimized /videos HTML Page

**Files:**
- Modify: `main.py`
- Modify: `tests/test_api.py`

- [ ] **Step 1: Add failing test for /videos page**

Append to `tests/test_api.py`:

```python
def test_videos_page_returns_html(client):
    resp = client.get("/videos")
    assert resp.status_code == 200
    assert "text/html" in resp.headers["content-type"]

def test_videos_page_shows_video(client):
    import db
    vid_id = db.add_video("https://twitter.com/x/status/123")
    db.update_video(vid_id, status="done", filename="1.mp4")
    resp = client.get("/videos")
    assert resp.status_code == 200
    assert f"/videos/{vid_id}/stream" in resp.text

def test_videos_page_sets_resume_time(client):
    import db
    vid_id = db.add_video("https://twitter.com/x/status/123")
    db.update_video(vid_id, status="done", filename="1.mp4")
    db.upsert_progress(vid_id, 55.0)
    resp = client.get("/videos")
    assert "55.0" in resp.text
```

- [ ] **Step 2: Run new tests — verify they fail**

```bash
pytest tests/test_api.py::test_videos_page_returns_html tests/test_api.py::test_videos_page_shows_video tests/test_api.py::test_videos_page_sets_resume_time -v
```

Expected: FAIL (route not found).

- [ ] **Step 3: Add /videos route to main.py**

Add after progress route:

```python
def _status_badge(status: str) -> str:
    colors = {"queued": "#888", "downloading": "#f90", "done": "#0a0", "error": "#c00"}
    return f'<span style="color:{colors.get(status,"#888")};font-size:0.8em">{status}</span>'


def _build_html(videos: list[dict]) -> str:
    cards = []
    for v in videos:
        progress = db.get_progress(v["id"])
        badge = _status_badge(v["status"])
        short_url = v["url"][:60] + ("…" if len(v["url"]) > 60 else "")

        if v["status"] == "done":
            player = f"""
            <video id="v{v['id']}" controls playsinline preload="metadata"
                   style="width:100%;border-radius:8px;background:#000;"
                   onloadedmetadata="this.currentTime={progress}">
              <source src="/videos/{v['id']}/stream" type="video/mp4">
            </video>"""
        elif v["status"] == "error":
            player = f'<p style="color:#c00;font-size:0.85em">Error: {v.get("error_msg","unknown")}</p>'
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


@app.get("/videos", response_class=HTMLResponse)
async def videos_page():
    all_videos = db.get_all_videos()
    return _build_html(all_videos)
```

- [ ] **Step 4: Run all tests — verify they pass**

```bash
pytest tests/ -v
```

Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add main.py tests/test_api.py
git commit -m "feat: add mobile-optimized /videos HTML page with resume support"
```

---

## Task 8: Manual Integration Test

- [ ] **Step 1: Create .env**

```bash
cp .env.example .env
# Edit .env and set a real UPLOAD_TOKEN value, e.g.:
# UPLOAD_TOKEN=mysecret123
```

- [ ] **Step 2: Start the server**

```bash
uvicorn main:app --reload --port 8000
```

Expected: server starts, logs "Application startup complete."

- [ ] **Step 3: Submit a Twitter video URL**

```bash
curl -X POST http://localhost:8000/upload \
  -H "Authorization: Bearer mysecret123" \
  -H "Content-Type: application/json" \
  -d '{"url":"https://twitter.com/i/status/REAL_TWEET_ID_WITH_VIDEO"}'
```

Expected: `{"id": 1, "status": "queued"}`

- [ ] **Step 4: Check download progress**

```bash
# Watch server logs — pybalt will log download activity
# Check DB directly:
sqlite3 data/watch_later.db "SELECT id, status, filename FROM videos;"
```

Expected: status progresses `queued → downloading → done`.

- [ ] **Step 5: Open /videos in mobile browser**

Navigate to `http://<your-local-ip>:8000/videos` on your phone (same network).

Expected:
- Video card appears with player
- Video plays inline (no forced fullscreen on iOS)
- Scrubbing to a position, pausing, refreshing — video resumes from same position

- [ ] **Step 6: Final commit**

```bash
git add .env.example
git commit -m "chore: finalize project — all features working"
```
