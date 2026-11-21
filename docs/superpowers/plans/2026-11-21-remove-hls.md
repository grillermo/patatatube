# Remove HLS completely — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** PatataTube stops producing, serving and playing HLS packages. Every video plays from its mp4, and the 36 GB under `/Volumes/Media/patatatube/data/hls` is freed.

**Architecture:** There are three parts.
- **Part A, the server.** It stops advertising `hls_path` and packaging anything. The installed app (2.8.0) already falls back to the mp4 when `hls_path` is absent (`PlaybackSource.swift`: `proxy_mp4` / `direct_mp4`). So Part A ships first and needs no app update, and the HLS folders can be deleted right after it.
- **Part B, the iOS app.** It drops HLS playback, HLS downloads, the proxy's HLS routes, the segment cache and the "Converting" UI. Any HLS package already saved on the phone is deleted, and that video is downloaded again as an mp4.
- **Part C, cleanup.** Once 2.9.0 is installed, it removes the `/api/jobs` endpoint, which 2.8.0 still polls.

**Tech Stack:**
- Server: Python 3.13, FastAPI, SQLite and pytest.
- Proxy: Caddy, configured in `~/c/server/Caddyfile`.
- App: Swift 6 / SwiftUI, with the PatataTubeKit SwiftPM package, swift-testing and XCTest, XcodeGen and xcodebuild.

---

## Background: why this exists

All 237 HLS packages are byte-for-byte repackagings of their mp4: `hls.build_ffmpeg_command` uses `-c copy` because every download is already H.264/AAC. That's 36.1 GB stored twice. A scan on 2026-11-21 found every HLS folder within 5% of its mp4's size.

Nothing that HLS uniquely provides is in use:
- **Subtitles** only reach the player through HLS. But `downloader._normalize_media_for_ios` passes `-sn`, which drops them, and none of the 237 packages contains a `.vtt` file.
- **Adaptive bitrate** never existed: each package has a single rendition.
- **AirPlay, `/sd`, Send to Yoto and the web page** all read the mp4 already.
- **Offline mp4 downloads** are the stronger path: parallel ranged streams, with a pause that resumes byte by byte. Pausing an HLS download restarts it from zero (`CacheManager.pauseExternal`).

## Decisions (made by the plan author; change here, not mid-task)

1. **The server ships first.** Without `hls_path`, the installed 2.8.0 app streams through `proxy_mp4`, so Part A has no ordering hazard. The HLS folders must not be deleted before Part A is live, though: 2.8.0 requests `master.m3u8` for every finished video, and today a missing package queues a packaging job (`router.hls_asset`).
2. **`/api/jobs` stays until 2.9.0 is installed,** answering an empty snapshot. Only `hls` jobs were ever listed there (`db.PROGRESS_JOB_KINDS`), and 2.8.0 polls it every 2 s. Part C deletes it.
3. **HLS packages already on a phone are downloaded again as mp4,** not kept. Keeping them would mean keeping the offline HLS route, the package format and its playback branch, which is most of what this plan removes. 2.9.0 deletes the `hls-*` folders at launch and queues mp4 downloads for those ids. Paused HLS downloads (a `remoteURL` ending in `.m3u8`) are dropped and queued the same way.
4. **The `versionId` plumbing stays.** It's out of scope, as in the Plex plan's Decision 4. The `_v<id>` suffix on `hls-*` folder names is still parsed by the migration.
5. **`jobs.progress` and `set_job_progress` stay.** They're generic converter bookkeeping that `sd` jobs write too. Only the reader (`active_jobs`) goes.
6. **The external-activity machinery in `CacheManager` goes.** `beginExternalActivity` and its relatives exist only for `downloadHLS`, so they're removed along with it, including the `beforeExternalPromotion` init parameter.
7. **iOS tests are compiled, not run, unless the owner asks** (CLAUDE.md). Every iOS task must leave `swift build --build-tests` green. The app target's `xcodebuild build-for-testing` is checked once, in Task B5.

## File map

**Server (Part A):**
- Delete: `hls.py`, `subtitles.py`, `check_subtitles.py`, `media_probe.py`, `tests/test_hls.py`, `tests/test_subtitles.py`, `tests/test_media_probe.py`.
- Modify:
  - `views/serializers.py`: drop `_hls_ready` and `hls_path`.
  - `downloader.py`: no HLS job after a download.
  - `router.py`: drop `import hls`, `_resolve_hls_source` and `hls_asset`; `api_jobs` returns a constant.
  - `converter.py`: drop the `hls` handler and its orphan cleanup.
  - `db.py`: `JOB_KINDS`, the `hls_status` guard, `set_hls_status`, `PROGRESS_JOB_KINDS` and `active_jobs` go, plus a new `_drop_hls` migration.
  - `paths.py`: drop `HLS_DIR`.
  - `classifier.py`: one comment.
  - `serve`: two comments.
  - `.env.example`, `CLAUDE.md`, `README.md`.
- Tests modified: `tests/test_serializers.py`, `tests/test_downloader.py`, `tests/test_api.py`, `tests/test_converter.py`, `tests/test_jobs.py`, `tests/test_db.py`, `tests/test_paths.py`.
- Other repo: `~/c/server/Caddyfile` loses handler 2 (HLS assets) and its comments.

**iOS (Part B):** paths below are relative to `ios/`.
- Delete:
  - Kit sources: `CacheManager+HLS.swift`, `HLSManifestParser.swift`, `SegmentCache.swift`, `JobsStore.swift` and `ConversionJob.swift`, all in `PatataTubeKit/Sources/PatataTubeKit/`.
  - App sources: `PatataTube/Sources/SpikeDownloadProbe.swift`.
  - Kit tests: `CacheManagerHLSTests.swift`, `HLSManifestParserTests.swift`, `JobsStoreTests.swift` and `APIClientJobsTests.swift`, all in `PatataTubeKit/Tests/PatataTubeKitTests/`.
- Modify (Kit):
  - `Video.swift`: drop `hlsPath`.
  - `APIClient.swift`: drop `jobs()` and the `JobsAPI` protocol.
  - `CacheManager.swift`: drop HLS, offline HLS and external activity; add the legacy-package migration.
  - `PausedDownloadStore.swift`: drop `isHLS`; filter out `.m3u8` entries.
  - `StreamProxy.swift`: drop the `hls` and `offline` routes.
  - `StreamCache.swift`: drop the `segments` store.
  - `CacheStatistics.swift`: drop the HLS rows.
- Modify (app):
  - `PlaybackSource.swift`: drop the HLS branches.
  - `AppModel.swift`: drop the HLS URL builders; add `migrateLegacyHLSDownloads()`.
  - `VideoGridView.swift`: an mp4-only download; no `JobsStore`.
  - `DownloadsView.swift`: no Converting section.
  - `DownloadButton.swift`: no conversion ring.
  - `VideoCell.swift`: drop the debug row.
  - `PatataTubeApp.swift`: call the migration.
- Tests modified (Kit): `StreamProxyTests.swift`, `CacheStatisticsCollectorTests.swift`, `StreamCacheTests.swift`, `VideoHashableTests.swift`, `APIClientReadTests.swift`, `CacheManagerByteCounterTests.swift`, `CacheManagerPauseTests.swift`, `PausedDownloadStoreTests.swift`.
- Tests modified (app): `PatataTube/Tests/DownloadButtonTests.swift`, `PatataTube/Tests/DownloadsViewTests.swift`.
- Create: `PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerLegacyHLSTests.swift`.

**Part C:** `router.py`, `tests/test_api.py` and `CLAUDE.md`.

## Running things

- **Backend tests,** run from the repo root. `MEDIA_ROOT=.` matters (CLAUDE.md):

```bash
MEDIA_ROOT=. ./python_env/bin/python -m pytest tests/ -q
```

  If `python_env` is broken on the machine (on immunemac python3.13 was missing), build a venv with uv and use its python instead:

```bash
uv venv "$TMPDIR/patatatube-venv" --python 3.13 && uv pip install --python "$TMPDIR/patatatube-venv/bin/python" -r requirements.txt
```

- **Kit build,** run from `ios/PatataTubeKit`:

```bash
swift build && swift build --build-tests
```

- **App build,** run from `ios/PatataTube`. Pick a simulator udid that exists on the machine from `xcrun simctl list devices available`; the udids in CLAUDE.md belong to another machine. After the build, restore `ios/PatataTubeKit/Package.resolved` with `git checkout`, because xcodebuild rewrites it:

```bash
xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination "platform=iOS Simulator,id=$(xcrun simctl list devices available | grep -m1 -o '[0-9A-F-]\{36\}')" build-for-testing
```

Record the backend baseline before Task A1 (540 passed at `b47a005`). Every later run compares against it, minus the tests this plan deletes.

---

# Part A — server (ships first; works with the installed 2.8.0 app)

