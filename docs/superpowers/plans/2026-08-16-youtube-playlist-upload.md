# YouTube Playlist Upload Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `POST /upload` accepts a YouTube (or YouTube Music) playlist URL, creates a new video group named after the playlist, and queues every entry into it.

**Architecture:** `_classify_url` gains a playlist branch that runs *before* the single-video branch and returns `platform="youtube_playlist"`. The endpoint short-circuits on that platform: no video row, no group resolution — it schedules `downloader.import_playlist(url)` as a `BackgroundTask` and returns `202` immediately. `import_playlist` shells out to `yt-dlp --flat-playlist -J` once, creates a fresh group from the playlist title (suffixing the name on collision), then walks the entries **sequentially**, reusing the existing per-video logic (`get_completed_video_by_source` dedupe → `db.add_video` → `await download_video`). The Redis response cache is flushed out of band because nothing here is an HTTP write.

**Tech Stack:** Python 3.13, FastAPI, SQLite (`db.py`), yt-dlp, pytest (+ `pytest-asyncio`, markers applied per-test).

**Spec:** This document. The design was agreed in chat on 2026-08-16; the decisions it locks in are:
- Background expansion — `202` returns immediately, before the group exists.
- Only `/playlist?list=…` counts as a playlist. `watch?v=X&list=Y` stays a single-video upload, list ignored.
- A name clash always creates a **new** suffixed group (never reuses an existing one).
- The playlist name always wins: an explicit `group_id` in the body is ignored for playlist URLs.
- `music.youtube.com` is accepted, for playlists *and* for single videos.

## Global Constraints

- Tests live under `tests/` and run with `python -m pytest tests/`. There is no `pytest.ini`/`pyproject.toml`, so **every async test must carry `@pytest.mark.asyncio` individually** — there is no global asyncio mode.
- Integration tests against the app reload `db` then `main` after setting `DB_PATH`/`UPLOAD_TOKEN` (the `client` fixture in `tests/test_api.py`). Downloader tests reload `db` then `downloader` (the `downloader_env` fixture in `tests/test_downloader.py`). Follow those fixtures; do not invent new ones.
- yt-dlp is invoked through the module-level `YTDLP_BIN` / `YTDLP_BROWSER` / `YTDLP_FORMAT` globals in `downloader.py`, never a hardcoded path. New invocations read the same globals.
- Only `converter.py` may spawn ffmpeg. Nothing in this plan spawns ffmpeg; normalization keeps going through the existing `_normalize_media_for_ios` job enqueue.
- Any code path that changes state without an HTTP request must flush the response cache itself (`await cache.clear()` on the event loop, `cache.clear_blocking()` off it). `import_playlist` is such a path.
- A download failure deletes its video row (`download_video` already does this). Do not add an `error` status.
- `groups.name` is `NOT NULL UNIQUE`. `db.PLEX_KINDS` names (`tv`, `movies`) are forbidden as group names.
- Never run the iOS test suites. Nothing in this plan touches `ios/`.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `router.py` | URL classification + the `/upload` endpoint | Modify: add `music.youtube.com` to the accepted hosts, add `_extract_youtube_playlist_id` / `_normalize_youtube_playlist_url`, add the playlist branch to `_classify_url`, add the playlist short-circuit to `upload`, import `import_playlist` |
| `downloader.py` | Fetching media, off the event loop | Modify: add `_slugify_playlist_title`, `_unique_group_name`, `_fetch_playlist_metadata` (+ its `_sync` half), and `import_playlist` |
| `tests/test_api.py` | Endpoint-level tests | Modify: classification + `/upload` playlist tests |
| `tests/test_downloader.py` | Downloader unit tests | Modify: slug/uniqueness/metadata/import tests |
| `CLAUDE.md` | Architecture notes | Modify: document the playlist path in the request→download→serve flow |

---

### Task 1: Accept `music.youtube.com` for single videos

Today `_extract_youtube_id` only accepts `youtube.com`, `m.youtube.com` and `youtu.be`, so a YouTube Music link 400s. The playlist work in Task 2 needs `music.youtube.com` in the host set anyway; this task lands it for the single-video path first, on its own, so a regression here is unambiguous.

**Files:**
- Modify: `router.py:223-252` (`_extract_youtube_id`)
- Test: `tests/test_api.py`

