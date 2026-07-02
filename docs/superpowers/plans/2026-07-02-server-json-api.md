# Server JSON API Implementation Plan (Plan 1 of 2) — COMPLETE

**Completed:** 2026-07-02. All 5 tasks done, 61 tests passing, merged to `main`.
Commits: 33f3b2b → 76c421f.

---

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a JSON API to the FastAPI backend for the native iPad app, sharing serialization and mutation logic with the existing server-rendered (SSR) HTML app, without changing SSR behavior.

**Architecture:** Extract a `serialize_video()` presenter (`views/serializers.py`) that both the SSR page and JSON list endpoint consume. Extract move/classify mutation logic into a shared `services.py` called by both the existing form endpoints and the new JSON endpoints. Add read-only JSON list + classifications endpoints and token-protected JSON move/classify endpoints. The PWA is untouched.

**Tech Stack:** Python 3.13, FastAPI 0.115, pytest 8.3 + `fastapi.testclient.TestClient`, sqlite3.

## Global Constraints

- SSR output must remain byte-identical — existing `tests/test_api.py` SSR tests must keep passing. Verify with the full suite each task.
- JSON write endpoints (`/api/videos/{id}/move`, `/api/videos/{id}/classify`) require the same Bearer token as `/upload` (`main._check_token`). The read endpoints (`/api/videos`, `/api/classifications`) are unauthenticated, matching the HTML page.
- Classifications are `["children", "adults", "education", "entertainment"]` — single source of truth is `db.CLASSIFICATIONS`. Never hardcode elsewhere.
- Video ordering is `position DESC, created_at DESC` (as in `db.get_all_videos`).
- Run tests with: `.venv/bin/pytest` (or `python -m pytest`) from repo root.

---

### Task 1: `serialize_video` presenter

**Files:**
- Create: `views/serializers.py`
- Test: `tests/test_serializers.py`

**Interfaces:**
- Consumes: nothing (pure function over a `db` video dict).
- Produces: `serialize_video(video: dict) -> dict` returning keys
  `id: int, url: str, title: str|None, platform: str|None, source_key: str|None,
  preview_url: str|None, classification: str, position: int|None, status: str,
  error_msg: str|None, stream_path: str`. Used by Task 3 (JSON list) and
  available to SSR.

- [ ] **Step 1: Write the failing test**

```python
# tests/test_serializers.py
from views.serializers import serialize_video


def test_serialize_video_full_shape():
    video = {
        "id": 7,
        "url": "https://youtu.be/dQw4w9WgXcQ",
        "title": "A Song",
        "platform": "youtube",
        "source_key": "dQw4w9WgXcQ",
        "preview_url": "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
        "classification": "children",
        "position": 3,
        "status": "done",
        "error_msg": None,
        "filename": "7.mp4",
        "created_at": "2026-07-02T00:00:00+00:00",
    }
    assert serialize_video(video) == {
        "id": 7,
        "url": "https://youtu.be/dQw4w9WgXcQ",
        "title": "A Song",
        "platform": "youtube",
        "source_key": "dQw4w9WgXcQ",
        "preview_url": "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
        "classification": "children",
        "position": 3,
        "status": "done",
        "error_msg": None,
        "stream_path": "/videos/7/stream",
    }


def test_serialize_video_defaults_classification_and_omits_internal_fields():
    video = {
        "id": 1,
        "url": "https://twitter.com/x/status/1",
        "status": "queued",
        "filename": None,
    }
    result = serialize_video(video)
    assert result["classification"] == "children"
    assert result["title"] is None
    assert result["stream_path"] == "/videos/1/stream"
    assert "filename" not in result
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/pytest tests/test_serializers.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'views.serializers'`

- [ ] **Step 3: Write minimal implementation**

```python
# views/serializers.py
"""Canonical video presenter shared by the SSR page and the JSON API."""


def serialize_video(video: dict) -> dict:
    return {
        "id": video["id"],
        "url": video["url"],
        "title": video.get("title"),
        "platform": video.get("platform"),
        "source_key": video.get("source_key"),
        "preview_url": video.get("preview_url"),
        "classification": video.get("classification") or "children",
        "position": video.get("position"),
        "status": video["status"],
        "error_msg": video.get("error_msg"),
        "stream_path": f"/videos/{video['id']}/stream",
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `.venv/bin/pytest tests/test_serializers.py -v`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add views/serializers.py tests/test_serializers.py
git commit -m "feat: add serialize_video presenter for shared SSR/JSON output"
```

