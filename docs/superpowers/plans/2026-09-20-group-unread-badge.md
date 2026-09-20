# Group Unread Badge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Each group card in the iOS Videos tab shows a white number on a red circle counting videos added to the group and not yet played; it drops by one the first time each video is played, is hidden at 0, and starts at 0 for every existing group.

**Architecture:** A per-video `videos.unread` flag on the server (default 0) is set when a download/upload finishes and cleared by a new idempotent `POST /api/videos/{id}/played`. `GET /api/groups` derives `unread_count` per group from that flag, so the count cannot drift and is shared across devices. The iOS app decodes `unread_count`, reports the first play of each video, refetches `/api/groups` after the server says something changed, and draws the badge.

**Tech Stack:** Python/FastAPI/SQLite (pytest), SwiftUI + PatataTubeKit (XCTest, not run by agents).

**Spec:** Agreed in chat, 2026-09-20 (no spec file; bounded change). Decisions: +1 only when a download/upload finishes (moves never add); -1 on any first playback (full-screen video *and* audio queue); count derived from a per-video flag; badge on Videos-tab group cards only (inbox included; Plex TV/Movies get none); every counter is zero after rollout.

## Global Constraints

- **Never run iOS tests** (`swift test`, `xcodebuild ... test`) — the user starts those. Write them, name them, and say which would cover the change. `swift build` in `ios/PatataTubeKit` is fine.
- **No `Co-Authored-By` trailer on commits in this repo** (project convention, overrides the default attribution line).
- Schema changes are idempotent `ALTER TABLE` guards in `db.init_db()`, not a migrations framework.
- Out-of-band writers (anything not an HTTP request) must flush the response cache themselves: `await cache.clear()` in the async downloader. Otherwise `/api/groups` serves a frozen count for up to 300s.
- Only YouTube/Twitter/file-upload downloads become unread. Library (Plex) rows never do.
- `VideoGroup` must keep decoding blobs without `unread_count` (`decodeIfPresent ?? 0`) because `GroupStore`'s UserDefaults mirror predates the field.
- Run pytest as `MEDIA_ROOT=. python -m pytest ...` from the repo root.
- Badge is hidden at 0.

## File Structure

| File | Change |
|---|---|
| `db.py` | `unread` column guard; `mark_unread`, `mark_played`, `unread_count`; `list_groups` returns `unread_count` |
| `downloader.py` | `_announce_new_video` helper called at the 3 `status="done"` sites |
| `router.py` | `serialize_group` adds `unread_count`; new `POST /api/videos/{id}/played` |
| `tests/test_groups.py`, `tests/test_downloader.py`, `tests/test_api.py` | backend tests |
| `ios/PatataTubeKit/Sources/PatataTubeKit/VideoGroup.swift` | `unreadCount` field + copy helpers |
| `ios/PatataTubeKit/Sources/PatataTubeKit/APIClient.swift` | `markPlayed(id:)` |
| `ios/PatataTubeKit/Tests/PatataTubeKitTests/GroupStoreTests.swift` | decode/round-trip tests |
| `ios/PatataTube/Sources/AppModel.swift` | `markPlayed(_:)` with per-session dedupe + group refresh |
| `ios/PatataTube/Sources/AudioQueuePlayer.swift`, `VideoPlayerView.swift` | call `model.markPlayed` at the 4 item-start sites |
| `ios/PatataTube/Sources/UnreadBadge.swift` (new), `GroupsView.swift` | badge view + overlay; keep `unreadCount` through the two inline `VideoGroup(...)` copies |
| `CLAUDE.md` | document the feature |

---

### Task 1: DB — `unread` flag, `mark_unread`, `mark_played`, group counts

**Files:**
- Modify: `db.py` (column guard after the `channel` guard near line 190; new functions near `set_video_group` ~line 1025; `list_groups` ~line 806)
- Test: `tests/test_groups.py`