**Interfaces:**
- Consumes: nothing.
- Produces: `_extract_youtube_id(raw_url: str) -> str` now accepts host `music.youtube.com`. Later tasks rely on that host being recognised.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_api.py`:

```python
def test_upload_accepts_youtube_music_watch_url(client, monkeypatch):
    monkeypatch.setattr("router.download_video", lambda *a, **kw: None)

    resp = client.post(
        "/upload",
        json={"url": "https://music.youtube.com/watch?v=dQw4w9WgXcQ&si=abc"},
        headers={"Authorization": "Bearer test-secret"},
    )

    assert resp.status_code == 202
    import db
    video = db.get_video(resp.json()["id"])
    assert video["platform"] == "youtube"
    assert video["source_key"] == "dQw4w9WgXcQ"
    assert video["url"] == "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_api.py::test_upload_accepts_youtube_music_watch_url -v`
Expected: FAIL — the response is `400 {"detail": "Unsupported URL"}`, so `resp.status_code == 202` fails.

- [ ] **Step 3: Write minimal implementation**

In `router.py`, in `_extract_youtube_id`, change the host check:

```python
    elif host in {"youtube.com", "m.youtube.com", "music.youtube.com"}:
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python -m pytest tests/test_api.py -v -k youtube`
Expected: PASS, including the pre-existing YouTube upload/classification tests.

- [ ] **Step 5: Commit**

```bash
git add router.py tests/test_api.py
git commit -m "feat: accept music.youtube.com watch URLs on /upload"
```

---

### Task 2: Classify `/playlist?list=…` URLs

**Files:**
- Modify: `router.py` — add `YOUTUBE_PLAYLIST_ID_RE` near `YOUTUBE_ID_RE` (`router.py:93`), add two functions after `_normalize_youtube_url` (`router.py:255-258`), add a branch to `_classify_url` (`router.py:265-280`)
- Test: `tests/test_api.py`

**Interfaces:**
- Consumes: `_extract_youtube_id` from Task 1 (host set includes `music.youtube.com`).
- Produces:
  - `_extract_youtube_playlist_id(raw_url: str) -> str` — raises `ValueError` when the URL is not a playlist page.
  - `_normalize_youtube_playlist_url(raw_url: str) -> tuple[str, str]` — returns `(normalized_url, list_id)`.
  - `_classify_url(raw_url)` may now return `{"platform": "youtube_playlist", "source_key": <list_id>, "normalized_url": "https://www.youtube.com/playlist?list=<list_id>"}`. Task 4 branches on that `platform` value.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_api.py`:

```python
@pytest.mark.parametrize(
    "url",
    [
        "https://www.youtube.com/playlist?list=PLVixkqSccxTvtXpNTlQPi7fSc3kzZ5EJa",
        "https://m.youtube.com/playlist?list=PLVixkqSccxTvtXpNTlQPi7fSc3kzZ5EJa",
        "https://music.youtube.com/playlist?list=PLVixkqSccxTvtXpNTlQPi7fSc3kzZ5EJa&si=eNDjY3nVNq-0D491",
    ],
)
def test_classify_url_recognizes_playlists(url):
    import router

    assert router._classify_url(url) == {
        "platform": "youtube_playlist",
        "source_key": "PLVixkqSccxTvtXpNTlQPi7fSc3kzZ5EJa",
        "normalized_url": "https://www.youtube.com/playlist?list=PLVixkqSccxTvtXpNTlQPi7fSc3kzZ5EJa",
    }


def test_classify_url_keeps_watch_with_list_a_single_video():
    import router

    assert router._classify_url(
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLVixkqSccxTvtXpNTlQPi7fSc3kzZ5EJa"
    ) == {
        "platform": "youtube",
        "source_key": "dQw4w9WgXcQ",
        "normalized_url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
    }


