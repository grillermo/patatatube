# Remove Manual Video Reordering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete manual up/down video reordering from the PWA, iOS app, and server while preserving stable newest-first ordering.

**Architecture:** Remove both user-facing controls and their entire mutation path: PWA form and iOS callback, client, store, API route, service, and database method. Retain the read-only `videos.position` data path because it also drives chronological and Plex/library ordering; regression tests treat the former routes as permanently absent.

**Tech Stack:** Python 3.13, FastAPI, Jinja2, pytest, Swift 6, SwiftUI, Swift Testing, ViewInspector, SwiftPM, XcodeGen/Xcodebuild.

## Global Constraints

- Remove manual reordering from both the PWA and native iOS app.
- Former PWA and JSON move endpoints must return HTTP 404.
- Preserve `videos.position`, `video_versions.position`, stable newest-first ordering, and API/model compatibility.
- Preserve download, playback, classify, delete, version selection, filtering, searching, and library refresh behavior.
- Do not rewrite historical files under `docs/superpowers/specs/` or `docs/superpowers/plans/`.
- Prefix every shell command with `rtk`.

---

### Task 1: Remove the PWA and Server Reorder Path

**Files:**
- Modify: `tests/test_api.py`
- Modify: `tests/test_services.py`
- Modify: `views/templates/_macros.html`
- Modify: `assets/app/videos.css`
- Modify: `router.py`
- Modify: `services.py`
- Modify: `db.py`

**Interfaces:**
- Consumes: `db.add_video(url: str) -> int`, the root PWA route, and FastAPI's default unmatched-route response.
- Produces: no `/videos/{video_id}/move` or `/api/videos/{video_id}/move` route; no `MoveRequest`, `services.apply_move`, or `db.move_video`; PWA card actions containing download but no reorder controls.

- [ ] **Step 1: Add failing UI and route-removal regression tests**

Add these tests near the existing page and API route tests in `tests/test_api.py`:

```python
def test_videos_page_omits_manual_reorder_controls(client):
    import db

    video_id = db.add_video("https://twitter.com/x/status/1")
    resp = client.get("/")

    assert resp.status_code == 200
    assert f'action="/videos/{video_id}/move"' not in resp.text
    assert 'aria-label="Move up"' not in resp.text
    assert 'aria-label="Move down"' not in resp.text


def test_move_endpoints_removed(client):
    import db

    video_id = db.add_video("https://twitter.com/x/status/1")
    pwa = client.post(
        f"/videos/{video_id}/move",
        data={"direction": "up"},
        follow_redirects=False,
    )
    api = client.post(
        f"/api/videos/{video_id}/move",
        json={"direction": "up"},
        headers={"Authorization": "Bearer test-secret"},
    )

    assert pwa.status_code == 404
    assert api.status_code == 404
```

- [ ] **Step 2: Run the new tests and verify the expected failures**

Run:

```bash
rtk pytest tests/test_api.py::test_videos_page_omits_manual_reorder_controls tests/test_api.py::test_move_endpoints_removed -q
```

Expected: both tests fail because the rendered card contains the move forms and the routes return 303/200 instead of 404.

- [ ] **Step 3: Remove the PWA controls while retaining download**

Replace the `<div class="move">` block in `views/templates/_macros.html` with:

```html
<div class="card-actions">
  {% if v.status == "done" -%}
  <a class="download-btn" href="/videos/{{ v.id }}/stream?token={{ upload_token }}" download="{{ v | download_name }}.mp4" aria-label="Download video">&#8681;</a>
  {%- endif %}
</div>
```

Rename the `.move` layout rule in `assets/app/videos.css` to `.card-actions`, and delete the `.move form`, `.move button`, and `.move button:active` rules. Leave `.download-btn` unchanged.

- [ ] **Step 4: Delete the server mutation path**

Delete `MoveRequest` and both move route functions from `router.py`, delete `apply_move` from `services.py`, and delete `move_video` from `db.py`. Do not alter position assignment, backfills, sorting, serialization, or version ordering.

Delete `test_api_move_requires_token`, `test_api_move_swaps_and_returns_ok`, and `test_api_move_invalid_direction_returns_not_ok` from `tests/test_api.py`. Delete `test_apply_move_swaps_positions` and `test_apply_move_rejects_bad_direction` from `tests/test_services.py`; the new 404 regression replaces their obsolete contract.

- [ ] **Step 5: Run focused backend tests and verify green**

Run:

```bash
rtk pytest tests/test_api.py::test_videos_page_omits_manual_reorder_controls tests/test_api.py::test_move_endpoints_removed tests/test_services.py -q
```

Expected: all selected tests pass.

- [ ] **Step 6: Commit the server and PWA removal**

```bash
rtk git add tests/test_api.py tests/test_services.py views/templates/_macros.html assets/app/videos.css router.py services.py db.py
rtk git commit -m "feat: remove manual reorder API and PWA controls"
```

---

### Task 2: Remove the iOS Reorder Path

**Files:**
- Create: `ios/PatataTube/Tests/VideoCellTests.swift`
- Modify: `ios/PatataTube/Sources/VideoCell.swift`
- Modify: `ios/PatataTube/Sources/VideoGridView.swift`
- Modify: `ios/PatataTube/Sources/MovieCell.swift`
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/APIClient.swift`
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/VideoStore.swift`
- Modify: `ios/PatataTubeKit/Tests/PatataTubeKitTests/APIClientReadTests.swift`
- Modify: `ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoStoreTests.swift`

**Interfaces:**
- Consumes: the existing `VideoCell` initializer and `VideoAPI` protocol.
- Produces: a `VideoCell` initializer with no `onMoveUp` or `onMoveDown`; a `VideoAPI`/`APIClient`/`VideoStore` surface with no `move` method.