### Task A1: Stop advertising `hls_path`

**Files:**
- Modify: `views/serializers.py`
- Test: `tests/test_serializers.py`

- [ ] **Step 1: write the failing test.** In `tests/test_serializers.py`, replace `test_done_download_row_exposes_hls_path` and `test_unready_row_omits_hls_path` with:

```python
def test_serialized_video_never_has_hls_path():
    for status in ("done", "queued", "downloading"):
        data = serialize_video({"id": 4, "url": "https://x.com/s/1", "status": status})
        assert "hls_path" not in data
```

  Then make two more edits:
  - Remove the `"hls_path": "/videos/7/hls/master.m3u8",` line from the expected dict in `test_serialize_video_full_shape`.
  - In `test_serialized_video_has_no_library_fields`, replace `assert data["hls_path"] == "/videos/1/hls/master.m3u8"` with `assert "hls_path" not in data`.

- [ ] **Step 2: run it and see it fail.**

```bash
MEDIA_ROOT=. ./python_env/bin/python -m pytest tests/test_serializers.py -q
```

  Expected: 3 failures, all on `hls_path`.

- [ ] **Step 3: implement.** In `views/serializers.py`:
  - Delete the whole `_hls_ready` function.
  - In `serialize_video`, delete these two lines:

```python
    if _hls_ready(video):
        data["hls_path"] = f"/videos/{video['id']}/hls/master.m3u8"
```

- [ ] **Step 4: run it and see it pass** (same command). Expected: all pass.

- [ ] **Step 5: commit.**

```bash
git add views/serializers.py tests/test_serializers.py
git commit -m "Stop advertising hls_path: every video plays from its mp4

Installed apps (2.8.0) fall back to proxy_mp4 when hls_path is absent."
```

### Task A2: No HLS job after a download

**Files:**
- Modify: `downloader.py`, `classifier.py`
- Test: `tests/test_downloader.py`

- [ ] **Step 1: write the failing test.** Replace `test_download_youtube_enqueues_hls_packaging` in `tests/test_downloader.py` with:

```python
@pytest.mark.asyncio
async def test_download_youtube_queues_no_packaging_job(
    monkeypatch, downloader_env, tmp_path
):
    db, downloader, _videos_dir = downloader_env
    source_file = tmp_path / "source.mp4"
    source_file.write_bytes(b"youtube-bytes")

    async def fake_download(url):
        return downloader.YoutubeDownload(source_file, "Downloaded Title", "Veritasium")

    async def fake_normalize(path, video_id, channel=None, source_key=None):
        return Path(path)

    monkeypatch.setattr(downloader, "_download_youtube_media", fake_download)
    monkeypatch.setattr(downloader, "_normalize_media_for_ios", fake_normalize)

    video_id = db.add_video(
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        platform="youtube",
        source_key="dQw4w9WgXcQ",
    )
    await downloader.download_video(video_id)

    assert db.get_video(video_id)["status"] == "done"
    assert db.claim_job() is None
```

- [ ] **Step 2: run it and see it fail.**

```bash
MEDIA_ROOT=. ./python_env/bin/python -m pytest tests/test_downloader.py -q -k packaging
```

  Expected: FAIL, because `claim_job()` returns the `hls` job.

- [ ] **Step 3: implement.**
  - In `downloader.download_video`, delete:

```python
            db.enqueue_job(
                "hls",
                video_id,
                priority=db.PRIORITY_BULK,
                payload={"source_path": str(VIDEOS_DIR / dest_name)},
            )
```

  - `VIDEOS_DIR` is still used elsewhere in the file; check with `grep -n VIDEOS_DIR downloader.py`, and leave the import.
  - In `classifier.py` around line 93, reword the comment that mentions "the HLS job" so it no longer names it.

- [ ] **Step 4: run the whole file.**

```bash
MEDIA_ROOT=. ./python_env/bin/python -m pytest tests/test_downloader.py -q
```

  If a test in the file has `import hls  # noqa`, delete that line. Expected: all pass.

- [ ] **Step 5: commit.**

```bash
git add downloader.py classifier.py tests/test_downloader.py
git commit -m "Downloads no longer queue HLS packaging"
```

### Task A3: Delete HLS serving, packaging and its modules

**Files:**
- Delete: `hls.py`, `subtitles.py`, `check_subtitles.py`, `media_probe.py`, `tests/test_hls.py`, `tests/test_subtitles.py`, `tests/test_media_probe.py`
- Modify: `router.py`, `converter.py`, `db.py` (the `JOB_KINDS` line only), `paths.py`
- Test: `tests/test_api.py`, `tests/test_converter.py`, `tests/test_jobs.py`, `tests/test_paths.py`

- [ ] **Step 1: write the failing tests.**
  - Add to `tests/test_api.py`, which already defines `_seed_done_download` and `AUTH`:

```python
def test_hls_urls_are_gone(client):
    import db

    video_id, _ = _seed_done_download()
    resp = client.get(f"/videos/{video_id}/hls/master.m3u8", headers=AUTH)

    assert resp.status_code == 404
    assert db.claim_job() is None


def test_jobs_endpoint_always_reports_nothing(client, auth_headers):
    import db

    video_id, _ = _seed_done_download()
    db.enqueue_job("sd", video_id)
    body = client.get("/api/jobs", headers=auth_headers).json()
    assert body == {"running": [], "queued": [], "queued_total": 0}
```

  - Add to `tests/test_jobs.py`:

```python
def test_hls_is_not_a_job_kind():
    import db

    with pytest.raises(ValueError):
        db.enqueue_job("hls", 1)
```

- [ ] **Step 2: run them and see them fail.**

```bash
MEDIA_ROOT=. ./python_env/bin/python -m pytest tests/test_api.py tests/test_jobs.py -q -k "hls_urls_are_gone or always_reports_nothing or not_a_job_kind"
```

  Expected: `hls_urls_are_gone` fails (409, and a job is queued) and `not_a_job_kind` fails. `always_reports_nothing` may already pass, since `sd` is not a progress kind; that's fine, because it guards Step 4.

- [ ] **Step 3: delete the modules and their tests.**

```bash
git rm hls.py subtitles.py check_subtitles.py media_probe.py tests/test_hls.py tests/test_subtitles.py tests/test_media_probe.py
```

- [ ] **Step 4: `router.py`.**
  - Delete `import hls`, the whole `_resolve_hls_source` function, and the whole `hls_asset` route (`@router.get("/videos/{video_id}/hls/{asset_path:path}")` through its final `raise`).
  - Replace `JOBS_QUEUED_LIMIT` and `api_jobs` with:

```python
@router.get("/api/jobs")
async def api_jobs(request: Request):
    """Kept only for PatataTube iOS 2.8.0, which polls it every 2s. Nothing
    reports progress any more: only HLS packaging did. Removed in Task C1 of
    docs/superpowers/plans/2026-11-21-remove-hls.md."""
    _check_token(request)
    return {"running": [], "queued": [], "queued_total": 0}
```

  - At line ~326, "Caddy's forward_auth re-sends stream/HLS requests" becomes "re-sends stream requests".

- [ ] **Step 5: `converter.py`.**
  - Delete `import hls  # noqa: E402`, the whole `_handle_hls` function, and the `"hls": _handle_hls,` entry in `JOB_HANDLERS`.
  - In `cleanup_orphan`, replace the `if job["kind"] == "hls": ... elif job["kind"] == "sd":` chain with:

```python
        if job["kind"] == "sd":
            sd.part_path(job["video_id"]).unlink(missing_ok=True)
```

  - The comment "Classification runs here, after each HLS job; without this its log lines never reach ./serve's "convert" stream." becomes "Classification can log from this process too; without this those lines never reach ./serve's "convert" stream."
  - The comment in `_handle_normalize`, "a normalize job is rare compared to hls", becomes "a normalize job is rare".

- [ ] **Step 6: `db.py`.** Change the `JOB_KINDS` line to:

```python
JOB_KINDS = ("normalize", "sd")
```

- [ ] **Step 7: `paths.py`.**
  - Delete the `HLS_DIR = ...` line.
  - In the docstring, change "keeps VIDEOS_DIR/HLS_DIR byte-identical" to "keeps VIDEOS_DIR byte-identical".
  - In `tests/test_paths.py`, delete every assertion on `paths.HLS_DIR` and any `HLS_DIR` env setting. Keep the `VIDEOS_DIR` assertions.