@pytest.mark.parametrize(
    "url",
    [
        "https://www.youtube.com/playlist",
        "https://www.youtube.com/playlist?list=",
        "https://www.youtube.com/playlist?list=a",
        "https://vimeo.com/playlist?list=PLVixkqSccxTvtXpNTlQPi7fSc3kzZ5EJa",
    ],
)
def test_classify_url_rejects_bad_playlist_urls(url):
    import router
    from fastapi import HTTPException

    with pytest.raises(HTTPException) as exc:
        router._classify_url(url)
    assert exc.value.status_code == 400
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tests/test_api.py -v -k playlist`
Expected: FAIL — `test_classify_url_recognizes_playlists` raises `HTTPException(400, "Unsupported YouTube URL")` instead of returning a dict. (`test_classify_url_keeps_watch_with_list_a_single_video` and the rejection cases already pass; they are regression guards.)

- [ ] **Step 3: Write minimal implementation**

In `router.py`, next to `YOUTUBE_ID_RE` (line 93):

```python
# Playlist ids are not fixed-width like video ids (PL…, OLAK5uy_…, RD…), so
# this is a charset + minimum-length check, not an exact-length one.
YOUTUBE_PLAYLIST_ID_RE = re.compile(r"^[A-Za-z0-9_-]{10,}$")
```

After `_normalize_youtube_url` (line 258):

```python
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
```

In `_classify_url`, insert this block between the twitter `try/except` and the youtube one — playlists must be tried **before** `_normalize_youtube_url`:

```python
    try:
        normalized_url, list_id = _normalize_youtube_playlist_url(raw_url)
        return {
            "platform": "youtube_playlist",
            "source_key": list_id,
            "normalized_url": normalized_url,
        }
    except ValueError:
        pass
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python -m pytest tests/test_api.py -v -k "playlist or youtube or upload"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add router.py tests/test_api.py
git commit -m "feat: classify YouTube playlist URLs"
```

---

### Task 3: Name a group after a playlist title

Pure functions for turning a playlist title into a free `groups.name` / `label` pair. No network, no yt-dlp — isolated so Task 5 only has to test orchestration.

**Files:**
- Modify: `downloader.py` (new helpers near the bottom, plus a `re` import)
- Test: `tests/test_downloader.py`

**Interfaces:**
- Consumes: `db.get_group_by_name`, `db.PLEX_KINDS`.
- Produces:
  - `_slugify_playlist_title(title: str) -> str` — lowercase ASCII slug, `""`→`"playlist"`, capped at 40 chars.
  - `_unique_group_name(slug: str, label: str) -> tuple[str, str]` — returns `(name, label)`, suffixing both until `name` is free and not a Plex kind. Task 5 calls this.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_downloader.py`:

```python
@pytest.mark.parametrize(
    "title,expected",
    [
        ("Lo-fi Beats", "lo-fi-beats"),
        ("  Summer 2026 Mix!!  ", "summer-2026-mix"),
        ("Café Música", "caf-m-sica"),
        ("🎵🎵", "playlist"),
        ("", "playlist"),
        ("a" * 80, "a" * 40),
    ],
)
def test_slugify_playlist_title(downloader_env, title, expected):
    _db, downloader, _videos_dir = downloader_env

    assert downloader._slugify_playlist_title(title) == expected


def test_unique_group_name_returns_slug_when_free(downloader_env):
    _db, downloader, _videos_dir = downloader_env

    assert downloader._unique_group_name("lo-fi-beats", "Lo-fi Beats") == (
        "lo-fi-beats",
        "Lo-fi Beats",
    )


def test_unique_group_name_suffixes_past_existing_groups(downloader_env):
    db, downloader, _videos_dir = downloader_env
    db.create_group("lo-fi-beats", "Lo-fi Beats")
    db.create_group("lo-fi-beats-2", "Lo-fi Beats (2)")

    assert downloader._unique_group_name("lo-fi-beats", "Lo-fi Beats") == (
        "lo-fi-beats-3",
        "Lo-fi Beats (3)",
    )


def test_unique_group_name_avoids_plex_kinds(downloader_env):
    _db, downloader, _videos_dir = downloader_env

    assert downloader._unique_group_name("movies", "Movies") == ("movies-2", "Movies (2)")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tests/test_downloader.py -v -k "slugify or unique_group"`
Expected: FAIL with `AttributeError: module 'downloader' has no attribute '_slugify_playlist_title'`.

- [ ] **Step 3: Write minimal implementation**

Add `import re` to `downloader.py`'s imports (alphabetically, after `os`). Then append:

```python
PLAYLIST_SLUG_MAX_LEN = 40
# Guards against a pathological run of pre-existing groups; hitting it means
# something is wrong, not that the user has 200 identically-named playlists.
PLAYLIST_NAME_MAX_ATTEMPTS = 200


def _slugify_playlist_title(title: str) -> str:
    """A `groups.name` candidate. Non-ASCII-alnum runs collapse to a hyphen."""
    slug = re.sub(r"[^a-z0-9]+", "-", (title or "").lower()).strip("-")
    slug = slug[:PLAYLIST_SLUG_MAX_LEN].strip("-")
    return slug or "playlist"


def _unique_group_name(slug: str, label: str) -> tuple[str, str]:
    """A free (name, label) pair. Playlists never reuse an existing group, so
    a clash suffixes instead of returning the incumbent."""
    for attempt in range(1, PLAYLIST_NAME_MAX_ATTEMPTS + 1):
        name = slug if attempt == 1 else f"{slug}-{attempt}"
        candidate_label = label if attempt == 1 else f"{label} ({attempt})"
        if name not in db.PLEX_KINDS and db.get_group_by_name(name) is None:
            return name, candidate_label
    raise RuntimeError(f"Could not find a free group name for {slug!r}")
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python -m pytest tests/test_downloader.py -v -k "slugify or unique_group"`
Expected: PASS (10 tests).

- [ ] **Step 5: Commit**

```bash
git add downloader.py tests/test_downloader.py
git commit -m "feat: derive a unique group name from a playlist title"
```

---

### Task 4: Route playlist uploads to a background import

The endpoint change, with the import function still stubbed out by the test's monkeypatch. Landing it before Task 5 keeps the HTTP contract reviewable on its own.

**Files:**
- Modify: `router.py:26` (the `from downloader import …` line), `router.py:291-324` (`upload`)
- Test: `tests/test_api.py`

**Interfaces:**
- Consumes: `_classify_url` from Task 2 (`platform == "youtube_playlist"`).
- Produces: `POST /upload` with a playlist URL returns `202 {"status": "queued", "playlist": "<list_id>"}` and schedules `import_playlist(normalized_url)`. Task 5 implements that function with signature `async def import_playlist(url: str) -> None`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_api.py`:

```python
def test_upload_playlist_schedules_import_and_creates_no_video(client, monkeypatch):
    import db

    imported = []
    monkeypatch.setattr("router.import_playlist", lambda *a, **kw: imported.append((a, kw)))

    resp = client.post(
        "/upload",
        json={
            "url": "https://music.youtube.com/playlist?list=PLVixkqSccxTvtXpNTlQPi7fSc3kzZ5EJa&si=x"
        },
        headers={"Authorization": "Bearer test-secret"},
    )

    assert resp.status_code == 202
    assert resp.json() == {
        "status": "queued",
        "playlist": "PLVixkqSccxTvtXpNTlQPi7fSc3kzZ5EJa",
    }
    assert imported == [
        (("https://www.youtube.com/playlist?list=PLVixkqSccxTvtXpNTlQPi7fSc3kzZ5EJa",), {})
    ]
    assert db.get_all_videos() == []


def test_upload_playlist_ignores_explicit_group_id(client, monkeypatch):
    import db

    monkeypatch.setattr("router.import_playlist", lambda *a, **kw: None)
    group_id = db.get_group_by_name("adults")["id"]

    resp = client.post(
        "/upload",
        json={
            "url": "https://www.youtube.com/playlist?list=PLVixkqSccxTvtXpNTlQPi7fSc3kzZ5EJa",
            "group_id": group_id,
        },
        headers={"Authorization": "Bearer test-secret"},
    )

    assert resp.status_code == 202
    assert "id" not in resp.json()


def test_upload_playlist_requires_token(client):
    resp = client.post(
        "/upload",
        json={"url": "https://www.youtube.com/playlist?list=PLVixkqSccxTvtXpNTlQPi7fSc3kzZ5EJa"},
    )
    assert resp.status_code == 401
```

Note: if `db.get_all_videos()` requires arguments in this codebase, call it the same way the neighbouring tests in `tests/test_api.py` do.

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tests/test_api.py -v -k upload_playlist`
Expected: FAIL — `monkeypatch.setattr("router.import_playlist", …)` raises `AttributeError: <module 'router'> has no attribute 'import_playlist'`.

- [ ] **Step 3: Write minimal implementation**

In `router.py`, extend the downloader import (line 26):

```python
from downloader import download_video, import_playlist, process_uploaded_video
```

In `upload`, move the classification **above** the group resolution and short-circuit on a playlist. The function becomes:

```python
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
        groups = db.list_groups()
        if not groups:
            raise HTTPException(status_code=409, detail="No video groups configured")
        group_id = groups[0]["id"]
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
    background_tasks.add_task(download_video, video_id)
    return {"id": video_id, "status": "queued"}
```

