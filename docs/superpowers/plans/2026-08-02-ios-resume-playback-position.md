# Resume Playback Position Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the user taps play on a `tv` or `movies` row that has meaningful saved progress, ask "Resume from 24:13" or "Play from start"; the position lives on the server.

**Architecture:** A new `videos.resume_secs` column plus a token-gated `POST /api/videos/{id}/position` endpoint hold the position. The iOS player reports its time every 10s and on every exit; writes are mirrored into `UserDefaults` so offline playback still resumes and unsent writes flush later. A pure `ResumeDecision` function decides whether the alert appears; auto-advance in the player never consults it.

**Tech Stack:** FastAPI + SQLite (`db.py`, `router.py`, `views/serializers.py`), pytest; SwiftUI app (`ios/PatataTube`) + SwiftPM logic package (`ios/PatataTubeKit`), swift-testing/XCTest.

## Global Constraints

- Position storage is server-side (`videos.resume_secs`), one value per video row, no per-device split.
- Modal appears only for rows whose `classification` is `tv` or `movies`, and only when the saved position is at least **60 seconds**.
- Reaching the end clears the stored position to `0` (client sends 0 when within **30 seconds** of the end).
- Save cadence: every **10 seconds** while playing, plus a forced write on pause, dismiss, background, and queue advance.
- Local mirror in `UserDefaults` is best-effort backup: it answers reads when offline and flushes pending writes when the API succeeds again.
- Auto-advance (next episode / autoplay / randomize) always starts at 0 and never shows the alert.
- Schema changes go into `db.init_db` as additive idempotent guards — no migrations framework.
- New async pytest tests must carry `@pytest.mark.asyncio` (no global asyncio mode). The tests here are sync TestClient tests, so none need it.
- Never log tokens or response bodies through `DevLog`; ids/seconds/status codes only.

---

### Task 1: Store the position in SQLite

**Files:**
- Modify: `db.py:136-147` (column guards inside `init_db`), and after `set_audio_lang` (`db.py:516-519`)
- Modify: `views/serializers.py` (the `data` dict in `serialize_video`)
- Test: `tests/test_db.py`, `tests/test_serializers.py`

**Interfaces:**
- Consumes: nothing.
- Produces: `db.set_resume_secs(video_id: int, secs: float) -> None`; `serialize_video` output gains `"resume_secs": float`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_db.py` (follow the module's existing fixture style — it already sets `DB_PATH` and reloads `db`; reuse whatever fixture the neighbouring tests use, e.g. `db_module`):

```python
def test_set_resume_secs_round_trips(db_module):
    video_id = db_module.add_video("https://x.com/i/status/1", "twitter")
    db_module.set_resume_secs(video_id, 123.5)
    assert db_module.get_video(video_id)["resume_secs"] == 123.5


def test_resume_secs_defaults_to_zero(db_module):
    video_id = db_module.add_video("https://x.com/i/status/2", "twitter")
    assert db_module.get_video(video_id)["resume_secs"] == 0


def test_set_resume_secs_clamps_negative(db_module):
    video_id = db_module.add_video("https://x.com/i/status/3", "twitter")
    db_module.set_resume_secs(video_id, -5)
    assert db_module.get_video(video_id)["resume_secs"] == 0


def test_init_db_is_idempotent_with_resume_secs(db_module):
    db_module.init_db()
    db_module.init_db()
    video_id = db_module.add_video("https://x.com/i/status/4", "twitter")
    assert db_module.get_video(video_id)["resume_secs"] == 0
```

If `add_video` in this repo needs more arguments, copy the exact call used by
the nearest existing test in `tests/test_db.py` rather than inventing one.

Append to `tests/test_serializers.py`:

```python
def test_serialize_video_exposes_resume_secs():
    from views.serializers import serialize_video

    data = serialize_video({
        "id": 7,
        "url": "https://x.com/i/status/7",
        "status": "done",
        "resume_secs": 61.25,
    })
    assert data["resume_secs"] == 61.25


def test_serialize_video_resume_secs_defaults_to_zero():
    from views.serializers import serialize_video

    data = serialize_video({"id": 8, "url": "u", "status": "done"})
    assert data["resume_secs"] == 0
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `python -m pytest tests/test_db.py -k resume -v tests/test_serializers.py -k resume`

Simplest split if the combined invocation is awkward:

```bash
python -m pytest tests/test_db.py -k resume -v
python -m pytest tests/test_serializers.py -k resume -v
```

Expected: FAIL — `AttributeError: module 'db' has no attribute 'set_resume_secs'` and `KeyError: 'resume_secs'`.

- [ ] **Step 3: Add the column guard**

In `db.py`, inside `init_db`, next to the other `if "<col>" not in columns:` guards (right after the `show_preview_version` guard):

```python
        # Playback resume point in seconds, written by the iOS player every
        # ~10s and on exit. 0 means "start from the beginning" — reaching the
        # end of a video resets it to 0, so a finished video never prompts.
        if "resume_secs" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN resume_secs REAL NOT NULL DEFAULT 0")
```

- [ ] **Step 4: Add the setter**

In `db.py`, directly after `set_audio_lang`:

```python
def set_resume_secs(video_id: int, secs: float) -> None:
    """Persist where playback got to. Negative input clamps to 0."""
    value = max(0.0, float(secs))
    with _conn() as conn:
        conn.execute("UPDATE videos SET resume_secs = ? WHERE id = ?", (value, video_id))
```

- [ ] **Step 5: Expose it in the API shape**

In `views/serializers.py`, inside the `data = {...}` literal in `serialize_video`, add after the `"position"` entry:

```python
        "resume_secs": video.get("resume_secs") or 0,
```

- [ ] **Step 6: Run the tests and the full suite**

```bash
python -m pytest tests/test_db.py -k resume -v
python -m pytest tests/test_serializers.py -k resume -v
python -m pytest tests/
```

Expected: the new tests PASS, and the rest of the suite is unchanged.

- [ ] **Step 7: Commit**

```bash
git add db.py views/serializers.py tests/test_db.py tests/test_serializers.py
git commit -m "feat(db): store playback resume position per video"
```

---

### Task 2: The position endpoint

