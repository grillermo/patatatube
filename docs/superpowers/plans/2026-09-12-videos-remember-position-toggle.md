# Videos "Remember position" Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give each video in the Videos section a per-video "Remember position" toggle that, when on, makes playback resume exactly the way it already does for Movies.

**Architecture:** The save side already exists and already covers every video — `PlaybackPositionReporter` posts to `/api/videos/{id}/position` every ~10s and on pause/background/dismiss regardless of tab, and the server stores it in `videos.resume_secs`. The only thing excluding group videos is one guard in `ResumeDecision.decide`, which returns `.playFromStart` whenever `plexKind == nil`. So this adds a per-video boolean (`videos.remember_position`, server-owned so it follows the video to every device), threads it into that guard, and surfaces it as a `Toggle` in the per-video ellipsis menu.

**Tech Stack:** Python 3.14 / FastAPI / SQLite / pytest on the server; Swift 6 / SwiftUI / SwiftPM (`PatataTubeKit`) + XCTest & swift-testing + ViewInspector on iOS.

**Spec:** None. This is a bounded change; the design was agreed in chat and is restated in full under "Design decisions" below. The plan is self-contained.

## Design decisions

Settled with the user before planning; do not re-litigate them mid-implementation:

1. **The flag lives on the server**, as a column on `videos`, exposed in the video JSON and set through a small POST endpoint — the same shape as `audio_lang` / `subtitle_lang`. Rationale: `resume_secs` itself is already server-owned, so a device-local flag would desync from the position it gates.
2. **Turning the toggle off keeps the stored position.** It only stops the prompt appearing. Position keeps being recorded in the background, so switching it back on resumes where playback actually got to. Nothing ever writes `resume_secs = 0` on toggle-off.
3. **Plex rows do not get a toggle.** They already prompt unconditionally. The toggle renders only inside the existing `if !video.isPlexItem` branch of the two cells.
4. **The prompt itself is unchanged.** Same `.ask(secs:)` confirmation dialog, same 60-second floor, same "reaching the end resets to 0" behaviour — a Videos item that remembers behaves identically to a movie.

## Global Constraints

- **Never run the iOS tests unaided.** Neither `swift test` nor `xcodebuild ... test`. They take many minutes on this machine and are the user's call to start (`CLAUDE.md`, "iOS"). Swift tasks below therefore write the test and the implementation and commit; Task 9 is where you *ask* for one authorized verification run. Python tests run freely.
- **There are two iOS test targets.** `ios/PatataTubeKit/Tests/` builds under `swift test`; `ios/PatataTube/Tests/` (target `PatataTubeTests`) only ever builds through `xcodebuild`, so it rots silently. Task 8 touches `ios/PatataTube/Sources/`, so its existing test construction in `VideoRowAudioTests.swift` MUST be updated in the same task or the test build breaks while `./deploy` keeps succeeding.
- **Python test invocation:** `.venv/bin/python -m pytest tests/...`. There is no `pytest.ini`/`pyproject.toml`; async tests carry `@pytest.mark.asyncio` individually (none of the tests below are async).
- **SQLite migrations** go through `_add_column(conn, ddl)` inside `init_db`'s column-check block — it swallows the concurrent-worker duplicate-column race. Never write a bare `ALTER TABLE`.
- **JSON casing:** the server emits snake_case; `APIClient.makeDecoder()` sets `.convertFromSnakeCase`. `remember_position` therefore decodes as `rememberPosition` with no `CodingKeys` entry of its own beyond the camelCase name.
- **Commit message format:** Conventional Commits, imperative subject ≤50 chars, no AI attribution in the body. Each task ends in exactly one commit.

---

### Task 1: Database column and setter

**Files:**
- Modify: `db.py:168-172` (migration block, right after the `resume_secs` column) and `db.py:656-663` (setter, right after `set_resume_secs`)
- Test: `tests/test_db.py` (append after `test_init_db_is_idempotent_with_resume_secs`, currently ending at line 70)

**Interfaces:**
- Consumes: nothing.
- Produces: `db.set_remember_position(video_id: int, on: bool) -> None`, and a `remember_position` key (SQLite integer 0/1) on every row returned by `db.get_video` / `db.list_videos`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_db.py`:

```python
def test_remember_position_defaults_to_off(tmp_db):
    video_id = tmp_db.add_video("https://x.com/i/status/10", "twitter")
    assert tmp_db.get_video(video_id)["remember_position"] == 0


def test_set_remember_position_turns_it_on(tmp_db):
    video_id = tmp_db.add_video("https://x.com/i/status/11", "twitter")
    tmp_db.set_remember_position(video_id, True)
    assert tmp_db.get_video(video_id)["remember_position"] == 1


def test_set_remember_position_turns_it_off_again(tmp_db):
    video_id = tmp_db.add_video("https://x.com/i/status/12", "twitter")
    tmp_db.set_remember_position(video_id, True)
    tmp_db.set_remember_position(video_id, False)
    assert tmp_db.get_video(video_id)["remember_position"] == 0


def test_turning_remember_position_off_keeps_the_stored_position(tmp_db):
    """Off stops the prompt; it must never discard where playback got to."""
    video_id = tmp_db.add_video("https://x.com/i/status/13", "twitter")
    tmp_db.set_resume_secs(video_id, 123.5)
    tmp_db.set_remember_position(video_id, True)
    tmp_db.set_remember_position(video_id, False)
    assert tmp_db.get_video(video_id)["resume_secs"] == 123.5