---

### Task 2: Shared move/classify service

**Files:**
- Create: `services.py`
- Modify: `main.py` (form endpoints `move_video_endpoint` ~line 397, `classify_video_endpoint` ~line 404 call the service)
- Test: `tests/test_services.py`

**Interfaces:**
- Consumes: `db.move_video`, `db.set_video_classification`, `db.CLASSIFICATIONS`.
- Produces:
  - `apply_move(video_id: int, direction: str) -> bool` — swaps position; returns False for invalid direction/no neighbor.
  - `apply_classification(video_id: int, classification: str) -> bool` — sets classification only if in `CLASSIFICATIONS`; returns True on success, False if invalid.
  Both consumed by Task 4 and Task 5, and by the refactored form endpoints.

- [ ] **Step 1: Write the failing test**

```python
# tests/test_services.py
import importlib

import pytest


@pytest.fixture()
def fresh_db(monkeypatch, tmp_path):
    monkeypatch.setenv("DB_PATH", str(tmp_path / "test.db"))
    import db
    importlib.reload(db)
    db.init_db()
    import services
    importlib.reload(services)
    return db, services


def test_apply_classification_accepts_valid(fresh_db):
    db, services = fresh_db
    vid = db.add_video("https://twitter.com/x/status/1")
    assert services.apply_classification(vid, "education") is True
    assert db.get_video(vid)["classification"] == "education"


def test_apply_classification_rejects_invalid(fresh_db):
    db, services = fresh_db
    vid = db.add_video("https://twitter.com/x/status/1")
    db.set_video_classification(vid, "children")
    assert services.apply_classification(vid, "bogus") is False
    assert db.get_video(vid)["classification"] == "children"


def test_apply_move_swaps_positions(fresh_db):
    db, services = fresh_db
    first = db.add_video("https://twitter.com/x/status/1")
    second = db.add_video("https://twitter.com/x/status/2")
    # second has the higher position (added later)
    assert services.apply_move(second, "down") is True
    assert db.get_video(first)["position"] > db.get_video(second)["position"]


def test_apply_move_rejects_bad_direction(fresh_db):
    db, services = fresh_db
    vid = db.add_video("https://twitter.com/x/status/1")
    assert services.apply_move(vid, "sideways") is False
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/pytest tests/test_services.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'services'`

- [ ] **Step 3: Write minimal implementation**

```python
# services.py
"""Mutation logic shared by the SSR form endpoints and the JSON API."""

import db
from db import CLASSIFICATIONS


def apply_move(video_id: int, direction: str) -> bool:
    return db.move_video(video_id, direction)


def apply_classification(video_id: int, classification: str) -> bool:
    if classification not in CLASSIFICATIONS:
        return False
    db.set_video_classification(video_id, classification)
    return True
```

- [ ] **Step 4: Run new test to verify it passes**

Run: `.venv/bin/pytest tests/test_services.py -v`
Expected: PASS (4 tests)

- [ ] **Step 5: Refactor form endpoints to use the service**

In `main.py`, add `import services` near the other imports (after `import db`).
Replace the body of `move_video_endpoint`:

```python
@app.post("/videos/{video_id}/move")
async def move_video_endpoint(video_id: int, direction: str = Form(...), classification: str | None = Form(default=None)):
    services.apply_move(video_id, direction)
    redirect_url = f"/?classification={classification}" if classification else "/"
    return RedirectResponse(url=redirect_url, status_code=303)
```

Replace the body of `classify_video_endpoint`:

```python
@app.post("/videos/{video_id}/classify")
async def classify_video_endpoint(video_id: int, classification: str = Form(...), current_classification: str | None = Form(default=None)):
    services.apply_classification(video_id, classification)
    redirect_url = f"/?classification={current_classification}" if current_classification else "/"
    return RedirectResponse(url=redirect_url, status_code=303)
```

- [ ] **Step 6: Run full suite to verify SSR unchanged**

Run: `.venv/bin/pytest -v`
Expected: PASS — all existing tests plus the new ones.

- [ ] **Step 7: Commit**

```bash
git add services.py tests/test_services.py main.py
git commit -m "refactor: extract shared move/classify service used by SSR endpoints"
```

---

