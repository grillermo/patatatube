# Caddy Serves Library Videos (symlink approach) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Caddy serve library-video byte ranges natively (sendfile) instead of routing them through Python's `_iter_file_range`, lifting streaming from ~24 MB/s to line rate.

**Architecture:** For every playable-mp4 library version, place a symlink `videos/{video_id}-v{version_id}.mp4` pointing at the real file on `/Volumes/Media`. The Caddy `@stream` block gains a `try_files` candidate using the `?version_id=` query placeholder, so a library stream URL resolves to the symlink and `file_server` serves it. Links are created at convert-completion, rebuilt on every `scan_library`, and removed on delete. No change to Python's streaming code.

**Tech Stack:** Python 3.13, FastAPI, SQLite (`db.py`), ffmpeg, Caddy (`~/c/server/Caddyfile`), pytest.

## Global Constraints

- Link naming: `videos/{video_id}-v{version_id}.mp4`. Download videos already own bare `videos/{id}.mp4`; managed library links are exactly the set matching glob `videos/*-v*.mp4` — this is the only class of symlink in `videos/` and is safe to bulk-remove/rebuild.
- **Symlinks, not hardlinks** — `videos/` is APFS, media is exFAT `/Volumes/Media` (different devices). Symlink targets MUST be absolute paths.
- Link only where the file the stream endpoint would serve is a playable `.mp4` AND the version status is `done`. That file is `converted_path or source_path` (per `router.py:429`): re-encoded versions have an mp4 `converted_path`; passthrough versions have `converted_path=None` and an mp4 `source_path` — both qualify. Unconverted `.mkv` sources do NOT (wrong container, unplayable on iOS) — skip them, they keep falling through to Python.
- Caddy `file_server` follows symlinks by default. A broken symlink (unmounted volume) fails `try_files` → falls through to the app → graceful 404, same as today.
- Cache-Control: download `videos/{id}.mp4` is content-addressed and never changes → `immutable`. Library links CAN change bytes at a stable path (audio-language re-conversion writes the same `converted_path` via `os.replace`) → must revalidate; use `public, max-age=3600, must-revalidate`, never `immutable`.
- iOS sends `?version_id={chosen_version_id}` for library rows and a bare URL for downloads (verified: `ios/PatataTube/Sources/AppModel.swift:76-80`, `views/serializers.py:70`). Only version-qualified URLs are covered by this plan; a library URL without `version_id` (e.g. the web SSR player, if any) simply falls through to Python unchanged — acceptable, out of scope.
- `VIDEOS_DIR = Path("videos")` (matches `router.py:30`, `downloader.py:15`).

---

## File Structure

- `db.py` — add one read helper, `streamable_library_versions()`, returning the rows the symlink layer needs. Keeps all SQL in the single SQLite layer.
- `library.py` — add the symlink lifecycle helpers and call them from `convert_library_video` and `scan_library`. Per the design doc this is the ~30-line home for link create/remove logic.
- `router.py` — one call added to the delete endpoint so links vanish immediately on delete instead of waiting for the next scan.
- `~/c/server/Caddyfile` — extend the `@stream` `try_files` and split the cache-control header. Config only, no app code.
- Tests: `tests/test_db.py`, `tests/test_library.py`, `tests/test_api.py` — mirror existing patterns (`fresh_db` fixture reloads `db` after setting `DB_PATH`; the `client` fixture in `test_api.py` reloads `db` then `main`).

---

### Task 1: `db.streamable_library_versions()`

**Files:**
- Modify: `db.py` (add function near `get_converted_paths`, `db.py:757`)
- Test: `tests/test_db.py`