- [ ] **Step 1: Add a compile-time/UI regression test for the desired cell contract**

Create `ios/PatataTube/Tests/VideoCellTests.swift`:

```swift
import PatataTubeKit
import Testing
import ViewInspector
@testable import PatataTube

@MainActor
@Test func videoCellOmitsManualReorderActions() throws {
    let video = Video(
        id: 1,
        url: "https://example.com/video",
        title: "Video",
        platform: nil,
        sourceKey: nil,
        previewUrl: nil,
        classification: "children",
        position: 1,
        status: "done",
        errorMsg: nil,
        streamPath: "/videos/1/stream"
    )
    let sut = VideoCell(
        video: video,
        cacheState: .notCached,
        currentCacheState: { .notCached },
        classifications: ["children", "adults"],
        onPlay: {},
        onDownload: { false },
        onCancel: {},
        onClassify: { _ in },
        onChooseVersion: { _ in },
        onDelete: {}
    )

    #expect(throws: InspectionError.self) {
        _ = try sut.inspect().find(text: "Move up")
    }
    #expect(throws: InspectionError.self) {
        _ = try sut.inspect().find(text: "Move down")
    }
}
```

- [ ] **Step 2: Generate the Xcode project and verify the test target fails to compile for the expected reason**

Run:

```bash
rtk proxy sh -c 'cd ios/PatataTube && xcodegen generate'
rtk test xcodebuild test -project ios/PatataTube/PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -only-testing:PatataTubeTests/videoCellOmitsManualReorderActions
```

Expected: build failure reporting missing `onMoveUp` and `onMoveDown` arguments in `VideoCellTests.swift`. This proves the new initializer contract is not yet implemented.

- [ ] **Step 3: Remove the iOS UI properties, controls, and callback wiring**

Delete the `onMoveUp` and `onMoveDown` properties and the two corresponding menu buttons from `VideoCell.swift`. Delete both callback arguments from the `VideoCell` construction in `VideoGridView.swift`. Update the `MovieCell.swift` comment to say the detail view owns `download/classify/delete`.

- [ ] **Step 4: Remove the unused iOS client and store methods**

Delete `move(id:direction:)` from `VideoAPI`, `APIClient`, and `VideoStore`. Delete `moveSendsAuthAndBody` from `APIClientReadTests.swift`. Change `writeThrowsWithoutToken` to exercise the retained classify write path:

```swift
@Test func writeThrowsWithoutToken() async {
    await #expect(throws: APIError.notConfigured) {
        _ = try await makeClient(token: nil).classify(id: 1, classification: "children")
    }
}
```

Delete `moveResult`, the fake `move(id:direction:)`, and `moveRefetchesOnSuccess` from `VideoStoreTests.swift`.

- [ ] **Step 5: Run iOS unit and package tests and verify green**

Run:

```bash
rtk test xcodebuild test -project ios/PatataTube/PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1'
rtk test swift test --package-path ios/PatataTubeKit
```

Expected: `PatataTubeTests` and all `PatataTubeKit` tests pass.

- [ ] **Step 6: Commit the iOS removal**

```bash
rtk git add ios/PatataTube/Tests/VideoCellTests.swift ios/PatataTube/Sources/VideoCell.swift ios/PatataTube/Sources/VideoGridView.swift ios/PatataTube/Sources/MovieCell.swift ios/PatataTubeKit/Sources/PatataTubeKit/APIClient.swift ios/PatataTubeKit/Sources/PatataTubeKit/VideoStore.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/APIClientReadTests.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoStoreTests.swift
rtk git commit -m "feat: remove iOS manual reorder controls"
```

---

### Task 3: Update Current Documentation and Verify the Whole Removal

**Files:**
- Modify: `ios/README.md`

**Interfaces:**
- Consumes: the completed PWA, server, and iOS removals.
- Produces: current documentation with no reorder claim and repository-wide proof that no live reorder path remains.

- [ ] **Step 1: Remove current manual-reorder documentation**

In `ios/README.md`, delete the “Reorder with up/down controls” feature bullet and the Reorder manual-test item. Change “classify/move/upload” to “classify/upload”, and change “Info / Move / classify / Delete” to “Info / classify / Delete”. Do not modify historical design or implementation-plan documents.

- [ ] **Step 2: Run static removal checks**

Run:

```bash
rtk proxy rg -n 'Move up|Move down|onMoveUp|onMoveDown|apply_move|def move_video|func move\(id: Int, direction: String\)|/videos/\{video_id\}/move|/api/videos/.*/move|class MoveRequest|class="move"|\.move\b' router.py services.py db.py views assets/app ios/PatataTube ios/PatataTubeKit ios/README.md
```

Expected: no matches. References in historical `docs/superpowers/` files are intentionally excluded.

- [ ] **Step 3: Run the complete backend test suite**

Run:

```bash
rtk pytest tests/ -q
```

Expected: all backend tests pass.

- [ ] **Step 4: Re-run complete iOS verification**

Run:

```bash
rtk test swift test --package-path ios/PatataTubeKit
rtk test xcodebuild test -project ios/PatataTube/PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1'
```

Expected: all Swift package and iOS app tests pass with no errors or warnings introduced by the removal.

- [ ] **Step 5: Inspect the final diff and commit documentation**

```bash
rtk git diff --check
rtk git diff --stat HEAD~2
rtk git status --short
rtk git add ios/README.md
rtk git commit -m "docs: remove manual reorder instructions"
```

Expected: the diff contains only the approved feature removal and its tests/docs; the pre-existing untracked `.claude/worktrees/` entry remains untouched.