Reordering classification ahead of the group lookup changes one existing behaviour: a request with **both** a bad URL and a bad `group_id` now returns the URL's 400 rather than the group's. Both are 400; if a test asserts the group-specific `detail`, keep that test passing by leaving its URL valid.

- [ ] **Step 4: Run tests to verify they pass**

Run: `python -m pytest tests/test_api.py -v -k upload`
Expected: PASS, including every pre-existing `/upload` test.

- [ ] **Step 5: Commit**

```bash
git add router.py tests/test_api.py
git commit -m "feat: route playlist uploads to a background import"
```

---

### Task 5: Fetch playlist metadata with yt-dlp

The single `yt-dlp --flat-playlist -J` call, isolated from the import loop so its subprocess handling is tested on its own.

**Files:**
- Modify: `downloader.py` (new functions after `_download_youtube_media_sync`, near `router.py`-independent helpers)
- Test: `tests/test_downloader.py`

**Interfaces:**
- Consumes: `YTDLP_BIN`, `YTDLP_BROWSER` module globals.
- Produces:
  - `_fetch_playlist_metadata_sync(url: str) -> tuple[str, list[dict]]` — `(playlist_title, entries)`; each entry is `{"id": str, "title": str | None}`, already filtered to valid 11-char video ids. Raises `RuntimeError` when yt-dlp fails or emits unparseable JSON.
  - `async def _fetch_playlist_metadata(url: str) -> tuple[str, list[dict]]` — the `asyncio.to_thread` wrapper Task 6 awaits.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_downloader.py`:

```python
def _playlist_json():
    return json.dumps(
        {
            "title": "Lo-fi Beats",
            "entries": [
                {"id": "dQw4w9WgXcQ", "title": "First"},
                {"id": "aBcDeFgHiJk", "title": "Second"},
                {"id": None, "title": "[Deleted video]"},
                {"title": "No id at all"},
                {"id": "short", "title": "Bad id"},
            ],
        }
    )


def test_fetch_playlist_metadata_parses_entries(monkeypatch, downloader_env):
    _db, downloader, _videos_dir = downloader_env
    seen = {}

    def fake_run(cmd, **kwargs):
        seen["cmd"] = cmd
        return subprocess.CompletedProcess(cmd, 0, stdout=_playlist_json())

    monkeypatch.setattr(downloader.subprocess, "run", fake_run)
    monkeypatch.setattr(downloader, "YTDLP_BIN", "/opt/homebrew/bin/yt-dlp")
    monkeypatch.setattr(downloader, "YTDLP_BROWSER", "chrome")

    title, entries = downloader._fetch_playlist_metadata_sync(
        "https://www.youtube.com/playlist?list=PL123456789"
    )

    assert title == "Lo-fi Beats"
    assert entries == [
        {"id": "dQw4w9WgXcQ", "title": "First"},
        {"id": "aBcDeFgHiJk", "title": "Second"},
    ]
    assert seen["cmd"][0] == "/opt/homebrew/bin/yt-dlp"
    assert "--flat-playlist" in seen["cmd"]
    assert "-J" in seen["cmd"]
    assert seen["cmd"][-1] == "https://www.youtube.com/playlist?list=PL123456789"


def test_fetch_playlist_metadata_raises_on_ytdlp_failure(monkeypatch, downloader_env):
    _db, downloader, _videos_dir = downloader_env

    def fake_run(cmd, **kwargs):
        return subprocess.CompletedProcess(cmd, 1, stdout="ERROR: private playlist")

    monkeypatch.setattr(downloader.subprocess, "run", fake_run)

    with pytest.raises(RuntimeError, match="private playlist"):
        downloader._fetch_playlist_metadata_sync("https://www.youtube.com/playlist?list=PL123456789")


def test_fetch_playlist_metadata_raises_on_bad_json(monkeypatch, downloader_env):
    _db, downloader, _videos_dir = downloader_env

    def fake_run(cmd, **kwargs):
        return subprocess.CompletedProcess(cmd, 0, stdout="not json")

    monkeypatch.setattr(downloader.subprocess, "run", fake_run)

    with pytest.raises(RuntimeError):
        downloader._fetch_playlist_metadata_sync("https://www.youtube.com/playlist?list=PL123456789")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tests/test_downloader.py -v -k fetch_playlist`
Expected: FAIL with `AttributeError: module 'downloader' has no attribute '_fetch_playlist_metadata_sync'`.

- [ ] **Step 3: Write minimal implementation**

Append to `downloader.py`:

```python
PLAYLIST_VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")