- [ ] **Step 8: fix the remaining tests.**
  - `tests/test_api.py`: delete these tests:
    - `test_cold_master_playlist_enqueues_an_hls_job`
    - `test_hls_master_404_for_missing_video`
    - `test_hls_master_409_when_source_not_ready`
    - `test_hls_master_prepares_then_serves_tree`
    - `test_hls_master_requires_auth`
    - `test_hls_rejects_path_traversal`
    - `test_jobs_returns_running_and_queued`
    - `test_jobs_caps_the_queued_list_at_twenty`

    Keep `test_jobs_is_empty_when_nothing_is_pending` and `test_jobs_requires_a_token`. In `test_preview_404_for_download_rows`, delete any `import hls` and `monkeypatch.setattr(hls, ...)` lines.
  - `tests/test_converter.py`: delete `test_cleanup_orphan_invalidates_partial_hls_output` and `test_hls_failure_resets_video_and_marks_job_failed`. In the other tests, change the job kind `"hls"` to `"sd"` and `JOB_HANDLERS["hls"]` monkeypatches to `JOB_HANDLERS["sd"]`. Delete any `import hls`.
  - `tests/test_jobs.py`: change every `"hls"` job kind to `"sd"`. `test_different_kinds_for_one_video_coexist` uses `"sd"` and `"normalize"`. Leave the `active_jobs` tests for Task A4.

- [ ] **Step 9: run the whole suite.**

```bash
MEDIA_ROOT=. ./python_env/bin/python -m pytest tests/ -q
```

  Expected: all pass. `git grep -n -E "import hls|HLS_DIR|set_hls_status" -- '*.py'` prints only `db.py` lines that Task A4 removes.

- [ ] **Step 10: commit.**

```bash
git add -A router.py converter.py db.py paths.py tests/
git commit -m "Remove HLS packaging and serving

Every package was a -c copy of its mp4. /api/jobs stays, empty, for the
installed 2.8.0 app."
```

### Task A4: DB — drop `hls_status` and stale `hls` jobs

**Files:**
- Modify: `db.py`
- Test: `tests/test_db.py`, `tests/test_jobs.py`

- [ ] **Step 1: write the failing tests.** Add to `tests/test_db.py`:

```python
def test_init_db_drops_hls(tmp_path, monkeypatch):
    import sqlite3

    import db

    path = tmp_path / "hls.sqlite"
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        CREATE TABLE videos (
            id INTEGER PRIMARY KEY AUTOINCREMENT, url TEXT NOT NULL, platform TEXT,
            source_key TEXT, title TEXT, filename TEXT, status TEXT NOT NULL DEFAULT 'queued',
            error_msg TEXT, created_at TEXT NOT NULL, resume_secs REAL NOT NULL DEFAULT 0,
            hls_status TEXT NOT NULL DEFAULT 'none'
        );
        CREATE TABLE jobs (id INTEGER PRIMARY KEY, kind TEXT NOT NULL, video_id INTEGER NOT NULL,
            version_id INTEGER NOT NULL DEFAULT 0, payload TEXT, result TEXT,
            priority INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT 'queued',
            attempts INTEGER NOT NULL DEFAULT 0, error_msg TEXT, created_at TEXT NOT NULL,
            started_at TEXT, finished_at TEXT);
        INSERT INTO videos (id, url, status, created_at, resume_secs, hls_status)
            VALUES (1, 'https://youtu.be/x', 'done', '2026-01-01', 42, 'done');
        INSERT INTO jobs (kind, video_id, created_at) VALUES ('hls', 1, '2026-01-01');
        INSERT INTO jobs (kind, video_id, created_at) VALUES ('sd', 1, '2026-01-01');
        """
    )
    conn.close()
    monkeypatch.setenv("DB_PATH", str(path))

    db.init_db()
    db.init_db()  # idempotent

    conn = sqlite3.connect(path)
    columns = {r[1] for r in conn.execute("PRAGMA table_info(videos)")}
    jobs = conn.execute("SELECT kind FROM jobs").fetchall()
    rows = conn.execute("SELECT id, resume_secs FROM videos").fetchall()
    conn.close()

    assert "hls_status" not in columns
    assert jobs == [("sd",)]
    assert rows == [(1, 42)]


def test_fresh_db_has_no_hls_status(tmp_path, monkeypatch):
    import sqlite3

    import db

    path = tmp_path / "fresh-hls.sqlite"
    monkeypatch.setenv("DB_PATH", str(path))
    db.init_db()
    conn = sqlite3.connect(path)
    columns = {r[1] for r in conn.execute("PRAGMA table_info(videos)")}
    conn.close()
    assert "hls_status" not in columns
```

  In `test_init_db_purges_the_library`, change `assert jobs == [("hls", 1)]` to `assert jobs == []`: the legacy fixture's only surviving job is an `hls` one, which the new migration deletes.

- [ ] **Step 2: run them and see them fail.**

```bash
MEDIA_ROOT=. ./python_env/bin/python -m pytest tests/test_db.py -q
```

  Expected: 3 failures.

- [ ] **Step 3: implement in `db.py`.**
  - Delete the guard:

```python
        if "hls_status" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN hls_status TEXT NOT NULL DEFAULT 'none'")
```

  - Add this function right after `_purge_library`:

```python
def _drop_hls(conn: sqlite3.Connection) -> None:
    """Remove HLS packaging's data. Idempotent.

    HLS was removed on 2026-11-21: every package was a `-c copy` of the mp4
    it came from, so its job kind and its status column go.
    """
    conn.execute("DELETE FROM jobs WHERE kind = 'hls'")
    columns = {row["name"] for row in conn.execute("PRAGMA table_info(videos)").fetchall()}
    if "hls_status" in columns:
        conn.execute("ALTER TABLE videos DROP COLUMN hls_status")
    conn.commit()
```

  - In `init_db`, call it right after `_purge_library(conn)`:

```python
        _purge_library(conn)
        _drop_hls(conn)
```

  - Delete `set_hls_status`, `PROGRESS_JOB_KINDS` and the whole `active_jobs` function. Keep `set_job_progress`.
  - Reword the comment near line 147 ("a download still running, or one whose HLS package is still being...") so it describes only a download still running.

- [ ] **Step 4: delete the `active_jobs` tests** in `tests/test_jobs.py`:
  - `test_active_jobs_caps_queued_but_counts_all`
  - `test_active_jobs_carries_the_video_title`
  - `test_active_jobs_excludes_normalize`
  - `test_active_jobs_orders_queued_by_priority_then_id`
  - `test_active_jobs_splits_running_from_queued`

- [ ] **Step 5: run the whole suite.**

```bash
MEDIA_ROOT=. ./python_env/bin/python -m pytest tests/ -q
```

  Expected: all pass.

- [ ] **Step 6: check the migration on a copy of the production database.** Plain `mode=ro` fails on that WAL database, so open it normally and use `backup()`. First take the snapshot, from this machine:

```bash
mkdir -p "$TMPDIR/hlsrm" && command ssh macmini 'cd ~/c/patatatube && ./python_env/bin/python -I -c "
import sqlite3; s = sqlite3.connect(\"data/watch_later.sqlite\"); d = sqlite3.connect(\"/tmp/hlsrm.sqlite\"); s.backup(d); d.close()"' && scp -q macmini:/tmp/hlsrm.sqlite "$TMPDIR/hlsrm/watch_later.sqlite" && command ssh macmini 'rm /tmp/hlsrm.sqlite'
```

  Then run the migration on it, from the repo root:

```bash
DB_PATH="$TMPDIR/hlsrm/watch_later.sqlite" MEDIA_ROOT=. ./python_env/bin/python -c "
import db, sqlite3, os; db.init_db(); db.init_db()
c = sqlite3.connect(os.environ['DB_PATH'])
print('hls_status' in {r[1] for r in c.execute('pragma table_info(videos)')})
print(c.execute(\"select count(*) from jobs where kind='hls'\").fetchone()[0])
print(c.execute('select count(*), sum(resume_secs), sum(play_count) from videos').fetchone())"
```

  Expected: `False`, `0`, and the same count, resume total and play-count total as before (239 / 20629.69… / 950 on 2026-11-21).

- [ ] **Step 7: commit.**

```bash
git add db.py tests/test_db.py tests/test_jobs.py
git commit -m "db: drop hls_status and stale hls jobs"
```

### Task A5: Docs and config

**Files:**
- Modify: `.env.example`, `serve`, `CLAUDE.md`, `README.md`

- [ ] **Step 1: `.env.example`.**
  - Delete the two `LIBRARY_AUDIO_LANGS` lines; only the deleted `media_probe.py` read the variable.
  - Delete `#HLS_DIR=`.
  - Change the `MEDIA_ROOT` comments to:

```
# Root for downloaded MP4s. Unset = repo-relative (videos/).
# Set to an external volume to keep them off the boot disk.
MEDIA_ROOT=/Volumes/Media/patatatube
# Optional override (defaults to $MEDIA_ROOT/videos)
#VIDEOS_DIR=
```

- [ ] **Step 2: `serve`.**
  - Line ~24: "serves static assets / HLS segments / downloaded MP4s" becomes "serves static assets / downloaded MP4s".
  - Line ~88: drop "HLS" from "Video streaming, HLS ...".