def test_init_db_is_idempotent_with_remember_position(tmp_db):
    tmp_db.init_db()
    tmp_db.init_db()
    video_id = tmp_db.add_video("https://x.com/i/status/14", "twitter")
    assert tmp_db.get_video(video_id)["remember_position"] == 0
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `.venv/bin/python -m pytest tests/test_db.py -k remember_position -q`
Expected: FAIL — `KeyError: 'remember_position'` on the first test, `AttributeError: module 'db' has no attribute 'set_remember_position'` on the rest.

- [ ] **Step 3: Add the migration**

In `db.py`, immediately after the `resume_secs` block that ends at line 172, insert:

```python
        # Whether this video's stored `resume_secs` may produce a resume
        # prompt. Plex rows prompt unconditionally and ignore this column; a
        # group video prompts only once the user switches it on for that
        # video. Position keeps being recorded either way, so switching it
        # back on resumes where playback actually got to.
        if "remember_position" not in columns:
            _add_column(
                conn,
                "ALTER TABLE videos ADD COLUMN remember_position INTEGER NOT NULL DEFAULT 0",
            )
```

- [ ] **Step 4: Add the setter**

In `db.py`, immediately after `set_resume_secs` (which ends at line 663), insert:

```python
def set_remember_position(video_id: int, on: bool) -> None:
    """Whether this video's resume position may produce a resume prompt.

    Deliberately does not touch `resume_secs`: turning the toggle off only
    silences the prompt, so turning it back on resumes where playback got to.
    """
    with _conn() as conn:
        conn.execute(
            "UPDATE videos SET remember_position = ? WHERE id = ?",
            (1 if on else 0, video_id),
        )
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `.venv/bin/python -m pytest tests/test_db.py -q`
Expected: PASS, whole file green.

- [ ] **Step 6: Commit**

```bash
git add db.py tests/test_db.py
git commit -m "feat(db): add remember_position column"
```

---

### Task 2: Serialize the flag into the video JSON

**Files:**
- Modify: `views/serializers.py:102` (inside the top-level `data` dict of `serialize_video`, next to `"resume_secs"`)
- Test: `tests/test_serializers.py` (append at end of file)

**Interfaces:**
- Consumes: the `remember_position` row key from Task 1.
- Produces: `serialize_video(video)["remember_position"] -> bool`. Always present, for group rows and Plex rows alike — the same unconditional placement `resume_secs` has, so a client never has to branch on row kind to read it.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_serializers.py`:

```python
def test_serialize_remember_position_defaults_to_false():
    assert serialize_video(_library_video())["remember_position"] is False


def test_serialize_remember_position_is_true_when_set():
    assert serialize_video(_library_video(remember_position=1))["remember_position"] is True


def test_serialize_remember_position_is_a_bool_not_an_int():
    """The iOS client decodes this into a Swift Bool; a 0/1 would fail to decode."""
    data = serialize_video(_library_video(remember_position=1))
    assert isinstance(data["remember_position"], bool)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `.venv/bin/python -m pytest tests/test_serializers.py -k remember_position -q`
Expected: FAIL — `KeyError: 'remember_position'`.

- [ ] **Step 3: Add the field**

In `views/serializers.py`, immediately after the `"resume_secs": video.get("resume_secs") or 0,` line (line 102), insert:

```python
        # SQLite stores this as 0/1; the iOS client decodes a Swift Bool, so
        # normalize here rather than leaking the integer into the API.
        "remember_position": bool(video.get("remember_position")),
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `.venv/bin/python -m pytest tests/test_serializers.py -q`
Expected: PASS, whole file green.

- [ ] **Step 5: Commit**

```bash
git add views/serializers.py tests/test_serializers.py
git commit -m "feat(api): expose remember_position in video JSON"
```

---

### Task 3: The POST endpoint

**Files:**
- Modify: `router.py:185-187` (add the request model right after `SubtitleRequest`) and `router.py:1149` (add the endpoint right after `api_save_position`, before `api_delete_video`)
- Test: `tests/test_api.py` (append after `test_position_requires_secs`, at the end of the position test block)

**Interfaces:**
- Consumes: `db.set_remember_position` from Task 1.
- Produces: `POST /api/videos/{video_id}/remember-position`, body `{"on": bool}`, bearer-token authed, `{"ok": true}` on success, 401 without a token, 404 for an unknown or soft-deleted video, 422 for a missing/non-boolean `on`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_api.py` (the module-level helper `_make_done_video(client, monkeypatch, url=...)` is already defined at line 2080 — reuse it, do not redefine it):

```python
def test_remember_position_requires_token(client):
    resp = client.post("/api/videos/1/remember-position", json={"on": True})
    assert resp.status_code == 401