**Interfaces:**
- Produces: `streamable_library_versions() -> list[tuple[int, int, str]]` — `(video_id, version_id, path)` for every non-tombstoned library version whose status is `done` and whose `converted_path or source_path` ends in `.mp4`. `path` is that resolved file.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_db.py` (it already imports `db` and uses a `DB_PATH`/reload fixture — follow the file's existing fixture; if a test needs a fresh db, replicate the reload pattern used by neighboring tests):

```python
def test_streamable_library_versions_lists_only_playable_mp4():
    # converted mp4 → included
    conv_id, _ = db.upsert_library_video({
        "source_path": "/Volumes/Media/a.mkv", "title": "A", "classification": "tv",
        "plex_rating_key": "10",
    })
    cv = db.get_video_versions(conv_id)[0]
    db.set_library_state(conv_id, "done", converted_path="/Volumes/Media/a.mp4", version_id=cv["id"])

    # passthrough: source is mp4, converted_path stays NULL → included
    pass_id, _ = db.upsert_library_video({
        "source_path": "/Volumes/Media/b.mp4", "title": "B", "classification": "tv",
        "plex_rating_key": "11",
    })
    pv = db.get_video_versions(pass_id)[0]
    db.set_library_state(pass_id, "done", version_id=pv["id"])

    # unconverted mkv → excluded (not done, and source is mkv)
    db.upsert_library_video({
        "source_path": "/Volumes/Media/c.mkv", "title": "C", "classification": "tv",
        "plex_rating_key": "12",
    })

    rows = db.streamable_library_versions()
    paths = {(vid, path) for vid, _ver, path in rows}
    assert (conv_id, "/Volumes/Media/a.mp4") in paths
    assert (pass_id, "/Volumes/Media/b.mp4") in paths
    assert all("c.mkv" not in path for _v, _ver, path in rows)