async def _fetch_playlist_metadata(url: str) -> tuple[str, list[dict]]:
    return await asyncio.to_thread(_fetch_playlist_metadata_sync, url)


def _fetch_playlist_metadata_sync(url: str) -> tuple[str, list[dict]]:
    """(title, entries) for a playlist page.

    `--flat-playlist` keeps this to one cheap request: it lists entries without
    resolving each video, which is all the import loop needs — every entry is
    downloaded later through the normal single-video path.
    """
    cmd = [
        YTDLP_BIN,
        "--cookies-from-browser",
        YTDLP_BROWSER,
        "--flat-playlist",
        "-J",
        url,
    ]
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    output = proc.stdout or ""
    if proc.returncode != 0:
        raise RuntimeError(output.strip() or "yt-dlp failed")

    try:
        data = json.loads(output)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Could not parse yt-dlp playlist JSON: {exc}") from exc

    title = (data.get("title") or "").strip()
    entries = []
    for entry in data.get("entries") or []:
        video_id = (entry or {}).get("id") or ""
        # Deleted and private entries keep a slot in the list with no usable id.
        if PLAYLIST_VIDEO_ID_RE.fullmatch(video_id):
            entries.append({"id": video_id, "title": entry.get("title")})
    return title, entries
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python -m pytest tests/test_downloader.py -v -k fetch_playlist`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add downloader.py tests/test_downloader.py
git commit -m "feat: fetch YouTube playlist metadata with yt-dlp"
```

---

### Task 6: Import a playlist into a new group

The orchestration: create the group, create a row per entry, download them one at a time, flush the cache.

**Files:**
- Modify: `downloader.py` (append `import_playlist`; add `import cache` to the imports)
- Test: `tests/test_downloader.py`

**Interfaces:**
- Consumes: `_fetch_playlist_metadata` (Task 5), `_unique_group_name` / `_slugify_playlist_title` (Task 3), `download_video`, `db.create_group`, `db.add_video`, `db.get_completed_video_by_source`, `db.set_video_group`, `cache.clear`.
- Produces: `async def import_playlist(url: str) -> None` — the function `router.upload` schedules in Task 4.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_downloader.py`:

```python
@pytest.fixture()
def playlist_env(monkeypatch, downloader_env):
    """downloader_env plus stubbed metadata, downloads and cache flush."""
    db, downloader, videos_dir = downloader_env
    state = {"downloaded": [], "cache_flushes": 0, "entries": [], "title": "Lo-fi Beats"}

    async def fake_metadata(url):
        state["metadata_url"] = url
        return state["title"], state["entries"]

    async def fake_download(video_id):
        state["downloaded"].append(video_id)
        db.update_video(video_id, status="done", filename=f"{video_id}.mp4")

    async def fake_clear():
        state["cache_flushes"] += 1

    monkeypatch.setattr(downloader, "_fetch_playlist_metadata", fake_metadata)
    monkeypatch.setattr(downloader, "download_video", fake_download)
    monkeypatch.setattr(downloader.cache, "clear", fake_clear)
    return db, downloader, state


@pytest.mark.asyncio
async def test_import_playlist_creates_group_and_queues_entries(playlist_env):
    db, downloader, state = playlist_env
    state["entries"] = [
        {"id": "dQw4w9WgXcQ", "title": "First"},
        {"id": "aBcDeFgHiJk", "title": "Second"},
    ]

    await downloader.import_playlist("https://www.youtube.com/playlist?list=PL123456789")

    group = db.get_group_by_name("lo-fi-beats")
    assert group is not None
    assert group["label"] == "Lo-fi Beats"

    videos = [v for v in db.get_all_videos() if v["group_id"] == group["id"]]
    assert [v["source_key"] for v in videos] == ["dQw4w9WgXcQ", "aBcDeFgHiJk"]
    assert [v["url"] for v in videos] == [
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://www.youtube.com/watch?v=aBcDeFgHiJk",
    ]
    assert [v["preview_url"] for v in videos] == [
        "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
        "https://i.ytimg.com/vi/aBcDeFgHiJk/hqdefault.jpg",
    ]
    assert state["downloaded"] == [v["id"] for v in videos]
    assert state["cache_flushes"] >= 1