- [ ] **Step 3: `CLAUDE.md`.** Locate each place by its quoted text:
  - **"4b."**: "Normalize and the HLS job come after" becomes "Normalize comes after". The clause "it used to be filed only once its HLS package existed, so that the move and the badge coincided, and that kept a new video out of its group for the whole conversion" becomes "it used to be filed only once the whole conversion had finished, which kept a new video out of its group".
  - **"### ffmpeg runs in exactly one process":**
    - "a cold `master.m3u8`, an SD rendition, and upload normalization all call" becomes "an SD rendition and upload normalization call".
    - Replace the "`priority=100` is the HLS package a finished download queues for itself" sentence with "`sd` renditions run at priority 200, behind interactive work."
    - Replace the two example log lines with `[job] +1 kind=sd id=812 priority=200 queued=3` and `[job] -1 kind=sd id=812 status=done secs=41`.
    - "`ffmpeg_progress.run_ffmpeg` is the only place `hls` jobs spawn ffmpeg" becomes "`ffmpeg_progress.run_ffmpeg` is how `sd` jobs spawn ffmpeg".
    - Delete the paragraph beginning "`GET /api/jobs` exposes running jobs".
  - **AirPlay bullet:** "MP4, not HLS: Caddy serves the packaged playlists as-is and their relative segment URIs don't carry the token." becomes "It is the MP4 `stream` URL, the only source there is."
  - **"Downloads can be paused" bullet:** "The segmented path (HLS segments)" becomes "The segmented path (parallel ranged mp4 transfers)". Delete the last sentence, "HLS packages have no partial state on disk, so pausing one restarts it from zero on resume."
  - **"### Posters and subtitles":** rename it "### Posters". Delete the four subtitle bullets ("Subtitles come from two places", "**Exactly one track ships per language**", "**Hidden files are never subtitles**", "**Filename tokens are NFC-folded"). Add: "Downloads carry no subtitles: `_normalize_media_for_ios` drops them (`-sn`). HLS packaging, the only path that ever delivered subtitles, was removed on 2026-11-21 (`docs/superpowers/plans/2026-11-21-remove-hls.md`)."
  - **"**Storage layout**" bullet:** `paths.py` holds `VIDEOS_DIR`, derived from `MEDIA_ROOT`. Drop `HLS_DIR` and "and HLS packages".
  - The iOS bullets that describe `PlaybackSource` and offline HLS wait for Task B6.

- [ ] **Step 4: `README.md`.** Delete or reword every HLS mention, finding them with `grep -n -i hls README.md`. Describe playback as "MP4 over HTTP Range, served by Caddy straight from disk".

- [ ] **Step 5: verify and commit.** `git grep -n -i hls -- serve .env.example README.md` prints nothing. Then:

```bash
git add .env.example serve CLAUDE.md README.md
git commit -m "docs: PatataTube no longer packages HLS"
```

### Task A6: Ship Part A on the macmini and free the space

PatataTube is a production service (`~/c/server/Caddyfile`, `:3050`). **Ask the owner before Step 3**: it restarts the production server. This repo is **not** covered by git-sync, so deliver the commits by hand (Step 2). If the work ran in a worktree, merge it into `main` first; deploys and deliveries are from `main`.