def test_remember_position_turns_on(client, monkeypatch):
    import db
    video_id = _make_done_video(client, monkeypatch, "https://twitter.com/x/status/910")
    resp = client.post(
        f"/api/videos/{video_id}/remember-position",
        json={"on": True},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 200
    assert resp.json() == {"ok": True}
    assert db.get_video(video_id)["remember_position"] == 1


def test_remember_position_turns_off(client, monkeypatch):
    import db
    video_id = _make_done_video(client, monkeypatch, "https://twitter.com/x/status/911")
    db.set_remember_position(video_id, True)
    resp = client.post(
        f"/api/videos/{video_id}/remember-position",
        json={"on": False},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 200
    assert db.get_video(video_id)["remember_position"] == 0


def test_remember_position_off_keeps_resume_secs(client, monkeypatch):
    import db
    video_id = _make_done_video(client, monkeypatch, "https://twitter.com/x/status/912")
    db.set_resume_secs(video_id, 91.5)
    client.post(
        f"/api/videos/{video_id}/remember-position",
        json={"on": False},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert db.get_video(video_id)["resume_secs"] == 91.5


def test_remember_position_unknown_video_is_404(client):
    resp = client.post(
        "/api/videos/999999/remember-position",
        json={"on": True},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 404


def test_remember_position_requires_on(client, monkeypatch):
    video_id = _make_done_video(client, monkeypatch, "https://twitter.com/x/status/913")
    resp = client.post(
        f"/api/videos/{video_id}/remember-position",
        json={},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 422


def test_video_list_exposes_remember_position(client, monkeypatch):
    import db
    video_id = _make_done_video(client, monkeypatch, "https://twitter.com/x/status/914")
    db.set_remember_position(video_id, True)
    resp = client.get("/api/videos")  # this route is unauthenticated, unlike the POSTs
    assert resp.status_code == 200
    row = next(v for v in resp.json() if v["id"] == video_id)
    assert row["remember_position"] is True
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `.venv/bin/python -m pytest tests/test_api.py -k remember_position -q`
Expected: FAIL — 404 from FastAPI for the unrouted path on most, and `AttributeError` on `db.set_remember_position` only if Task 1 was skipped.

- [ ] **Step 3: Add the request model**

In `router.py`, immediately after the `SubtitleRequest` class (which ends at line 187, before `class PositionRequest`), insert:

```python
class RememberPositionRequest(BaseModel):
    on: bool
```

- [ ] **Step 4: Add the endpoint**

In `router.py`, immediately after `api_save_position` (its `return Response(status_code=204)` at line 1149) and before `@router.post("/api/video/{video_id}/delete")`, insert:

```python
@router.post("/api/videos/{video_id}/remember-position")
async def api_set_remember_position(
    video_id: int, body: RememberPositionRequest, request: Request
):
    """Opt one video into the resume prompt.

    Plex rows prompt unconditionally, so in practice this only matters for
    group videos — the Videos tab is the only place the toggle is shown.
    Turning it off does not clear `resume_secs`: the position keeps being
    reported, so switching it back on resumes where playback got to.
    """
    _check_token(request)
    video = db.get_video(video_id)
    if not video or video.get("deleted_at"):
        raise HTTPException(status_code=404, detail="Video not found")
    db.set_remember_position(video_id, body.on)
    return {"ok": True}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `.venv/bin/python -m pytest tests/test_api.py -q`
Expected: PASS — 181 pre-existing tests plus the 7 new ones, all green.

- [ ] **Step 6: Commit**

```bash
git add router.py tests/test_api.py
git commit -m "feat(api): add remember-position endpoint"
```

---

### Task 4: `Video.rememberPosition`

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/Video.swift` — property (after `resumeSecs`, line 82), `CodingKeys` (line 93), memberwise `init` signature (line 116) and body (line 130), `init(from:)` (line 164), and the four `Video(...)` constructions inside `withChosenVersion(_:Int?)`, `withGroupID`, `withAudioLang`, `withSubtitleLang`
- Create: `ios/PatataTubeKit/Tests/PatataTubeKitTests/RememberPositionAPITests.swift`

**Interfaces:**
- Consumes: the `remember_position` JSON key from Task 2.
- Produces: `Video.rememberPosition: Bool` (memberwise-init parameter `rememberPosition: Bool = false`, placed between `resumeSecs:` and `channel:`) and `Video.withRememberPosition(_ on: Bool) -> Video`.

- [ ] **Step 1: Write the failing test**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/RememberPositionAPITests.swift`. It nests inside the existing `APIClientTests` suite for the same reason `ResumePositionAPITests.swift` does — `MockURLProtocol`'s handler is global to the test process, so every suite that touches it must be serialized under that one parent:

```swift
import Testing
import Foundation
@testable import PatataTubeKit

// Nested in the one serialized APIClientTests suite because MockURLProtocol's
// handler is global to the test process.
extension APIClientTests {
    struct RememberPositionTests {
        @Test func videoDecodesRememberPosition() throws {
            let json = """
            {"id": 1, "url": "u", "group_id": 3, "plex_kind": null, "status": "done",
             "stream_path": "/videos/1/stream", "remember_position": true}
            """.data(using: .utf8)!
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let video = try decoder.decode(Video.self, from: json)
            #expect(video.rememberPosition)
        }

        @Test func videoRememberPositionDefaultsToFalseWhenMissing() throws {
            // An offline VideoListCache written before this feature shipped has
            // no such key; it must still decode rather than poisoning the list.
            let json = """
            {"id": 1, "url": "u", "group_id": 3, "plex_kind": null, "status": "done",
             "stream_path": "/videos/1/stream"}
            """.data(using: .utf8)!
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let video = try decoder.decode(Video.self, from: json)
            #expect(video.rememberPosition == false)
        }

        @Test func withRememberPositionFlipsOnlyThatField() {
            let video = Video(
                id: 7, url: "u", title: "t", platform: nil, sourceKey: nil,
                previewUrl: nil, groupID: 3, plexKind: nil, position: nil,
                status: "done", errorMsg: nil, streamPath: "/videos/7/stream",
                subtitleLang: "es", resumeSecs: 91.5
            )
            let flipped = video.withRememberPosition(true)
            #expect(flipped.rememberPosition)
            #expect(flipped.resumeSecs == 91.5)
            #expect(flipped.subtitleLang == "es")
            #expect(flipped.id == 7)
        }

        @Test func theOtherCopyHelpersCarryRememberPositionThrough() {
            // Every `with…` helper rebuilds Video field by field, so a new
            // stored property is silently dropped unless each one passes it.
            let video = Video(
                id: 7, url: "u", title: "t", platform: nil, sourceKey: nil,
                previewUrl: nil, groupID: 3, plexKind: nil, position: nil,
                status: "done", errorMsg: nil, streamPath: "/videos/7/stream",
                rememberPosition: true
            )
            #expect(video.withGroupID(9).rememberPosition)
            #expect(video.withAudioLang("spa").rememberPosition)
            #expect(video.withSubtitleLang("es").rememberPosition)
            #expect(video.withChosenVersion(nil).rememberPosition)
        }
    }
}
```

- [ ] **Step 2: Do NOT run the Swift tests**

Per the Global Constraints, `swift test` is the user's call. Move straight to the implementation; Task 9 verifies.

- [ ] **Step 3: Add the stored property, coding key, and init plumbing**

In `Video.swift`:

a. After `public let resumeSecs: Double` (line 82), add:

```swift
    /// Whether this video's `resumeSecs` may produce a resume prompt. Plex
    /// rows prompt regardless; a group video prompts only once the user turns
    /// this on from the Videos tab. Position is recorded either way.
    public let rememberPosition: Bool
```

b. In `CodingKeys`, after `case resumeSecs` (line 93), add:

```swift
        case rememberPosition
```

c. In the memberwise `init`, change the tail of the signature from:

```swift
            resumeSecs: Double = 0,
            channel: String? = nil) {
```

to:

```swift
            resumeSecs: Double = 0,
            rememberPosition: Bool = false,
            channel: String? = nil) {
```

d. In that init's body, after `self.resumeSecs = resumeSecs` (line 130), add:

```swift
        self.rememberPosition = rememberPosition
```

e. In `init(from:)`, after `self.resumeSecs = try c.decodeIfPresent(Double.self, forKey: .resumeSecs) ?? 0` (line 164), add:

```swift
        self.rememberPosition = try c.decodeIfPresent(Bool.self, forKey: .rememberPosition) ?? false
```

- [ ] **Step 4: Carry it through every copy helper**

Four `with…` helpers rebuild `Video` field by field and each ends with the same line. Replace **all four** occurrences of:

```swift
              resumeSecs: resumeSecs, channel: channel)
```

with:

```swift
              resumeSecs: resumeSecs, rememberPosition: rememberPosition, channel: channel)
```

(They are in `withChosenVersion(_:Int?)`, `withGroupID`, `withAudioLang`, and `withSubtitleLang`. `withChosenVersion(_:Int)` delegates to the optional overload and needs no change.)

- [ ] **Step 5: Add the new copy helper**

Immediately after `withSubtitleLang` (it ends at line 223), insert:

```swift
    func withRememberPosition(_ on: Bool) -> Video {
        return Video(id: id, url: url, title: title, platform: platform, sourceKey: sourceKey,
              previewUrl: previewUrl, groupID: groupID, plexKind: plexKind, position: position,
              status: status, errorMsg: errorMsg, streamPath: streamPath,
              source: source, showTitle: showTitle, season: season,
              episode: episode, summary: summary, showPreviewUrl: showPreviewUrl,
              chosenVersionId: chosenVersionId, versions: versions,
              hlsPath: hlsPath, subtitleTracks: subtitleTracks,
              sourceFilename: sourceFilename, audioLang: audioLang, subtitleLang: subtitleLang,
              resumeSecs: resumeSecs, rememberPosition: on, channel: channel)
    }
```

- [ ] **Step 6: Build the package (build only, not test)**

Run: `cd ios/PatataTubeKit && swift build`
Expected: succeeds. A build is not a test run and is not covered by the "never run iOS tests" rule; it catches a dropped argument in seconds.

- [ ] **Step 7: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/Video.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/RememberPositionAPITests.swift
git commit -m "feat(ios): decode rememberPosition on Video"
```

---

### Task 5: Let the flag open the resume gate

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/ResumeDecision.swift` (the doc comment and the `decide` signature/guard)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/ResumeDecisionTests.swift` (append inside the existing `ResumeDecisionTests` XCTestCase — this file is XCTest, not swift-testing; match it)

**Interfaces:**
- Consumes: `Video.rememberPosition` from Task 4 (conceptually; `decide` takes a plain `Bool`, not a `Video`).
- Produces: `ResumeDecision.decide(resumeSecs: Double, plexKind: PlexKind?, remembersPosition: Bool = false, minimumSecs: Double = ResumeDecision.defaultMinimumSecs) -> ResumeDecision`. The default keeps every existing call site and test compiling unchanged.

- [ ] **Step 1: Write the failing tests**

Append inside the `final class ResumeDecisionTests: XCTestCase { ... }` body in `ResumeDecisionTests.swift`, before its closing brace:

```swift
    func testAsksForAGroupVideoThatRemembersPosition() {
        XCTAssertEqual(
            ResumeDecision.decide(resumeSecs: 120, plexKind: nil, remembersPosition: true),
            .ask(secs: 120)
        )
    }

    func testDoesNotAskForAGroupVideoThatDoesNotRemember() {
        XCTAssertEqual(
            ResumeDecision.decide(resumeSecs: 120, plexKind: nil, remembersPosition: false),
            .playFromStart
        )
    }

    func testARememberingGroupVideoStillRespectsTheFloor() {
        XCTAssertEqual(
            ResumeDecision.decide(resumeSecs: 59.9, plexKind: nil, remembersPosition: true),
            .playFromStart
        )
    }

    func testARememberingGroupVideoAsksAtExactlyTheFloor() {
        XCTAssertEqual(
            ResumeDecision.decide(resumeSecs: 60.0, plexKind: nil, remembersPosition: true),
            .ask(secs: 60.0)
        )
    }

    func testAFinishedRememberingGroupVideoDoesNotAsk() {
        // The reporter writes 0 once playback reaches the final seconds, so a
        // watched video reads as playFromStart without any extra upper bound.
        XCTAssertEqual(
            ResumeDecision.decide(resumeSecs: 0, plexKind: nil, remembersPosition: true),
            .playFromStart
        )
    }

    func testAPlexItemStillAsksWithoutTheFlag() {
        XCTAssertEqual(
            ResumeDecision.decide(resumeSecs: 120, plexKind: .movies, remembersPosition: false),
            .ask(secs: 120)
        )
    }
```

- [ ] **Step 2: Do NOT run the Swift tests**

Move to the implementation; Task 9 verifies.

- [ ] **Step 3: Widen the gate**

In `ResumeDecision.swift`, replace the doc comment above `decide` and the function's first two lines. The whole `decide` becomes:

```swift
    /// A Plex item always prompts. A group video prompts only when the user
    /// turned "Remember position" on for it in the Videos tab — position is
    /// recorded for every video, so the flag is what decides whether that
    /// recorded position is allowed to interrupt the next tap.
    public static func decide(
        resumeSecs: Double,
        plexKind: PlexKind?,
        remembersPosition: Bool = false,
        minimumSecs: Double = ResumeDecision.defaultMinimumSecs
    ) -> ResumeDecision {
        guard plexKind != nil || remembersPosition else { return .playFromStart }
        guard resumeSecs >= minimumSecs else { return .playFromStart }
        return .ask(secs: resumeSecs)
    }
```

Also update the type's own doc comment: change the line `/// Only Plex rows ever prompt, and only past a floor —` to `/// Plex rows and opted-in Videos rows prompt, and only past a floor —`.

- [ ] **Step 4: Build the package**

Run: `cd ios/PatataTubeKit && swift build`
Expected: succeeds.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/ResumeDecision.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/ResumeDecisionTests.swift
git commit -m "feat(ios): let opted-in videos offer resume"
```

---

### Task 6: `APIClient.setRememberPosition`

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/APIClient.swift` — the `VideoAPI` protocol (after `chooseSubtitle`, line 29), the `public extension VideoAPI` defaults (after `chooseSubtitle`, line 56), and the `APIClient` implementation (after `chooseSubtitle`, line 170)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/RememberPositionAPITests.swift` (append inside the `RememberPositionTests` struct from Task 4)

**Interfaces:**
- Consumes: the endpoint from Task 3.
- Produces: `VideoAPI.setRememberPosition(id: Int, on: Bool) async throws -> Bool`, defaulted to `false` in the protocol extension so the many existing test doubles conforming to `VideoAPI` keep compiling without implementing it.

- [ ] **Step 1: Write the failing tests**

Append inside the `struct RememberPositionTests { ... }` body, before its closing brace:

```swift
        @Test func setRememberPositionPostsTheFlag() async throws {
            MockURLProtocol.handler = { request in
                #expect(request.httpMethod == "POST")
                #expect(request.url?.path == "/api/videos/12/remember-position")
                let json = try JSONSerialization.jsonObject(
                    with: request.httpBodyData()
                ) as? [String: Bool]
                #expect(json?["on"] == true)
                return (jsonResponse(request.url!, status: 200), Data("{\"ok\": true}".utf8))
            }

            let ok = try await makeClient(statusToken: "tok")
                .setRememberPosition(id: 12, on: true)
            #expect(ok)
        }

        @Test func setRememberPositionPostsFalse() async throws {
            MockURLProtocol.handler = { request in
                let json = try JSONSerialization.jsonObject(
                    with: request.httpBodyData()
                ) as? [String: Bool]
                #expect(json?["on"] == false)
                return (jsonResponse(request.url!, status: 200), Data("{\"ok\": true}".utf8))
            }

            let ok = try await makeClient(statusToken: "tok")
                .setRememberPosition(id: 12, on: false)
            #expect(ok)
        }

        @Test func setRememberPositionThrowsOnBadStatus() async {
            MockURLProtocol.handler = { request in
                (jsonResponse(request.url!, status: 404), Data())
            }
            await #expect(throws: APIError.badStatus(404)) {
                _ = try await makeClient(statusToken: "tok")
                    .setRememberPosition(id: 12, on: true)
            }
        }
```

- [ ] **Step 2: Do NOT run the Swift tests**

Move to the implementation; Task 9 verifies.

- [ ] **Step 3: Declare it on the protocol**

In `APIClient.swift`, after `func chooseSubtitle(id: Int, lang: String?) async throws -> Bool` in the `VideoAPI` protocol (line 29), add:

```swift
    func setRememberPosition(id: Int, on: Bool) async throws -> Bool
```

- [ ] **Step 4: Add the test-double default**

In `public extension VideoAPI`, after `func chooseSubtitle(id: Int, lang: String?) async throws -> Bool { false }` (line 56), add:

```swift
    func setRememberPosition(id: Int, on: Bool) async throws -> Bool { false }
```

- [ ] **Step 5: Implement it on `APIClient`**

After `public func chooseSubtitle(...)` (it ends at line 170), add:

```swift
    public func setRememberPosition(id: Int, on: Bool) async throws -> Bool {
        try await postOK("api/videos/\(id)/remember-position", body: ["on": on])
    }
```

- [ ] **Step 6: Build the package**

Run: `cd ios/PatataTubeKit && swift build`
Expected: succeeds.

- [ ] **Step 7: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/APIClient.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/RememberPositionAPITests.swift
git commit -m "feat(ios): post the remember-position flag"
```

---

### Task 7: `VideoStore.setRememberPosition`

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/VideoStore.swift` (after `chooseSubtitle`, lines 387-398)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoStoreTests.swift` — add a stub + two counters to the private `FakeAPI` (near the other mutators, lines 78-110) and append the tests after `chooseSubtitleRevertsWhenServerReturnsNotOk` (line 1122)

**Interfaces:**
- Consumes: `VideoAPI.setRememberPosition` (Task 6) and `Video.withRememberPosition` (Task 4).
- Produces: `@MainActor VideoStore.setRememberPosition(id: Int, _ on: Bool) async` — optimistic local write, reverted when the server answers not-ok or throws. Signature mirrors `chooseSubtitle(id:lang:)` so the call site in Task 8 reads the same as its neighbours.

- [ ] **Step 1: Extend the test double**

In `VideoStoreTests.swift`, next to `var chooseSubtitleResult = true` / `private(set) var chosenSubtitle: [(id: Int, lang: String?)] = []` (lines 82-83), add:

```swift
    var setRememberPositionResult = true
    private(set) var rememberPositionCalls: [(id: Int, on: Bool)] = []
```

and next to the `func chooseSubtitle(...)` stub (lines 106-109), add:

```swift
    func setRememberPosition(id: Int, on: Bool) async throws -> Bool {
        if let mutationError { throw mutationError }
        rememberPositionCalls.append((id, on))
        return setRememberPositionResult
    }
```

- [ ] **Step 2: Write the failing tests**

Append after `chooseSubtitleRevertsWhenServerReturnsNotOk` (which ends at line 1122). This file is swift-testing, not XCTest — match the `@MainActor @Test func` shape of its neighbours:

```swift
@MainActor @Test func setRememberPositionOptimisticallyUpdates() async {
    let api = FakeAPI()
    api.videosToReturn = [makeVideo(id: 1)]
    let store = VideoStore(api: api, defaults: makeDefaults())
    await store.load()

    await store.setRememberPosition(id: 1, true)

    #expect(api.rememberPositionCalls.map(\.id) == [1])
    #expect(api.rememberPositionCalls.map(\.on) == [true])
    #expect(store.videos[0].rememberPosition)
    #expect(api.loadCount == 1)
}

@MainActor @Test func setRememberPositionRevertsWhenServerReturnsNotOk() async {
    let api = FakeAPI()
    api.videosToReturn = [makeVideo(id: 1)]
    api.setRememberPositionResult = false
    let store = VideoStore(api: api, defaults: makeDefaults())
    await store.load()

    await store.setRememberPosition(id: 1, true)

    #expect(store.videos[0].rememberPosition == false)
}

@MainActor @Test func setRememberPositionRevertsWhenTheRequestThrows() async {
    let api = FakeAPI()
    api.videosToReturn = [makeVideo(id: 1)]
    api.mutationError = APIError.badStatus(500)
    let store = VideoStore(api: api, defaults: makeDefaults())
    await store.load()

    await store.setRememberPosition(id: 1, true)

    #expect(store.videos[0].rememberPosition == false)
}

@MainActor @Test func setRememberPositionIgnoresAnUnknownID() async {
    let api = FakeAPI()
    api.videosToReturn = [makeVideo(id: 1)]
    let store = VideoStore(api: api, defaults: makeDefaults())
    await store.load()

    await store.setRememberPosition(id: 999, true)

    #expect(api.rememberPositionCalls.isEmpty)
}

@MainActor @Test func setRememberPositionLeavesResumeSecsAlone() async {
    // Off must never discard the stored position: the toggle gates the
    // prompt, it does not reset progress.
    let api = FakeAPI()
    api.videosToReturn = [makeVideo(id: 1, resumeSecs: 91.5)]
    let store = VideoStore(api: api, defaults: makeDefaults())
    await store.load()

    await store.setRememberPosition(id: 1, false)

    #expect(store.videos[0].resumeSecs == 91.5)
}
```

- [ ] **Step 3: Do NOT run the Swift tests**

Move to the implementation; Task 9 verifies.

- [ ] **Step 4: Implement the store method**

In `VideoStore.swift`, immediately after `chooseSubtitle` (it ends at line 398), add:

```swift
    /// Opts one video into the resume prompt. Optimistic like the other
    /// per-video writes here — the menu's switch flips at once and a rejected
    /// or failed request puts it back. Never touches `resumeSecs`.
    public func setRememberPosition(id: Int, _ on: Bool) async {
        guard let index = videos.firstIndex(where: { $0.id == id }) else { return }
        let previous = videos[index]
        videos[index] = videos[index].withRememberPosition(on)
        do {
            let ok = try await api.setRememberPosition(id: id, on: on)
            if !ok { videos[index] = previous }
        } catch {
            videos[index] = previous
            report(error)
        }
    }
```

- [ ] **Step 5: Build the package**

Run: `cd ios/PatataTubeKit && swift build`
Expected: succeeds.

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/VideoStore.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoStoreTests.swift
git commit -m "feat(ios): toggle remember position in VideoStore"
```

---

### Task 8: The toggle in the Videos menus

**Files:**
- Modify: `ios/PatataTube/Sources/VideoRow.swift` (callback property after `onChooseVersion`, line 33; the menu's `if !video.isPlexItem` block, lines 141-150)
- Modify: `ios/PatataTube/Sources/VideoCell.swift` (callback property after `onChooseVersion`, line 30; the menu's `if !video.isPlexItem` block, lines 146-155)
- Modify: `ios/PatataTube/Sources/VideoGridView.swift` (both cell call sites, after `onChooseVersion:` at lines 549 and 573; and `startPlayback`'s `decide` call at lines 1062-1063)
- Modify: `ios/PatataTube/Tests/VideoRowAudioTests.swift:25-32` (the existing `VideoRow(...)` construction — it must gain the new argument or the `PatataTubeTests` target stops building)

**Interfaces:**
- Consumes: `VideoStore.setRememberPosition(id:_:)` (Task 7), `Video.rememberPosition` (Task 4), and `ResumeDecision.decide(resumeSecs:plexKind:remembersPosition:)` (Task 5).
- Produces: nothing further tasks depend on. This is the last code task.

**Why this is confined to the Videos section:** `VideoRow` and `VideoCell` are built only by `VideoGridView.defaultGrid`, which renders for the `.videos` tab. `.movies` renders `moviesGrid` (`MovieRow`/`MovieCell`) and `.tv` renders `ShowsView`. The `if !video.isPlexItem` guard is belt-and-braces on top of that.

- [ ] **Step 1: Add the callback to `VideoRow`**

In `VideoRow.swift`, after `let onChooseVersion: (Int) -> Void` (line 33), add:

```swift
    /// Videos-tab only: opt this video into the resume prompt.
    let onSetRememberPosition: (Bool) -> Void
```

- [ ] **Step 2: Add the toggle to `VideoRow`'s menu**

In `VideoRow.swift`, inside `private var menu`, the block currently reads:

```swift
            if !video.isPlexItem {
                ForEach(groups) { group in
                    Button(group.label) { onSetGroup(group.id) }
                }
```

Insert the toggle as the first thing in that block, so it sits above the group list:

```swift
            if !video.isPlexItem {
                Toggle(isOn: Binding(
                    get: { video.rememberPosition },
                    set: { onSetRememberPosition($0) }
                )) {
                    Label("Remember position", systemImage: "clock.arrow.circlepath")
                }

                ForEach(groups) { group in
                    Button(group.label) { onSetGroup(group.id) }
                }
```

- [ ] **Step 3: Add the callback to `VideoCell`**

In `VideoCell.swift`, after `let onChooseVersion: (Int) -> Void` (line 30), add:

```swift
    /// Videos-tab only: opt this video into the resume prompt.
    let onSetRememberPosition: (Bool) -> Void
```

- [ ] **Step 4: Add the toggle to `VideoCell`'s menu**

In `VideoCell.swift`, the menu block currently reads:

```swift
                    Button("Info", systemImage: "info.circle") { showingInfo = true }
                    if !video.isPlexItem {
                        ForEach(groups) { group in
                            Button(group.label) { onSetGroup(group.id) }
                        }
```

Insert the same toggle as the first thing inside the `if`:

```swift
                    Button("Info", systemImage: "info.circle") { showingInfo = true }
                    if !video.isPlexItem {
                        Toggle(isOn: Binding(
                            get: { video.rememberPosition },
                            set: { onSetRememberPosition($0) }
                        )) {
                            Label("Remember position", systemImage: "clock.arrow.circlepath")
                        }

                        ForEach(groups) { group in
                            Button(group.label) { onSetGroup(group.id) }
                        }
```

- [ ] **Step 5: Wire both call sites in `VideoGridView`**

In `VideoGridView.swift`, in the `VideoRow(` construction, after the `onChooseVersion:` line (line 549), add:

```swift
                            onSetRememberPosition: { on in
                                Task { await store.setRememberPosition(id: video.id, on) }
                            },
```

and in the `VideoCell(` construction, after its `onChooseVersion:` line (line 573), add the same with that block's indentation:

```swift
                            onSetRememberPosition: { on in
                                Task { await store.setRememberPosition(id: video.id, on) }
                            },
```

- [ ] **Step 6: Pass the flag into the resume gate**

In `VideoGridView.swift`'s `startPlayback`, change:

```swift
        switch ResumeDecision.decide(resumeSecs: secs, plexKind: video.plexKind) {
```

to:

```swift
        switch ResumeDecision.decide(resumeSecs: secs, plexKind: video.plexKind,
                                     remembersPosition: video.rememberPosition) {
```

Also update the comment three lines above it — `/// tv/movies rows with real progress stop here and ask first.` becomes `/// tv/movies rows, and Videos rows that remember, stop here and ask first.`

- [ ] **Step 7: Repair the app-target test construction**

`ios/PatataTube/Tests/` only builds under `xcodebuild`, so a stale constructor there breaks the *test* build while `./deploy` keeps succeeding — exactly the rot `CLAUDE.md` warns about. In `VideoRowAudioTests.swift`, change:

```swift
                onDeleteCache: {}, onSetGroup: { _ in }, onPromote: { _ in },
                onChooseVersion: { _ in }, onDelete: {}
```

to:

```swift
                onDeleteCache: {}, onSetGroup: { _ in }, onPromote: { _ in },
                onChooseVersion: { _ in }, onDelete: {},
                onSetRememberPosition: { _ in }
```

- [ ] **Step 8: Build the app (build only, not test)**

Run:

```bash
cd ios/PatataTube && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube \
  -destination 'generic/platform=iOS Simulator' build
```

Expected: `BUILD SUCCEEDED`. `generic/platform=iOS Simulator` is fine for `build` and rejected by anything that runs tests — this step deliberately does not run tests.

- [ ] **Step 9: Commit**

```bash
git add ios/PatataTube/Sources/VideoRow.swift ios/PatataTube/Sources/VideoCell.swift \
        ios/PatataTube/Sources/VideoGridView.swift ios/PatataTube/Tests/VideoRowAudioTests.swift
git commit -m "feat(ios): add Remember position toggle to Videos"
```

---

### Task 9: Verification

**Files:** none modified.

**Interfaces:** none.

- [ ] **Step 1: Run the full Python suite**

Run: `.venv/bin/python -m pytest tests/ -q`
Expected: PASS. Report the count.

- [ ] **Step 2: Ask the user before running any iOS test**

Do not start these yourself. Say which suites cover the change and ask for authorization:

- `cd ios/PatataTubeKit && swift test` — covers Tasks 4-7 (`RememberPositionAPITests`, `ResumeDecisionTests`, `VideoStoreTests`).
- `cd ios/PatataTube && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination "platform=iOS Simulator,id=$(xcrun simctl list devices available | grep -m1 -o '[0-9A-F-]\{36\}')" test` — covers Task 8's target. Run the **whole** target; `-only-testing:` hangs indefinitely on this project.

- [ ] **Step 3: If authorized, run them and read the results carefully**

Known pre-existing noise, per `CLAUDE.md`: a full parallel `swift test` run prints a `Fatal error: Index out of range` from the swift-testing suites and can show unrelated flaky `VideoStoreTests` failures that do not reproduce under a targeted run. Re-run any failure in isolation before calling it a regression.

- [ ] **Step 4: Manual check on device or simulator**

1. Videos tab → a group with a video longer than a couple of minutes → ellipsis menu shows **Remember position**, off.
2. Turn it on, play past 60s, dismiss the player, tap the video again → the resume prompt appears with the right timestamp.
3. Turn the toggle off, tap again → plays from the start, no prompt.
4. Turn it back on, tap again → the prompt returns with the position still there (proves off did not clear `resume_secs`).
5. Movies tab → ellipsis menu shows **no** Remember position entry, and resume still works there unchanged.

---

## Self-review notes

- **Coverage:** each of the four design decisions maps to tasks — server-owned flag (1-3), off-keeps-position (asserted in Tasks 1, 3 and 7), no toggle on Plex rows (Task 8, `if !video.isPlexItem`), unchanged prompt (Task 5 reuses the same floor and `.ask` case).
- **Name consistency:** `remember_position` on the wire and in SQLite; `rememberPosition` on `Video`; `setRememberPosition(id:on:)` on `VideoAPI`/`APIClient`; `setRememberPosition(id:_:)` on `VideoStore` (unlabeled second argument, matching `chooseSubtitle`'s neighbours in the call site); `remembersPosition:` as the `ResumeDecision.decide` parameter. These differ deliberately and are used consistently across tasks.
- **Not in scope:** the SSR web views under `views/templates/` get no toggle — the resume prompt is an iOS-player feature and the templates have no player that reads `resume_secs`.