@pytest.mark.asyncio
async def test_import_playlist_reuses_completed_video(playlist_env):
    db, downloader, state = playlist_env
    existing_id = db.add_video(
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        platform="youtube",
        source_key="dQw4w9WgXcQ",
    )
    db.update_video(existing_id, status="done", filename=f"{existing_id}.mp4")
    state["entries"] = [{"id": "dQw4w9WgXcQ", "title": "First"}]

    await downloader.import_playlist("https://www.youtube.com/playlist?list=PL123456789")

    group = db.get_group_by_name("lo-fi-beats")
    assert db.get_video(existing_id)["group_id"] == group["id"]
    assert state["downloaded"] == []
    assert len(db.get_all_videos()) == 1


@pytest.mark.asyncio
async def test_import_playlist_creates_no_group_when_empty(playlist_env):
    db, downloader, state = playlist_env
    state["entries"] = []

    await downloader.import_playlist("https://www.youtube.com/playlist?list=PL123456789")

    assert db.get_group_by_name("lo-fi-beats") is None
    assert db.get_all_videos() == []


@pytest.mark.asyncio
async def test_import_playlist_creates_no_group_when_metadata_fails(monkeypatch, playlist_env):
    db, downloader, _state = playlist_env

    async def boom(url):
        raise RuntimeError("private playlist")

    monkeypatch.setattr(downloader, "_fetch_playlist_metadata", boom)

    await downloader.import_playlist("https://www.youtube.com/playlist?list=PL123456789")

    assert db.list_groups() == db.list_groups()  # no exception escaped
    assert db.get_group_by_name("lo-fi-beats") is None


@pytest.mark.asyncio
async def test_import_playlist_continues_past_a_failing_entry(monkeypatch, playlist_env):
    db, downloader, state = playlist_env
    state["entries"] = [
        {"id": "dQw4w9WgXcQ", "title": "First"},
        {"id": "aBcDeFgHiJk", "title": "Second"},
    ]

    async def flaky_download(video_id):
        if len(state["downloaded"]) == 0:
            state["downloaded"].append(video_id)
            raise RuntimeError("network died")
        state["downloaded"].append(video_id)
        db.update_video(video_id, status="done", filename=f"{video_id}.mp4")

    monkeypatch.setattr(downloader, "download_video", flaky_download)

    await downloader.import_playlist("https://www.youtube.com/playlist?list=PL123456789")

    assert len(state["downloaded"]) == 2


@pytest.mark.asyncio
async def test_import_playlist_suffixes_a_taken_group_name(playlist_env):
    db, downloader, state = playlist_env
    db.create_group("lo-fi-beats", "Lo-fi Beats")
    state["entries"] = [{"id": "dQw4w9WgXcQ", "title": "First"}]

    await downloader.import_playlist("https://www.youtube.com/playlist?list=PL123456789")

    group = db.get_group_by_name("lo-fi-beats-2")
    assert group is not None
    assert group["label"] == "Lo-fi Beats (2)"


@pytest.mark.asyncio
async def test_import_playlist_falls_back_when_title_is_empty(playlist_env):
    db, downloader, state = playlist_env
    state["title"] = ""
    state["entries"] = [{"id": "dQw4w9WgXcQ", "title": "First"}]

    await downloader.import_playlist("https://www.youtube.com/playlist?list=PL123456789")

    group = db.get_group_by_name("playlist")
    assert group is not None
    assert group["label"] == "Playlist"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tests/test_downloader.py -v -k import_playlist`
Expected: FAIL with `AttributeError: module 'downloader' has no attribute 'import_playlist'`.

- [ ] **Step 3: Write minimal implementation**

Add `import cache` to `downloader.py`'s local imports (next to `import db`). Then append:

```python
PLAYLIST_FALLBACK_LABEL = "Playlist"


def _youtube_watch_url(video_id: str) -> str:
    return f"https://www.youtube.com/watch?v={video_id}"


def _youtube_preview_url(video_id: str) -> str:
    return f"https://i.ytimg.com/vi/{video_id}/hqdefault.jpg"