**Interfaces:**
- Produces:
  - `db.mark_unread(video_id: int) -> None`
  - `db.mark_played(video_id: int) -> bool` — True only if the flag flipped 1 → 0
  - `db.unread_count(group_id: int) -> int`
  - `db.list_groups()` rows gain `"unread_count": int`

- [ ] **Step 1: Write the failing tests** (append to `tests/test_groups.py`; uses the existing `fresh_db` fixture, whose seeded groups start at id 1)

```python
def _done_video(db, group_id, url="https://x/1"):
    video_id = db.add_video(url, platform="youtube", group_id=group_id)
    db.update_video(video_id, status="done", filename=f"{video_id}.mp4")
    return video_id


def test_every_group_starts_with_zero_unread(fresh_db):
    assert [g["unread_count"] for g in fresh_db.list_groups()] == [0, 0, 0, 0]


def test_videos_that_existed_before_the_column_are_read(tmp_path, monkeypatch):
    # A database created by the previous release: no `unread` column yet.
    path = tmp_path / "old.sqlite"
    monkeypatch.setenv("DB_PATH", str(path))
    import db as db_module

    importlib.reload(db_module)
    db_module.init_db()
    with db_module._conn() as conn:
        conn.execute("ALTER TABLE videos DROP COLUMN unread")
    video_id = _done_video(db_module, group_id=1)

    db_module.init_db()  # the migration guard re-adds the column

    assert db_module.unread_count(1) == 0
    assert db_module.get_video(video_id)["unread"] == 0


def test_mark_unread_counts_in_the_videos_group(fresh_db):
    a = _done_video(fresh_db, group_id=1, url="https://x/a")
    _done_video(fresh_db, group_id=1, url="https://x/b")
    fresh_db.mark_unread(a)

    assert fresh_db.unread_count(1) == 1
    counts = {g["id"]: g["unread_count"] for g in fresh_db.list_groups()}
    assert counts[1] == 1 and counts[2] == 0


def test_mark_played_decrements_once_and_reports_change(fresh_db):
    video_id = _done_video(fresh_db, group_id=1)
    fresh_db.mark_unread(video_id)

    assert fresh_db.mark_played(video_id) is True
    assert fresh_db.unread_count(1) == 0
    assert fresh_db.mark_played(video_id) is False
    assert fresh_db.unread_count(1) == 0


def test_moving_a_video_never_adds_but_carries_its_unread_state(fresh_db):
    video_id = _done_video(fresh_db, group_id=1)
    other = _done_video(fresh_db, group_id=1, url="https://x/other")  # read
    fresh_db.mark_unread(video_id)

    fresh_db.set_video_group(video_id, 2)
    fresh_db.set_video_group(other, 2)

    assert fresh_db.unread_count(1) == 0
    assert fresh_db.unread_count(2) == 1  # only the unread one


def test_unfinished_and_deleted_videos_are_not_counted(fresh_db):
    queued = fresh_db.add_video("https://x/q", platform="youtube", group_id=1)
    fresh_db.mark_unread(queued)  # still queued
    gone = _done_video(fresh_db, group_id=1, url="https://x/gone")
    fresh_db.mark_unread(gone)
    fresh_db.delete_video(gone)

    assert fresh_db.unread_count(1) == 0
```

- [ ] **Step 2: Run to verify failure**

Run: `MEDIA_ROOT=. python -m pytest tests/test_groups.py -k "unread or played" -v`
Expected: FAIL (`AttributeError: module 'db' has no attribute 'unread_count'` / `KeyError: 'unread_count'`)

- [ ] **Step 3: Implement**

In `init_db()` after the `channel` guard (`if "channel" not in columns: ...`, `db.py` ~line 190), add:

```python
        # 1 from the moment a download/upload finishes until it is first played.
        # A group's badge is the count of these, derived rather than stored, so it
        # cannot drift. DEFAULT 0 is deliberate: every video that already exists
        # is "read", which is what makes every counter start at zero on rollout.
        if "unread" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN unread INTEGER NOT NULL DEFAULT 0")
```

Replace `list_groups` (`db.py` ~line 806) and add the counters next to it:

```python
_UNREAD_WHERE = "unread = 1 AND status = 'done' AND deleted_at IS NULL"


def list_groups() -> list[dict]:
    with _conn() as conn:
        rows = conn.execute(
            f"""
            SELECT g.*,
                   (SELECT COUNT(*) FROM videos v
                    WHERE v.group_id = g.id AND {_UNREAD_WHERE}
                   ) AS unread_count
            FROM groups g
            ORDER BY g.position ASC, g.id ASC
            """
        ).fetchall()
        return [dict(r) for r in rows]


def unread_count(group_id: int) -> int:
    with _conn() as conn:
        return conn.execute(
            f"SELECT COUNT(*) FROM videos WHERE group_id = ? AND {_UNREAD_WHERE}",
            (group_id,),
        ).fetchone()[0]


def mark_unread(video_id: int) -> None:
    """Called when a download or upload finishes. Moves never call this."""
    with _conn() as conn:
        conn.execute("UPDATE videos SET unread = 1 WHERE id = ?", (video_id,))


def mark_played(video_id: int) -> bool:
    """True only when the video was unread. Idempotent: replays return False."""
    with _conn() as conn:
        cur = conn.execute(
            "UPDATE videos SET unread = 0 WHERE id = ? AND unread = 1", (video_id,)
        )
        return cur.rowcount > 0
```

- [ ] **Step 4: Run to verify pass**

Run: `MEDIA_ROOT=. python -m pytest tests/test_groups.py -v`
Expected: all PASS (existing group tests included — `list_groups` gains a key only).

- [ ] **Step 5: Commit**

```bash
git add db.py tests/test_groups.py
git commit -m "feat(db): per-video unread flag and derived group unread counts"
```

---

### Task 2: Downloader marks finished downloads unread and flushes the cache

**Files:**
- Modify: `downloader.py` (three `status="done"` sites: YouTube ~line 57, Twitter ~line 75, `process_uploaded_video` ~line 112)
- Test: `tests/test_downloader.py`

**Interfaces:**
- Consumes: `db.mark_unread(video_id)`, `db.unread_count(group_id)` (Task 1); `cache.clear()` (async; fails open with no Redis)
- Produces: `downloader._announce_new_video(video_id: int) -> None` (async)

- [ ] **Step 1: Write the failing tests** (append to `tests/test_downloader.py`; mirrors the existing `test_download_youtube_success_persists_title` and `test_process_uploaded_video_success`)

```python
@pytest.mark.asyncio
async def test_finished_youtube_download_adds_one_unread_to_its_group(monkeypatch, downloader_env, tmp_path):
    db, downloader, _videos_dir = downloader_env
    source_file = tmp_path / "source.mp4"
    source_file.write_bytes(b"youtube-bytes")

    async def fake_download(url):
        return downloader.YoutubeDownload(source_file, "T", "Ch")

    async def fake_normalize(path, video_id, channel=None, source_key=None):
        return Path(path)

    monkeypatch.setattr(downloader, "_download_youtube_media", fake_download)
    monkeypatch.setattr(downloader, "_normalize_media_for_ios", fake_normalize)
    group_id = db.list_groups()[0]["id"]
    video_id = db.add_video(
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        platform="youtube", source_key="dQw4w9WgXcQ", group_id=group_id,
    )
    assert db.unread_count(group_id) == 0  # not while it is still queued

    await downloader.download_video(video_id)

    assert db.unread_count(group_id) == 1


@pytest.mark.asyncio
async def test_finished_upload_adds_one_unread_and_flushes_the_cache(monkeypatch, downloader_env, tmp_path):
    db, downloader, _videos_dir = downloader_env
    tmp_upload = tmp_path / "up.mp4"
    tmp_upload.write_bytes(b"bytes")
    group_id = db.list_groups()[0]["id"]
    video_id = db.add_video(str(tmp_upload), platform="upload", title="U", group_id=group_id)

    async def fake_normalize(path, video_id, channel=None, source_key=None):
        return Path(path)

    flushes = []

    async def fake_clear():
        flushes.append(1)

    monkeypatch.setattr(downloader, "_normalize_media_for_ios", fake_normalize)
    monkeypatch.setattr(downloader.cache, "clear", fake_clear)

    await downloader.process_uploaded_video(video_id)

    assert db.unread_count(group_id) == 1
    assert flushes, "a stale cached /api/groups would hide the new badge"


@pytest.mark.asyncio
async def test_failed_download_leaves_no_unread(monkeypatch, downloader_env):
    db, downloader, _videos_dir = downloader_env

    async def fake_download(url):
        raise RuntimeError("yt-dlp failed")

    monkeypatch.setattr(downloader, "_download_youtube_media", fake_download)
    group_id = db.list_groups()[0]["id"]
    video_id = db.add_video("https://www.youtube.com/watch?v=abc", platform="youtube",
                            source_key="abc", group_id=group_id)

    await downloader.download_video(video_id)

    assert db.unread_count(group_id) == 0
```