- [ ] **Step 1: the full suite is green on `main`** (Task A4 Step 5's command).

- [ ] **Step 2: deliver `main` to the macmini.** Push into a temporary branch, then fast-forward its checked-out `main`:

```bash
git push grillermo@192.168.1.1:c/patatatube main:refs/heads/hls-removal && command ssh macmini 'cd ~/c/patatatube && git status --short | wc -l && git merge --ff-only hls-removal && git branch -d hls-removal && git log --oneline -1'
```

  Expected: `0` (a clean tree), then the commit from Task A5.

- [ ] **Step 3: back up the database, then restart.** The restart must run in a login shell, or it gets macOS's Ruby 2.6 and the wrong PATH. The backup:

```bash
command ssh macmini 'cd ~/c/patatatube && ./python_env/bin/python -I -c "
import sqlite3; s = sqlite3.connect(\"data/watch_later.sqlite\"); d = sqlite3.connect(\"data/watch_later.pre-hls-removal.sqlite\"); s.backup(d); d.close()"'
```

  Then the restart:

```bash
command ssh macmini 'zsh -lic "cd ~/c/patatatube && ./serve" 2>&1 | tail -8'
```

  Expected: `==> Serving. Session 'patatatube-server': caddy, convert, web on 3051.`

- [ ] **Step 4: verify.**

```bash
command ssh macmini 'cd ~/c/patatatube && tail -n 40 log/backend.log | grep -i -E "error|traceback" ; ./python_env/bin/python -I -c "
import sqlite3; c = sqlite3.connect(\"data/watch_later.sqlite\")
print(\"hls_status\" in {r[1] for r in c.execute(\"pragma table_info(videos)\")})
print(c.execute(\"select count(*) from jobs where kind=\x27hls\x27\").fetchone()[0])
print(c.execute(\"select count(*) from videos\").fetchone()[0])"'
```

  Expected: no error lines, then `False`, `0`, and the video count (239 on 2026-11-21). On 2026-11-21, `/api/videos` answered from the LAN without a token:

```bash
curl -s http://192.168.1.1:3050/api/videos | grep -c hls_path
```

  Expected: `0`.

- [ ] **Step 5: the owner checks the installed 2.8.0 app.** A video plays, from the network and from a downloaded mp4. AirPlay works.

- [ ] **Step 6: delete the HLS packages.** Plain SSH cannot open `/Volumes/Media` (macOS privacy permissions). A detached session on the macmini's tmux server can, because the server was started from a GUI terminal:

```bash
command ssh macmini 'df -h /Volumes/Media | tail -1; /opt/homebrew/bin/tmux new-session -d -s hlsrm "rm -rf /Volumes/Media/patatatube/data/hls && echo done > /tmp/hlsrm.out"; for i in $(seq 1 150); do [ -f /tmp/hlsrm.out ] && break; sleep 2; done; cat /tmp/hlsrm.out; rm -f /tmp/hlsrm.out; df -h /Volumes/Media | tail -1'
```

  Expected: `done`, and about 36 GB more free space.

- [ ] **Step 7: Caddy.** `~/c/server` is git-synced, and the macmini's `/opt/homebrew/etc/Caddyfile` links to it. Edit `~/c/server/Caddyfile` on this machine:
  - Delete handler 2 entirely: from the comment `# 2. HLS assets: token check in-process, ...` through the closing `}` of `handle @hls { ... }`.
  - Change the block's header comment (lines ~140–147) to:

```
# patatatube — Caddy owns client-facing :3050, app runs on :3051.
# Static assets and downloaded MP4s come straight off disk; the API and the
# SSR page proxy to FastAPI.
#
# The token check for disk-served files happens *here*, not via forward_auth:
# a round trip to FastAPI /check-auth per range request turned an iOS
# "Download all" into thousands of Python requests. UPLOAD_TOKEN reaches
# Caddy via `caddy run --envfile /Users/grillermo/c/patatatube/.env` (see
# homebrew.mxcl.caddy.plist).
```

  - Renumber `# 3. Downloaded/uploaded videos` to `# 2.`, and each later numbered handler comment down by one.

  Validate on the macmini without the env file; a local hook blocks commands that mention it:

```bash
scp -q ~/c/server/Caddyfile macmini:/tmp/Caddyfile.check && command ssh macmini '/opt/homebrew/opt/caddy/bin/caddy validate --adapter caddyfile --config /tmp/Caddyfile.check 2>&1 | tail -1; rm -f /tmp/Caddyfile.check'
```

  Expected: `Valid configuration`. Commit in `~/c/server`:

```bash
git -C ~/c/server add Caddyfile && git -C ~/c/server commit -m "Caddy: patatatube no longer serves HLS packages"
```

  When `command ssh macmini 'git -C ~/c/server log --oneline -1'` shows the commit (git-sync carried it), **ask the owner**, then reload:

```bash
command ssh macmini 'cd ~/c/server && zsh -lic ./reload 2>&1 | tail -3'
```

  Re-run Step 4's `curl`, and play a video from the web page.

- [ ] **Step 8: after a week with no problems,** delete the backup:

```bash
command ssh macmini 'rm ~/c/patatatube/data/watch_later.pre-hls-removal.sqlite'
```

---

# Part B — iOS 2.9.0 (no HLS anywhere)

After every Kit task, `swift build && swift build --build-tests` in `ios/PatataTubeKit` must succeed. The app target builds again only at the end of Task B5, because Tasks B1–B4 remove Kit APIs the app still calls.

### Task B1: Kit — no `hlsPath`, no jobs API

**Files:**
- Delete: `PatataTubeKit/Sources/PatataTubeKit/JobsStore.swift`, `PatataTubeKit/Sources/PatataTubeKit/ConversionJob.swift`, and from `PatataTubeKit/Tests/PatataTubeKitTests/`: `JobsStoreTests.swift` and `APIClientJobsTests.swift`
- Modify: `PatataTubeKit/Sources/PatataTubeKit/Video.swift`, `PatataTubeKit/Sources/PatataTubeKit/APIClient.swift`
- Test: `PatataTubeKit/Tests/PatataTubeKitTests/APIClientReadTests.swift`, `VideoHashableTests.swift`

- [ ] **Step 1: write the test.** In `APIClientReadTests.swift`, `decodesHlsMetadata` and `decodesVideoWithoutHlsFields` become one test. Keep `decodesHlsMetadata`'s body, including its transport stub and its JSON with `"hls_path"`, and rename it. Replace its last `#expect` (`videos[0].hlsPath == …`) with:

```swift
            // A 2.8-era server still sends hls_path; decoding ignores it.
            #expect(videos.count == 1)
            #expect(videos[0].streamPath == "/videos/1/stream")
```

  Rename the test to `ignoresALegacyHlsPathField`, and make its JSON include `"stream_path":"/videos/1/stream"` if it doesn't already. Then delete `decodesVideoWithoutHlsFields`, and delete the `hlsPath:` argument in `VideoHashableTests.swift`.

- [ ] **Step 2: implement.**
  - `Video.swift`: delete the `hlsPath` property, its `CodingKeys` case, its `init` parameter and assignment, its `decodeIfPresent` line, and its use in the copy at line ~92. `Decodable` ignores unknown keys, so old payloads still decode.
  - `APIClient.swift`: delete `func jobs() async throws -> JobsSnapshot` from the protocol and the `public func jobs()` implementation (line ~223). If a `JobsAPI` protocol is declared in the Kit (`grep -rn "protocol JobsAPI" ios/PatataTubeKit/Sources`), delete it too.
  - Delete the Kit files:

```bash
git rm ios/PatataTubeKit/Sources/PatataTubeKit/JobsStore.swift ios/PatataTubeKit/Sources/PatataTubeKit/ConversionJob.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/JobsStoreTests.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/APIClientJobsTests.swift
```

- [ ] **Step 3: build.**

```bash
cd ios/PatataTubeKit && swift build && swift build --build-tests
```

  Expected: both succeed. `grep -rn -E 'hlsPath|JobsStore|ConversionJob|JobsSnapshot' ios/PatataTubeKit` prints nothing.

- [ ] **Step 4: commit.**

```bash
git add -A ios/PatataTubeKit
git commit -m "ios(kit): drop hlsPath and the jobs API"
```

### Task B2: Kit — the proxy serves mp4 only, and downloads are mp4 only

These two changes land together: `StreamProxy.stagedHLSAsset` calls `CacheManager.hlsStagingDir` from `CacheManager+HLS.swift`, and `CacheManager+HLS.swift` reads `SegmentCache`, so neither side compiles without the other.

**Files:**
- Delete:
  - Kit sources: `SegmentCache.swift`, `CacheManager+HLS.swift` and `HLSManifestParser.swift` in `PatataTubeKit/Sources/PatataTubeKit/`.
  - Kit tests: `CacheManagerHLSTests.swift` and `HLSManifestParserTests.swift` in `PatataTubeKit/Tests/PatataTubeKitTests/`.
- Modify: `StreamProxy.swift`, `StreamCache.swift`, `CacheStatistics.swift`, `CacheManager.swift`, `PausedDownloadStore.swift`
- Test: `StreamProxyTests.swift`, `StreamCacheTests.swift`, `CacheStatisticsCollectorTests.swift`, `CacheManagerPauseTests.swift`, `PausedDownloadStoreTests.swift`, `CacheManagerByteCounterTests.swift`

- [ ] **Step 1: write the failing test.** Add to `PausedDownloadStoreTests.swift`, next to `entriesSurviveANewStoreOnTheSameRoot`:

```swift
    @Test func dropsEntriesThatPausedAnHLSDownload() throws {
        let root = temporaryRoot()
        var store = PausedDownloadStore(root: root)
        store.insert(sample(videoID: 8, versionID: nil))
        // Rewrite the file as 2.8 left it: a second entry paused on a playlist.
        let file = root.appendingPathComponent("paused-downloads.json")
        var raw = try JSONSerialization.jsonObject(
            with: Data(contentsOf: file)) as! [[String: Any]]
        var hls = raw[0]
        hls["videoID"] = 7
        hls["remoteURL"] = "https://h/videos/7/hls/master.m3u8"
        hls["isHLS"] = true
        raw.append(hls)
        try JSONSerialization.data(withJSONObject: raw).write(to: file)

        let reopened = PausedDownloadStore(root: root)

        #expect(reopened.entries.map(\.videoID) == [8])
        #expect(PausedDownloadStore.droppedHLSVideoIDs(root: root) == [7])
    }
```

  `sample(videoID:versionID:)` and `temporaryRoot()` are the file's existing helpers. If `PausedDownload`'s encoded key for the id isn't `videoID`, use the key `raw[0]` actually has (print it once while writing the test).

- [ ] **Step 2: see the build fail.** `swift build --build-tests` fails: `droppedHLSVideoIDs` is undefined.

- [ ] **Step 3: delete the HLS files.**

```bash
git rm ios/PatataTubeKit/Sources/PatataTubeKit/SegmentCache.swift ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager+HLS.swift ios/PatataTubeKit/Sources/PatataTubeKit/HLSManifestParser.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerHLSTests.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/HLSManifestParserTests.swift
```

- [ ] **Step 4: `StreamProxy.swift`.**
  - In `start()`, delete the `GET /\(secret)/hls/:id/:v/*` and `GET /\(secret)/offline/:id/:v/*` routes.
  - Delete `hlsURL(videoId:versionId:)` and `offlineHLSURL(videoId:versionId:)`.
  - Delete the whole `// MARK: - HLS` section: `handleHLS`, `servePlaylist`, `storePlaylist`, `storeHLSAssetWithRecovery`, `serveHLSAsset` and `stagedHLSAsset`. Also delete the whole `// MARK: - Offline` section (`handleOffline`).
  - Delete the stored properties `currentHash`, `pendingPlaylists` and `singleFlight`, plus the `PlaylistScope` struct. Keep `probeSingleFlight` and the `SingleFlight` actor.
  - Delete `params(of:)`; only the removed routes used it. Drop the `asset` field from `RouteParams` and the `asset: ""` argument in `mp4Params(of:)`.
  - `contentType(for:)`: if `grep -n 'contentType(for' StreamProxy.swift` finds no caller left, delete it. Otherwise delete its `m3u8`, `vtt` and `m4s` cases.
  - `offlineRoot`: if `grep -n offlineRoot StreamProxy.swift` shows only its declaration, `init` parameter and assignment, delete all three. Its construction site in `AppModel.swift` is fixed in Task B5.

- [ ] **Step 5: `StreamCache.swift`.**
  - Delete `let segments: SegmentCache`, the `hlsRoot` constant, its `createDirectory`, and `self.segments = SegmentCache(root: hlsRoot)`.
  - The LRU becomes `StreamCacheLRU(managedDirs: [mp4Root], budgetBytes: budgetBytes)`.
  - In `removeVideo(id:)`, delete `await segments.removeAll(videoId: id)`.
  - The type's doc comment becomes "Owner of the temporary stream cache: MP4 range store + LRU budget. One instance is shared by the playback proxy (read-through writes) and the download manager (seeding)."

- [ ] **Step 6: `CacheStatistics.swift`.**
  - Delete `case hls`, the `name.hasPrefix("hls-")` mapping, the `hls` accumulator and its `case .hls:` branch, the `proxyHLS` scan, and the `proxy.hls` and `videos.hls` rows.
  - The combined proxy row uses `proxyMP4.byteCount` / `proxyMP4.itemCount` alone.

- [ ] **Step 7: `PausedDownloadStore.swift`.**
  - Delete `isHLS` from `PausedDownload` (the property, the `init` parameter, the assignment and its doc comment).
  - Replace the store's `init` and add the dropped-id helpers:

```swift
    init(root: URL, fileManager: FileManager = .default) {
        self.url = root.appendingPathComponent("paused-downloads.json")
        self.fileManager = fileManager
        let decoded = (try? Data(contentsOf: url)).flatMap {
            try? JSONDecoder().decode([PausedDownload].self, from: $0)
        } ?? []
        // A 2.8-era pause of an HLS download stored its master playlist URL.
        // There is no HLS path any more: drop those entries and record their
        // ids, which CacheManager.removeLegacyHLSPackages re-downloads.
        let isHLS: (PausedDownload) -> Bool = { $0.remoteURL.pathExtension == "m3u8" }
        self.entries = decoded.filter { !isHLS($0) }
        let dropped = decoded.filter(isHLS).map(\.videoID)
        if !dropped.isEmpty {
            Self.recordDroppedHLS(dropped, root: root)
            persist()
        }
    }

    private static func droppedURL(root: URL) -> URL {
        root.appendingPathComponent("paused-hls-dropped.json")
    }

    private static func recordDroppedHLS(_ ids: [Int], root: URL) {
        let merged = Set(droppedHLSVideoIDs(root: root)).union(ids)
        guard let data = try? JSONEncoder().encode(merged.sorted()) else { return }
        try? data.write(to: droppedURL(root: root), options: .atomic)
    }

    /// Video ids whose paused HLS download was dropped at load, ascending.
    static func droppedHLSVideoIDs(root: URL) -> [Int] {
        (try? Data(contentsOf: droppedURL(root: root)))
            .flatMap { try? JSONDecoder().decode([Int].self, from: $0) } ?? []
    }

    static func clearDroppedHLS(root: URL) {
        try? FileManager.default.removeItem(at: droppedURL(root: root))
    }
```

  `persist()` is called from `init` after all stored properties are set, which a struct allows. `JSONDecoder` ignores the stale `isHLS` key.

- [ ] **Step 8: `CacheManager.swift`: remove HLS and external activity.** Locate everything by symbol:
  - **Stored properties:** delete `hlsRetrySleep`, `maxHLSPackagingPolls`, `beforeExternalPromotion`, `externalActivityKeys`, `externalCancellationRequests`, `externalTasks` and `externalProgressCallCount`.
  - **The internal `init(...)`:** delete its last parameter (`beforeExternalPromotion: @escaping @Sendable () async -> Void = {}`) and `self.beforeExternalPromotion = beforeExternalPromotion`. Find tests that pass `beforeExternalPromotion:` with `grep -rn beforeExternalPromotion ios/PatataTubeKit/Tests`. Delete the argument; if the test was about external promotion, delete the test.
  - **Methods:** delete `offlineHLSDir(for:versionId:)`, `offlineHLSMasterURL(for:versionId:)`, `streamSegmentCache`, `waitBeforeExternalPromotion()`, `beginExternalActivity`, `updateExternalActivity`, `endExternalActivity`, `registerExternalTask`, `cancelExternalActivity`, `throwIfExternalActivityCancelled`, `promoteExternalActivity`, `pauseExternal(key:)` and `offlineHLSDirectoryNames(id:)`.
  - **Registration guards:** delete every `!externalActivityKeys.contains(key)` line, and the `(manifest.cacheKey)` variant. There are five: two in `resumeInterrupted`, one in the fresh-probe path, one in the segmented resume and one in `downloadLegacy`. In `resumeInterrupted`'s `||` chain, delete `|| externalActivityKeys.contains(key)`.
  - **`state(for:versionId:)`:** delete the `offlineHLSMasterURL` line.
  - **`activeDownloads()`:** `landed` becomes the mp4 check alone, with the comment "A finished mp4 means the pause raced a completion":

```swift
            let landed = fileManager.fileExists(
                atPath: localURL(for: entry.videoID, versionId: entry.versionID).path
            )
```

  - **`downloadedByteCount()`:** delete the `meta["ext_progress_calls"]` line.
  - **`resume(id:versionId:bearerToken:)`:** delete the `"hls"` DevLog key. Replace the `if entry.isHLS { ... } else { ... }` with only the `performDownload(...)` call it contains. In the `defer` comment, "The HLS path has no segments to consume the flag, and a segmented transfer…" becomes "A segmented transfer that never reached `startIncompleteSegments` leaves it set; it must not outlive this resume."
  - **`pause(...)`:** delete the `isHLS: Bool,` parameter, the `isHLS: isHLS,` argument to `PausedDownload`, the `"hls"` DevLog key and the `pauseExternal(key: key)` call. In the doc comment, "because the HLS path leaves nothing on disk to recover them from and a resume may happen in a later process" becomes "because a resume may happen in a later process".
  - **`cancel(id:versionId:)`:** delete `try? fileManager.removeItem(at: offlineHLSDir(for: id, versionId: versionId))` and `cancelExternalActivity(key: key)`.
  - **The function at line ~1195** (it removes `localURL(for:versionId:)`): delete its `offlineHLSDir` removal.
  - **`hasAnyCached(id:)`:** its body becomes `!cachedVideoFilenames(id: id).isEmpty`, with the doc comment "True when any cached MP4 exists for this video."
  - **`removeAllCached(id:)`:** drop `+ offlineHLSDirectoryNames(id: id)` and "HLS package," from its doc comment.
  - **`clearAllVideos()`:** keep `|| name.hasPrefix("hls-")`, which still clears 2.8-era folders. Its doc comment's "MP4s + HLS packages" becomes "MP4s (and any 2.8-era `hls-*` folders)".
  - **`defaultConfiguration()`'s doc comment:** "so the HLS retry loop doesn't spin while offline" becomes "so a retry doesn't spin while offline".

- [ ] **Step 9: fix the tests.**
  - `StreamProxyTests.swift`: delete these tests:
    - `testHLSSegmentReadThroughCachesAndServesFromDiskSecondTime`
    - `testHLSStorageFailureEvictsAndRetriesBeforePassingThrough`
    - `testHLSSegmentServedFromDownloadStagingWithoutUpstreamFetch`
    - `testHLSStagingFromAnotherPackageIsIgnored`
    - `testHLSCachedAssetsAreScopedByVersionWhenPlaylistBytesMatch`
    - `testInitialMasterIsCachedAfterMediaPlaylistEstablishesHash`

    In `testWrongSecretIs404`, `testServerExitClearsPortSoURLsGoNil` and `testEnsureRunningRestartsAfterListenerDies`, replace `hlsURL(videoId:versionId:)` and `offlineHLSURL(videoId:versionId:)` with `mp4URL(videoId:versionId:)`. A secret-less path built from `hls/...` becomes `mp4/<id>/0`.
  - `StreamCacheTests.swift`: it asserted that `removeVideo` deletes `hls/3/...`. Change it to seed `root/mp4/3/x` (write any file there), call `await cache.removeVideo(id: 3)`, and expect `root/mp4/3` to be gone.
  - `CacheStatisticsCollectorTests.swift`: delete the `hls-2/master.m3u8` and `hls/10/seg.m4s` fixtures and the four `proxy.hls` / `videos.hls` assertions. The combined row's expectation is `stat(stats, "proxy.mp4")` alone.
  - `CacheManagerPauseTests.swift` and `PausedDownloadStoreTests.swift`: delete every `isHLS: false,` argument (11 occurrences).
  - `CacheManagerByteCounterTests.swift`: delete `unitProgressDoesNotStandInForTransferredBytes` and its comment; it exercised only `beginExternalActivity`.

- [ ] **Step 10: build.**

```bash
cd ios/PatataTubeKit && swift build && swift build --build-tests
```

  Expected: both succeed. `grep -rn -i -E 'hls|externalActivity|SegmentCache' ios/PatataTubeKit/Sources` prints only `PausedDownloadStore`'s `m3u8` filter and dropped-id helpers, plus `clearAllVideos`'s `hls-` prefix.

- [ ] **Step 11: commit.**

```bash
git add -A ios/PatataTubeKit
git commit -m "ios(kit): the proxy and downloads are mp4 only

Drops the proxy's hls/offline routes, the segment cache, downloadHLS,
offline HLS packages and the external-activity machinery only the HLS
packager used. A paused HLS download from 2.8 is dropped at load and
recorded for re-download."
```

### Task B3: Kit — remove legacy HLS packages and report what to re-download

**Files:**
- Modify: `PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift`
- Create: `PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerLegacyHLSTests.swift`

- [ ] **Step 1: write the failing tests.**

```swift
import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Legacy HLS cleanup")
struct CacheManagerLegacyHLSTests {
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-hls-\(UUID().uuidString)")
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    @Test func removesPackagesAndStagingAndReportsTheirIDs() throws {
        let root = temporaryRoot()
        try touch(root.appendingPathComponent("hls-7/master.m3u8"))
        try touch(root.appendingPathComponent("hls-9_v2/master.m3u8"))
        try touch(root.appendingPathComponent(".hls-tmp/12/video.m3u8"))
        try touch(root.appendingPathComponent("5.mp4"))
        let manager = CacheManager(root: root)

        let ids = manager.removeLegacyHLSPackages()

        #expect(ids == [7, 9, 12])
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!left.contains { $0.hasPrefix("hls-") || $0 == ".hls-tmp" })
        #expect(left.contains("5.mp4"))
    }

    @Test func skipsVideosAlreadyOnDiskAsMP4() throws {
        let root = temporaryRoot()
        try touch(root.appendingPathComponent("hls-5/master.m3u8"))
        try touch(root.appendingPathComponent("5.mp4"))
        let manager = CacheManager(root: root)

        #expect(manager.removeLegacyHLSPackages() == [])
    }

    @Test func includesDroppedPausedHLSDownloadsOnce() throws {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode([3]).write(
            to: root.appendingPathComponent("paused-hls-dropped.json"))
        let manager = CacheManager(root: root)

        #expect(manager.removeLegacyHLSPackages() == [3])
        #expect(manager.removeLegacyHLSPackages() == [])
    }
}
```

- [ ] **Step 2: see the build fail.** `swift build --build-tests` fails: `removeLegacyHLSPackages` is undefined.

- [ ] **Step 3: implement.** Add to `CacheManager.swift`, next to `clearAllVideos()`:

```swift
    /// One-time cleanup of the HLS era (<= 2.8): deletes every offline HLS
    /// package (`hls-<id>` / `hls-<id>_v<v>`) and the `.hls-tmp` staging dir,
    /// and returns the ids to download again as mp4 — those packages plus the
    /// paused HLS downloads `PausedDownloadStore` dropped at load. Ids whose
    /// mp4 is already on disk are left out. Idempotent: a second call finds
    /// nothing and returns `[]`.
    public func removeLegacyHLSPackages() -> [Int] {
        let contents = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        var ids = Set(PausedDownloadStore.droppedHLSVideoIDs(root: root))
        for name in contents where name.hasPrefix("hls-") {
            let digits = name.dropFirst("hls-".count).prefix { $0.isNumber }
            if let id = Int(digits) { ids.insert(id) }
            try? fileManager.removeItem(at: root.appendingPathComponent(name))
        }
        let staging = root.appendingPathComponent(".hls-tmp", isDirectory: true)
        if let staged = try? fileManager.contentsOfDirectory(atPath: staging.path) {
            for key in staged { ids.insert(videoId(from: key)) }
        }
        try? fileManager.removeItem(at: staging)
        PausedDownloadStore.clearDroppedHLS(root: root)
        let pending = ids.filter { !hasAnyCached(id: $0) }.sorted()
        if !pending.isEmpty {
            DevLog.event(.cache, "legacy HLS removed", [
                "ids": pending.map(String.init).joined(separator: ","),
            ])
        }
        return pending
    }
```

  `videoId(from:)` already parses a cache key (`"12"` or `"12:2"`); confirm with `grep -n 'func videoId(from' CacheManager.swift`. If it's `private` in another type, add an equivalent one-liner here: `Int(key.split(separator: ":").first ?? "") ?? 0`.

- [ ] **Step 4: build** with `swift build && swift build --build-tests`. With the owner's OK, run the suite:

```bash
cd ios/PatataTubeKit && swift test --filter CacheManagerLegacyHLSTests
```

- [ ] **Step 5: commit.**

```bash
git add ios/PatataTubeKit
git commit -m "ios(kit): removeLegacyHLSPackages for the 2.8 -> 2.9 upgrade"
```

### Task B4: App — mp4-only playback and downloads

**Files:**
- Modify: `PatataTube/Sources/PlaybackSource.swift`, `PatataTube/Sources/AppModel.swift`, `PatataTube/Sources/VideoGridView.swift`, `PatataTube/Sources/VideoCell.swift`, `PatataTube/Sources/VideoPlayerView.swift`
- Delete: `PatataTube/Sources/SpikeDownloadProbe.swift`

- [ ] **Step 1: `PlaybackSource.swift`.**
  - In `chose(...)`, delete the `"has_hls"` meta key. The `"proxy_port"` comment becomes "Proxy down (port nil) kills the proxied MP4 route, so a non-cached video falls to `direct_mp4`."
  - After the `airplay_mp4` branch, replace everything from `if cacheState == .cached {` (the offline-HLS block) through the `direct_mp4` branch with:

```swift
        if let proxied = model.proxiedMP4URL(for: video), model.streamURL(for: video) != nil {
            // Proxied MP4: read-through cache, no headers needed.
            return chose("proxy_mp4", AVPlayerItem(url: proxied))
        }
        if let url = model.streamURL(for: video) {
            // Proxy down: direct MP4 with authed headers.
            return chose("direct_mp4", AVPlayerItem(asset: authedAsset(url: url, model: model)), ["proxy": "down"])
        }
```

  - Keep the `if log { … "source -> none" … }` and `return nil` after it.
  - The doc comment's "five source branches" becomes "four source branches (`local_mp4`, `airplay_mp4`, `proxy_mp4`, `direct_mp4`)".
  - `authedAsset`'s doc comment becomes "One asset carrying the bearer header, so AVFoundation authenticates every range request on the same asset."

- [ ] **Step 2: `AppModel.swift`.**
  - Delete `hlsURL(for:)`, `proxiedHLSURL(for:)` and `offlineHLSURL(for:)`.
  - In `airPlayStreamURL`'s doc comment, delete the sentence "MP4 rather than HLS because Caddy serves the packaged playlists as-is, and their relative segment URIs don't carry the token."
  - If Task B2 removed `StreamProxy`'s `offlineRoot` parameter, delete that argument where `AppModel.init` constructs the proxy.

- [ ] **Step 3: `VideoGridView.swift`.** In `download(_:)`, replace everything from `let master = model.hlsURL(for: target)` through the end of the `if`/`else` inside `do` with:

```swift
        DevLog.event(.download, "download branch", [
            "video_id": "\(target.id)",
            "branch": "mp4",
            "status": target.status,
            "state": DevLog.describe(model.cache.state(for: target.id, versionId: target.chosenVersionId)),
        ])
        do {
            try await model.cache.download(id: target.id, versionId: target.chosenVersionId, from: url, preview: preview,
                                           bearerToken: model.credentials.token,
                                           streamCount: model.downloadStreamCount)
            return true
```

  Keep the following `catch` unchanged. Also delete the comment block above `DevLog.event` that explains "The ring reads `cache.state`…", since there's no branch left to tie.

  Then replace the body of `pauseParameters(for:versionID:)` and its return type:

```swift
    /// The parameters a paused entry has to remember, resolved from the loaded
    /// video: its stream URL, the stream count and the poster.
    private func pauseParameters(
        for videoID: Int, versionID: Int?
    ) -> (remote: URL, streamCount: Int, preview: URL?)? {
        guard let target = Self.downloadVideo(
            id: videoID, versionID: versionID, videos: store.videos
        ) else { return nil }
        guard let remote = model.streamURL(for: target) else { return nil }
        return (
            remote: remote,
            streamCount: model.downloadStreamCount,
            preview: resolveImageURL(target.previewUrl)
        )
    }
```

  In the `onPause` closure, delete `isHLS: parameters.isHLS,`.

- [ ] **Step 4: the rest.**
  - `VideoCell.swift`: delete `row("HLS path", video.hlsPath)`.
  - `VideoPlayerView.swift` line ~385: reword the comment that names `offlineHLSURL` so it names the proxied mp4 URL instead.
  - Delete `SpikeDownloadProbe.swift` (`git rm ios/PatataTube/Sources/SpikeDownloadProbe.swift`). `grep -rn SpikeDownloadProbe ios/PatataTube` must print nothing; if `project.yml` lists the file explicitly, remove it there.

- [ ] **Step 5: commit** (the app may not build until Task B5 removes `JobsStore` uses):

```bash
git add -A ios/PatataTube
git commit -m "ios: play and download mp4 only"
```

### Task B5: App — no Converting UI, and the 2.8 → 2.9 re-download

**Files:**
- Modify: `PatataTube/Sources/VideoGridView.swift`, `PatataTube/Sources/DownloadsView.swift`, `PatataTube/Sources/DownloadButton.swift`, `PatataTube/Sources/AppModel.swift`, `PatataTube/Sources/PatataTubeApp.swift`
- Test: `PatataTube/Tests/DownloadButtonTests.swift`, `PatataTube/Tests/DownloadsViewTests.swift`

- [ ] **Step 1: remove the jobs UI.**
  - `VideoGridView.swift`: delete `@State private var jobsStore: JobsStore`, `_jobsStore = State(initialValue: JobsStore(api: api))`, `.environment(jobsStore)`, and the `.onAppear { jobsStore.subscribe() }` / `.onDisappear { jobsStore.unsubscribe() }` pair. If `api` becomes unused in that `init`, leave the parameter; callers still pass it.
  - `DownloadsView.swift`:
    - Delete `@Environment(JobsStore.self) private var jobsStore: JobsStore?`, `let snapshot = jobsStore?.snapshot ?? .empty`, `let converting = snapshot.running + snapshot.queued`, and the whole `if !converting.isEmpty { Section("Converting") { … } }` block.
    - Delete `jobsStore?.subscribe()` from `.onAppear`, and the `.onDisappear { jobsStore?.unsubscribe() }` modifier.
    - Delete `convertingRow(_:)`.
  - `DownloadButton.swift`: delete `@Environment(JobsStore.self) private var jobsStore: JobsStore?` and the `private struct ConversionRing` at line ~300. Then make `control`:

```swift
    @ViewBuilder
    private var control: some View {
        cacheControl
    }
```

- [ ] **Step 2: the re-download.** Add to `AppModel.swift`:

```swift
    private static let legacyHLSPendingKey = "legacyHLSRedownloads"
    private var legacyHLSMigrationRunning = false

    /// 2.8 -> 2.9: offline HLS packages and paused HLS downloads are gone;
    /// download those videos again as mp4. Runs on every activation until the
    /// pending list is empty. A video the server no longer has (404) leaves
    /// the list rather than being retried forever; a pause or cancellation
    /// keeps it for the next activation.
    func migrateLegacyHLSDownloads() {
        let defaults = UserDefaults.standard
        var pending = Set(defaults.array(forKey: Self.legacyHLSPendingKey) as? [Int] ?? [])
        pending.formUnion(cache.removeLegacyHLSPackages())
        defaults.set(pending.sorted(), forKey: Self.legacyHLSPendingKey)
        guard !pending.isEmpty, !legacyHLSMigrationRunning,
              let base = credentials.baseURL else { return }
        legacyHLSMigrationRunning = true
        let token = credentials.token
        let streams = downloadStreamCount
        let cache = self.cache
        Task { @MainActor in
            await withBoundedTaskGroup(limit: cache.maxConcurrentDownloads, over: pending.sorted()) { id in
                let url = base.appendingPathComponent("videos/\(id)/stream")
                do {
                    try await cache.download(id: id, from: url, bearerToken: token, streamCount: streams)
                } catch is CancellationError {
                    return
                } catch is DownloadPausedError {
                    return
                } catch {
                    DevLog.error(error, "legacy HLS re-download failed", ["video_id": "\(id)"])
                }
                var left = Set(UserDefaults.standard.array(forKey: Self.legacyHLSPendingKey) as? [Int] ?? [])
                left.remove(id)
                UserDefaults.standard.set(left.sorted(), forKey: Self.legacyHLSPendingKey)
            }
            self.legacyHLSMigrationRunning = false
        }
    }
```

  `DownloadPausedError` is declared in the Kit. If it isn't `public`, make it `public` (one keyword in `CacheManager.swift`). If `AppModel` isn't `@MainActor`-isolated, annotate this method `@MainActor`.

- [ ] **Step 3: call it.** In `PatataTubeApp.swift`'s `.onChange(of: scenePhase)` `.active` branch, right after `model.cache.resumeInterrupted(bearerToken: model.credentials.token)`, add:

```swift
                        model.migrateLegacyHLSDownloads()
```

- [ ] **Step 4: the app tests.**
  - `DownloadButtonTests.swift`: delete `StubJobsAPI`, `hostedDownloadButtonWithJobsStore` and the two tests that build a `JobsStore` (lines ~408–420).
  - `DownloadsViewTests.swift`: delete `StubJobsAPI`, the `JobsStore` host helper, `listsConvertingJobsWithTheirPercent`, and the other tests that build a `JobsStore` (around lines 228 and 241). If a remaining test used the host helper only to supply a `JobsStore`, host the view without it, the way other tests in the file inspect it.

- [ ] **Step 5: build the app and its tests.** Use the "App build" command under Running things, then restore `Package.resolved`:

```bash
git checkout ios/PatataTubeKit/Package.resolved
```

  Expected: `** TEST BUILD SUCCEEDED **`. `grep -rn -i -E 'JobsStore|ConversionJob|hlsURL|offlineHLS|isHLS' ios/PatataTube` prints nothing.

- [ ] **Step 6: commit.**

```bash
git add -A ios/PatataTube ios/PatataTubeKit
git commit -m "ios: drop the Converting UI; re-download 2.8 HLS packages as mp4"
```

### Task B6: Ship 2.9.0

- [ ] **Step 1: ask the owner whether to run the iOS tests.** CLAUDE.md forbids starting them unasked. If yes, run all three:
  - `swift test` and `swift test -c release` in `ios/PatataTubeKit`.
  - The `PatataTubeTests` target: the "App build" command with `test` in place of `build-for-testing`.

- [ ] **Step 2: update `CLAUDE.md` for the app side.**
  - Wherever `PlaybackSource`'s branches are listed, list `local_mp4`, `airplay_mp4`, `proxy_mp4` and `direct_mp4`.
  - Remove any sentence left about offline HLS packages, the HLS segment cache or the Converting section.
  - Add a bullet under "### iOS": "**2.9.0 removed HLS.** On activation `AppModel.migrateLegacyHLSDownloads` deletes 2.8's offline HLS packages (`hls-<id>`, `.hls-tmp`) and paused HLS downloads, and re-downloads those videos as mp4. Pending ids live in `UserDefaults` (`legacyHLSRedownloads`) until each download finishes or fails for good."

  Commit:

```bash
git commit -am "docs: the iOS app plays mp4 only"
```

- [ ] **Step 3: merge into `main`** if the work ran on a branch, then deliver `main` to the macmini. Use Task A6 Step 2's command with branch name `hls-removal-ios`. These commits change only iOS and docs, so the server needs no restart.

- [ ] **Step 4: deploy from the macmini,** where the publish directory and upload settings live, in a login shell for rbenv's Ruby. CLAUDE.local.md is the standing go-ahead.

```bash
command ssh macmini 'zsh -lic "cd ~/c/patatatube && ./deploy minor --yes --summary \"Videos play and download as MP4; HLS is gone\" --note \"Videos you had saved download again as MP4 in the background\" --note \"No more Converting step\"" 2>&1 | tail -25'
```

  Expected: `✓ Published PatataTube 2.9.0`. Then bring the release commit back to this machine:

```bash
git pull --ff-only github main
```

  Send the install link:

```bash
~/c/agents-configs/bin/ntfy_machines.sh "PatataTube 2.9.0" "HLS removed. Tap to install." default "https://files.chiq.me/files/patatatube-install.html"
```

- [ ] **Step 5: the owner checks on the phone:**
  - A video streams, and seeking works.
  - The mini player and PiP work.
  - AirPlay works.
  - A video downloaded before the update shows "In Progress" in Downloads, then plays offline.
  - Pause and Resume a download.
  - There's no Converting section.

---

# Part C — after 2.9.0 is installed

### Task C1: Remove `/api/jobs`

**Files:**
- Modify: `router.py`, `tests/test_api.py`, `CLAUDE.md`

- [ ] **Step 1: write the failing test.** In `tests/test_api.py`, replace `test_jobs_endpoint_always_reports_nothing`, `test_jobs_is_empty_when_nothing_is_pending` and `test_jobs_requires_a_token` with:

```python
def test_jobs_endpoint_is_gone(client, auth_headers):
    assert client.get("/api/jobs", headers=auth_headers).status_code == 404
```

- [ ] **Step 2: see it fail.**

```bash
MEDIA_ROOT=. ./python_env/bin/python -m pytest tests/test_api.py -q -k jobs_endpoint_is_gone
```

  Expected: FAIL (200).

- [ ] **Step 3: implement.** Delete the `api_jobs` route from `router.py`.

- [ ] **Step 4: run the full suite** (the backend test command under Running things). Expected: all pass. `grep -n "api/jobs" CLAUDE.md router.py` prints nothing.

- [ ] **Step 5: commit, deliver and restart.** Commit:

```bash
git add router.py tests/test_api.py CLAUDE.md
git commit -m "Remove /api/jobs: 2.9.0 no longer polls it"
```

  Deliver as in Task A6 Step 2 with branch name `jobs-removal`. **Ask the owner**, restart as in Task A6 Step 3, and check `log/backend.log` for a clean start.

---

## Self-review notes

- **Spec coverage:**
  - Server: serializer A1, download hook A2, route/modules/converter/job kinds A3, DB A4, docs A5.
  - Production data and Caddy: A6.
  - iOS: model/API B1; proxy, cache, stats, downloads and pause B2; on-device cleanup B3; playback B4; UI and re-download B5.
  - Shipping: B6. The leftover endpoint: C1.
- **Ordering hazard:** Deleting `data/hls` before A1–A3 are live would make 2.8.0 request `master.m3u8` for every video, and the old server would queue a packaging job for each one. That's why A6 Step 6 comes after the restart. With Part A live, 2.8.0 gets no `hls_path` and never asks.
- **`/api/jobs` lifetime:** 2.8.0 polls it, so it answers empty from A3 until C1.
- **Build windows:** after B1–B3 the app target doesn't compile until B5. The Kit always does.
- **Line numbers** are from `b47a005` and drift as earlier steps delete code. Locate code by the quoted symbol.