### Task 3: `GET /api/videos` and `GET /api/classifications`

**Files:**
- Modify: `main.py` (add import + two routes near the SSR `videos_page`, ~line 412)
- Test: `tests/test_api.py` (append)

**Interfaces:**
- Consumes: `db.get_all_videos`, `db.CLASSIFICATIONS`, `serialize_video` (Task 1).
- Produces:
  - `GET /api/videos?classification=<opt>` → `list[serialize_video]`.
  - `GET /api/classifications` → `{"classifications": [...]}`.

- [ ] **Step 1: Write the failing test**

```python
# append to tests/test_api.py
def test_api_videos_returns_serialized_list(client):
    import db
    vid = db.add_video(
        "https://youtu.be/dQw4w9WgXcQ",
        platform="youtube",
        source_key="dQw4w9WgXcQ",
        title="Saved Title",
        preview_url="https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
    )
    db.update_video(vid, status="done", filename="yt.mp4", title="Saved Title")
    resp = client.get("/api/videos")
    assert resp.status_code == 200
    data = resp.json()
    assert isinstance(data, list)
    item = next(v for v in data if v["id"] == vid)
    assert item["title"] == "Saved Title"
    assert item["platform"] == "youtube"
    assert item["status"] == "done"
    assert item["stream_path"] == f"/videos/{vid}/stream"
    assert "filename" not in item


def test_api_videos_filters_by_classification(client):
    import db
    a = db.add_video("https://twitter.com/x/status/1")
    b = db.add_video("https://twitter.com/x/status/2")
    db.set_video_classification(a, "education")
    db.set_video_classification(b, "children")
    resp = client.get("/api/videos", params={"classification": "education"})
    assert resp.status_code == 200
    ids = {v["id"] for v in resp.json()}
    assert a in ids and b not in ids


def test_api_videos_ignores_unknown_classification(client):
    import db
    vid = db.add_video("https://twitter.com/x/status/1")
    resp = client.get("/api/videos", params={"classification": "bogus"})
    assert resp.status_code == 200
    assert any(v["id"] == vid for v in resp.json())


def test_api_classifications_lists_all(client):
    resp = client.get("/api/classifications")
    assert resp.status_code == 200
    assert resp.json() == {
        "classifications": ["children", "adults", "education", "entertainment"]
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv/bin/pytest tests/test_api.py -k "api_videos or api_classifications" -v`
Expected: FAIL — 404 (routes not defined).

- [ ] **Step 3: Write minimal implementation**

In `main.py`, add to the imports from `views` (the `serialize_video` symbol):

```python
from views.serializers import serialize_video
```

Add the routes (place directly above the `@app.get("/", response_class=HTMLResponse)` block):

```python
@app.get("/api/classifications")
async def api_classifications():
    return {"classifications": CLASSIFICATIONS}


@app.get("/api/videos")
async def api_videos(classification: str | None = None):
    if classification and classification not in CLASSIFICATIONS:
        classification = None
    videos = db.get_all_videos(classification)
    return [serialize_video(v) for v in videos]
```

Note: `CLASSIFICATIONS` is already imported in `main.py` (`from db import CLASSIFICATIONS`).

- [ ] **Step 4: Run tests to verify they pass**

Run: `.venv/bin/pytest tests/test_api.py -k "api_videos or api_classifications" -v`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add main.py tests/test_api.py
git commit -m "feat: add GET /api/videos and /api/classifications JSON endpoints"
```

---

### Task 4: `POST /api/videos/{id}/move`

**Files:**
- Modify: `main.py` (add route + a Pydantic body model)
- Test: `tests/test_api.py` (append)

**Interfaces:**
- Consumes: `main._check_token`, `services.apply_move` (Task 2).
- Produces: `POST /api/videos/{id}/move` body `{"direction": "up"|"down"}` → `{"ok": bool}`. Requires Bearer token.

- [ ] **Step 1: Write the failing test**

```python
# append to tests/test_api.py
def test_api_move_requires_token(client):
    import db
    vid = db.add_video("https://twitter.com/x/status/1")
    resp = client.post(f"/api/videos/{vid}/move", json={"direction": "up"})
    assert resp.status_code == 401