- [ ] **Step 2: Run to verify failure**

Run: `MEDIA_ROOT=. python -m pytest tests/test_downloader.py -k "unread" -v`
Expected: the first two FAIL (`assert 0 == 1`); the third passes already (it guards against over-counting).

- [ ] **Step 3: Implement**

Add near `process_uploaded_video` in `downloader.py`:

```python
async def _announce_new_video(video_id: int) -> None:
    """Flag a finished download unread and flush the response cache.

    The cache flush is not optional: this runs as a BackgroundTask, after the
    request that queued it has already returned, so nothing else invalidates a
    cached `GET /api/groups` and the badge would not appear for up to
    CACHE_TTL_SECONDS.
    """
    db.mark_unread(video_id)
    await cache.clear()
```

Confirm `cache` is imported at the top of `downloader.py` (`import cache`; the existing test monkeypatches `downloader.cache`). Then call it:

- YouTube branch: after `if classify: await _classify_into_group(video_id, meta)` and **before** `db.enqueue_job("hls", ...)`, add `await _announce_new_video(video_id)` (after classification so the flush also covers a group move).
- Twitter branch: after `db.update_video(video_id, status="done", filename=dest_name)` (~line 75) add `await _announce_new_video(video_id)`.
- `process_uploaded_video`: after `db.update_video(video_id, status="done", filename=dest_name)` (~line 112) add `await _announce_new_video(video_id)`.

- [ ] **Step 4: Run to verify pass**