**Files:**
- Modify: `router.py:144-152` (request models), `router.py:833-867` (add the route after `api_choose_audio`)
- Test: `tests/test_api.py`

**Interfaces:**
- Consumes: `db.set_resume_secs` from Task 1.
- Produces: `POST /api/videos/{video_id}/position`, Bearer-authed, JSON body `{"secs": <float>}`, `204 No Content` on success, `401` unauthenticated, `404` for missing/tombstoned rows, `422` for a missing/non-numeric `secs`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_api.py`:

```python
def _make_done_video(client, monkeypatch, url="https://twitter.com/x/status/900"):
    """Insert a row directly; the API's own upload path schedules downloads."""
    import db
    return db.add_video(url, "twitter")


def test_position_requires_token(client):
    resp = client.post("/api/videos/1/position", json={"secs": 12.0})
    assert resp.status_code == 401


def test_position_saves_seconds(client, monkeypatch):
    import db
    video_id = _make_done_video(client, monkeypatch)
    resp = client.post(
        f"/api/videos/{video_id}/position",
        json={"secs": 91.5},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 204
    assert db.get_video(video_id)["resume_secs"] == 91.5


def test_position_clamps_negative(client, monkeypatch):
    import db
    video_id = _make_done_video(client, monkeypatch, "https://twitter.com/x/status/901")
    resp = client.post(
        f"/api/videos/{video_id}/position",
        json={"secs": -3},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 204
    assert db.get_video(video_id)["resume_secs"] == 0


def test_position_unknown_video_is_404(client):
    resp = client.post(
        "/api/videos/999999/position",
        json={"secs": 5},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 404


def test_position_requires_secs(client, monkeypatch):
    video_id = _make_done_video(client, monkeypatch, "https://twitter.com/x/status/902")
    resp = client.post(
        f"/api/videos/{video_id}/position",
        json={},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 422


def test_video_list_includes_resume_secs(client, monkeypatch):
    import db
    video_id = _make_done_video(client, monkeypatch, "https://twitter.com/x/status/903")
    db.set_resume_secs(video_id, 42.0)
    resp = client.get("/api/videos", headers={"Authorization": "Bearer test-secret"})
    assert resp.status_code == 200
    row = next(v for v in resp.json() if v["id"] == video_id)
    assert row["resume_secs"] == 42.0
```

If `db.add_video` takes different arguments, copy the call shape used by the
nearest existing helper in `tests/test_api.py`. If `/api/videos` returns an
envelope rather than a bare list in this codebase, adapt the last test to the
shape the neighbouring list tests assert on.

- [ ] **Step 2: Run the tests and watch them fail**

Run: `python -m pytest tests/test_api.py -k position -v`
Expected: FAIL with 404/405 from the missing route.

- [ ] **Step 3: Add the request model**

In `router.py`, next to `AudioRequest`:

```python
class PositionRequest(BaseModel):
    secs: float
```

- [ ] **Step 4: Add the route**

In `router.py`, after `api_choose_audio`:

```python
@router.post("/api/videos/{video_id}/position", status_code=204)
async def api_save_position(video_id: int, body: PositionRequest, request: Request):
    """Where playback got to, reported by the iOS player.

    Fire-and-forget from the client's point of view: no body comes back, and a
    lost write only costs a few seconds of accuracy. 0 means "watched to the
    end" — the client sends it once playback reaches the final seconds.
    """
    _check_token(request)
    video = db.get_video(video_id)
    if not video or video.get("deleted_at"):
        raise HTTPException(status_code=404, detail="Video not found")
    db.set_resume_secs(video_id, body.secs)
    return Response(status_code=204)
```

`Response` and `HTTPException` are already imported in `router.py` (see
`api_devlog` at the end of the file).

- [ ] **Step 5: Run the tests**

```bash
python -m pytest tests/test_api.py -k position -v
python -m pytest tests/
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add router.py tests/test_api.py
git commit -m "feat(api): POST /api/videos/{id}/position to save resume point"
```

---

### Task 3: Client model + API call

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/Video.swift` (property, `CodingKeys`, `init`, `init(from:)`, `withClassification`)
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/APIClient.swift` (`VideoAPI` protocol + `APIClient`)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/ResumePositionAPITests.swift` (create)

**Interfaces:**
- Consumes: the `resume_secs` JSON field from Task 1 and the endpoint from Task 2.
- Produces: `Video.resumeSecs: Double` (decoded from `resume_secs` via the client's `.convertFromSnakeCase` strategy); `VideoAPI.savePosition(id: Int, secs: Double) async throws`.

- [ ] **Step 1: Write the failing test**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/ResumePositionAPITests.swift`. Match the style of `APIClientReadTests.swift`, which already wires `MockURLProtocol` and a `CredentialStore`; copy its setup helper verbatim rather than inventing one.

```swift
import XCTest
@testable import PatataTubeKit

final class ResumePositionAPITests: XCTestCase {
    func testVideoDecodesResumeSecs() throws {
        let json = """
        {"id": 1, "url": "u", "classification": "movies", "status": "done",
         "stream_path": "/videos/1/stream", "resume_secs": 91.5}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let video = try decoder.decode(Video.self, from: json)
        XCTAssertEqual(video.resumeSecs, 91.5)
    }

    func testVideoResumeSecsDefaultsToZeroWhenMissing() throws {
        let json = """
        {"id": 1, "url": "u", "classification": "movies", "status": "done",
         "stream_path": "/videos/1/stream"}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let video = try decoder.decode(Video.self, from: json)
        XCTAssertEqual(video.resumeSecs, 0)
    }

    func testSavePositionPostsSeconds() async throws {
        // Use the same MockURLProtocol setup helper as APIClientReadTests.
        let (client, recorder) = makeClient(status: 204, body: Data())
        try await client.savePosition(id: 12, secs: 91.5)
        let request = try XCTUnwrap(recorder.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/videos/12/position")
        let body = try XCTUnwrap(recorder.lastBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(json?["secs"] as? Double, 91.5)
    }

    func testSavePositionThrowsOnBadStatus() async {
        let (client, _) = makeClient(status: 500, body: Data())
        do {
            try await client.savePosition(id: 12, secs: 10)
            XCTFail("expected throw")
        } catch let error as APIError {
            XCTAssertEqual(error, APIError.badStatus(500))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
```

`makeClient(status:body:)` and the request recorder are whatever
`APIClientReadTests.swift` already uses — reuse those exact helpers; if they
are private to that file, lift them into a shared helper in this new file with
the same behaviour.

- [ ] **Step 2: Run the tests and watch them fail**

Run: `cd ios/PatataTubeKit && swift test --filter ResumePositionAPITests`
Expected: compile failure — `value of type 'Video' has no member 'resumeSecs'`.

- [ ] **Step 3: Add `resumeSecs` to `Video`**

In `Video.swift`:

```swift
    public let resumeSecs: Double
```

add `resumeSecs` to the `CodingKeys` enum's case list, add the parameter to the
memberwise `init` with a default so no existing call site breaks:

```swift
                audioLang: String? = nil, resumeSecs: Double = 0) {
```
```swift
        self.resumeSecs = resumeSecs
```

and in `init(from:)`:

```swift
        self.resumeSecs = try c.decodeIfPresent(Double.self, forKey: .resumeSecs) ?? 0
```

Then update `withClassification(_:)` (and any other `Video(...)` rebuild helper
in the file) to pass `resumeSecs: resumeSecs` so the value survives optimistic
updates.

- [ ] **Step 4: Add the API call**

In `APIClient.swift`, add to the `VideoAPI` protocol:

```swift
    func savePosition(id: Int, secs: Double) async throws
```

and to `APIClient`:

```swift
    /// Reports where playback got to. The server answers 204 with no body, so
    /// there is nothing to decode — a throw is the only failure signal.
    public func savePosition(id: Int, secs: Double) async throws {
        _ = try await authedPost("api/videos/\(id)/position", body: ["secs": secs])
    }
```

Any test double or mock conforming to `VideoAPI` elsewhere in the package or
app tests must gain the new method; a no-op implementation is fine.

- [ ] **Step 5: Run the tests**

```bash
cd ios/PatataTubeKit && swift test --filter ResumePositionAPITests
cd ios/PatataTubeKit && swift build
```

Expected: PASS, and the package builds.

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTubeKit
git commit -m "feat(ios): decode resume_secs and add savePosition API call"
```

---

### Task 4: Resume decision + local mirror

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/ResumeDecision.swift`
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/ResumePositionStore.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/ResumeDecisionTests.swift` (create)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/ResumePositionStoreTests.swift` (create)

**Interfaces:**
- Consumes: `Video.resumeSecs` from Task 3.
- Produces:
  - `ResumeDecision.decide(resumeSecs: Double, classification: String?, minimumSecs: Double = ResumeDecision.defaultMinimumSecs) -> ResumeDecision`, cases `.playFromStart` and `.ask(secs: Double)`
  - `ResumeDecision.defaultMinimumSecs: Double` (60)
  - `ResumeDecision.timestamp(_ secs: Double) -> String`
  - `ResumePositionStore` with `local(for:)`, `setLocal(_:for:)`, `markSynced(id:)`, `pending() -> [Int: Double]`, `resolved(server:for:) -> Double`

- [ ] **Step 1: Write the failing decision tests**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/ResumeDecisionTests.swift`:

```swift
import XCTest
@testable import PatataTubeKit

final class ResumeDecisionTests: XCTestCase {
    func testAsksWhenPastThresholdOnMovies() {
        XCTAssertEqual(ResumeDecision.decide(resumeSecs: 120, classification: "movies"),
                       .ask(secs: 120))
    }

    func testAsksOnTv() {
        XCTAssertEqual(ResumeDecision.decide(resumeSecs: 61, classification: "tv"),
                       .ask(secs: 61))
    }

    func testDoesNotAskBelowThreshold() {
        XCTAssertEqual(ResumeDecision.decide(resumeSecs: 59.9, classification: "movies"),
                       .playFromStart)
    }

    func testDoesNotAskAtZero() {
        XCTAssertEqual(ResumeDecision.decide(resumeSecs: 0, classification: "tv"),
                       .playFromStart)
    }

    func testDoesNotAskForOtherClassifications() {
        for classification in ["children", "adults", "education"] {
            XCTAssertEqual(ResumeDecision.decide(resumeSecs: 500, classification: classification),
                           .playFromStart, classification)
        }
    }

    func testDoesNotAskWithoutClassification() {
        XCTAssertEqual(ResumeDecision.decide(resumeSecs: 500, classification: nil),
                       .playFromStart)
    }

    func testTimestampUnderAnHour() {
        XCTAssertEqual(ResumeDecision.timestamp(1453), "24:13")
    }

    func testTimestampOverAnHour() {
        XCTAssertEqual(ResumeDecision.timestamp(5053), "1:24:13")
    }

    func testTimestampFloorsFractions() {
        XCTAssertEqual(ResumeDecision.timestamp(59.9), "0:59")
    }
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `cd ios/PatataTubeKit && swift test --filter ResumeDecisionTests`
Expected: compile failure — `cannot find 'ResumeDecision' in scope`.

- [ ] **Step 3: Implement `ResumeDecision`**

Create `ios/PatataTubeKit/Sources/PatataTubeKit/ResumeDecision.swift`:

```swift
import Foundation

/// Whether a play tap should offer "resume" or just start.
///
/// Only long-form rows (`tv`, `movies`) ever prompt, and only past a floor —
/// a 20-second accidental open must not put a modal in front of the next tap.
/// There is deliberately no upper bound here: reaching the end of a video
/// resets the stored position to 0 (see `PlaybackPositionReporter`), so a
/// finished video already reads as `.playFromStart`.
public enum ResumeDecision: Equatable, Sendable {
    case playFromStart
    case ask(secs: Double)

    public static let defaultMinimumSecs: Double = 60

    /// Classifications that get the prompt. Mirrors the server's tv/movies rows.
    public static let promptingClassifications: Set<String> = ["tv", "movies"]

    public static func decide(
        resumeSecs: Double,
        classification: String?,
        minimumSecs: Double = ResumeDecision.defaultMinimumSecs
    ) -> ResumeDecision {
        guard let classification, promptingClassifications.contains(classification) else {
            return .playFromStart
        }
        guard resumeSecs >= minimumSecs else { return .playFromStart }
        return .ask(secs: resumeSecs)
    }

    /// "24:13" under an hour, "1:24:13" over it. Seconds floor, never round up
    /// past the position actually stored.
    public static func timestamp(_ secs: Double) -> String {
        let total = Int(max(0, secs))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
```

- [ ] **Step 4: Run the decision tests**

Run: `cd ios/PatataTubeKit && swift test --filter ResumeDecisionTests`
Expected: PASS.

- [ ] **Step 5: Write the failing store tests**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/ResumePositionStoreTests.swift`:

```swift
import XCTest
@testable import PatataTubeKit

final class ResumePositionStoreTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        let suite = "resume-tests-\(UUID().uuidString)"
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    func testSetLocalRoundTrips() throws {
        let store = ResumePositionStore(defaults: try makeDefaults())
        store.setLocal(91.5, for: 7)
        XCTAssertEqual(store.local(for: 7), 91.5)
    }

    func testLocalIsNilWhenUnset() throws {
        let store = ResumePositionStore(defaults: try makeDefaults())
        XCTAssertNil(store.local(for: 7))
    }

    func testSetLocalMarksPending() throws {
        let store = ResumePositionStore(defaults: try makeDefaults())
        store.setLocal(91.5, for: 7)
        XCTAssertEqual(store.pending(), [7: 91.5])
    }

    func testMarkSyncedClearsPendingButKeepsValue() throws {
        let store = ResumePositionStore(defaults: try makeDefaults())
        store.setLocal(91.5, for: 7)
        store.markSynced(id: 7)
        XCTAssertEqual(store.pending(), [:])
        XCTAssertEqual(store.local(for: 7), 91.5)
    }

    func testResolvedPrefersPendingLocalOverServer() throws {
        let store = ResumePositionStore(defaults: try makeDefaults())
        store.setLocal(300, for: 7)
        XCTAssertEqual(store.resolved(server: 10, for: 7), 300)
    }

    func testResolvedPrefersServerOnceSynced() throws {
        let store = ResumePositionStore(defaults: try makeDefaults())
        store.setLocal(300, for: 7)
        store.markSynced(id: 7)
        XCTAssertEqual(store.resolved(server: 10, for: 7), 10)
    }

    func testResolvedFallsBackToServerWithoutLocal() throws {
        let store = ResumePositionStore(defaults: try makeDefaults())
        XCTAssertEqual(store.resolved(server: 42, for: 7), 42)
    }

    func testZeroIsStoredNotTreatedAsMissing() throws {
        let store = ResumePositionStore(defaults: try makeDefaults())
        store.setLocal(0, for: 7)
        XCTAssertEqual(store.local(for: 7), 0)
        XCTAssertEqual(store.resolved(server: 500, for: 7), 0)
    }
}
```

- [ ] **Step 6: Run and watch it fail**

Run: `cd ios/PatataTubeKit && swift test --filter ResumePositionStoreTests`
Expected: compile failure — `cannot find 'ResumePositionStore' in scope`.

- [ ] **Step 7: Implement `ResumePositionStore`**

Create `ios/PatataTubeKit/Sources/PatataTubeKit/ResumePositionStore.swift`:

```swift
import Foundation

/// Local mirror of the server's resume positions.
///
/// The server is the source of truth, but a device watching a downloaded file
/// on a dead network still has to resume correctly, and a write that failed
/// must not be lost. Every write lands here first and is marked pending until
/// the API accepts it; a pending value outranks whatever the list endpoint
/// last said, because it is strictly newer.
public final class ResumePositionStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func valueKey(_ id: Int) -> String { "resumeSecs.\(id)" }
    private func pendingKey(_ id: Int) -> String { "resumeSecsPending.\(id)" }

    public func local(for id: Int) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard defaults.object(forKey: valueKey(id)) != nil else { return nil }
        return defaults.double(forKey: valueKey(id))
    }

    public func setLocal(_ secs: Double, for id: Int) {
        lock.lock(); defer { lock.unlock() }
        defaults.set(max(0, secs), forKey: valueKey(id))
        defaults.set(true, forKey: pendingKey(id))
    }

    public func markSynced(id: Int) {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: pendingKey(id))
    }

    /// Ids whose latest local value never reached the server, newest value each.
    public func pending() -> [Int: Double] {
        lock.lock(); defer { lock.unlock() }
        var result: [Int: Double] = [:]
        for (key, _) in defaults.dictionaryRepresentation() where key.hasPrefix("resumeSecsPending.") {
            let suffix = String(key.dropFirst("resumeSecsPending.".count))
            guard let id = Int(suffix), defaults.bool(forKey: key) else { continue }
            result[id] = defaults.double(forKey: valueKey(id))
        }
        return result
    }

    /// The position to actually use: a pending local write wins, otherwise the
    /// server's value.
    public func resolved(server: Double, for id: Int) -> Double {
        lock.lock()
        let isPending = defaults.bool(forKey: pendingKey(id))
        let hasLocal = defaults.object(forKey: valueKey(id)) != nil
        let localValue = defaults.double(forKey: valueKey(id))
        lock.unlock()
        return (isPending && hasLocal) ? localValue : server
    }
}
```

- [ ] **Step 8: Run both suites**

```bash
cd ios/PatataTubeKit && swift test --filter ResumeDecisionTests
cd ios/PatataTubeKit && swift test --filter ResumePositionStoreTests
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add ios/PatataTubeKit
git commit -m "feat(ios): resume decision rules and local position mirror"
```

---

### Task 5: The position reporter

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/PlaybackPositionReporter.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/PlaybackPositionReporterTests.swift` (create)

**Interfaces:**
- Consumes: `ResumePositionStore` (Task 4), `VideoAPI.savePosition` (Task 3).
- Produces:
  - `protocol PositionReporting: Sendable` with `func record(id: Int, secs: Double, duration: Double?, force: Bool) async` and `func flushPending() async`
  - `actor PlaybackPositionReporter: PositionReporting`, `init(api: any VideoAPI, store: ResumePositionStore, minimumIntervalSecs: Double = 10, endWindowSecs: Double = 30, now: @escaping @Sendable () -> Date = Date.init)`
  - `func flushPending() async`

- [ ] **Step 1: Write the failing tests**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/PlaybackPositionReporterTests.swift`:

```swift
import XCTest
@testable import PatataTubeKit

/// Records savePosition calls; every other VideoAPI member is unused here.
private final class SpyAPI: VideoAPI, @unchecked Sendable {
    var saved: [(id: Int, secs: Double)] = []
    var failNext = false
    let lock = NSLock()

    func savePosition(id: Int, secs: Double) async throws {
        lock.lock(); defer { lock.unlock() }
        if failNext {
            failNext = false
            throw APIError.badStatus(500)
        }
        saved.append((id, secs))
    }

    // Unused by these tests.
    func videos(classification: String?) async throws -> [Video] { [] }
    func classifications() async throws -> [String] { [] }
    func classify(id: Int, classification: String) async throws -> ClassifyResult { ClassifyResult(ok: true) }
    func chooseVersion(id: Int, versionId: Int) async throws -> Bool { true }
    func chooseAudio(id: Int, lang: String) async throws -> Bool { true }
    func upload(url: String) async throws -> Int { 0 }
    func delete(id: Int) async throws -> Bool { true }
    func scanLibrary() async throws -> ScanResult { ScanResult(added: 0, updated: 0, skipped: 0) }
    func prepare(id: Int, bulk: Bool) async throws -> String { "done" }
    func video(id: Int) async throws -> Video {
        throw APIError.notConfigured
    }
    func imageData(path: String) async throws -> Data { Data() }
}

final class PlaybackPositionReporterTests: XCTestCase {
    private func makeStore() throws -> ResumePositionStore {
        ResumePositionStore(defaults: try XCTUnwrap(UserDefaults(suiteName: "reporter-\(UUID().uuidString)")))
    }

    func testFirstRecordWritesThrough() async throws {
        let api = SpyAPI()
        let store = try makeStore()
        let reporter = PlaybackPositionReporter(api: api, store: store)
        await reporter.record(id: 5, secs: 30, duration: 1000, force: false)
        XCTAssertEqual(api.saved.map(\.secs), [30])
        XCTAssertEqual(store.local(for: 5), 30)
    }

    func testSecondRecordInsideIntervalIsLocalOnly() async throws {
        let api = SpyAPI()
        let store = try makeStore()
        var clock = Date(timeIntervalSince1970: 0)
        let reporter = PlaybackPositionReporter(api: api, store: store, now: { clock })
        await reporter.record(id: 5, secs: 30, duration: 1000, force: false)
        clock = Date(timeIntervalSince1970: 4)
        await reporter.record(id: 5, secs: 34, duration: 1000, force: false)
        XCTAssertEqual(api.saved.map(\.secs), [30])
        XCTAssertEqual(store.local(for: 5), 34)
    }

    func testRecordAfterIntervalWritesThrough() async throws {
        let api = SpyAPI()
        let store = try makeStore()
        var clock = Date(timeIntervalSince1970: 0)
        let reporter = PlaybackPositionReporter(api: api, store: store, now: { clock })
        await reporter.record(id: 5, secs: 30, duration: 1000, force: false)
        clock = Date(timeIntervalSince1970: 11)
        await reporter.record(id: 5, secs: 41, duration: 1000, force: false)
        XCTAssertEqual(api.saved.map(\.secs), [30, 41])
    }

    func testForceWritesThroughInsideInterval() async throws {
        let api = SpyAPI()
        let store = try makeStore()
        var clock = Date(timeIntervalSince1970: 0)
        let reporter = PlaybackPositionReporter(api: api, store: store, now: { clock })
        await reporter.record(id: 5, secs: 30, duration: 1000, force: false)
        clock = Date(timeIntervalSince1970: 1)
        await reporter.record(id: 5, secs: 31, duration: 1000, force: true)
        XCTAssertEqual(api.saved.map(\.secs), [30, 31])
    }

    func testNearEndClearsToZero() async throws {
        let api = SpyAPI()
        let store = try makeStore()
        let reporter = PlaybackPositionReporter(api: api, store: store)
        await reporter.record(id: 5, secs: 980, duration: 1000, force: true)
        XCTAssertEqual(api.saved.map(\.secs), [0])
        XCTAssertEqual(store.local(for: 5), 0)
    }

    func testUnknownDurationDoesNotClear() async throws {
        let api = SpyAPI()
        let store = try makeStore()
        let reporter = PlaybackPositionReporter(api: api, store: store)
        await reporter.record(id: 5, secs: 980, duration: nil, force: true)
        XCTAssertEqual(api.saved.map(\.secs), [980])
    }

    func testFailedWriteStaysPending() async throws {
        let api = SpyAPI()
        api.failNext = true
        let store = try makeStore()
        let reporter = PlaybackPositionReporter(api: api, store: store)
        await reporter.record(id: 5, secs: 30, duration: 1000, force: true)
        XCTAssertEqual(api.saved.count, 0)
        XCTAssertEqual(store.pending(), [5: 30])
    }

    func testFlushPendingResendsAndClears() async throws {
        let api = SpyAPI()
        api.failNext = true
        let store = try makeStore()
        let reporter = PlaybackPositionReporter(api: api, store: store)
        await reporter.record(id: 5, secs: 30, duration: 1000, force: true)
        await reporter.flushPending()
        XCTAssertEqual(api.saved.map(\.secs), [30])
        XCTAssertEqual(store.pending(), [:])
    }

    func testSuccessfulWriteClearsPending() async throws {
        let api = SpyAPI()
        let store = try makeStore()
        let reporter = PlaybackPositionReporter(api: api, store: store)
        await reporter.record(id: 5, secs: 30, duration: 1000, force: true)
        XCTAssertEqual(store.pending(), [:])
    }
}
```

If `VideoAPI` gained or lost members by the time this task runs, make `SpyAPI`
match the protocol exactly — the compiler names anything missing.

- [ ] **Step 2: Run and watch it fail**

Run: `cd ios/PatataTubeKit && swift test --filter PlaybackPositionReporterTests`
Expected: compile failure — `cannot find 'PlaybackPositionReporter' in scope`.

- [ ] **Step 3: Implement the reporter**

Create `ios/PatataTubeKit/Sources/PatataTubeKit/PlaybackPositionReporter.swift`:

```swift
import Foundation

public protocol PositionReporting: Sendable {
    /// `force` bypasses the interval throttle — use it for pause, dismiss,
    /// background and queue advance, where there is no later chance to write.
    func record(id: Int, secs: Double, duration: Double?, force: Bool) async
    func flushPending() async
}

/// Sends playback positions to the server, throttled, with a local mirror.
///
/// Never throws into the playback path: a failed write leaves the value marked
/// pending in `ResumePositionStore` and the next successful call flushes it.
public actor PlaybackPositionReporter: PositionReporting {
    private let api: any VideoAPI
    private let store: ResumePositionStore
    private let minimumIntervalSecs: Double
    private let endWindowSecs: Double
    private let now: @Sendable () -> Date
    private var lastSentAt: [Int: Date] = [:]

    public init(
        api: any VideoAPI,
        store: ResumePositionStore,
        minimumIntervalSecs: Double = 10,
        endWindowSecs: Double = 30,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.api = api
        self.store = store
        self.minimumIntervalSecs = minimumIntervalSecs
        self.endWindowSecs = endWindowSecs
        self.now = now
    }

    public func record(id: Int, secs: Double, duration: Double?, force: Bool) async {
        let value = Self.effectiveSecs(secs: secs, duration: duration, endWindowSecs: endWindowSecs)
        store.setLocal(value, for: id)

        let timestamp = now()
        if !force, let last = lastSentAt[id], timestamp.timeIntervalSince(last) < minimumIntervalSecs {
            return
        }
        lastSentAt[id] = timestamp
        await send(id: id, secs: value)
    }

    public func flushPending() async {
        for (id, secs) in store.pending() {
            await send(id: id, secs: secs)
        }
    }

    private func send(id: Int, secs: Double) async {
        do {
            try await api.savePosition(id: id, secs: secs)
            store.markSynced(id: id)
            DevLog.event(.net, "position saved", ["video_id": "\(id)", "secs": "\(Int(secs))"])
        } catch {
            DevLog.error("position save failed", ["video_id": "\(id)"])
        }
    }

    /// Within the final `endWindowSecs` counts as watched: store 0 so the next
    /// play starts fresh with no prompt.
    static func effectiveSecs(secs: Double, duration: Double?, endWindowSecs: Double) -> Double {
        guard let duration, duration > 0 else { return max(0, secs) }
        if secs >= duration - endWindowSecs { return 0 }
        return max(0, secs)
    }
}
```

Check `DevLog.error`'s actual signature in
`ios/PatataTubeKit/Sources/PatataTubeKit/DevLog.swift` and match it; if it
requires an `Error` argument, pass the caught `error` and keep the metadata to
ids only.

- [ ] **Step 4: Run the tests**

```bash
cd ios/PatataTubeKit && swift test --filter PlaybackPositionReporterTests
cd ios/PatataTubeKit && swift build
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit
git commit -m "feat(ios): throttled playback position reporter with offline mirror"
```

---

### Task 6: Ask before playing

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/PlaybackQueue.swift` (add `startSecs`)
- Modify: `ios/PatataTube/Sources/AppModel.swift` (own the store + reporter)
- Modify: `ios/PatataTube/Sources/VideoGridView.swift` (`play(_:queueSnapshot:sleepMode:)` at ~line 309, `startPlayback` at ~line 344, alert next to the existing "Download all" alert at ~line 193, the `fullScreenCover(item: $playing)` at ~line 212)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/PlaybackQueueTests.swift`

**Interfaces:**
- Consumes: `ResumeDecision.decide`, `ResumeDecision.timestamp`, `ResumePositionStore.resolved(server:for:)`, `Video.resumeSecs`.
- Produces: `PlaybackQueue.startSecs: Double` (0 = from the beginning), and `AppModel.resumeStore: ResumePositionStore` / `AppModel.positions: PlaybackPositionReporter`, both consumed by Task 7.

- [ ] **Step 1: Write the failing queue test**

Append to `ios/PatataTubeKit/Tests/PatataTubeKitTests/PlaybackQueueTests.swift` (reuse the file's existing `Video` factory helper):

```swift
    func testStartSecsDefaultsToZero() {
        let video = makeVideo(id: 1)
        let queue = PlaybackQueue(video: video, queueSnapshot: [video])
        XCTAssertEqual(queue.startSecs, 0)
    }

    func testStartSecsIsCarried() {
        let video = makeVideo(id: 1)
        let queue = PlaybackQueue(video: video, queueSnapshot: [video], startSecs: 91.5)
        XCTAssertEqual(queue.startSecs, 91.5)
    }
```

- [ ] **Step 2: Run and watch it fail**

Run: `cd ios/PatataTubeKit && swift test --filter PlaybackQueueTests`
Expected: compile failure — no `startSecs` argument.

- [ ] **Step 3: Add `startSecs` to `PlaybackQueue`**

In `PlaybackQueue.swift`:

```swift
    /// Where to seek the first item to, in seconds. 0 plays from the start.
    /// Only ever non-zero when the user picked "Resume" — auto-advance inside
    /// the player always starts the next item at 0.
    public let startSecs: Double
```

and in the `init`, add the parameter and assignment:

```swift
    public init(video: Video, queueSnapshot: [Video], sleepMode: Bool = false, startSecs: Double = 0) {
        self.sleepMode = sleepMode
        self.startSecs = startSecs
```

- [ ] **Step 4: Run the queue tests**

Run: `cd ios/PatataTubeKit && swift test --filter PlaybackQueueTests`
Expected: PASS.

- [ ] **Step 5: Own the reporter in `AppModel`**

In `ios/PatataTube/Sources/AppModel.swift`, alongside the existing `cache` /
`credentials` / `streamProxy` properties:

```swift
    /// Local mirror of server resume positions, and the throttled writer that
    /// keeps the server in sync. Shared so the grid can read a position at tap
    /// time and the player can report against the same store.
    let resumeStore = ResumePositionStore()
    lazy var positions = PlaybackPositionReporter(
        api: APIClient(store: credentials),
        store: resumeStore
    )
```

Match the file's existing construction style: if `AppModel` builds its
`APIClient` once and reuses it, reuse that instance instead of making another.

- [ ] **Step 6: Add the alert state and gate to `VideoGridView`**

Add near the other `@State` declarations (~line 25):

```swift
    /// Set when a tv/movies tap has a resume point worth asking about; the
    /// alert below turns it into either a seek or a fresh start.
    @State private var pendingResume: PendingResume?
```

Add the value type at file scope, next to `DownloadAllRequest` (~line 7):

```swift
/// A play tap parked behind the resume prompt.
struct PendingResume: Identifiable {
    let id: Int
    let video: Video
    let queueSnapshot: [Video]
    let sleepMode: Bool
    let secs: Double
}
```

Change `startPlayback` to take the seek offset and route the decision. Replace
the existing `startPlayback` body (~line 344) with:

```swift
    /// Starts playback from the tap-time queue snapshot. `video` may be the
    /// ensureReady-updated copy, so it replaces its stale row in the snapshot.
    /// tv/movies rows with real progress stop here and ask first.
    private func startPlayback(_ video: Video, queueSnapshot: [Video], sleepMode: Bool = false) {
        let secs = model.resumeStore.resolved(server: video.resumeSecs, for: video.id)
        switch ResumeDecision.decide(resumeSecs: secs, classification: video.classification) {
        case .ask(let secs):
            pendingResume = PendingResume(id: video.id, video: video,
                                          queueSnapshot: queueSnapshot,
                                          sleepMode: sleepMode, secs: secs)
        case .playFromStart:
            begin(video, queueSnapshot: queueSnapshot, sleepMode: sleepMode, startSecs: 0)
        }
    }

    private func begin(_ video: Video, queueSnapshot: [Video], sleepMode: Bool, startSecs: Double) {
        playing = PlaybackQueue(video: video, queueSnapshot: queueSnapshot,
                                sleepMode: sleepMode, startSecs: startSecs)
    }
```

Add the alert immediately after the existing "Download all" `.alert(...)` block
(~line 211):

```swift
            .alert(
                "Resume playback",
                isPresented: Binding(
                    get: { pendingResume != nil },
                    set: { if !$0 { pendingResume = nil } }
                ),
                presenting: pendingResume
            ) { request in
                Button("Resume from \(ResumeDecision.timestamp(request.secs))") {
                    pendingResume = nil
                    begin(request.video, queueSnapshot: request.queueSnapshot,
                          sleepMode: request.sleepMode, startSecs: request.secs)
                }
                Button("Play from start") {
                    pendingResume = nil
                    begin(request.video, queueSnapshot: request.queueSnapshot,
                          sleepMode: request.sleepMode, startSecs: 0)
                }
                Button("Cancel", role: .cancel) { pendingResume = nil }
            } message: { request in
                Text("You stopped at \(ResumeDecision.timestamp(request.secs)).")
            }
```

Pass the offset through to the player in the `fullScreenCover(item: $playing)`
(~line 212):

```swift
            .fullScreenCover(item: $playing) { request in
                VideoPlayerView(videos: request.videos, startIndex: request.startIndex,
                                sleepMode: request.sleepMode,
                                randomize: model.randomize(for: store.filter),
                                startSecs: request.startSecs)
            }
```

`VideoPlayerView` does not accept `startSecs` until Task 7 — that parameter is
added there. Implement Task 7 before building the app target, or add the
parameter to `VideoPlayerView.init` first with a `= 0` default and wire its
behaviour in Task 7.

- [ ] **Step 7: Build and check the app compiles**

```bash
cd ios/PatataTubeKit && swift build
cd ios/PatataTube && xcodegen generate
xcodebuild -project ios/PatataTube/PatataTube.xcodeproj -scheme PatataTube \
  -destination 'generic/platform=iOS Simulator' build | tail -20
```

Expected: build succeeds once Task 7's `startSecs` parameter exists; until
then, the only error should be the missing argument label on `VideoPlayerView`.

- [ ] **Step 8: Commit**

```bash
git add ios/PatataTubeKit ios/PatataTube
git commit -m "feat(ios): ask resume or restart before playing tv and movies"
```

---

### Task 7: Seek on resume, report while playing

**Files:**
- Modify: `ios/PatataTube/Sources/VideoPlayerView.swift` (`init` ~line 24, `setup()` ~line 153, `advance(by:)` ~line 438, `bindPlayToEnd()` ~line 355, `.onChange(of: scenePhase)` ~line 101, `.onDisappear` ~line 114)
- Test: `ios/PatataTube/Tests/VideoPlayerResumeTests.swift` (create)

**Interfaces:**
- Consumes: `PlaybackQueue.startSecs` (Task 6), `AppModel.positions` (Task 6), `PlaybackPositionReporter.record` (Task 5).
- Produces: nothing downstream.

- [ ] **Step 1: Write the failing test**

The seek/report wiring lives in a SwiftUI view, so test the one piece of logic
that can be isolated: the seek target. Create
`ios/PatataTube/Tests/VideoPlayerResumeTests.swift`:

```swift
import XCTest
import PatataTubeKit
@testable import PatataTube

final class VideoPlayerResumeTests: XCTestCase {
    func testSeeksOnlyForMeaningfulOffsets() {
        XCTAssertNil(VideoPlayerView.seekTarget(startSecs: 0))
        XCTAssertNil(VideoPlayerView.seekTarget(startSecs: 0.4))
        XCTAssertEqual(VideoPlayerView.seekTarget(startSecs: 91.5)?.seconds ?? 0, 91.5, accuracy: 0.01)
    }
}
```

Follow the import and target conventions of the neighbouring
`ios/PatataTube/Tests/VideoGridViewTests.swift`.

- [ ] **Step 2: Run and watch it fail**

Run the `PatataTube` test target in Xcode, or:

```bash
xcodebuild test -project ios/PatataTube/PatataTube.xcodeproj -scheme PatataTube \
  -destination 'platform=iOS Simulator,name=iPad (10th generation)' \
  -only-testing:PatataTubeTests/VideoPlayerResumeTests | tail -30
```

Expected: FAIL — `type 'VideoPlayerView' has no member 'seekTarget'`. If the
simulator name does not exist locally, pick one from `xcrun simctl list devices`.

- [ ] **Step 3: Accept `startSecs` and add the seek helper**

In `VideoPlayerView.swift`, add the stored property and init parameter:

```swift
    /// Where to start the *first* item, in seconds. Only ever non-zero when the
    /// user chose "Resume" in the grid's prompt — every later item in the queue
    /// starts at 0.
    let startSecs: Double
```

```swift
    init(videos: [Video], startIndex: Int, sleepMode: Bool = false,
         randomize: Bool = false, startSecs: Double = 0) {
        self.videos = videos
        self.startIndex = startIndex
        self.sleepMode = sleepMode
        self.randomize = randomize
        self.startSecs = startSecs
```

and the pure helper:

```swift
    /// Sub-second offsets aren't worth a seek — they only cost a buffer stall.
    static func seekTarget(startSecs: Double) -> CMTime? {
        guard startSecs >= 1 else { return nil }
        return CMTime(seconds: startSecs, preferredTimescale: 600)
    }
```

`CMTime` needs `import CoreMedia` if `AVKit` does not already bring it in.

- [ ] **Step 4: Seek before the first play**

In `setup()`, immediately after `self.player = player` and *before*
`playWhenReady(item: item, on: player)`:

```swift
        if let target = Self.seekTarget(startSecs: startSecs) {
            DevLog.event(.play, "resuming", [
                "video_id": "\(video.id)", "secs": "\(Int(startSecs))",
            ])
            await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        }
```

Seeking before `playWhenReady` matters: that function calls `player.play()` the
moment buffering reports ready, and a seek issued after it would visibly play
the first frames from 0.

- [ ] **Step 5: Report the position while playing**

Add state for the observer near the other `@State` declarations:

```swift
    /// Periodic time observer that feeds the resume reporter. Removed on dismiss.
    @State private var positionObserver: Any?
```

At the end of `setup()`, after `bindPlayToEnd()`:

```swift
        positionObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 10, preferredTimescale: 600), queue: .main
        ) { time in
            guard player.timeControlStatus == .playing else { return }
            let id = video.id
            let duration = player.currentItem?.duration.seconds
            let secs = time.seconds
            Task { await model.positions.record(id: id, secs: secs,
                                                duration: duration?.isFinite == true ? duration : nil,
                                                force: false) }
        }
        await model.positions.flushPending()
```

Add a helper for the forced writes:

```swift
    /// Forced write for the moments with no later chance: pause, background,
    /// dismiss, and queue advance.
    private func reportPosition(force: Bool = true) {
        guard let player else { return }
        let id = video.id
        let secs = player.currentTime().seconds
        guard secs.isFinite else { return }
        let duration = player.currentItem?.duration.seconds
        Task { await model.positions.record(id: id, secs: secs,
                                            duration: duration?.isFinite == true ? duration : nil,
                                            force: force) }
    }
```

- [ ] **Step 6: Call it at every exit**

In `.onChange(of: scenePhase)`, in the `.inactive` case, after the existing
`resumeAfterDetaching` assignment:

```swift
                reportPosition()
```

In `.onDisappear`, before `player?.pause()`:

```swift
            reportPosition()
```

and in the same block, after `readyTimeoutTask = nil`:

```swift
            if let positionObserver { player?.removeTimeObserver(positionObserver) }
            positionObserver = nil
```

Order matters in `onDisappear`: read the time before pausing/tearing down, and
remove the observer before the player goes away.

In `advance(by direction: Int)`, as the first statement of the function
(before the next index is resolved), so the outgoing video's position is
recorded:

```swift
        reportPosition()
```

In `bindPlayToEnd()`, inside the notification handler before the
`switch`/`advance` branch runs, record the finish so the position clears:

```swift
                reportPosition()
```

`PlaybackPositionReporter` turns "within 30s of the end" into a stored 0, so a
finished video prompts nothing next time.

- [ ] **Step 7: Confirm auto-advance never resumes**

`advance(by:)` builds the next item with `playerItem(for:)` and calls
`player.replaceCurrentItem(with:)`; it must not seek. Read the function and
verify no `seek` call was added — `startSecs` is only consulted in `setup()`,
which runs once per presentation.

- [ ] **Step 8: Run tests and build**

```bash
cd ios/PatataTubeKit && swift test
xcodebuild test -project ios/PatataTube/PatataTube.xcodeproj -scheme PatataTube \
  -destination 'platform=iOS Simulator,name=iPad (10th generation)' \
  -only-testing:PatataTubeTests/VideoPlayerResumeTests | tail -30
python -m pytest tests/
```

Expected: PASS. Note the pre-existing full-parallel `swift test` flakiness
documented in `CLAUDE.md` — re-run any failure filtered before treating it as a
regression.

- [ ] **Step 9: Manual check on the simulator**

1. `./serve`, launch the app in the simulator, open a `movies` row, let it play
   past 60 seconds, then swipe down to dismiss.
2. `grep '"msg":"position saved"' log/ios.jsonl | tail -5` — a record should be there.
3. `sqlite3 data/patatatube.db 'select id, resume_secs from videos where resume_secs > 0'` —
   the row should carry the seconds. Use the actual `DB_PATH` from `.env` if it differs.
4. Tap the same movie again: the alert should offer "Resume from M:SS".
5. Choose Resume and confirm playback starts at that point; choose Play from
   start on a second attempt and confirm it starts at 0 (and that the stored
   position then tracks from 0 upward).
6. Open a `children` row with the same treatment and confirm no alert appears.

- [ ] **Step 10: Commit**

```bash
git add ios/PatataTube
git commit -m "feat(ios): seek on resume and report playback position"
```

---

### Task 8: Document the feature

**Files:**
- Modify: `CLAUDE.md` (the `### iOS` section under Architecture)

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Add the note**

Append to the `### iOS` bullet list in `CLAUDE.md`:

```markdown
- **Resume positions live on the server.** `videos.resume_secs` is written by
  `POST /api/videos/{id}/position`; the iOS player reports every 10s and on
  pause/background/dismiss/advance via `PlaybackPositionReporter`, mirroring
  each write into `UserDefaults` (`ResumePositionStore`) so offline playback
  still resumes and failed writes flush later. The Resume/Play-from-start
  alert only appears for `tv`/`movies` rows past 60s (`ResumeDecision`);
  reaching the last 30s stores 0, and auto-advance inside the player always
  starts the next item at 0.
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: describe server-side resume positions"
```