async def import_playlist(url: str) -> None:
    """Expand a YouTube playlist into a new group, then download it.

    Runs as a BackgroundTask: the HTTP response went out before any of this, so
    there is nowhere to report failures except the log. Nothing is created when
    the playlist can't be read or has no usable entries — the user simply sees
    no new group.

    Downloads run one at a time on purpose. Fanning a 200-entry playlist out
    into 200 concurrent yt-dlp runs is the failure that took the machine down
    on 2026-07-31 (see docs/superpowers/specs/2026-07-31-ffmpeg-job-queue-design.md).
    """
    try:
        title, entries = await _fetch_playlist_metadata(url)
    except Exception as exc:
        logger.warning("Playlist metadata failed for %s: %s", url, exc)
        return

    if not entries:
        logger.warning("Playlist %s has no downloadable entries; no group created", url)
        return

    name, label = _unique_group_name(
        _slugify_playlist_title(title), title.strip() or PLAYLIST_FALLBACK_LABEL
    )
    group = db.create_group(name, label)
    logger.info("Playlist %s -> group %s (%d entries)", url, name, len(entries))

    video_ids = []
    for entry in entries:
        existing = db.get_completed_video_by_source("youtube", entry["id"])
        if existing:
            db.set_video_group(existing["id"], group["id"])
            continue
        video_ids.append(
            db.add_video(
                _youtube_watch_url(entry["id"]),
                platform="youtube",
                source_key=entry["id"],
                title=entry.get("title"),
                preview_url=_youtube_preview_url(entry["id"]),
                group_id=group["id"],
            )
        )

    # The group and its rows exist now; flush before the (long) download loop so
    # the app sees the group immediately. Nothing above was an HTTP write, so
    # the cache middleware never fired.
    await cache.clear()

    for video_id in video_ids:
        try:
            await download_video(video_id)
        except Exception as exc:
            logger.warning("Playlist entry %s failed: %s", video_id, exc)
        await cache.clear()
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python -m pytest tests/test_downloader.py -v -k import_playlist`
Expected: PASS (7 tests).

- [ ] **Step 5: Run the whole suite**

Run: `python -m pytest tests/`
Expected: PASS. `download_video` swallows its own exceptions, so the "failing entry" test exercises the belt-and-braces `try` in the loop.

- [ ] **Step 6: Commit**

```bash
git add downloader.py tests/test_downloader.py
git commit -m "feat: import a YouTube playlist into a new group"
```

---

### Task 7: Document the playlist path

**Files:**
- Modify: `CLAUDE.md` (the "Request → download → serve flow" section, step 1)

**Interfaces:**
- Consumes: everything above. Produces: nothing code-level.

- [ ] **Step 1: Update the flow description**

In `CLAUDE.md`, under "### Request → download → serve flow", insert after item 1:

```markdown
   A YouTube **playlist** URL (`/playlist?list=…`, on `youtube.com`,
   `m.youtube.com` or `music.youtube.com`) classifies as `youtube_playlist` and
   takes a different route: no row is inserted, `body.group_id` is ignored, and
   `downloader.import_playlist` runs as a BackgroundTask. It calls
   `yt-dlp --flat-playlist -J` once, creates a **new** group named after the
   playlist title (`name` slugified, suffixed `-2`, `-3`… on collision — an
   existing group is never reused), inserts one row per entry, and downloads
   them **sequentially**. `watch?v=X&list=Y` is deliberately *not* a playlist:
   shared links routinely carry a Mix id nobody meant to hand over. The
   response is `202 {"status": "queued", "playlist": "<list_id>"}` — no ids,
   because neither the group nor the rows exist yet; clients poll
   `/api/groups`. A failed or empty playlist creates nothing and is only
   visible in `log/backend.log`.
```

- [ ] **Step 2: Verify nothing else drifted**

Run: `python -m pytest tests/`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: describe the playlist upload path"
```

---

## Manual verification

After Task 7, with `./serve` running:

```bash
curl -X POST localhost:3050/upload \
  -H "Authorization: Bearer $UPLOAD_TOKEN" -H 'Content-Type: application/json' \
  -d '{"url":"https://music.youtube.com/playlist?list=PLVixkqSccxTvtXpNTlQPi7fSc3kzZ5EJa&si=eNDjY3nVNq-0D491"}'
# => {"status":"queued","playlist":"PLVixkqSccxTvtXpNTlQPi7fSc3kzZ5EJa"}

grep -i playlist log/backend.log          # group name + entry count
curl -s localhost:3050/api/groups | jq    # the new group appears
```

The iOS Videos tab renders `/api/groups`, so the new group shows up there on the next fetch with no app change.