Run: `MEDIA_ROOT=. python -m pytest tests/test_downloader.py -v`
Expected: all PASS (existing playlist test's `cache_flushes >= 1` still holds).

- [ ] **Step 5: Commit**

```bash
git add downloader.py tests/test_downloader.py
git commit -m "feat(downloader): mark finished downloads unread and flush the cache"
```

---

### Task 3: API — `unread_count` in groups, `POST /api/videos/{id}/played`

**Files:**
- Modify: `router.py` (`serialize_group` ~line 995; new endpoint after `api_save_position` ~line 1183)
- Test: `tests/test_api.py`

**Interfaces:**
- Consumes: `db.mark_played`, `db.unread_count`, `db.list_groups()["unread_count"]` (Task 1)
- Produces: `GET /api/groups` → each group has `"unread_count": int`; `POST /api/videos/{id}/played` (Bearer) → `200 {"changed": bool}`, `404` for unknown/deleted video, `401` without token.

- [ ] **Step 1: Write the failing tests** (append to `tests/test_api.py`; uses `client` and `auth_headers`)

```python
def _finished_video(client, group_id):
    import db
    video_id = db.add_video("https://x/v", platform="youtube", group_id=group_id)
    db.update_video(video_id, status="done", filename=f"{video_id}.mp4")
    db.mark_unread(video_id)
    return video_id


def test_groups_report_unread_count(client, auth_headers):
    import db
    group_id = db.list_groups()[0]["id"]
    _finished_video(client, group_id)

    groups = {g["id"]: g for g in client.get("/api/groups", headers=auth_headers).json()["groups"]}

    assert groups[group_id]["unread_count"] == 1
    assert all(g["unread_count"] == 0 for gid, g in groups.items() if gid != group_id)


def test_played_clears_unread_once_and_refreshes_groups(client, auth_headers):
    import db
    group_id = db.list_groups()[0]["id"]
    video_id = _finished_video(client, group_id)
    client.get("/api/groups", headers=auth_headers)  # prime any response cache

    first = client.post(f"/api/videos/{video_id}/played", headers=auth_headers)
    second = client.post(f"/api/videos/{video_id}/played", headers=auth_headers)

    assert first.status_code == 200 and first.json() == {"changed": True}
    assert second.json() == {"changed": False}
    groups = {g["id"]: g for g in client.get("/api/groups", headers=auth_headers).json()["groups"]}
    assert groups[group_id]["unread_count"] == 0


def test_played_requires_token(client):
    assert client.post("/api/videos/1/played").status_code == 401


def test_played_unknown_video_is_404(client, auth_headers):
    assert client.post("/api/videos/99999/played", headers=auth_headers).status_code == 404


def test_patching_a_group_still_reports_its_unread_count(client, auth_headers):
    import db
    group_id = db.list_groups()[0]["id"]
    _finished_video(client, group_id)

    resp = client.patch(f"/api/groups/{group_id}", json={"display_titles": True}, headers=auth_headers)

    assert resp.json()["unread_count"] == 1
```

- [ ] **Step 2: Run to verify failure**

Run: `MEDIA_ROOT=. python -m pytest tests/test_api.py -k "unread or played" -v`
Expected: FAIL (`KeyError: 'unread_count'`, 404 on the new route).

- [ ] **Step 3: Implement**

In `router.py`, `serialize_group` gains one key. `update_group`/`create_group` return rows without the aggregate, so fall back to a direct count:

```python
        "description": group["description"],
        "unread_count": (
            group["unread_count"]
            if "unread_count" in group
            else db.unread_count(group["id"])
        ),
```

Add the endpoint after `api_save_position`:

```python
@router.post("/api/videos/{video_id}/played")
async def api_mark_played(video_id: int, request: Request):
    """First playback of a video: take it out of its group's unread badge.

    Idempotent — `changed` is false for a video that was already played (or
    never unread), and the iOS client uses it to decide whether to refetch the
    groups. Being a POST, it also flushes the response cache, so the refetch
    sees the new count.
    """
    _check_token(request)
    video = db.get_video(video_id)
    if not video or video.get("deleted_at"):
        raise HTTPException(status_code=404, detail="Video not found")
    return {"changed": db.mark_played(video_id)}
```

- [ ] **Step 4: Run to verify pass**

Run: `MEDIA_ROOT=. python -m pytest tests/ -q`
Expected: full backend suite PASS.

- [ ] **Step 5: Commit**

```bash
git add router.py tests/test_api.py
git commit -m "feat(api): unread_count on groups and POST /api/videos/{id}/played"
```

---

### Task 4: PatataTubeKit — `VideoGroup.unreadCount` and `APIClient.markPlayed`

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/VideoGroup.swift`, `ios/PatataTubeKit/Sources/PatataTubeKit/APIClient.swift` (next to `savePosition`, ~line 195)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/GroupStoreTests.swift`

**Interfaces:**
- Produces:
  - `VideoGroup.unreadCount: Int` (default 0); `init(..., description: String? = nil, unreadCount: Int = 0)`
  - `withDisplayTitles` / `withDescription` preserve `unreadCount`
  - `VideoGroup.withUnreadCount(_ n: Int) -> VideoGroup` is **not** added (YAGNI: the app refetches instead of editing locally)
  - `APIClient.markPlayed(id: Int) async throws -> Bool` (the server's `changed`)

- [ ] **Step 1: Write the failing tests** (append to `GroupStoreTests`; **do not run**)

```swift
    func testDecodesUnreadCountFromServerPayload() throws {
        let json = #"[{"id":1,"name":"children","label":"Children","emoji":null,"position":0,"display_titles":false,"unread_count":3}]"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        XCTAssertEqual(try decoder.decode([VideoGroup].self, from: Data(json.utf8)).first?.unreadCount, 3)
    }

    func testMirrorWrittenBeforeUnreadCountExistedDecodesAsZero() throws {
        // A UserDefaults blob from a build that predates the field.
        let json = #"[{"id":1,"name":"children","label":"Children","position":0}]"#
        XCTAssertEqual(try JSONDecoder().decode([VideoGroup].self, from: Data(json.utf8)).first?.unreadCount, 0)
    }

    func testCopyHelpersKeepTheUnreadCount() {
        let g = VideoGroup(id: 1, name: "a", label: "A", emoji: nil, position: 0, unreadCount: 4)
        XCTAssertEqual(g.withDisplayTitles(true).unreadCount, 4)
        XCTAssertEqual(g.withDescription("x").unreadCount, 4)
    }

    func testUnreadCountSurvivesTheUserDefaultsMirror() {
        let defaults = makeDefaults()
        GroupStore(defaults: defaults).apply([VideoGroup(id: 1, name: "a", label: "A", emoji: nil, position: 0, unreadCount: 2)])
        XCTAssertEqual(GroupStore(defaults: defaults).groups.first?.unreadCount, 2)
    }
```

(If `APIClient.makeDecoder()` is not snake-case-convert based, use it in the first test instead of a bare `JSONDecoder` — check `APIClient.swift` `makeDecoder`.)

- [ ] **Step 2: Confirm the tests do not compile yet** (no run)

Run: `cd ios/PatataTubeKit && swift build --build-tests 2>&1 | tail -5`
Expected: error `extra argument 'unreadCount'` / `value of type 'VideoGroup' has no member 'unreadCount'`. This compiles tests without executing them.

- [ ] **Step 3: Implement**

`VideoGroup.swift`:

```swift
    /// Videos added to this group and not yet played, derived by the server
    /// from `videos.unread`. The card hides its badge at 0.
    public let unreadCount: Int

    public init(id: Int, name: String, label: String, emoji: String?, position: Int,
                displayTitles: Bool = false, description: String? = nil,
                unreadCount: Int = 0) {
        // ...existing assignments...
        self.unreadCount = unreadCount
    }
```

In `init(from:)` add:

```swift
        unreadCount = try c.decodeIfPresent(Int.self, forKey: .unreadCount) ?? 0
```

Update `withDisplayTitles` and `withDescription` to pass `unreadCount: unreadCount`. Update the doc comment on `init(from:)` to mention `unreadCount`.

`APIClient.swift`, after `savePosition`:

```swift
    /// First playback of a video. Answers whether the server actually cleared an
    /// unread flag; only then do the group badges need refetching.
    public func markPlayed(id: Int) async throws -> Bool {
        let data = try await authedPost("api/videos/\(id)/played", body: [:])
        struct Result: Decodable { let changed: Bool }
        do { return try JSONDecoder().decode(Result.self, from: data).changed }
        catch { throw APIError.decoding(String(describing: error)) }
    }
```

- [ ] **Step 4: Verify it builds (tests compile too)**

Run: `cd ios/PatataTubeKit && swift build --build-tests 2>&1 | tail -5`
Expected: `Build complete!`. Tests that *would* cover this: `GroupStoreTests.testDecodesUnreadCountFromServerPayload`, `testMirrorWrittenBeforeUnreadCountExistedDecodesAsZero`, `testCopyHelpersKeepTheUnreadCount`, `testUnreadCountSurvivesTheUserDefaultsMirror` — the user runs them.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit
git commit -m "feat(ios-kit): VideoGroup.unreadCount and APIClient.markPlayed"
```

---

### Task 5: App — report first plays, refetch groups, draw the badge

**Files:**
- Create: `ios/PatataTube/Sources/UnreadBadge.swift`
- Modify: `ios/PatataTube/Sources/AppModel.swift`, `AudioQueuePlayer.swift` (after `currentVideo = video` at ~line 97 in `start`, and ~line 328 in `advance(by:)`), `VideoPlayerView.swift` (~line 403 initial item next to `bindPauseTransitions(... videoID: video.id)`; ~line 641 in `advance(by:)`), `GroupsView.swift` (two inline `VideoGroup(...)` copies in `save` and `rename`; the card artwork)

**Interfaces:**
- Consumes: `APIClient.markPlayed(id:) -> Bool`, `GroupStore.apply`, `VideoGroup.unreadCount` (Task 4)
- Produces: `AppModel.markPlayed(_ video: Video)`; `UnreadBadge(count: Int)`

- [ ] **Step 1: Add `markPlayed` to `AppModel`** (near `resetPositionIfForgotten`)

```swift
    /// Videos already reported as played this run. The server is idempotent, so
    /// this is only about not sending a request on every replay or every
    /// hand-back from the full-screen player.
    private var reportedPlayed = Set<Int>()

    /// The first playback of `video` — any player (full-screen or the audio
    /// queue) calls this each time an item starts. Plex items have no badge.
    /// On a server-side change the group list is refetched rather than edited
    /// locally, so the badge is always exactly what the server counts. A failed
    /// request is forgotten so the next play tries again.
    func markPlayed(_ video: Video) {
        guard video.plexKind == nil, reportedPlayed.insert(video.id).inserted else { return }
        let id = video.id
        Task {
            guard let changed = try? await api.markPlayed(id: id) else {
                reportedPlayed.remove(id)
                return
            }
            if changed, let remote = try? await api.groups() {
                groups.apply(remote)
            }
        }
    }
```

- [ ] **Step 2: Call it at the four item-start sites**

- `AudioQueuePlayer.start` — right after `currentVideo = video`: `model.markPlayed(video)` (the closure already captures `model` as the `start` parameter).
- `AudioQueuePlayer.advance(by:)` — right after `currentVideo = video`: `model?.markPlayed(video)` (`model` is the stored optional set in `start`; use whatever the surrounding code uses to reach it — e.g. the `self.model = model` property).
- `VideoPlayerView` initial item — immediately after the `bindPauseTransitions(player: player, item: item, videoID: video.id)` call at ~line 403: `model.markPlayed(video)`.
- `VideoPlayerView.advance(by:)` — after `bindPauseTransitions(... videoID: videos[nextIndex].id)` at ~line 641: `model.markPlayed(videos[nextIndex])`.

A hand-back from the full-screen player to audio, or the reverse, re-enters these sites for a video already in `reportedPlayed`, so it is a no-op.

- [ ] **Step 3: Create the badge**

`ios/PatataTube/Sources/UnreadBadge.swift`:

```swift
// ios/PatataTube/Sources/UnreadBadge.swift
import SwiftUI

/// White number on a red circle: how many videos in a group are new and unplayed.
/// Renders nothing at 0, so a caught-up group looks exactly as before.
struct UnreadBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .frame(minWidth: 24, minHeight: 24)
                .background(.red, in: Capsule())
                .accessibilityLabel("\(count) unplayed")
        }
    }
}
```

(`Capsule` with a min 24pt square is a circle for 1–2 digits and stretches for "99+".)

- [ ] **Step 4: Draw it on the card and keep the count through local edits**

In `GroupsView.card(for:)`, on the artwork `Rectangle()` (the `NavigationLink` label), after `.clipShape(RoundedRectangle(cornerRadius: 8))` add:

```swift
                    .overlay(alignment: .bottomTrailing) {
                        UnreadBadge(count: group.unreadCount).padding(8)
                    }