def test_streamable_library_versions_excludes_tombstoned():
    vid, _ = db.upsert_library_video({
        "source_path": "/Volumes/Media/d.mp4", "title": "D", "classification": "tv",
        "plex_rating_key": "13",
    })
    v = db.get_video_versions(vid)[0]
    db.set_library_state(vid, "done", version_id=v["id"])
    db.tombstone_video(vid)
    assert all(row[0] != vid for row in db.streamable_library_versions())
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_db.py::test_streamable_library_versions_lists_only_playable_mp4 -v`
Expected: FAIL with `AttributeError: module 'db' has no attribute 'streamable_library_versions'`

- [ ] **Step 3: Write minimal implementation**

Add to `db.py` (after `get_converted_paths`, around `db.py:772`):

```python
def streamable_library_versions() -> list[tuple[int, int, str]]:
    """(video_id, version_id, file) for library versions Caddy can serve directly.

    The file is what /videos/{id}/stream resolves (converted_path or source_path);
    only .mp4 and status 'done' qualify — an unconverted .mkv source is unplayable
    on iOS and must keep falling through to the app.
    """
    with _conn() as conn:
        rows = conn.execute(
            """
            SELECT vv.video_id AS video_id, vv.id AS version_id,
                   COALESCE(vv.converted_path, vv.source_path) AS path
            FROM video_versions vv
            JOIN videos v ON v.id = vv.video_id
            WHERE v.source = 'library'
              AND v.deleted_at IS NULL
              AND vv.status = 'done'
              AND COALESCE(vv.converted_path, vv.source_path) LIKE '%.mp4'
            """
        ).fetchall()
    return [(r["video_id"], r["version_id"], r["path"]) for r in rows]
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python -m pytest tests/test_db.py -k streamable_library_versions -v`
Expected: PASS (both tests)

- [ ] **Step 5: Commit**

```bash
git add db.py tests/test_db.py
git commit -m "feat(library): db helper listing Caddy-servable library versions"
```

---

### Task 2: symlink lifecycle helpers in `library.py`

**Files:**
- Modify: `library.py` (add `VIDEOS_DIR` constant near the top imports, `library.py:1-16`; add helpers after `convert_library_video`, `library.py:217`)
- Test: `tests/test_library.py`

**Interfaces:**
- Consumes: `db.streamable_library_versions()` (Task 1).
- Produces:
  - `stream_link_name(video_id: int, version_id: int) -> str` → `"{video_id}-v{version_id}.mp4"`
  - `link_stream_file(video_id: int, version_id: int, target: Path) -> None` — atomically (re)creates `videos/{video_id}-v{version_id}.mp4` as an absolute symlink to `target`.
  - `unlink_stream_files(video_id: int) -> None` — removes all `videos/{video_id}-v*.mp4` links.
  - `refresh_stream_links() -> None` — removes every `videos/*-v*.mp4` link, then recreates one per `db.streamable_library_versions()` row.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_library.py` (top already has `from pathlib import Path`, `import library`):

```python
def test_link_stream_file_creates_absolute_symlink(tmp_path, monkeypatch):
    videos = tmp_path / "videos"
    monkeypatch.setattr(library, "VIDEOS_DIR", videos)
    target = tmp_path / "media" / "movie.mp4"
    target.parent.mkdir(parents=True)
    target.write_bytes(b"x")

    library.link_stream_file(7, 3, target)

    link = videos / "7-v3.mp4"
    assert link.is_symlink()
    assert Path(os.readlink(link)).is_absolute()
    assert link.resolve() == target.resolve()


def test_link_stream_file_replaces_existing(tmp_path, monkeypatch):
    videos = tmp_path / "videos"
    monkeypatch.setattr(library, "VIDEOS_DIR", videos)
    old = tmp_path / "old.mp4"; old.write_bytes(b"o")
    new = tmp_path / "new.mp4"; new.write_bytes(b"n")

    library.link_stream_file(7, 3, old)
    library.link_stream_file(7, 3, new)  # re-point, no error

    assert (videos / "7-v3.mp4").resolve() == new.resolve()


def test_unlink_stream_files_removes_only_that_video(tmp_path, monkeypatch):
    videos = tmp_path / "videos"
    monkeypatch.setattr(library, "VIDEOS_DIR", videos)
    library.link_stream_file(7, 3, tmp_path / "a.mp4")
    library.link_stream_file(7, 4, tmp_path / "b.mp4")
    library.link_stream_file(8, 1, tmp_path / "c.mp4")

    library.unlink_stream_files(7)

    assert not (videos / "7-v3.mp4").exists()
    assert not (videos / "7-v4.mp4").exists()
    assert (videos / "8-v1.mp4").is_symlink()


def test_refresh_stream_links_rebuilds_from_db(tmp_path, monkeypatch):
    videos = tmp_path / "videos"
    monkeypatch.setattr(library, "VIDEOS_DIR", videos)
    # a stale managed link that the DB no longer backs
    library.link_stream_file(99, 1, tmp_path / "gone.mp4")
    # a real download file that must be left untouched
    videos.mkdir(exist_ok=True)
    (videos / "5.mp4").write_bytes(b"download")

    monkeypatch.setattr(library.db, "streamable_library_versions",
                        lambda: [(7, 3, str(tmp_path / "keep.mp4"))])
    library.refresh_stream_links()

    assert not (videos / "99-v1.mp4").exists()          # stale removed
    assert (videos / "7-v3.mp4").is_symlink()            # db row created
    assert (videos / "5.mp4").read_bytes() == b"download"  # download untouched
```

Add `import os` at the top of `tests/test_library.py` if not already present.

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_library.py -k "link_stream or refresh_stream or unlink_stream" -v`
Expected: FAIL with `AttributeError: module 'library' has no attribute 'link_stream_file'`

- [ ] **Step 3: Write minimal implementation**

Add near the top of `library.py` (after the imports, alongside the other module constants around `library.py:16`):

```python
VIDEOS_DIR = Path("videos")
```

Add after `convert_library_video` (after `library.py:217`):

```python
def stream_link_name(video_id: int, version_id: int) -> str:
    """Filename Caddy resolves for /videos/{id}/stream?version_id={ver}."""
    return f"{video_id}-v{version_id}.mp4"


def link_stream_file(video_id: int, version_id: int, target: Path) -> None:
    """Atomically point videos/{id}-v{ver}.mp4 at an absolute-path target.

    Symlink (not hardlink): videos/ and /Volumes/Media are different devices.
    Create-then-replace so a concurrent Caddy stat never sees a half-made link.
    """
    VIDEOS_DIR.mkdir(exist_ok=True)
    link = VIDEOS_DIR / stream_link_name(video_id, version_id)
    tmp = link.with_name("." + link.name + ".tmp")
    tmp.unlink(missing_ok=True)
    os.symlink(os.path.abspath(target), tmp)
    os.replace(tmp, link)


def unlink_stream_files(video_id: int) -> None:
    """Remove every managed stream link for one library video."""
    for link in VIDEOS_DIR.glob(f"{video_id}-v*.mp4"):
        link.unlink(missing_ok=True)


def refresh_stream_links() -> None:
    """Rebuild all managed links from the DB so disk can't drift.

    Managed links are exactly videos/*-v*.mp4 (download videos use bare
    {id}.mp4), so wiping and recreating that set never touches a real file.
    """
    for link in VIDEOS_DIR.glob("*-v*.mp4"):
        link.unlink(missing_ok=True)
    for video_id, version_id, path in db.streamable_library_versions():
        link_stream_file(video_id, version_id, Path(path))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python -m pytest tests/test_library.py -k "link_stream or refresh_stream or unlink_stream" -v`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add library.py tests/test_library.py
git commit -m "feat(library): symlink lifecycle helpers for Caddy streaming"
```

---

### Task 3: create the link at convert-completion (both branches)

**Files:**
- Modify: `library.py` — `convert_library_video`, passthrough branch (`library.py:178-184`) and re-encode branch (`library.py:202-208`)
- Test: `tests/test_library.py`

**Interfaces:**
- Consumes: `link_stream_file` (Task 2). Passthrough links `source` (an mp4); re-encode links `target` (the converted mp4).

- [ ] **Step 1: Write the failing test**

Add to `tests/test_library.py` (uses the existing `fresh_db` fixture and `lib_row` / `probe` helpers, `tests/test_library.py:191-217`):

```python
def test_convert_passthrough_links_source(fresh_db, tmp_path, monkeypatch):
    import db
    videos = tmp_path / "videos"
    monkeypatch.setattr(library, "VIDEOS_DIR", videos)
    vid, src = lib_row(tmp_path, "ep.mp4")  # source already mp4
    version = db.get_video_versions(vid)[0]
    monkeypatch.setattr(library, "probe_source", lambda p: probe(
        container="mov,mp4,m4a,3gp,3g2,mj2", vcodec="h264", acodec="aac"))

    library.convert_library_video(vid)

    link = videos / f"{vid}-v{version['id']}.mp4"
    assert link.is_symlink()
    assert link.resolve() == src.resolve()


def test_convert_reencode_links_converted_output(fresh_db, tmp_path, monkeypatch):
    import db
    videos = tmp_path / "videos"
    monkeypatch.setattr(library, "VIDEOS_DIR", videos)
    vid, src = lib_row(tmp_path)  # ep.mkv
    version = db.get_video_versions(vid)[0]
    monkeypatch.setattr(library, "probe_source", lambda p: probe())
    monkeypatch.setattr(library, "_run_ffmpeg",
                        lambda cmd: Path(cmd[-1]).write_bytes(b"converted"))

    library.convert_library_video(vid)

    link = videos / f"{vid}-v{version['id']}.mp4"
    assert link.is_symlink()
    assert link.resolve() == (tmp_path / "ep.mp4").resolve()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_library.py -k "convert_passthrough_links or convert_reencode_links" -v`
Expected: FAIL — link file does not exist (`assert link.is_symlink()`).

- [ ] **Step 3: Write minimal implementation**

In `library.py`, passthrough branch — after `db.set_library_state(... "done" ...)` and before `return` (`library.py:179-185`):

```python
        if plan.passthrough:
            db.set_library_state(
                video_id, "done",
                converted_langs=json.dumps([t["lang"] for t in audio_track_list(probe)]),
                version_id=version["id"],
            )
            link_stream_file(video_id, version["id"], source)
            return
```

Re-encode branch — after the `db.set_library_state(... converted_path=str(target) ...)` call (`library.py:203-208`), before the `import hls` line:

```python
        db.set_library_state(
            video_id, "done",
            converted_path=str(target),
            converted_langs=json.dumps(plan.audio_langs),
            version_id=version["id"],
        )
        link_stream_file(video_id, version["id"], target)
        # The streamable file changed; any packaged HLS output is stale.
        # Function-level import avoids hls importing library at module load.
        import hls
        hls.invalidate(video_id)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python -m pytest tests/test_library.py -v`
Expected: PASS (all library tests, including the two new ones and the pre-existing convert tests)

- [ ] **Step 5: Commit**

```bash
git add library.py tests/test_library.py
git commit -m "feat(library): link stream file when a version finishes converting"
```

---

### Task 4: rebuild on scan, remove on delete

**Files:**
- Modify: `library.py` — `scan_library` return path (`library.py:298`)
- Modify: `router.py` — `api_delete_video` library branch (`router.py:718-724`)
- Test: `tests/test_library.py`, `tests/test_api.py`

**Interfaces:**
- Consumes: `refresh_stream_links`, `unlink_stream_files` (Task 2).

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_library.py`:

```python
def test_scan_library_refreshes_stream_links(fresh_db, tmp_path, monkeypatch):
    monkeypatch.setattr(library, "VIDEOS_DIR", tmp_path / "videos")
    monkeypatch.setattr(library.plex, "fetch_library_items", lambda: [])
    called = []
    monkeypatch.setattr(library, "refresh_stream_links", lambda: called.append(True))

    library.scan_library()

    assert called == [True]
```

Add to `tests/test_api.py` (mirror the file's existing library-delete test for setup; the `client` fixture reloads `db` then `main`, and write endpoints need the `Authorization: Bearer <UPLOAD_TOKEN>` header — copy the token/header pattern from a neighboring `/api/video/{id}/delete` test):

```python
def test_delete_library_video_removes_stream_links(client, tmp_path, monkeypatch):
    import db, library
    monkeypatch.setattr(library, "VIDEOS_DIR", tmp_path / "videos")
    vid, _ = db.upsert_library_video({
        "source_path": str(tmp_path / "x.mp4"), "title": "X",
        "classification": "tv", "plex_rating_key": "77",
    })
    v = db.get_video_versions(vid)[0]
    db.set_library_state(vid, "done", version_id=v["id"])
    library.link_stream_file(vid, v["id"], tmp_path / "x.mp4")
    assert (tmp_path / "videos" / f"{vid}-v{v['id']}.mp4").exists()

    resp = client.post(f"/api/video/{vid}/delete", headers=AUTH_HEADERS)
    assert resp.status_code == 200
    assert not (tmp_path / "videos" / f"{vid}-v{v['id']}.mp4").exists()
```

Use whatever the file already names its auth header constant/fixture instead of `AUTH_HEADERS` if it differs.

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tests/test_library.py -k scan_library_refreshes tests/test_api.py -k delete_library_video_removes -v`
Expected: FAIL — `refresh_stream_links` not called during scan; link still present after delete.

- [ ] **Step 3: Write minimal implementation**

In `library.py`, `scan_library` — replace the final `return` line (`library.py:298`):

```python
        _probe_missing_audio_langs(video_id)
    refresh_stream_links()
    return {"added": added, "updated": updated, "skipped": skipped}
```

In `router.py`, `api_delete_video` library branch (`router.py:718-724`) — add the unlink call after tombstoning:

```python
        if video.get("source") == "library":
            for version in video.get("versions", []):
                if version.get("converted_path"):
                    Path(version["converted_path"]).unlink(missing_ok=True)
            if video.get("converted_path"):
                Path(video["converted_path"]).unlink(missing_ok=True)
            db.tombstone_video(video_id)
            library.unlink_stream_files(video_id)
```

(`library` is already imported in `router.py` — confirm the import exists near the top; it is used by `library.convert_library_video` at `router.py:709`.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `python -m pytest tests/test_library.py tests/test_api.py -v`
Expected: PASS (full library + api suites)

- [ ] **Step 5: Run the whole suite**

Run: `python -m pytest tests/ -q`
Expected: PASS (no regressions)

- [ ] **Step 6: Commit**

```bash
git add library.py router.py tests/test_library.py tests/test_api.py
git commit -m "feat(library): refresh links on scan, drop them on delete"
```

---

### Task 5: Caddy `@stream` try_files + split cache-control

**Files:**
- Modify: `~/c/server/Caddyfile` — the `patatatube` `:3050` block, `@stream` handler (`Caddyfile:165-189`)

**Interfaces:**
- Consumes: the on-disk symlinks `videos/{id}-v{version_id}.mp4` created by Tasks 2–4. No app-code interface.

This task is config; it is verified by `caddy validate` and a live `curl`, not by pytest.

- [ ] **Step 1: Edit the `@stream` block**

Replace the `@stream` handler body (`Caddyfile:168-189`) with:

```caddyfile
	@stream path_regexp stream ^/videos/([0-9]+)/stream$
	handle @stream {
		route {
			forward_auth localhost:3051 {
				uri /check-auth?{query}
			}
			# Library streams carry ?version_id= and resolve to a symlink;
			# download videos have no query and use the bare {id}.mp4.
			@mp4 file {
				try_files /videos/{re.stream.1}-v{http.request.uri.query.version_id}.mp4 /videos/{re.stream.1}.mp4
			}
			rewrite @mp4 {http.matchers.file.relative}
			# Download files are content-addressed and never change → immutable.
			@dl path_regexp ^/videos/[0-9]+\.mp4$
			header @dl Cache-Control "public, max-age=31536000, immutable"
			# Library links can change bytes at a stable path on re-conversion →
			# must revalidate; ETag/Last-Modified come from the symlink target.
			@lib path_regexp ^/videos/[0-9]+-v[0-9]+\.mp4$
			header @lib Cache-Control "public, max-age=3600, must-revalidate"
			@served path /videos/*.mp4
			log_append @served served_by caddy
			file_server @served
			reverse_proxy localhost:3051 {
				header_up Host {host}
				header_up X-Real-IP {remote_host}
				header_up X-Forwarded-For {remote_host}
				header_up X-Forwarded-Proto {scheme}
			}
		}
	}
```

Note: `rewrite @mp4 {http.matchers.file.relative}` rewrites to whichever candidate the `file` matcher found (Caddy exposes the matched file in that placeholder), so the same block serves both the library symlink and the bare download file. If your Caddy version does not populate `{http.matchers.file.relative}`, fall back to two explicit candidates by keeping the prior single-candidate `rewrite @mp4 /videos/{re.stream.1}.mp4` for downloads and adding a separate `@libmp4 file { try_files /videos/{re.stream.1}-v{http.request.uri.query.version_id}.mp4 }` + `rewrite @libmp4 /videos/{re.stream.1}-v{http.request.uri.query.version_id}.mp4` ahead of it.

- [ ] **Step 2: Validate the Caddyfile**

Run: `caddy validate --config ~/c/server/Caddyfile --adapter caddyfile`
Expected: `Valid configuration`

- [ ] **Step 3: Reload Caddy**

Run: `caddy reload --config ~/c/server/Caddyfile --adapter caddyfile`
Expected: exit 0, no error output.

- [ ] **Step 4: Verify a library stream is served by Caddy**

Pick a done library video id and its chosen `version_id` (from `/api/videos` or the DB), confirm the symlink exists, then range-request it:

```bash
ls -l videos/*-v*.mp4                                   # symlinks present
curl -s -D- -o /dev/null -H "Range: bytes=0-1023" \
  "http://localhost:3050/videos/<ID>/stream?version_id=<VER>&token=$UPLOAD_TOKEN"
```

Expected: `HTTP/1.1 206 Partial Content`, `Accept-Ranges: bytes`, `Cache-Control: public, max-age=3600, must-revalidate`. Then check the access log:

```bash
tail -n 5 log/caddy_access.log | grep served_by
```

Expected: the request shows `served_by: caddy` (previously absent / reverse-proxied to Python).

- [ ] **Step 5: Verify a download stream still works (regression)**

```bash
curl -s -D- -o /dev/null -H "Range: bytes=0-1023" \
  "http://localhost:3050/videos/<DOWNLOAD_ID>/stream?token=$UPLOAD_TOKEN"
```

Expected: `206`, `Cache-Control: public, max-age=31536000, immutable`, `served_by: caddy`.

- [ ] **Step 6: Commit**

The Caddyfile lives outside this repo (`~/c/server`). Commit it in its own repo if it is version-controlled:

```bash
cd ~/c/server && git add Caddyfile && git commit -m "feat(patatatube): serve library video streams via symlinks"
```

If `~/c/server` is not a git repo, note the change was applied and reloaded in the PatataTube commit message / PR description instead.

---

## Self-Review

**Spec coverage** (against `docs/caddy-serves-all.md`):
- Symlink naming `{video_id}-v{version_id}.mp4` + optional default — Task 2 (default-version bare link intentionally omitted; iOS always sends `version_id`, documented in Global Constraints).
- Only playable mp4s linked — Task 1 SQL (`LIKE '%.mp4'` + status `done`), covering both converted and passthrough (a doc gap: passthrough has no `converted_path` yet is a playable mp4 — resolved).
- Lifecycle: create at convert-completion — Task 3; scan backfill via full rebuild — Task 4; remove on delete — Task 4; re-conversion needs no action (path stable, `os.replace` swaps bytes, Caddy re-stats) — noted in Global Constraints.
- Staleness handled — Caddy stats symlink target; plus non-`immutable` cache-control for library so clients revalidate (doc glossed the `immutable` hazard) — Task 5.
- Unmounted volume → broken symlink → `try_files` miss → app 404 — Global Constraints + Task 5 fall-through.
- No namespace clash — bare `{id}.mp4` vs `{id}-v{ver}.mp4`; managed set is `*-v*.mp4` — Task 2/4.
- Caddyfile `try_files` with `{http.request.uri.query.version_id}` — Task 5.

**Placeholder scan:** no TBD/TODO; every code step shows full code; every command has expected output.

**Type consistency:** `streamable_library_versions() -> list[tuple[int,int,str]]` produced in Task 1, consumed unchanged in Task 2 `refresh_stream_links`. `stream_link_name`/`link_stream_file`/`unlink_stream_files` signatures identical across Tasks 2–4. `VIDEOS_DIR` defined once in `library.py`, monkeypatched by the same attribute path in every test.