def test_api_move_swaps_and_returns_ok(client):
    import db
    first = db.add_video("https://twitter.com/x/status/1")
    second = db.add_video("https://twitter.com/x/status/2")
    resp = client.post(
        f"/api/videos/{second}/move",
        json={"direction": "down"},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 200
    assert resp.json() == {"ok": True}
    assert db.get_video(first)["position"] > db.get_video(second)["position"]


def test_api_move_invalid_direction_returns_not_ok(client):
    import db
    vid = db.add_video("https://twitter.com/x/status/1")
    resp = client.post(
        f"/api/videos/{vid}/move",
        json={"direction": "sideways"},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 200
    assert resp.json() == {"ok": False}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv/bin/pytest tests/test_api.py -k "api_move" -v`
Expected: FAIL — 404/405 (route not defined).

- [ ] **Step 3: Write minimal implementation**

In `main.py`, add a body model near `UploadRequest` (~line 97):

```python
class MoveRequest(BaseModel):
    direction: str
```

Add the route (place after the `api_videos` route):

```python
@app.post("/api/videos/{video_id}/move")
async def api_move_video(video_id: int, body: MoveRequest, request: Request):
    _check_token(request)
    ok = services.apply_move(video_id, body.direction)
    return {"ok": ok}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `.venv/bin/pytest tests/test_api.py -k "api_move" -v`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add main.py tests/test_api.py
git commit -m "feat: add POST /api/videos/{id}/move JSON endpoint"
```

---

### Task 5: `POST /api/videos/{id}/classify`

**Files:**
- Modify: `main.py` (add route + Pydantic body model)
- Test: `tests/test_api.py` (append)

**Interfaces:**
- Consumes: `main._check_token`, `services.apply_classification` (Task 2).
- Produces: `POST /api/videos/{id}/classify` body `{"classification": "<one of CLASSIFICATIONS>"}` → `{"ok": bool}`. Requires Bearer token.

- [ ] **Step 1: Write the failing test**

```python
# append to tests/test_api.py
def test_api_classify_requires_token(client):
    import db
    vid = db.add_video("https://twitter.com/x/status/1")
    resp = client.post(f"/api/videos/{vid}/classify", json={"classification": "education"})
    assert resp.status_code == 401


def test_api_classify_sets_and_returns_ok(client):
    import db
    vid = db.add_video("https://twitter.com/x/status/1")
    resp = client.post(
        f"/api/videos/{vid}/classify",
        json={"classification": "education"},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 200
    assert resp.json() == {"ok": True}
    assert db.get_video(vid)["classification"] == "education"


def test_api_classify_invalid_returns_not_ok(client):
    import db
    vid = db.add_video("https://twitter.com/x/status/1")
    db.set_video_classification(vid, "children")
    resp = client.post(
        f"/api/videos/{vid}/classify",
        json={"classification": "bogus"},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 200
    assert resp.json() == {"ok": False}
    assert db.get_video(vid)["classification"] == "children"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv/bin/pytest tests/test_api.py -k "api_classify" -v`
Expected: FAIL — 404/405 (route not defined).

- [ ] **Step 3: Write minimal implementation**

In `main.py`, add a body model near `MoveRequest`:

```python
class ClassifyRequest(BaseModel):
    classification: str
```

Add the route (place after the `api_move_video` route):

```python
@app.post("/api/videos/{video_id}/classify")
async def api_classify_video(video_id: int, body: ClassifyRequest, request: Request):
    _check_token(request)
    ok = services.apply_classification(video_id, body.classification)
    return {"ok": ok}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `.venv/bin/pytest tests/test_api.py -k "api_classify" -v`
Expected: PASS (3 tests)

- [ ] **Step 5: Run the full suite**

Run: `.venv/bin/pytest -v`
Expected: PASS — entire suite green (SSR unchanged, all JSON endpoints working).

- [ ] **Step 6: Commit**

```bash
git add main.py tests/test_api.py
git commit -m "feat: add POST /api/videos/{id}/classify JSON endpoint"
```

---

## Done criteria

- `GET /api/videos`, `GET /api/classifications`, `POST /api/videos/{id}/move`,
  `POST /api/videos/{id}/classify` all implemented and tested.
- SSR page + form endpoints unchanged (all pre-existing tests pass).
- Serialization and mutation logic shared via `views/serializers.py` and
  `services.py` — no duplication.

**Next:** Plan 2 (iOS SwiftUI app) consumes these endpoints. Write it after this plan is merged and the API is confirmed stable.