```

In `save(_:for:)` and `rename(_:for:)` the inline `VideoGroup(id:…description:)` copies must carry the count or the badge vanishes until the next fetch — add `unreadCount: $0.unreadCount` as a trailing argument to both.

- [ ] **Step 5: Regenerate the project and build (no tests)**

Run:
```bash
cd ios/PatataTube && xcodegen generate && \
xcodebuild -project PatataTube.xcodeproj -scheme PatataTube \
  -destination "generic/platform=iOS Simulator" build 2>&1 | tail -15
```
Expected: `** BUILD SUCCEEDED **`. (Build only. Per project rules, do not run `xcodebuild ... test`.)

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTube
git commit -m "feat(ios): unread badge on group cards, cleared by first playback"
```

---

### Task 6: Rollout — verify all counters are zero, document

**Files:**
- Modify: `CLAUDE.md` (a short paragraph in the Architecture section after the per-group display settings paragraph)

- [ ] **Step 1: Restart the server** so `init_db()` applies the column and the converter picks up the new `db.py`: stop `./serve` and start it again (`--reload` does not restart the converter).

- [ ] **Step 2: Verify every counter is zero against the real database**

Run:
```bash
sqlite3 data/watch_later.sqlite "SELECT COUNT(*) FROM videos WHERE unread = 1;"
curl -s -H "Authorization: Bearer $UPLOAD_TOKEN" http://localhost:3050/api/groups \
  | python3 -c "import sys,json; print([(g['label'], g['unread_count']) for g in json.load(sys.stdin)['groups']])"
```
Expected: `0`, and every group listed with `0`. If the first is non-zero, run `sqlite3 data/watch_later.sqlite "UPDATE videos SET unread = 0;"` and recheck — that is the "make all counters zero" step, and it must happen **before** any new download lands.

- [ ] **Step 3: Verify end to end on the simulator** (manual)

Upload a short video into a group → the group card shows a red **1** within one `/api/groups` fetch (pull to the Videos root or relaunch) → play it → badge disappears → replay → stays gone. Also play a group as list-mode audio and confirm the same. `log/backend.log` shows a `POST /api/videos/{id}/played` returning 200.

- [ ] **Step 4: Document** — add to `CLAUDE.md`:

```markdown
**Group cards show an unread badge.** `videos.unread` (idempotent `ALTER TABLE`
guard, default 0) is set by `downloader._announce_new_video` when a download or
upload finishes and cleared by `POST /api/videos/{id}/played`, which any player
start calls once per video (`AppModel.markPlayed`: full-screen and the audio
queue). `GET /api/groups` derives `unread_count` per group from the flag, so it
never drifts and a **move never adds to it** — an unread video carries its
badge to the new group. The default of 0 is what zeroed every counter on
rollout. `_announce_new_video` also flushes the response cache: a BackgroundTask
finishes after the request that queued it, so nothing else would. The app
refetches `/api/groups` when `played` answers `changed: true` instead of editing
the count locally. Plex rows have no badge.
```

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: unread badge on group cards"
```

---

## Self-Review

**Spec coverage:** +1 on download/upload completion, not moves → Tasks 1–2 (`test_moving_a_video_never_adds…`). -1 on first play of any kind → Task 5 sites (video initial + advance, audio start + advance). Derived per-video flag → Task 1. Badge on Videos-tab group cards, hidden at 0, inbox included, Plex excluded → Task 5 (`UnreadBadge`, `plexKind == nil` guard; `unread` only ever set by the downloader). All counters zero → default 0 (Task 1 test) + verification step (Task 6). Cache correctness → Task 2 flush test.

**Placeholder scan:** none. Two spots depend on unread code shape and say exactly what to match: how `AudioQueuePlayer.advance` reaches `model` (uses the property `start` assigns, `self.model = model`), and whether `APIClient.makeDecoder()` is snake-case (test 1 instructions).

**Type consistency:** `mark_unread`/`mark_played`/`unread_count` (db) ↔ `_announce_new_video`, `api_mark_played`, `serialize_group`; JSON key `unread_count` ↔ `VideoGroup.unreadCount` ↔ `UnreadBadge(count:)`; `changed` ↔ `markPlayed(id:) -> Bool` ↔ `AppModel.markPlayed`.

**Known limits (accepted):** a failed `played` request leaves the video unread until its next play; the iOS `xcodebuild ... test` and `swift test` targets are not run by agents.
