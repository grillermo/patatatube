# HLS Stream Caching Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make watched HLS bytes reusable by the offline download manager (and vice versa) on iOS, replacing the MP4 range-capture stack with `.movpkg` caching driven by `AVAssetDownloadURLSession`.

**Architecture:** Playback of a non-cached video goes through an `AVAggregateAssetDownloadTask`; the player is handed `task.urlAsset`, so AVFoundation serves already-downloaded segments from disk and fetches only the missing ones — that is the read-through cache. A `temp` entry that reaches 100% while watching is promoted to a `permanent` download; incomplete entries stay as LRU-evictable partials that a later Download tap resumes. Four small units (`HLSAssetStore`, `HLSDownloadEngine`, `PlaybackAssetProvider`, `CacheEvictor`) sit behind `CacheManager`'s existing public API so the SwiftUI layer barely changes.

**Tech Stack:** Swift 6 / SwiftPM package `PatataTubeKit`, AVFoundation (`AVAssetDownloadURLSession`, `AVAggregateAssetDownloadTask`), swift-testing (`import Testing`, `#expect`), SwiftUI app shell (XcodeGen), FastAPI + SQLite backend, pytest.

**Spec:** `docs/superpowers/specs/2026-07-25-hls-stream-caching-design.md`

## Global Constraints

- iOS only. No changes to the SSR web page or its JS.
- No local HTTP proxy. No `AVAssetResourceLoaderDelegate` for media data.
- One offline format: HLS `.movpkg`. The MP4 capture stack is deleted, not kept as a fallback.
- `CacheManager`'s public API stays as it is today: `state(for:versionId:)`, `download(id:versionId:from:preview:showPosterKey:showPoster:bearerToken:streamCount:)`, `cancel(id:versionId:)`, `removePartial(id:versionId:)`, `removeCached(id:versionId:)`, `removeAllCached(id:)`, `hasAnyCached(id:)`, `clearAllVideos()`, `clearAllCovers()`, `localURL(for:versionId:)`, `activeDownloads()`, `recentDownloads()`, `resumeInterrupted(bearerToken:)`, `setMaxConcurrentDownloads(_:)`, `maxConcurrentDownloads`, and every preview/poster method. Preview and poster code is untouched by this plan.
- Cache key format stays `"\(videoId)"` or `"\(videoId):\(versionId)"`.
- Fill-ahead (watch-driven download) runs on Wi-Fi only: `allowsCellularAccess = false`. Explicit Download taps may use cellular.
- Temp cache cap: user-configurable, default **10 GB** (`UserDefaults` key `hlsTempCacheCapBytes`), LRU by `lastPlayedAt`. `permanent` entries are never evicted.
- Auto-download rule: an entry is promoted to `permanent` when its download task reports completion, no playhead tracking.
- Python: no new dependencies. Swift: no new packages.
- Tests: `cd ios/PatataTubeKit && swift test` and `python -m pytest tests/`. New async Python tests need `@pytest.mark.asyncio` (no global asyncio mode). Python integration tests reload `db` then `main` after setting env (see the `client` fixture in `tests/test_api.py`).
- Commit after every task. `docs/` is gitignored in this repo — never `git add` plan or spec files.

---

## File Structure

**Created (Swift, `ios/PatataTubeKit/Sources/PatataTubeKit/`):**

| File | Responsibility |
|---|---|
| `HLSAssetStore.swift` | `HLSCacheEntry` + the on-disk index (`Library/hls-cache/index.json`). Foundation only, no AVFoundation. |
| `HLSCacheEviction.swift` | `CacheEvictor`: pure LRU selection + deletion through an injected closure. |
| `HLSDownloadEngine.swift` | `HLSDownloading` protocol + `HLSDownloadEngine` (real `AVAssetDownloadURLSession` implementation + delegate). |
| `PlaybackAssetProvider.swift` | `PlaybackAssetDecision` + the decision function; picks local `.movpkg` / task asset / plain remote. |

**Created (Swift tests, `ios/PatataTubeKit/Tests/PatataTubeKitTests/`):** `HLSAssetStoreTests.swift`, `HLSCacheEvictionTests.swift`, `PlaybackAssetProviderTests.swift`, `HLSCacheStateTests.swift`, `FakeHLSDownloader.swift`.

**Created (app):** `ios/PatataTube/Sources/HLSCacheSizeSettings.swift`.

**Modified:** `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift`, `Video.swift`; `ios/PatataTube/Sources/VideoPlayerView.swift`, `VideoGridView.swift`, `SettingsView.swift`, `AppModel.swift`, `PatataTubeApp.swift`, `MovieDetailView.swift`; `views/serializers.py`, `hls.py`, `db.py`, `router.py`; `tests/test_serializers.py`, `tests/test_hls.py`, `tests/test_api.py`; `ios/README.md`.

**Deleted:** `RangeFetcher.swift`, `RangeFetcherRegistry.swift`, `CaptureManager.swift`, `CapturedDownload.swift`, `CapturedRanges.swift` and the test files listed in Task 8.

---

### Task 0: Device spike — confirm four `AVAssetDownloadTask` behaviors

Throwaway code on a scratch branch. Nothing here ships. If item 1 or 2 fails, **stop and report** — the design's no-proxy premise breaks and the spec must be revised before Task 4.

**Files:**
- Create (throwaway): `ios/PatataTube/Sources/SpikeDownloadProbe.swift`
- Reference: `ios/PatataTube/Sources/SettingsView.swift` (where to hang a temporary debug button)

**Interfaces:**
- Consumes: nothing.
- Produces: findings appended to `docs/superpowers/specs/2026-07-25-hls-stream-caching-design.md` under a new `## Spike findings (2026-07-26)` heading. Task 4 reads them.

- [ ] **Step 1: Create a scratch branch**

```bash
git checkout -b spike/hls-download-probe
```

- [ ] **Step 2: Write the probe**

Create `ios/PatataTube/Sources/SpikeDownloadProbe.swift`:

```swift
import AVFoundation
import Foundation

/// Throwaway spike. Prints answers to the four questions in Task 0 of the
/// HLS stream caching plan. Delete before shipping.
final class SpikeDownloadProbe: NSObject, AVAssetDownloadDelegate {
    private var session: AVAssetDownloadURLSession!
    private var task: AVAggregateAssetDownloadTask?
    private var localURL: URL?
    private var fractionAtCancel: Double = 0

    override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: "spike.hls.probe")
        session = AVAssetDownloadURLSession(
            configuration: config, assetDownloadDelegate: self, delegateQueue: .main)
    }

    /// `master` is an authed https master.m3u8 URL; `token` the bearer token.
    func start(master: URL, token: String) async {
        let asset = AVURLAsset(url: master, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(token)"]
        ])
        let selections = asset.allMediaSelections
        print("SPIKE q4: allMediaSelections count = \(selections.count)")
        task = session.aggregateAssetDownloadTask(
            with: asset, mediaSelections: selections, assetTitle: "spike",
            assetArtworkData: nil, options: nil)
        task?.resume()

        // Cancel at roughly 20%, then restart and observe whether the first
        // progress report resumes near 20% (resume) or near 0% (restart).
        try? await Task.sleep(for: .seconds(20))
        print("SPIKE q1a: cancelling at fraction \(fractionAtCancel)")
        task?.cancel()
        try? await Task.sleep(for: .seconds(3))
        let restartAsset = AVURLAsset(url: master, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(token)"]
        ])
        task = session.aggregateAssetDownloadTask(
            with: restartAsset, mediaSelections: restartAsset.allMediaSelections,
            assetTitle: "spike", assetArtworkData: nil, options: nil)
        task?.resume()
    }

    /// q2: play the running task's asset and print whether playback starts.
    func playRunningTaskAsset() {
        guard let asset = task?.urlAsset else { print("SPIKE q2: no task"); return }
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.play()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            print("SPIKE q2: status=\(item.status.rawValue) time=\(player.currentTime().seconds)")
        }
    }

    /// q3: after cancelling, play the partial from its local URL (run in Airplane Mode).
    func playPartialOffline() {
        guard let localURL else { print("SPIKE q3: no local URL"); return }
        let item = AVPlayerItem(asset: AVURLAsset(url: localURL))
        let player = AVPlayer(playerItem: item)
        player.play()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            print("SPIKE q3: status=\(item.status.rawValue) error=\(String(describing: item.error)) time=\(player.currentTime().seconds)")
            let groups = try? await item.asset.loadMediaSelectionGroup(for: .legible)
            print("SPIKE q4 offline: legible options = \(groups?.options.count ?? -1)")
        }
    }

    func urlSession(
        _ session: URLSession, aggregateAssetDownloadTask: AVAggregateAssetDownloadTask,
        willDownloadTo location: URL
    ) {
        localURL = location
        print("SPIKE willDownloadTo: \(location.path)")
    }

    func urlSession(
        _ session: URLSession, aggregateAssetDownloadTask: AVAggregateAssetDownloadTask,
        didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue],
        timeRangeExpectedToLoad: CMTimeRange, for mediaSelection: AVMediaSelection
    ) {
        let loaded = loadedTimeRanges.reduce(0.0) { $0 + $1.timeRangeValue.duration.seconds }
        let expected = timeRangeExpectedToLoad.duration.seconds
        let fraction = expected > 0 ? loaded / expected : 0
        fractionAtCancel = fraction
        print("SPIKE progress: \(fraction) bytesReceived=\(aggregateAssetDownloadTask.countOfBytesReceived)")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        print("SPIKE didComplete error=\(String(describing: error))")
    }
}
```

- [ ] **Step 3: Hang a temporary trigger in Settings**

In `ios/PatataTube/Sources/SettingsView.swift`, inside the last `Section { … }` (the one holding "Cache all videos"), add:

```swift
                    Button("SPIKE: probe HLS download") {
                        guard let base = model.credentials.baseURL,
                              let token = model.credentials.token,
                              let video = model.store.videos.first(where: { $0.hlsPath != nil }),
                              let path = video.hlsPath else { return }
                        let master = base.appendingPathComponent(
                            path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                        let probe = SpikeDownloadProbe()
                        SpikeProbeHolder.shared = probe
                        Task { await probe.start(master: master, token: token) }
                    }
                    Button("SPIKE: play running task asset") { SpikeProbeHolder.shared?.playRunningTaskAsset() }
                    Button("SPIKE: play partial offline") { SpikeProbeHolder.shared?.playPartialOffline() }
```

And at the bottom of `SpikeDownloadProbe.swift`:

```swift
enum SpikeProbeHolder {
    @MainActor static var shared: SpikeDownloadProbe?
}
```

- [ ] **Step 4: Build, install, run on the iPad, capture the log**

```bash
cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

Install the build on the device (same route `./deploy` uses), open Settings, tap the three SPIKE buttons in order (Airplane Mode on before the third), and read the console output with the device attached (Xcode → Window → Devices and Simulators → Open Console, filter `SPIKE`).

Record the answers:
1. **Resume**: after cancel + recreate, does the first `SPIKE progress:` line come back near the cancel fraction (resume) or near `0.0` (restart)?
2. **Play-while-downloading**: does `SPIKE q2` print `status=1` (readyToPlay) and a non-zero time?
3. **Partial offline**: does `SPIKE q3` print `status=1` with `error=nil`?
4. **Selections**: is `allMediaSelections count` > 1, and does `q4 offline` report legible options > 0?

- [ ] **Step 5: Write findings into the spec**

Append to `docs/superpowers/specs/2026-07-25-hls-stream-caching-design.md`:

```markdown
## Spike findings (2026-07-26)

1. Cancelled-task resume: <resumes from ~N% | restarts from 0>
2. `task.urlAsset` playback while downloading: <works | fails: …>
3. Partial `.movpkg` offline playback: <works | fails: …>
4. Aggregate task media selections: count=<N>, legible options offline=<N>
```

If (1) says "restarts from 0", also record that Task 4 must resume by constructing `AVURLAsset(url: <persisted .movpkg URL>)` instead of the remote URL, and re-run the probe with that variant to confirm it resumes.

- [ ] **Step 6: Throw the spike away**

```bash
git checkout main && git branch -D spike/hls-download-probe
```

Nothing from this task is committed.

---

### Task 1: Backend — real HLS status, exposed status, rebuild endpoint

**Files:**
- Modify: `hls.py:275-281` (`prepare`), `db.py:530-533` (`set_hls_status`)
- Modify: `views/serializers.py:64-90` (`serialize_video`)
- Modify: `router.py` (add rebuild endpoint next to `hls_asset`, ~line 597; add the error guard inside `hls_asset` at ~line 594)
- Test: `tests/test_hls.py`, `tests/test_serializers.py`, `tests/test_api.py`

**Interfaces:**
- Consumes: nothing.
- Produces: `hls_status` string in every `/api/videos` row (`"none" | "converting" | "done" | "error"`); `POST /api/videos/{video_id}/hls/rebuild` returning `{"status": "none"}`; `db.set_hls_status(video_id: int, status: str, error_msg: str | None = None)`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_hls.py`:

```python
def test_prepare_records_error_status_on_failure(monkeypatch, tmp_path):
    import db
    import hls

    statuses = []
    monkeypatch.setattr(db, "get_video", lambda video_id: {"id": video_id, "audio_lang": None})
    monkeypatch.setattr(
        db, "set_hls_status",
        lambda video_id, status, error_msg=None: statuses.append((status, error_msg)),
    )

    def boom(*args, **kwargs):
        raise RuntimeError("ffmpeg exploded")

    monkeypatch.setattr(hls, "build_hls_package", boom)

    hls.prepare(7, str(tmp_path / "in.mp4"))

    assert statuses == [("error", "ffmpeg exploded")]
```

Append to `tests/test_serializers.py`:

```python
def test_serialize_video_exposes_hls_status():
    from views.serializers import serialize_video

    row = {
        "id": 3, "url": "https://x.test/1", "status": "done",
        "hls_status": "error", "source": "download",
    }
    data = serialize_video(row)
    assert data["hls_status"] == "error"


def test_serialize_video_defaults_hls_status_to_none():
    from views.serializers import serialize_video

    row = {"id": 4, "url": "https://x.test/2", "status": "queued", "source": "download"}
    assert serialize_video(row)["hls_status"] == "none"
```

Append to `tests/test_api.py`:

```python
def test_hls_rebuild_resets_status(client):
    import db

    video_id = db.add_video("https://twitter.com/x/status/55", "twitter")
    db.update_video(video_id, status="done", filename=f"{video_id}.mp4")
    db.set_hls_status(video_id, "error", "ffmpeg exploded")

    resp = client.post(
        f"/api/videos/{video_id}/hls/rebuild",
        headers={"Authorization": "Bearer test-secret"},
    )

    assert resp.status_code == 200
    assert resp.json() == {"status": "none"}
    assert db.get_video(video_id)["hls_status"] == "none"


def test_hls_rebuild_requires_token(client):
    import db

    video_id = db.add_video("https://twitter.com/x/status/56", "twitter")
    resp = client.post(f"/api/videos/{video_id}/hls/rebuild")
    assert resp.status_code == 401


def test_hls_master_does_not_repackage_while_errored(client, monkeypatch):
    import db
    import router

    video_id = db.add_video("https://twitter.com/x/status/57", "twitter")
    db.update_video(video_id, status="done", filename=f"{video_id}.mp4")
    db.set_hls_status(video_id, "error", "ffmpeg exploded")
    (router.VIDEOS_DIR / f"{video_id}.mp4").write_bytes(b"x")

    called = []
    monkeypatch.setattr(router.hls, "prepare", lambda *a, **k: called.append(a))

    resp = client.get(
        f"/videos/{video_id}/hls/master.m3u8",
        headers={"Authorization": "Bearer test-secret"},
    )

    assert resp.status_code == 409
    assert resp.json()["detail"] == "HLS packaging failed"
    assert called == []
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
python -m pytest tests/test_hls.py::test_prepare_records_error_status_on_failure tests/test_serializers.py -k hls_status tests/test_api.py -k hls_rebuild -v
```

Expected: FAIL — `set_hls_status()` takes 2 positional args, `KeyError`/missing `hls_status`, and 404/405 on the rebuild route.

- [ ] **Step 3: Implement**

`db.py` — replace `set_hls_status`:

```python
def set_hls_status(video_id: int, status: str, error_msg: str | None = None) -> None:
    """Track HLS package readiness: 'none' | 'converting' | 'done' | 'error'.

    'error' means packaging failed for this source and retrying it unprompted
    is pointless — only an explicit rebuild clears it.
    """
    with _conn() as conn:
        conn.execute(
            "UPDATE videos SET hls_status = ?, hls_error_msg = ? WHERE id = ?",
            (status, error_msg, video_id),
        )
```

`db.py` — add an idempotent column guard next to the existing `hls_status` guard (line ~94), matching the surrounding style:

```python
    _add_column(conn, "ALTER TABLE videos ADD COLUMN hls_error_msg TEXT")
```

(Use whatever the neighbouring guard helper is actually called at `db.py:94`; keep it identical to the `hls_status` line above it.)

`hls.py` — replace the `except` block of `prepare`:

```python
    except Exception as exc:  # noqa: BLE001 - background task, must not raise
        traceback.print_exc()
        db.set_hls_status(video_id, "error", str(exc).strip()[:500] or "HLS packaging failed")
```

`views/serializers.py` — inside `serialize_video`'s `data` dict, after `"status": video["status"],`:

```python
        "hls_status": video.get("hls_status") or "none",
        "hls_error_msg": video.get("hls_error_msg"),
```

`router.py` — inside `hls_asset`, replace the master-playlist branch:

```python
    if asset_path == "master.m3u8":
        status = video.get("hls_status")
        if status == "error":
            return JSONResponse({"detail": "HLS packaging failed"}, status_code=409)
        if status != "converting":
            db.set_hls_status(video_id, "converting")
            background_tasks.add_task(hls.prepare, video_id, str(source))
        return JSONResponse({"detail": "HLS preparing"}, status_code=409)
```

`router.py` — add after `hls_asset`:

```python
@router.post("/api/videos/{video_id}/hls/rebuild")
async def hls_rebuild(video_id: int, request: Request):
    """Discard a video's HLS package and clear its status so the next play
    repackages it. The only way out of hls_status='error'."""
    _check_token(request)
    video = db.get_video(video_id)
    if not video or video.get("deleted_at"):
        raise HTTPException(status_code=404, detail="Video not found")
    hls.invalidate(video_id)
    return {"status": "none"}
```

`hls.py` — `invalidate` already calls `db.set_hls_status(video_id, "none")`, which now also clears `hls_error_msg`. No change needed there.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
python -m pytest tests/ -q
```

Expected: all PASS (the whole suite, since `set_hls_status`'s signature changed).

- [ ] **Step 5: Commit**

```bash
git add hls.py db.py views/serializers.py router.py tests/test_hls.py tests/test_serializers.py tests/test_api.py
git commit -m "feat(hls): record packaging failures and expose hls_status

A failed hls.prepare reverted status to 'none', so every master.m3u8 poll
relaunched ffmpeg and the client could not tell 'not built yet' from
'cannot build'. Failures now persist as 'error' with a message, the API
exposes hls_status/hls_error_msg, and POST /api/videos/{id}/hls/rebuild
is the explicit way to retry.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: `Video.hlsStatus` + `HLSAssetStore`

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/Video.swift:73-176`
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/HLSAssetStore.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoTests.swift`, `ios/PatataTubeKit/Tests/PatataTubeKitTests/HLSAssetStoreTests.swift`

**Interfaces:**
- Consumes: `hls_status` / `hls_error_msg` JSON from Task 1.
- Produces:
  - `Video.hlsStatus: String` (defaults `"none"`), `Video.hlsErrorMsg: String?`
  - `struct HLSCacheEntry: Codable, Equatable, Sendable` with `cacheKey, videoId, versionId, bookmark: Data, kind: HLSCacheEntry.Kind, isComplete: Bool, fractionComplete: Double, byteCount: Int64, lastPlayedAt: Date, audioLang: String?`
  - `enum HLSCacheEntry.Kind: String, Codable, Sendable { case temp, permanent }`
  - `final class HLSAssetStore: @unchecked Sendable` with `init(root: URL, fileManager: FileManager = .default)`, `func entries() -> [HLSCacheEntry]`, `func entry(cacheKey: String) -> HLSCacheEntry?`, `func upsert(_ entry: HLSCacheEntry)`, `func remove(cacheKey: String)`, `func removeAll()`, `func resolve(_ entry: HLSCacheEntry) -> URL?`, `static func makeBookmark(for url: URL) -> Data?`, `func directorySize(of url: URL) -> Int64`

- [ ] **Step 1: Write the failing tests**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/HLSAssetStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import PatataTubeKit

private func storeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("hls-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// A real directory so bookmarks resolve.
private func makePackage(in root: URL, named name: String) throws -> URL {
    let url = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try Data(repeating: 0x7, count: 2048).write(to: url.appendingPathComponent("data.bin"))
    return url
}

@Suite("HLS asset store")
struct HLSAssetStoreTests {
    @Test func upsertAndLookupRoundTrip() throws {
        let root = try storeRoot()
        let store = HLSAssetStore(root: root)
        let package = try makePackage(in: root, named: "9.movpkg")
        let bookmark = try #require(HLSAssetStore.makeBookmark(for: package))

        let entry = HLSCacheEntry(
            cacheKey: "9", videoId: 9, versionId: nil, bookmark: bookmark,
            kind: .temp, isComplete: false, fractionComplete: 0.25,
            byteCount: 2048, lastPlayedAt: Date(timeIntervalSince1970: 100),
            audioLang: "eng")
        store.upsert(entry)

        #expect(store.entry(cacheKey: "9") == entry)
        #expect(store.entries().count == 1)
    }

    @Test func indexSurvivesAFreshInstance() throws {
        let root = try storeRoot()
        let package = try makePackage(in: root, named: "4.v2.movpkg")
        let bookmark = try #require(HLSAssetStore.makeBookmark(for: package))
        HLSAssetStore(root: root).upsert(HLSCacheEntry(
            cacheKey: "4:2", videoId: 4, versionId: 2, bookmark: bookmark,
            kind: .permanent, isComplete: true, fractionComplete: 1,
            byteCount: 2048, lastPlayedAt: Date(), audioLang: nil))

        let reopened = HLSAssetStore(root: root)
        #expect(reopened.entry(cacheKey: "4:2")?.kind == .permanent)
        #expect(reopened.entry(cacheKey: "4:2")?.isComplete == true)
    }

    @Test func removeDropsTheRowAndThePackage() throws {
        let root = try storeRoot()
        let store = HLSAssetStore(root: root)
        let package = try makePackage(in: root, named: "5.movpkg")
        store.upsert(HLSCacheEntry(
            cacheKey: "5", videoId: 5, versionId: nil,
            bookmark: try #require(HLSAssetStore.makeBookmark(for: package)),
            kind: .temp, isComplete: false, fractionComplete: 0.1,
            byteCount: 2048, lastPlayedAt: Date(), audioLang: nil))

        store.remove(cacheKey: "5")

        #expect(store.entry(cacheKey: "5") == nil)
        #expect(!FileManager.default.fileExists(atPath: package.path))
    }

    @Test func resolveReturnsNilAndDropsRowWhenPackageIsGone() throws {
        let root = try storeRoot()
        let store = HLSAssetStore(root: root)
        let package = try makePackage(in: root, named: "6.movpkg")
        let entry = HLSCacheEntry(
            cacheKey: "6", videoId: 6, versionId: nil,
            bookmark: try #require(HLSAssetStore.makeBookmark(for: package)),
            kind: .permanent, isComplete: true, fractionComplete: 1,
            byteCount: 2048, lastPlayedAt: Date(), audioLang: nil)
        store.upsert(entry)
        try FileManager.default.removeItem(at: package)

        #expect(store.resolve(entry) == nil)
        #expect(store.entry(cacheKey: "6") == nil)
    }

    @Test func corruptIndexIsTreatedAsEmpty() throws {
        let root = try storeRoot()
        try Data("not json".utf8).write(
            to: root.appendingPathComponent("hls-cache").appendingPathComponent("index.json"),
            options: [])
        // The directory may not exist yet; create it first, then rewrite garbage.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("hls-cache"), withIntermediateDirectories: true)
        try Data("not json".utf8).write(
            to: root.appendingPathComponent("hls-cache").appendingPathComponent("index.json"))

        let store = HLSAssetStore(root: root)
        #expect(store.entries().isEmpty)

        let package = try makePackage(in: root, named: "8.movpkg")
        store.upsert(HLSCacheEntry(
            cacheKey: "8", videoId: 8, versionId: nil,
            bookmark: try #require(HLSAssetStore.makeBookmark(for: package)),
            kind: .temp, isComplete: false, fractionComplete: 0,
            byteCount: 2048, lastPlayedAt: Date(), audioLang: nil))
        #expect(HLSAssetStore(root: root).entries().count == 1)
    }

    @Test func directorySizeSumsTheContents() throws {
        let root = try storeRoot()
        let store = HLSAssetStore(root: root)
        let package = try makePackage(in: root, named: "10.movpkg")
        #expect(store.directorySize(of: package) >= 2048)
    }
}
```

Append to `ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoTests.swift`:

```swift
    @Test func decodesHLSStatusAndError() throws {
        let json = """
        {"id": 1, "url": "https://x.test/1", "status": "done",
         "classification": "children", "stream_path": "/videos/1/stream",
         "hls_status": "error", "hls_error_msg": "ffmpeg exploded"}
        """
        let video = try JSONDecoder().decode(Video.self, from: Data(json.utf8))
        #expect(video.hlsStatus == "error")
        #expect(video.hlsErrorMsg == "ffmpeg exploded")
    }

    @Test func defaultsHLSStatusToNoneWhenAbsent() throws {
        let json = """
        {"id": 2, "url": "https://x.test/2", "status": "queued",
         "classification": "children", "stream_path": "/videos/2/stream"}
        """
        let video = try JSONDecoder().decode(Video.self, from: Data(json.utf8))
        #expect(video.hlsStatus == "none")
        #expect(video.hlsErrorMsg == nil)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd ios/PatataTubeKit && swift test 2>&1 | tail -20
```

Expected: FAIL — `cannot find 'HLSAssetStore' in scope`, `Video has no member 'hlsStatus'`.

- [ ] **Step 3: Implement `HLSAssetStore`**

Create `ios/PatataTubeKit/Sources/PatataTubeKit/HLSAssetStore.swift`:

```swift
import Foundation

/// One cached HLS package. The `.movpkg` location is chosen by AVFoundation, so
/// it is stored as a bookmark and never assumed to exist: iOS may purge these
/// packages, and a moved package must never be resurrected from a stale path.
struct HLSCacheEntry: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Written by watching. LRU-evictable.
        case temp
        /// The user asked for it (or a watch completed it). Never evicted.
        case permanent
    }

    let cacheKey: String
    let videoId: Int
    let versionId: Int?
    var bookmark: Data
    var kind: Kind
    var isComplete: Bool
    /// Time-based, as reported by AVFoundation — not a byte ratio.
    var fractionComplete: Double
    var byteCount: Int64
    var lastPlayedAt: Date
    /// Audio language the package was built with. A different server-side choice
    /// makes this package stale.
    var audioLang: String?
}

/// The cache index. Disk bookkeeping only — no AVFoundation, no networking, so
/// every rule here is unit-testable.
final class HLSAssetStore: @unchecked Sendable {
    private let root: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var index: [String: HLSCacheEntry]

    init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
        self.index = Self.load(indexURL: Self.indexURL(root: root), fileManager: fileManager)
    }

    private static func indexURL(root: URL) -> URL {
        root.appendingPathComponent("hls-cache", isDirectory: true)
            .appendingPathComponent("index.json")
    }

    /// A corrupt or missing index is an empty cache, never a crash: the packages
    /// it described are unreachable without their bookmarks anyway.
    private static func load(indexURL: URL, fileManager: FileManager) -> [String: HLSCacheEntry] {
        guard let data = try? Data(contentsOf: indexURL),
              let entries = try? JSONDecoder().decode([HLSCacheEntry].self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.cacheKey, $0) })
    }

    private func persistLocked() {
        let url = Self.indexURL(root: root)
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Array(index.values)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func entries() -> [HLSCacheEntry] {
        lock.withLock { Array(index.values) }
    }

    func entry(cacheKey: String) -> HLSCacheEntry? {
        lock.withLock { index[cacheKey] }
    }

    func upsert(_ entry: HLSCacheEntry) {
        lock.withLock {
            index[entry.cacheKey] = entry
            persistLocked()
        }
    }

    /// Drops the row *and* deletes the package it points at.
    func remove(cacheKey: String) {
        let entry = lock.withLock { () -> HLSCacheEntry? in
            let entry = index.removeValue(forKey: cacheKey)
            persistLocked()
            return entry
        }
        guard let entry, let url = resolveWithoutPruning(entry) else { return }
        try? fileManager.removeItem(at: url)
    }

    func removeAll() {
        for entry in entries() { remove(cacheKey: entry.cacheKey) }
    }

    static func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData()
    }

    /// The package's current location, or nil when it is gone — in which case the
    /// row is dropped so `state(for:)` reports `.notCached` from then on.
    func resolve(_ entry: HLSCacheEntry) -> URL? {
        guard let url = resolveWithoutPruning(entry) else {
            lock.withLock {
                index.removeValue(forKey: entry.cacheKey)
                persistLocked()
            }
            return nil
        }
        return url
    }

    private func resolveWithoutPruning(_ entry: HLSCacheEntry) -> URL? {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: entry.bookmark, bookmarkDataIsStale: &stale),
            fileManager.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    /// Bytes a `.movpkg` occupies. Walked on demand (task end, eviction scan),
    /// never per progress callback.
    func directorySize(of url: URL) -> Int64 {
        guard let walker = fileManager.enumerator(
            at: url, includingPropertiesForKeys: [.fileAllocatedSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let child as URL in walker {
            let size = (try? child.resourceValues(forKeys: [.fileAllocatedSizeKey]))?
                .fileAllocatedSize ?? 0
            total += Int64(size)
        }
        return total
    }
}
```

- [ ] **Step 4: Implement the `Video` fields**

In `ios/PatataTubeKit/Sources/PatataTubeKit/Video.swift`:

- next to `public let hlsPath: String?` (line ~73) add:

```swift
    /// Server-side HLS packaging state: "none" | "converting" | "done" | "error".
    /// "error" means this source cannot be packaged; only an explicit rebuild retries.
    public let hlsStatus: String
    public let hlsErrorMsg: String?
```

- add `hlsStatus, hlsErrorMsg` to the `CodingKeys` list (line ~81, alongside `hlsPath`).
- in the memberwise `init` (line ~94) add parameters `hlsStatus: String = "none", hlsErrorMsg: String? = nil` right after `hlsPath:`, and assign them next to `self.hlsPath = hlsPath`.
- in `init(from decoder:)` (line ~129) add:

```swift
        self.hlsStatus = try c.decodeIfPresent(String.self, forKey: .hlsStatus) ?? "none"
        self.hlsErrorMsg = try c.decodeIfPresent(String.self, forKey: .hlsErrorMsg)
```

- in each of the three copy helpers (lines ~142, ~162, ~173) pass `hlsStatus: hlsStatus, hlsErrorMsg: hlsErrorMsg` alongside the existing `hlsPath: hlsPath,`.

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd ios/PatataTubeKit && swift test 2>&1 | tail -20
```

Expected: PASS, whole suite green.

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/HLSAssetStore.swift ios/PatataTubeKit/Sources/PatataTubeKit/Video.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/HLSAssetStoreTests.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoTests.swift
git commit -m "feat(ios): add HLS cache index and hls_status decoding

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: `CacheEvictor` + configurable cap

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/HLSCacheEviction.swift`
- Create: `ios/PatataTube/Sources/HLSCacheSizeSettings.swift`
- Modify: `ios/PatataTube/Sources/AppModel.swift` (settings load/save, mirroring `downloadStreamCount`), `ios/PatataTube/Sources/SettingsView.swift` (new row in the `Downloads` section)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/HLSCacheEvictionTests.swift`

**Interfaces:**
- Consumes: `HLSCacheEntry`, `HLSCacheEntry.Kind` (Task 2).
- Produces:
  - `enum CacheEvictor { static func keysToEvict(entries: [HLSCacheEntry], capBytes: Int64, protectedKeys: Set<String>) -> [String] }`
  - `HLSCacheSizeSettings` (app target) with `static let key = "hlsTempCacheCapBytes"`, `static let defaultBytes: Int64 = 10 * 1_073_741_824`, `static let allowedGigabytes = 1...200`, `func load() -> Int64`, `func save(_ bytes: Int64)`
  - `AppModel.hlsCacheCapGigabytes: Int` (published, persisted through `saveSettings()`)

- [ ] **Step 1: Write the failing test**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/HLSCacheEvictionTests.swift`:

```swift
import Foundation
import Testing
@testable import PatataTubeKit

private func entry(
    _ key: String, kind: HLSCacheEntry.Kind, bytes: Int64, playedAt: TimeInterval
) -> HLSCacheEntry {
    HLSCacheEntry(
        cacheKey: key, videoId: Int(key.prefix(1)) ?? 0, versionId: nil,
        bookmark: Data([0x1]), kind: kind, isComplete: false,
        fractionComplete: 0.5, byteCount: bytes,
        lastPlayedAt: Date(timeIntervalSince1970: playedAt), audioLang: nil)
}

@Suite("HLS cache eviction")
struct HLSCacheEvictionTests {
    @Test func noEvictionWhenUnderCap() {
        let keys = CacheEvictor.keysToEvict(
            entries: [entry("1", kind: .temp, bytes: 100, playedAt: 1)],
            capBytes: 1_000, protectedKeys: [])
        #expect(keys.isEmpty)
    }

    @Test func evictsOldestTempFirstUntilUnderCap() {
        let entries = [
            entry("1", kind: .temp, bytes: 400, playedAt: 30),
            entry("2", kind: .temp, bytes: 400, playedAt: 10),
            entry("3", kind: .temp, bytes: 400, playedAt: 20),
        ]
        let keys = CacheEvictor.keysToEvict(
            entries: entries, capBytes: 900, protectedKeys: [])
        #expect(keys == ["2"])
    }

    @Test func evictsMultipleWhenOneIsNotEnough() {
        let entries = [
            entry("1", kind: .temp, bytes: 400, playedAt: 30),
            entry("2", kind: .temp, bytes: 400, playedAt: 10),
            entry("3", kind: .temp, bytes: 400, playedAt: 20),
        ]
        let keys = CacheEvictor.keysToEvict(
            entries: entries, capBytes: 500, protectedKeys: [])
        #expect(keys == ["2", "3"])
    }

    @Test func permanentEntriesAreNeitherEvictedNorCounted() {
        let entries = [
            entry("1", kind: .permanent, bytes: 5_000, playedAt: 1),
            entry("2", kind: .temp, bytes: 100, playedAt: 2),
        ]
        let keys = CacheEvictor.keysToEvict(
            entries: entries, capBytes: 1_000, protectedKeys: [])
        #expect(keys.isEmpty)
    }

    @Test func protectedKeysAreSkippedEvenWhenOldest() {
        let entries = [
            entry("1", kind: .temp, bytes: 400, playedAt: 10),
            entry("2", kind: .temp, bytes: 400, playedAt: 20),
        ]
        let keys = CacheEvictor.keysToEvict(
            entries: entries, capBytes: 500, protectedKeys: ["1"])
        #expect(keys == ["2"])
    }

    @Test func zeroCapEvictsEveryUnprotectedTemp() {
        let entries = [
            entry("1", kind: .temp, bytes: 1, playedAt: 10),
            entry("2", kind: .permanent, bytes: 1, playedAt: 20),
        ]
        let keys = CacheEvictor.keysToEvict(
            entries: entries, capBytes: 0, protectedKeys: [])
        #expect(keys == ["1"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd ios/PatataTubeKit && swift test --filter HLSCacheEvictionTests 2>&1 | tail -10
```

Expected: FAIL — `cannot find 'CacheEvictor' in scope`.

- [ ] **Step 3: Implement**

Create `ios/PatataTubeKit/Sources/PatataTubeKit/HLSCacheEviction.swift`:

```swift
import Foundation

/// LRU policy for the temporary watch cache. Pure selection: the caller deletes.
enum CacheEvictor {
    /// Cache keys to drop so `temp` entries fit inside `capBytes`.
    ///
    /// `permanent` entries are what the user asked to keep — they are neither
    /// counted against the cap nor evicted. `protectedKeys` are keys with a live
    /// download task; evicting one would delete a package AVFoundation is
    /// writing to.
    static func keysToEvict(
        entries: [HLSCacheEntry], capBytes: Int64, protectedKeys: Set<String>
    ) -> [String] {
        let temps = entries.filter { $0.kind == .temp }
        var total = temps.reduce(Int64(0)) { $0 + $1.byteCount }
        guard total > capBytes else { return [] }

        var victims: [String] = []
        for candidate in temps
            .filter({ !protectedKeys.contains($0.cacheKey) })
            .sorted(by: { $0.lastPlayedAt < $1.lastPlayedAt })
        {
            guard total > capBytes else { break }
            victims.append(candidate.cacheKey)
            total -= candidate.byteCount
        }
        return victims
    }
}
```

Create `ios/PatataTube/Sources/HLSCacheSizeSettings.swift` (mirrors `DownloadStreamSettings`):

```swift
import Foundation

/// Size cap for the temporary watch cache, in bytes. Stored as bytes so the
/// cache layer needs no unit conversion; edited in whole gigabytes in Settings.
struct HLSCacheSizeSettings {
    static let key = "hlsTempCacheCapBytes"
    static let bytesPerGigabyte: Int64 = 1_073_741_824
    static let defaultGigabytes = 10
    static let allowedGigabytes = 1...200
    static var defaultBytes: Int64 { Int64(defaultGigabytes) * bytesPerGigabyte }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> Int64 {
        guard defaults.object(forKey: Self.key) != nil else { return Self.defaultBytes }
        let gigabytes = Int(defaults.integer(forKey: Self.key) / Int(Self.bytesPerGigabyte))
        let clamped = min(
            max(gigabytes, Self.allowedGigabytes.lowerBound),
            Self.allowedGigabytes.upperBound)
        return Int64(clamped) * Self.bytesPerGigabyte
    }

    func save(_ bytes: Int64) {
        let gigabytes = min(
            max(Int(bytes / Self.bytesPerGigabyte), Self.allowedGigabytes.lowerBound),
            Self.allowedGigabytes.upperBound)
        defaults.set(Int64(gigabytes) * Self.bytesPerGigabyte, forKey: Self.key)
    }
}
```

In `ios/PatataTube/Sources/AppModel.swift`, alongside the existing `downloadStreamCount` / `downloadConcurrency` handling (see `AppModel.swift:105-114`):

```swift
    @Published var hlsCacheCapGigabytes: Int = HLSCacheSizeSettings.defaultGigabytes
```

…initialize it in `init` from `hlsCacheSettings.load()` (`Int(bytes / HLSCacheSizeSettings.bytesPerGigabyte)`), add `private let hlsCacheSettings = HLSCacheSizeSettings()`, and in `saveSettings()`:

```swift
        let capBytes = Int64(hlsCacheCapGigabytes) * HLSCacheSizeSettings.bytesPerGigabyte
        hlsCacheSettings.save(capBytes)
        cache.setTempCacheCap(bytes: capBytes)
```

`setTempCacheCap(bytes:)` arrives in Task 6; until then this line will not compile, so **add it in Task 6** and leave the `hlsCacheSettings.save(capBytes)` line here.

In `ios/PatataTube/Sources/SettingsView.swift`, inside `Section("Downloads")` after the "Simultaneous downloads" stepper:

```swift
                    Stepper(
                        value: $model.hlsCacheCapGigabytes,
                        in: HLSCacheSizeSettings.allowedGigabytes
                    ) {
                        LabeledContent(
                            "Watch cache limit",
                            value: "\(model.hlsCacheCapGigabytes) GB"
                        )
                    }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd ios/PatataTubeKit && swift test 2>&1 | tail -10
cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS' -allowProvisioningUpdates build 2>&1 | tail -5
```

Expected: `swift test` PASS. The app build also PASSes (the `setTempCacheCap` call is deliberately not added yet).

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/HLSCacheEviction.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/HLSCacheEvictionTests.swift ios/PatataTube/Sources/HLSCacheSizeSettings.swift ios/PatataTube/Sources/AppModel.swift ios/PatataTube/Sources/SettingsView.swift
git commit -m "feat(ios): add LRU eviction policy and watch-cache size setting

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: `HLSDownloadEngine`

The only unit that touches `AVAssetDownloadURLSession`. Not unit-testable — its contract is a protocol that Tasks 5 and 6 test against a fake, plus the Task 0 spike and the manual checklist in Task 8.

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/HLSDownloadEngine.swift`
- Create: `ios/PatataTubeKit/Tests/PatataTubeKitTests/FakeHLSDownloader.swift`
- Reference: Task 0's spike findings in the spec.

**Interfaces:**
- Consumes: `HLSAssetStore`, `HLSCacheEntry` (Task 2).
- Produces:

```swift
struct HLSDownloadRequest: Sendable {
    let cacheKey: String
    let videoId: Int
    let versionId: Int?
    let master: URL
    let bearerToken: String?
    let title: String
    let audioLang: String?
    /// Fill-ahead started by playback (Wi-Fi only, entry stays `.temp` until complete)
    /// vs an explicit Download tap (cellular allowed, entry is `.permanent` at once).
    let isFillAhead: Bool
}

enum HLSDownloadEvent: Sendable {
    case progress(cacheKey: String, fraction: Double, transferredBytes: Int64)
    case finished(cacheKey: String)
    case failed(cacheKey: String, error: Error)
    case cancelled(cacheKey: String)
}

protocol HLSDownloading: AnyObject, Sendable {
    func start(_ request: HLSDownloadRequest) -> AVURLAsset?
    func cancel(cacheKey: String)
    func isRunning(cacheKey: String) -> Bool
    func runningKeys() -> Set<String>
    func restoreTasks() async
    func setEventHandler(_ handler: @escaping @Sendable (HLSDownloadEvent) -> Void)
}
```

- [ ] **Step 1: Write the fake (the testable seam other tasks consume)**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/FakeHLSDownloader.swift`:

```swift
import AVFoundation
import Foundation
@testable import PatataTubeKit

/// Scriptable stand-in for `HLSDownloadEngine`. Records requests and lets a test
/// emit progress/terminal events synchronously.
final class FakeHLSDownloader: HLSDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (HLSDownloadEvent) -> Void)?
    private var running: Set<String> = []
    private(set) var requests: [HLSDownloadRequest] = []
    private(set) var cancelledKeys: [String] = []
    var restoreCallCount = 0
    /// Asset handed back by `start`; nil simulates a session that refused the task.
    var assetToReturn: AVURLAsset? = AVURLAsset(url: URL(string: "https://fake.test/m.m3u8")!)

    func start(_ request: HLSDownloadRequest) -> AVURLAsset? {
        lock.withLock {
            requests.append(request)
            running.insert(request.cacheKey)
        }
        return assetToReturn
    }

    func cancel(cacheKey: String) {
        lock.withLock {
            cancelledKeys.append(cacheKey)
            running.remove(cacheKey)
        }
        emit(.cancelled(cacheKey: cacheKey))
    }

    func isRunning(cacheKey: String) -> Bool {
        lock.withLock { running.contains(cacheKey) }
    }

    func runningKeys() -> Set<String> {
        lock.withLock { running }
    }

    func restoreTasks() async {
        lock.withLock { restoreCallCount += 1 }
    }

    func setEventHandler(_ handler: @escaping @Sendable (HLSDownloadEvent) -> Void) {
        lock.withLock { self.handler = handler }
    }

    // MARK: Test drivers

    func emitProgress(cacheKey: String, fraction: Double, bytes: Int64 = 1_024) {
        emit(.progress(cacheKey: cacheKey, fraction: fraction, transferredBytes: bytes))
    }

    func emitFinished(cacheKey: String) {
        lock.withLock { running.remove(cacheKey) }
        emit(.finished(cacheKey: cacheKey))
    }

    func emitFailure(cacheKey: String, error: Error) {
        lock.withLock { running.remove(cacheKey) }
        emit(.failed(cacheKey: cacheKey, error: error))
    }

    private func emit(_ event: HLSDownloadEvent) {
        let handler = lock.withLock { self.handler }
        handler?(event)
    }
}
```

- [ ] **Step 2: Implement the engine**

Create `ios/PatataTubeKit/Sources/PatataTubeKit/HLSDownloadEngine.swift`:

```swift
import AVFoundation
import Foundation

struct HLSDownloadRequest: Sendable {
    let cacheKey: String
    let videoId: Int
    let versionId: Int?
    let master: URL
    let bearerToken: String?
    let title: String
    let audioLang: String?
    /// Fill-ahead started by playback (Wi-Fi only) vs an explicit Download tap.
    let isFillAhead: Bool
}

enum HLSDownloadEvent: Sendable {
    case progress(cacheKey: String, fraction: Double, transferredBytes: Int64)
    case finished(cacheKey: String)
    case failed(cacheKey: String, error: Error)
    case cancelled(cacheKey: String)
}

enum HLSDownloadError: Error, Equatable {
    /// The session refused to create a task (bad asset, or no HLS at that URL).
    case taskCreationFailed
}

protocol HLSDownloading: AnyObject, Sendable {
    /// Starts (or resumes) the download for `request` and returns the asset the
    /// player should use. Returning the *task's* asset is what makes playback
    /// read through the download's own store.
    func start(_ request: HLSDownloadRequest) -> AVURLAsset?
    func cancel(cacheKey: String)
    func isRunning(cacheKey: String) -> Bool
    func runningKeys() -> Set<String>
    /// Reattaches to tasks that survived app suspension/termination.
    func restoreTasks() async
    func setEventHandler(_ handler: @escaping @Sendable (HLSDownloadEvent) -> Void)
}

/// Owns the app's two `AVAssetDownloadURLSession`s: one Wi-Fi-only session for
/// watch-driven fill-ahead, one unrestricted session for explicit downloads.
/// A session is one-per-identifier and must never be invalidated, so both live
/// for the app's lifetime.
final class HLSDownloadEngine: NSObject, HLSDownloading, AVAssetDownloadDelegate, @unchecked Sendable {
    private let store: HLSAssetStore
    private let lock = NSLock()
    private var handler: (@Sendable (HLSDownloadEvent) -> Void)?
    private var tasksByKey: [String: AVAggregateAssetDownloadTask] = [:]
    private var keysByTask: [Int: String] = [:]
    private var requestsByKey: [String: HLSDownloadRequest] = [:]

    private var fillAheadSession: AVAssetDownloadURLSession!
    private var manualSession: AVAssetDownloadURLSession!

    init(store: HLSAssetStore) {
        self.store = store
        super.init()
        let fillAhead = URLSessionConfiguration.background(
            withIdentifier: "patatatube.hls.fillahead")
        // Watching must never spend cellular data in the background; an explicit
        // Download tap goes through `manualSession` instead.
        fillAhead.allowsCellularAccess = false
        fillAheadSession = AVAssetDownloadURLSession(
            configuration: fillAhead, assetDownloadDelegate: self, delegateQueue: .main)

        let manual = URLSessionConfiguration.background(withIdentifier: "patatatube.hls.manual")
        manual.allowsCellularAccess = true
        manualSession = AVAssetDownloadURLSession(
            configuration: manual, assetDownloadDelegate: self, delegateQueue: .main)
    }

    func setEventHandler(_ handler: @escaping @Sendable (HLSDownloadEvent) -> Void) {
        lock.withLock { self.handler = handler }
    }

    func isRunning(cacheKey: String) -> Bool {
        lock.withLock { tasksByKey[cacheKey] != nil }
    }

    func runningKeys() -> Set<String> {
        lock.withLock { Set(tasksByKey.keys) }
    }

    func start(_ request: HLSDownloadRequest) -> AVURLAsset? {
        if let existing = lock.withLock({ tasksByKey[request.cacheKey] }) {
            return existing.urlAsset
        }
        let asset = makeAsset(for: request)
        let session = request.isFillAhead ? fillAheadSession! : manualSession!
        guard let task = session.aggregateAssetDownloadTask(
            with: asset,
            mediaSelections: asset.allMediaSelections,
            assetTitle: request.title,
            assetArtworkData: nil,
            options: nil
        ) else {
            emit(.failed(cacheKey: request.cacheKey, error: HLSDownloadError.taskCreationFailed))
            return nil
        }
        lock.withLock {
            tasksByKey[request.cacheKey] = task
            keysByTask[task.taskIdentifier] = request.cacheKey
            requestsByKey[request.cacheKey] = request
        }
        task.resume()
        return task.urlAsset
    }

    /// Resume source. Per the Task 0 spike: a previously started package resumes
    /// when the task is recreated from the *local* `.movpkg` asset; the remote
    /// master is used only for a first-time download. If the spike found the
    /// remote asset also resumes, this still works — the local asset is the
    /// stronger guarantee and needs no network for the playlist.
    private func makeAsset(for request: HLSDownloadRequest) -> AVURLAsset {
        if let entry = store.entry(cacheKey: request.cacheKey),
           !entry.isComplete,
           let local = store.resolve(entry) {
            return AVURLAsset(url: local)
        }
        var options: [String: Any] = [:]
        if let token = request.bearerToken {
            options["AVURLAssetHTTPHeaderFieldsKey"] = ["Authorization": "Bearer \(token)"]
        }
        return AVURLAsset(url: request.master, options: options)
    }

    func cancel(cacheKey: String) {
        let task = lock.withLock { () -> AVAggregateAssetDownloadTask? in
            guard let task = tasksByKey.removeValue(forKey: cacheKey) else { return nil }
            keysByTask[task.taskIdentifier] = nil
            requestsByKey[cacheKey] = nil
            return task
        }
        guard let task else { return }
        // Cancelling keeps the partial package: the whole point is resuming it.
        task.cancel()
        emit(.cancelled(cacheKey: cacheKey))
    }

    /// Background sessions outlive the process. Reattach so a download that
    /// continued while the app was away keeps reporting progress.
    func restoreTasks() async {
        for session in [fillAheadSession!, manualSession!] {
            let tasks = await session.allTasks
            for task in tasks.compactMap({ $0 as? AVAggregateAssetDownloadTask }) {
                guard let key = cacheKey(matching: task) else {
                    task.cancel()
                    continue
                }
                lock.withLock {
                    tasksByKey[key] = task
                    keysByTask[task.taskIdentifier] = key
                }
            }
        }
    }

    /// Maps a restored task back to a cache key via the index: the only durable
    /// link is the package location AVFoundation reported in `willDownloadTo`.
    private func cacheKey(matching task: AVAggregateAssetDownloadTask) -> String? {
        let url = task.urlAsset.url
        for entry in store.entries() where store.resolve(entry) == url {
            return entry.cacheKey
        }
        return nil
    }

    private func emit(_ event: HLSDownloadEvent) {
        let handler = lock.withLock { self.handler }
        handler?(event)
    }

    // MARK: AVAssetDownloadDelegate

    func urlSession(
        _ session: URLSession,
        aggregateAssetDownloadTask task: AVAggregateAssetDownloadTask,
        willDownloadTo location: URL
    ) {
        guard let key = lock.withLock({ keysByTask[task.taskIdentifier] }),
              let request = lock.withLock({ requestsByKey[key] }),
              let bookmark = HLSAssetStore.makeBookmark(for: location)
        else { return }
        // First sighting of the package's location — record it before any byte
        // lands so a kill mid-download still leaves a resumable, evictable row.
        let existing = store.entry(cacheKey: key)
        store.upsert(HLSCacheEntry(
            cacheKey: key,
            videoId: request.videoId,
            versionId: request.versionId,
            bookmark: bookmark,
            kind: request.isFillAhead ? (existing?.kind ?? .temp) : .permanent,
            isComplete: false,
            fractionComplete: existing?.fractionComplete ?? 0,
            byteCount: existing?.byteCount ?? 0,
            lastPlayedAt: existing?.lastPlayedAt ?? Date(),
            audioLang: request.audioLang))
    }

    func urlSession(
        _ session: URLSession,
        aggregateAssetDownloadTask task: AVAggregateAssetDownloadTask,
        didLoad timeRange: CMTimeRange,
        totalTimeRangesLoaded loadedTimeRanges: [NSValue],
        timeRangeExpectedToLoad: CMTimeRange,
        for mediaSelection: AVMediaSelection
    ) {
        guard let key = lock.withLock({ keysByTask[task.taskIdentifier] }) else { return }
        let loaded = loadedTimeRanges.reduce(0.0) { $0 + $1.timeRangeValue.duration.seconds }
        let expected = timeRangeExpectedToLoad.duration.seconds
        let fraction = expected > 0 ? min(max(loaded / expected, 0), 1) : 0
        emit(.progress(
            cacheKey: key, fraction: fraction, transferredBytes: task.countOfBytesReceived))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let key = lock.withLock({ () -> String? in
            guard let key = keysByTask.removeValue(forKey: task.taskIdentifier) else { return nil }
            tasksByKey[key] = nil
            requestsByKey[key] = nil
            return key
        }) else { return }

        if let error {
            let urlError = error as? URLError
            if urlError?.code == .cancelled {
                emit(.cancelled(cacheKey: key))
            } else {
                emit(.failed(cacheKey: key, error: error))
            }
            return
        }
        emit(.finished(cacheKey: key))
    }
}
```

- [ ] **Step 3: Build the package**

```bash
cd ios/PatataTubeKit && swift build 2>&1 | tail -20
```

Expected: builds. If `session.allTasks` is unavailable in this SDK, use the completion-handler form wrapped in `withCheckedContinuation`:

```swift
            let tasks: [URLSessionTask] = await withCheckedContinuation { continuation in
                session.getAllTasks { continuation.resume(returning: $0) }
            }
```

- [ ] **Step 4: Run the suite (nothing new should break)**

```bash
cd ios/PatataTubeKit && swift test 2>&1 | tail -10
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/HLSDownloadEngine.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/FakeHLSDownloader.swift
git commit -m "feat(ios): add HLS aggregate download engine

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: `PlaybackAssetProvider`

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/PlaybackAssetProvider.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/PlaybackAssetProviderTests.swift`

**Interfaces:**
- Consumes: `HLSCacheEntry` (Task 2), `HLSDownloadRequest` (Task 4).
- Produces:

```swift
enum PlaybackAssetDecision: Equatable, Sendable {
    case localPackage           // play the cached .movpkg, no task
    case fillAhead              // start/attach a fill-ahead task, play task.urlAsset
    case remoteOnly             // plain authed remote HLS, nothing cached
    case unplayable(reason: String)
}

enum PlaybackAssetProvider {
    static func decide(
        hlsStatus: String,
        entry: HLSCacheEntry?,
        entryAudioLangMatches: Bool,
        isOnWiFi: Bool,
        hasNetwork: Bool
    ) -> PlaybackAssetDecision
}
```

- [ ] **Step 1: Write the failing test**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/PlaybackAssetProviderTests.swift`:

```swift
import Foundation
import Testing
@testable import PatataTubeKit

private func entry(
    kind: HLSCacheEntry.Kind = .temp, complete: Bool = false
) -> HLSCacheEntry {
    HLSCacheEntry(
        cacheKey: "1", videoId: 1, versionId: nil, bookmark: Data([0x1]),
        kind: kind, isComplete: complete, fractionComplete: complete ? 1 : 0.4,
        byteCount: 1_000, lastPlayedAt: Date(), audioLang: "eng")
}

@Suite("Playback asset decisions")
struct PlaybackAssetProviderTests {
    @Test func completePackagePlaysLocally() {
        #expect(PlaybackAssetProvider.decide(
            hlsStatus: "done", entry: entry(kind: .permanent, complete: true),
            entryAudioLangMatches: true, isOnWiFi: false, hasNetwork: false
        ) == .localPackage)
    }

    @Test func completePackageWinsOverPackagingErrors() {
        // The package is already on disk; the server's inability to repackage
        // must not block offline playback.
        #expect(PlaybackAssetProvider.decide(
            hlsStatus: "error", entry: entry(kind: .permanent, complete: true),
            entryAudioLangMatches: true, isOnWiFi: true, hasNetwork: true
        ) == .localPackage)
    }

    @Test func staleAudioLanguageIsNotPlayedLocally() {
        #expect(PlaybackAssetProvider.decide(
            hlsStatus: "done", entry: entry(kind: .permanent, complete: true),
            entryAudioLangMatches: false, isOnWiFi: true, hasNetwork: true
        ) == .fillAhead)
    }

    @Test func partialPackageOfflinePlaysWhatIsOnDisk() {
        #expect(PlaybackAssetProvider.decide(
            hlsStatus: "done", entry: entry(complete: false),
            entryAudioLangMatches: true, isOnWiFi: false, hasNetwork: false
        ) == .localPackage)
    }

    @Test func wifiWithoutAPackageFillsAhead() {
        #expect(PlaybackAssetProvider.decide(
            hlsStatus: "done", entry: nil,
            entryAudioLangMatches: true, isOnWiFi: true, hasNetwork: true
        ) == .fillAhead)
    }

    @Test func cellularWithoutAPackageStreamsWithoutCaching() {
        #expect(PlaybackAssetProvider.decide(
            hlsStatus: "done", entry: nil,
            entryAudioLangMatches: true, isOnWiFi: false, hasNetwork: true
        ) == .remoteOnly)
    }

    @Test func packagingErrorWithoutAPackageIsUnplayable() {
        #expect(PlaybackAssetProvider.decide(
            hlsStatus: "error", entry: nil,
            entryAudioLangMatches: true, isOnWiFi: true, hasNetwork: true
        ) == .unplayable(reason: "HLS packaging failed"))
    }

    @Test func notYetPackagedWithoutAPackageIsUnplayable() {
        #expect(PlaybackAssetProvider.decide(
            hlsStatus: "converting", entry: nil,
            entryAudioLangMatches: true, isOnWiFi: true, hasNetwork: true
        ) == .unplayable(reason: "HLS not ready"))
    }

    @Test func offlineWithoutAPackageIsUnplayable() {
        #expect(PlaybackAssetProvider.decide(
            hlsStatus: "done", entry: nil,
            entryAudioLangMatches: true, isOnWiFi: false, hasNetwork: false
        ) == .unplayable(reason: "Offline and not downloaded"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd ios/PatataTubeKit && swift test --filter PlaybackAssetProviderTests 2>&1 | tail -10
```

Expected: FAIL — `cannot find 'PlaybackAssetProvider' in scope`.

- [ ] **Step 3: Implement**

Create `ios/PatataTubeKit/Sources/PatataTubeKit/PlaybackAssetProvider.swift`:

```swift
import Foundation

/// What the player should be handed for a video.
enum PlaybackAssetDecision: Equatable, Sendable {
    /// Play the cached `.movpkg` directly — complete, or partial while offline.
    case localPackage
    /// Start (or attach to) a fill-ahead download and play its asset, so watched
    /// bytes land on disk and already-downloaded bytes are read from disk.
    case fillAhead
    /// Stream the remote playlist without caching (cellular).
    case remoteOnly
    case unplayable(reason: String)
}

/// The single place that decides where playback bytes come from.
enum PlaybackAssetProvider {
    static func decide(
        hlsStatus: String,
        entry: HLSCacheEntry?,
        entryAudioLangMatches: Bool,
        isOnWiFi: Bool,
        hasNetwork: Bool
    ) -> PlaybackAssetDecision {
        if let entry, entryAudioLangMatches {
            // A package built for a different audio language is stale — the user
            // would hear the wrong track — so it is not played and not resumed.
            if entry.isComplete { return .localPackage }
            // Partial: offline, the downloaded region is all there is. Online,
            // the fill-ahead task both serves it and finishes it.
            if !hasNetwork { return .localPackage }
            return isOnWiFi ? .fillAhead : .remoteOnly
        }

        guard hasNetwork else { return .unplayable(reason: "Offline and not downloaded") }
        switch hlsStatus {
        case "done":
            return isOnWiFi ? .fillAhead : .remoteOnly
        case "error":
            return .unplayable(reason: "HLS packaging failed")
        default:
            return .unplayable(reason: "HLS not ready")
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd ios/PatataTubeKit && swift test 2>&1 | tail -10
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/PlaybackAssetProvider.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/PlaybackAssetProviderTests.swift
git commit -m "feat(ios): decide playback source from cache, network and hls status

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Rewire `CacheManager` onto the HLS units

The API stays; the engine changes. The MP4 code is still present after this task (it is removed in Task 8) but no longer reachable from `state`/`download`/`cancel`.

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/HLSCacheStateTests.swift`

**Interfaces:**
- Consumes: `HLSAssetStore`, `CacheEvictor`, `HLSDownloading`, `HLSDownloadRequest`, `HLSDownloadEvent`, `PlaybackAssetProvider`, `PlaybackAssetDecision`, `FakeHLSDownloader`.
- Produces (new/changed on `CacheManager`):
  - `init(root: URL?, configuration: URLSessionConfiguration, fileManager: FileManager, now:, cancellationFence:, concurrencyGate:, waitBeforePublication:, downloader: any HLSDownloading)` — new last parameter, defaulting to a real `HLSDownloadEngine`
  - `public func setTempCacheCap(bytes: Int64)`
  - `public func playbackAsset(for video: PlaybackTarget, isOnWiFi: Bool, hasNetwork: Bool) -> PlaybackAsset`
  - `public func notePlaybackEnded(videoId: Int, versionId: Int?)`
  - `public struct PlaybackTarget: Sendable { public init(id: Int, versionId: Int?, master: URL?, bearerToken: String?, title: String, audioLang: String?, hlsStatus: String) }`
  - `public enum PlaybackAsset: Sendable { case asset(AVURLAsset), unplayable(reason: String) }`
  - `localURL(for:versionId:)` returns the `.movpkg` location (or a `hls-cache/<key>.movpkg` placeholder path when nothing is cached)
  - unchanged signatures: `state`, `download`, `cancel`, `removePartial`, `removeCached`, `removeAllCached`, `hasAnyCached`, `clearAllVideos`, `activeDownloads`, `recentDownloads`, `resumeInterrupted`

- [ ] **Step 1: Write the failing test**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/HLSCacheStateTests.swift`:

```swift
import AVFoundation
import Foundation
import Testing
@testable import PatataTubeKit

private func managerRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("hls-cache-mgr-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func makeManager(root: URL, downloader: FakeHLSDownloader) -> CacheManager {
    CacheManager(
        root: root, configuration: .ephemeral, fileManager: .default,
        downloader: downloader)
}

private func target(id: Int = 1, hlsStatus: String = "done") -> CacheManager.PlaybackTarget {
    CacheManager.PlaybackTarget(
        id: id, versionId: nil,
        master: URL(string: "https://pt.test/videos/\(id)/hls/master.m3u8"),
        bearerToken: "tok", title: "clip", audioLang: "eng", hlsStatus: hlsStatus)
}

@Suite("HLS cache state and promotion")
struct HLSCacheStateTests {
    @Test func unknownVideoIsNotCached() throws {
        let root = try managerRoot()
        let manager = makeManager(root: root, downloader: FakeHLSDownloader())
        #expect(manager.state(for: 1) == .notCached)
    }

    @Test func playbackStartsAFillAheadTaskOnWiFi() throws {
        let root = try managerRoot()
        let fake = FakeHLSDownloader()
        let manager = makeManager(root: root, downloader: fake)

        let asset = manager.playbackAsset(for: target(), isOnWiFi: true, hasNetwork: true)

        guard case .asset = asset else {
            Issue.record("expected a playable asset, got \(asset)")
            return
        }
        #expect(fake.requests.count == 1)
        #expect(fake.requests[0].isFillAhead)
        #expect(fake.requests[0].cacheKey == "1")
    }

    @Test func fillAheadProgressReportsDownloadingState() throws {
        let root = try managerRoot()
        let fake = FakeHLSDownloader()
        let manager = makeManager(root: root, downloader: fake)
        _ = manager.playbackAsset(for: target(), isOnWiFi: true, hasNetwork: true)

        fake.emitProgress(cacheKey: "1", fraction: 0.3)

        #expect(manager.state(for: 1) == .downloading(0.3))
        #expect(manager.activeDownloads().count == 1)
    }

    @Test func completedFillAheadIsPromotedToCached() throws {
        let root = try managerRoot()
        let fake = FakeHLSDownloader()
        let manager = makeManager(root: root, downloader: fake)
        _ = manager.playbackAsset(for: target(), isOnWiFi: true, hasNetwork: true)
        fake.emitProgress(cacheKey: "1", fraction: 0.9)

        fake.emitFinished(cacheKey: "1")

        #expect(manager.state(for: 1) == .cached)
        #expect(manager.recentDownloads().count == 1)
    }

    @Test func incompletePlaybackLeavesAPausedPartialAndCancelsTheTask() throws {
        let root = try managerRoot()
        let fake = FakeHLSDownloader()
        let manager = makeManager(root: root, downloader: fake)
        _ = manager.playbackAsset(for: target(), isOnWiFi: true, hasNetwork: true)
        fake.emitProgress(cacheKey: "1", fraction: 0.4)

        manager.notePlaybackEnded(videoId: 1, versionId: nil)

        #expect(fake.cancelledKeys == ["1"])
        #expect(manager.state(for: 1) == .paused(0.4))
    }

    @Test func cellularPlaybackDoesNotCache() throws {
        let root = try managerRoot()
        let fake = FakeHLSDownloader()
        let manager = makeManager(root: root, downloader: fake)

        _ = manager.playbackAsset(for: target(), isOnWiFi: false, hasNetwork: true)

        #expect(fake.requests.isEmpty)
        #expect(manager.state(for: 1) == .notCached)
    }

    @Test func packagingErrorIsReportedAsUnplayable() throws {
        let root = try managerRoot()
        let manager = makeManager(root: root, downloader: FakeHLSDownloader())

        let asset = manager.playbackAsset(
            for: target(hlsStatus: "error"), isOnWiFi: true, hasNetwork: true)

        #expect(asset == .unplayable(reason: "HLS packaging failed"))
    }

    @Test func explicitDownloadUsesAManualTaskAndCompletes() async throws {
        let root = try managerRoot()
        let fake = FakeHLSDownloader()
        let manager = makeManager(root: root, downloader: fake)
        let master = URL(string: "https://pt.test/videos/2/hls/master.m3u8")!

        let download = Task {
            try await manager.download(id: 2, from: master, bearerToken: "tok")
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(fake.requests.first?.isFillAhead == false)
        fake.emitFinished(cacheKey: "2")
        try await download.value

        #expect(manager.state(for: 2) == .cached)
    }

    @Test func failedDownloadThrowsAndDropsTheEntry() async throws {
        let root = try managerRoot()
        let fake = FakeHLSDownloader()
        let manager = makeManager(root: root, downloader: fake)
        let master = URL(string: "https://pt.test/videos/3/hls/master.m3u8")!

        let download = Task {
            try await manager.download(id: 3, from: master, bearerToken: "tok")
        }
        try await Task.sleep(for: .milliseconds(50))
        fake.emitFailure(cacheKey: "3", error: URLError(.timedOut))

        await #expect(throws: (any Error).self) { try await download.value }
        #expect(manager.state(for: 3) == .notCached)
    }

    @Test func evictionRunsAfterPlaybackAndSparesPermanentEntries() throws {
        let root = try managerRoot()
        let fake = FakeHLSDownloader()
        let manager = makeManager(root: root, downloader: fake)
        manager.setTempCacheCap(bytes: 0)

        _ = manager.playbackAsset(for: target(), isOnWiFi: true, hasNetwork: true)
        fake.emitProgress(cacheKey: "1", fraction: 0.4)
        manager.notePlaybackEnded(videoId: 1, versionId: nil)

        // Cap 0 → the just-watched temp partial is evicted.
        #expect(manager.state(for: 1) == .notCached)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd ios/PatataTubeKit && swift test --filter HLSCacheStateTests 2>&1 | tail -15
```

Expected: FAIL — `CacheManager` has no `downloader:` parameter, no `playbackAsset`, no `notePlaybackEnded`, no `setTempCacheCap`.

- [ ] **Step 3: Implement — types, storage, init**

In `CacheManager.swift`, add above `public final class CacheManager`:

```swift
public extension CacheManager {
    /// Everything the cache needs to serve or download one video's HLS package.
    struct PlaybackTarget: Sendable {
        public let id: Int
        public let versionId: Int?
        public let master: URL?
        public let bearerToken: String?
        public let title: String
        public let audioLang: String?
        public let hlsStatus: String

        public init(
            id: Int, versionId: Int?, master: URL?, bearerToken: String?,
            title: String, audioLang: String?, hlsStatus: String
        ) {
            self.id = id
            self.versionId = versionId
            self.master = master
            self.bearerToken = bearerToken
            self.title = title
            self.audioLang = audioLang
            self.hlsStatus = hlsStatus
        }
    }

    enum PlaybackAsset: Sendable, Equatable {
        case asset(AVURLAsset)
        case unplayable(reason: String)
    }
}
```

Inside the class, add stored properties next to `capturedManifestProgress`:

```swift
    private let hlsStore: HLSAssetStore
    private let downloader: any HLSDownloading
    /// Live fraction per cache key, mirrored so `state(for:)` never reads disk.
    private var hlsProgress: [String: Double] = [:]
    /// Continuations of explicit `download()` calls awaiting a terminal event.
    private var downloadWaiters: [String: CheckedContinuation<Void, Error>] = [:]
    private var tempCacheCapBytes: Int64 = 10 * 1_073_741_824
```

Extend both initializers: add `downloader: (any HLSDownloading)? = nil` as the last parameter of the designated `init`, and inside it (after `super.init()`):

```swift
        self.hlsStore = HLSAssetStore(root: self.root, fileManager: fileManager)
        self.downloader = downloader ?? HLSDownloadEngine(store: self.hlsStore)
        self.downloader.setEventHandler { [weak self] event in
            self?.handle(event)
        }
```

`hlsStore` must be assigned before `super.init()` for the compiler (it is a `let`): declare it as `private let hlsStore: HLSAssetStore` and assign `self.hlsStore = HLSAssetStore(root: root ?? …)` in the same place the existing `capturedStore` is built (line ~163), then pass it to the engine after `super.init()` by making `downloader` a `private var downloader: (any HLSDownloading)!`.

Add the convenience-init passthrough so app code keeps calling `CacheManager(root:configuration:)` unchanged.

- [ ] **Step 4: Implement — state, playback, promotion, eviction**

Replace `state(for:versionId:)`:

```swift
    public func state(for id: Int, versionId: Int? = nil) -> CacheState {
        let key = cacheKey(videoId: id, versionId: versionId)
        guard let entry = hlsStore.entry(cacheKey: key), hlsStore.resolve(entry) != nil else {
            return .notCached
        }
        if entry.kind == .permanent, entry.isComplete { return .cached }
        if downloader.isRunning(cacheKey: key) {
            return .downloading(lock.withLock { hlsProgress[key] ?? entry.fractionComplete })
        }
        return .paused(lock.withLock { hlsProgress[key] ?? entry.fractionComplete })
    }
```

Add the playback entry point, promotion, and eviction:

```swift
    // MARK: Playback

    /// The asset the player should use, and the read-through cache's front door.
    /// On Wi-Fi this starts (or attaches to) a fill-ahead download and hands back
    /// *its* asset, so already-downloaded segments are read from disk and only
    /// the missing ones hit the network.
    public func playbackAsset(
        for target: PlaybackTarget, isOnWiFi: Bool, hasNetwork: Bool
    ) -> PlaybackAsset {
        let key = cacheKey(videoId: target.id, versionId: target.versionId)
        let entry = hlsStore.entry(cacheKey: key)
        let langMatches = entry.map { $0.audioLang == target.audioLang } ?? false

        switch PlaybackAssetProvider.decide(
            hlsStatus: target.hlsStatus, entry: entry,
            entryAudioLangMatches: langMatches,
            isOnWiFi: isOnWiFi, hasNetwork: hasNetwork
        ) {
        case .localPackage:
            guard let entry, let url = hlsStore.resolve(entry) else {
                return .unplayable(reason: "Cached package is gone")
            }
            touch(cacheKey: key)
            return .asset(AVURLAsset(url: url))

        case .fillAhead:
            // A stale-language package cannot be resumed — its segments carry the
            // wrong audio. Drop it and start clean.
            if let entry, !langMatches { hlsStore.remove(cacheKey: key) }
            guard let master = target.master else {
                return .unplayable(reason: "No server URL configured")
            }
            let request = HLSDownloadRequest(
                cacheKey: key, videoId: target.id, versionId: target.versionId,
                master: master, bearerToken: target.bearerToken, title: target.title,
                audioLang: target.audioLang, isFillAhead: true)
            guard let asset = downloader.start(request) else {
                return authedRemoteAsset(target: target)
            }
            lock.withLock {
                if inFlight[key] == nil {
                    inFlight[key] = DownloadActivityAccumulator(
                        videoID: target.id, versionID: target.versionId,
                        totalByteCount: nil, now: now())
                }
            }
            touch(cacheKey: key)
            return .asset(asset)

        case .remoteOnly:
            return authedRemoteAsset(target: target)

        case .unplayable(let reason):
            return .unplayable(reason: reason)
        }
    }

    private func authedRemoteAsset(target: PlaybackTarget) -> PlaybackAsset {
        guard let master = target.master else {
            return .unplayable(reason: "No server URL configured")
        }
        var options: [String: Any] = [:]
        if let token = target.bearerToken {
            options["AVURLAssetHTTPHeaderFieldsKey"] = ["Authorization": "Bearer \(token)"]
        }
        return .asset(AVURLAsset(url: master, options: options))
    }

    /// Playback of this video stopped. A finished fill-ahead has already been
    /// promoted; anything short of complete is cancelled and kept as an
    /// LRU-evictable partial, because the user skipped and only an explicit
    /// Download should spend data on the rest.
    public func notePlaybackEnded(videoId: Int, versionId: Int? = nil) {
        let key = cacheKey(videoId: videoId, versionId: versionId)
        if let entry = hlsStore.entry(cacheKey: key), !entry.isComplete,
           lock.withLock({ downloadWaiters[key] == nil })
        {
            downloader.cancel(cacheKey: key)
        }
        touch(cacheKey: key)
        evictIfNeeded()
    }

    public func setTempCacheCap(bytes: Int64) {
        lock.withLock { tempCacheCapBytes = max(bytes, 0) }
        evictIfNeeded()
    }

    private func touch(cacheKey key: String) {
        guard var entry = hlsStore.entry(cacheKey: key) else { return }
        entry.lastPlayedAt = now()
        if let url = hlsStore.resolve(entry) {
            entry.byteCount = hlsStore.directorySize(of: url)
        }
        hlsStore.upsert(entry)
    }

    private func evictIfNeeded() {
        let cap = lock.withLock { tempCacheCapBytes }
        for key in CacheEvictor.keysToEvict(
            entries: hlsStore.entries(), capBytes: cap,
            protectedKeys: downloader.runningKeys()
        ) {
            hlsStore.remove(cacheKey: key)
            lock.withLock { hlsProgress[key] = nil }
        }
    }
```

- [ ] **Step 5: Implement — event handling**

```swift
    // MARK: Engine events

    private func handle(_ event: HLSDownloadEvent) {
        switch event {
        case .progress(let key, let fraction, let bytes):
            var entry = hlsStore.entry(cacheKey: key)
            entry?.fractionComplete = fraction
            if let entry { hlsStore.upsert(entry) }
            lock.withLock {
                hlsProgress[key] = fraction
                if inFlight[key] == nil, let entry {
                    inFlight[key] = DownloadActivityAccumulator(
                        videoID: entry.videoId, versionID: entry.versionId,
                        totalByteCount: nil, now: now())
                }
                inFlight[key]?.record(
                    transferredByteCount: bytes, progress: fraction,
                    totalByteCount: nil, now: now())
            }

        case .finished(let key):
            if var entry = hlsStore.entry(cacheKey: key) {
                entry.isComplete = true
                entry.fractionComplete = 1
                // Completion is the auto-download rule: a watch that fetched the
                // whole asset becomes a permanent download.
                entry.kind = .permanent
                if let url = hlsStore.resolve(entry) {
                    entry.byteCount = hlsStore.directorySize(of: url)
                }
                hlsStore.upsert(entry)
                lock.withLock {
                    hlsProgress[key] = 1
                    inFlight[key] = nil
                    completionHistory.record(DownloadCompletion(
                        videoID: entry.videoId, versionID: entry.versionId,
                        completedAt: now()))
                }
            }
            resumeWaiter(key: key, result: .success(()))

        case .failed(let key, let error):
            // Segments can vanish under us (the server repackages on an audio
            // change), and a partial from a previous package is not resumable —
            // drop it rather than resume garbage.
            hlsStore.remove(cacheKey: key)
            lock.withLock {
                hlsProgress[key] = nil
                inFlight[key] = nil
            }
            resumeWaiter(key: key, result: .failure(error))

        case .cancelled(let key):
            lock.withLock { inFlight[key] = nil }
            resumeWaiter(key: key, result: .failure(CancellationError()))
        }
    }

    private func resumeWaiter(key: String, result: Result<Void, Error>) {
        let waiter = lock.withLock { downloadWaiters.removeValue(forKey: key) }
        switch result {
        case .success: waiter?.resume()
        case .failure(let error): waiter?.resume(throwing: error)
        }
    }
```

- [ ] **Step 6: Implement — `download`, `cancel`, removals, resume**

Replace the body of `download(...)` (keep its exact signature; `streamCount` is now unused — AVFoundation manages its own connections, so document that):

```swift
    /// Downloads a video's HLS package for offline playback, resuming whatever a
    /// previous watch already captured. `streamCount` is ignored: AVFoundation
    /// manages segment concurrency inside its own session.
    public func download(id: Int, versionId: Int? = nil, from remote: URL, preview: URL? = nil,
                         showPosterKey: String? = nil, showPoster: URL? = nil,
                         bearerToken: String? = nil, streamCount: Int = 1) async throws {
        await concurrencyGate.acquire()
        defer { concurrencyGate.release() }
        let key = cacheKey(videoId: id, versionId: versionId)

        if state(for: id, versionId: versionId) != .cached {
            let request = HLSDownloadRequest(
                cacheKey: key, videoId: id, versionId: versionId, master: remote,
                bearerToken: bearerToken, title: "\(id)",
                audioLang: hlsStore.entry(cacheKey: key)?.audioLang,
                isFillAhead: false)
            guard downloader.start(request) != nil else {
                throw HLSDownloadError.taskCreationFailed
            }
            lock.withLock {
                if inFlight[key] == nil {
                    inFlight[key] = DownloadActivityAccumulator(
                        videoID: id, versionID: versionId, totalByteCount: nil, now: now())
                }
            }
            try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    lock.withLock { downloadWaiters[key] = continuation }
                }
            }, onCancel: {
                self.cancel(id: id, versionId: versionId)
            })
        }
        if let preview { try? await cachePreview(id: id, from: preview, bearerToken: bearerToken) }
        if let showPosterKey, let showPoster, cachedShowPosterURL(for: showPosterKey) == nil {
            try? await cacheShowPoster(key: showPosterKey, from: showPoster, bearerToken: bearerToken)
        }
    }
```

Replace `cancel`, `removePartial`, `removeCached`, `hasAnyCached`, `removeAllCached`, `clearAllVideos`, `resumeInterrupted`, `localURL`:

```swift
    /// Stops an in-flight download. The partial package stays on disk, so
    /// `state(for:)` reports `.paused(progress)` and a later download resumes it.
    public func cancel(id: Int, versionId: Int? = nil) {
        downloader.cancel(cacheKey: cacheKey(videoId: id, versionId: versionId))
    }

    /// Deletes a partial package, reclaiming the disk.
    public func removePartial(id: Int, versionId: Int? = nil) {
        let key = cacheKey(videoId: id, versionId: versionId)
        cancel(id: id, versionId: versionId)
        guard let entry = hlsStore.entry(cacheKey: key), !entry.isComplete else { return }
        hlsStore.remove(cacheKey: key)
        lock.withLock {
            hlsProgress[key] = nil
            inFlight[key] = nil
        }
    }

    /// Deletes a cached package, complete or not.
    public func removeCached(id: Int, versionId: Int? = nil) {
        let key = cacheKey(videoId: id, versionId: versionId)
        cancel(id: id, versionId: versionId)
        hlsStore.remove(cacheKey: key)
        lock.withLock {
            hlsProgress[key] = nil
            inFlight[key] = nil
        }
    }

    /// True when any complete package (any version) exists for this video.
    public func hasAnyCached(id: Int) -> Bool {
        hlsStore.entries().contains { $0.videoId == id && $0.isComplete }
    }

    /// Deletes every package for this video, all versions. Preview images and
    /// show posters are kept — small, still useful offline.
    public func removeAllCached(id: Int) {
        for entry in hlsStore.entries() where entry.videoId == id {
            removeCached(id: entry.videoId, versionId: entry.versionId)
        }
    }

    /// Clears every downloaded video: cancels in-flight downloads, removes all
    /// packages and completion history. Cover images are kept.
    public func clearAllVideos() {
        for entry in hlsStore.entries() {
            cancel(id: entry.videoId, versionId: entry.versionId)
        }
        hlsStore.removeAll()
        lock.withLock {
            hlsProgress.removeAll()
            inFlight.removeAll()
            completionHistory.clear()
        }
    }

    /// Reattaches to background tasks that outlived a suspension or a kill.
    /// Fire-and-forget; returns the video ids with a live or resumable package.
    @discardableResult
    public func resumeInterrupted(bearerToken: String? = nil) -> [Int] {
        Task { await downloader.restoreTasks() }
        evictIfNeeded()
        return hlsStore.entries().filter { !$0.isComplete }.map(\.videoId)
    }

    /// Location of the cached package. When nothing is cached this is where one
    /// would live, so callers can build a path without a nil check — check
    /// `state(for:)` before playing it.
    public func localURL(for id: Int, versionId: Int? = nil) -> URL {
        let key = cacheKey(videoId: id, versionId: versionId)
        if let entry = hlsStore.entry(cacheKey: key), let url = hlsStore.resolve(entry) {
            return url
        }
        return root.appendingPathComponent("hls-cache", isDirectory: true)
            .appendingPathComponent("\(key.replacingOccurrences(of: ":", with: ".")).movpkg")
    }
```

Delete `recentDownloads`'s file-existence pruning predicate's reliance on MP4 paths by swapping the closure body:

```swift
    public func recentDownloads() -> [DownloadCompletion] {
        lock.withLock {
            completionHistory.prune { completion in
                hlsStore.entry(cacheKey: cacheKey(
                    videoId: completion.videoID, versionId: completion.versionID)) != nil
            }
        }
    }
```

- [ ] **Step 7: Run the tests**

```bash
cd ios/PatataTubeKit && swift test 2>&1 | tail -25
```

Expected: `HLSCacheStateTests` PASS. The old MP4 suites (`CacheManagerRangeDownloadTests`, `CacheManagerCaptureStateTests`) now FAIL — they assert MP4 behavior that is deliberately gone. Leave them failing; Task 8 deletes them. Confirm the failures are only in the files listed in Task 8 Step 1.

- [ ] **Step 8: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/HLSCacheStateTests.swift
git commit -m "feat(ios): serve playback and downloads from one HLS package cache

state/download/cancel/removals now run on the HLS asset store and the
aggregate download engine. Playback is handed the download task's own
asset, so watched bytes persist and a later download fetches only the
segments that are missing.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: Wire the app shell

**Files:**
- Modify: `ios/PatataTube/Sources/VideoPlayerView.swift:208-265` (`playerItem`, play-to-end hook), `ios/PatataTube/Sources/VideoGridView.swift:249-262` (`play`), `ios/PatataTube/Sources/AppModel.swift` (cap wiring + Wi-Fi flag), `ios/PatataTube/Sources/MovieDetailView.swift:120-160` (retry action), `ios/PatataTube/Sources/PatataTubeApp.swift:75-90`
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/APIClient.swift` (rebuild call)

**Interfaces:**
- Consumes: `CacheManager.playbackAsset(for:isOnWiFi:hasNetwork:)`, `notePlaybackEnded`, `setTempCacheCap`, `Video.hlsStatus` / `hlsErrorMsg`.
- Produces: `APIClient.rebuildHLS(id: Int) async throws`; `AppModel.isOnWiFi: Bool`, `AppModel.hasNetwork: Bool`; `AppModel.playbackTarget(for: Video) -> CacheManager.PlaybackTarget`.

- [ ] **Step 1: Add the API call**

In `ios/PatataTubeKit/Sources/PatataTubeKit/APIClient.swift`, following the shape of the existing POST helpers:

```swift
    /// Discards the server's HLS package so the next play repackages it. The
    /// only escape from `hls_status == "error"`.
    public func rebuildHLS(id: Int) async throws {
        _ = try await send(path: "/api/videos/\(id)/hls/rebuild", method: "POST", body: Optional<Data>.none)
    }
```

Match the actual private request helper's name and signature in that file (it is the one `classifications()` and `ensureReady`-style calls already use); do not invent a new networking path.

- [ ] **Step 2: Add network reachability + playback target to `AppModel`**

In `ios/PatataTube/Sources/AppModel.swift`:

```swift
import Network
```

```swift
    @Published private(set) var isOnWiFi = true
    @Published private(set) var hasNetwork = true
    private let pathMonitor = NWPathMonitor()

    /// Fill-ahead is Wi-Fi-only, so playback needs the current interface type.
    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.hasNetwork = path.status == .satisfied
                self?.isOnWiFi = path.status == .satisfied
                    && !path.usesInterfaceType(.cellular)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "patatatube.network.monitor"))
    }

    /// Everything the cache needs to serve one video.
    func playbackTarget(for video: Video) -> CacheManager.PlaybackTarget {
        CacheManager.PlaybackTarget(
            id: video.id,
            versionId: video.chosenVersionId,
            master: hlsURL(for: video),
            bearerToken: credentials.token,
            title: video.title ?? video.sourceFilename ?? "PatataTube",
            audioLang: video.audioLang,
            hlsStatus: video.hlsStatus)
    }
```

Call `startNetworkMonitor()` at the end of `init`. Add the deferred line from Task 3 Step 3 to `saveSettings()`:

```swift
        cache.setTempCacheCap(bytes: capBytes)
```

…and also call `cache.setTempCacheCap(bytes:)` once in `init` with the loaded value, so a fresh launch honors the setting before any playback.

- [ ] **Step 3: Rewire `playerItem`**

In `ios/PatataTube/Sources/VideoPlayerView.swift`, replace `playerItem(for:)` (lines ~208-238) with:

```swift
    /// AVPlayerItem for a queue entry, or nil when it has no playable source
    /// (skipped during queue navigation). All sources are HLS now: a cached
    /// `.movpkg`, a fill-ahead download's asset, or the remote playlist.
    private func playerItem(for video: Video) -> AVPlayerItem? {
        // Library rows that haven't been converted server-side have no source yet.
        if video.isLibrary && video.status != "done" { return nil }
        switch model.cache.playbackAsset(
            for: model.playbackTarget(for: video),
            isOnWiFi: model.isOnWiFi,
            hasNetwork: model.hasNetwork
        ) {
        case .asset(let asset):
            return AVPlayerItem(asset: asset)
        case .unplayable(let reason):
            model.store.errorText = reason
            return nil
        }
    }
```

- [ ] **Step 4: Replace the finalize hook with the playback-ended hook**

In the same file, in the `AVPlayerItemDidPlayToEndTime` observer (lines ~260-266), replace the `finalizeCapture` block with:

```swift
                let finished = video   // the item that reached end
                model.cache.notePlaybackEnded(
                    videoId: finished.id, versionId: finished.chosenVersionId)
```

And in `.onDisappear` (line ~107), before `nowPlaying.detach()`, add — so closing mid-video also cancels fill-ahead and runs eviction:

```swift
            model.cache.notePlaybackEnded(videoId: video.id, versionId: video.chosenVersionId)
```

- [ ] **Step 5: Update the grid's play gate**

In `ios/PatataTube/Sources/VideoGridView.swift`, in `play(_:queueSnapshot:sleepMode:)` (line ~249) the `.cached` fast path stays correct as written (a cached package plays offline without `/prepare`). Only its comment needs to stop saying MP4:

```swift
        // Already downloaded to device: play the local package directly, no
        // network. ensureReady() would hit /prepare and fail offline (-1009)
        // even though the cached package is ready to play.
```

- [ ] **Step 6: Add the retry affordance**

In `ios/PatataTube/Sources/MovieDetailView.swift`, inside the actions area near the existing delete buttons (lines ~120-156), add:

```swift
                    if currentVideo.hlsStatus == "error" {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(currentVideo.hlsErrorMsg ?? "Server could not package this video.")
                                .font(.footnote)
                                .foregroundStyle(.red)
                            Button("Retry packaging") {
                                Task {
                                    model.cache.removeCached(
                                        id: currentVideo.id,
                                        versionId: currentVideo.chosenVersionId)
                                    try? await model.api.rebuildHLS(id: currentVideo.id)
                                    await model.store.load()
                                }
                            }
                        }
                    }
```

- [ ] **Step 7: Build and run everything**

```bash
cd ios/PatataTubeKit && swift test 2>&1 | tail -15
cd ../PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS' -allowProvisioningUpdates build 2>&1 | tail -10
```

Expected: the app target builds. `swift test` still shows only the Task 8 files failing.

- [ ] **Step 8: Commit**

```bash
git add ios/PatataTube/Sources ios/PatataTubeKit/Sources/PatataTubeKit/APIClient.swift
git commit -m "feat(ios): play through the HLS cache and retry failed packaging

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 8: Delete the MP4 capture stack, clean up legacy files, update the checklist

**Files:**
- Delete: `ios/PatataTubeKit/Sources/PatataTubeKit/RangeFetcher.swift`, `RangeFetcherRegistry.swift`, `CaptureManager.swift`, `CapturedDownload.swift`, `CapturedRanges.swift`
- Delete tests: `CacheManagerRangeDownloadTests.swift`, `CacheManagerCaptureStateTests.swift`, `CapturedDownloadManifestTests.swift`, `CapturedDownloadStoreTests.swift`, `CapturedRangesTests.swift`, `CaptureManagerSchemeTests.swift`, `RangeFetcherTests.swift`, `RangeFetcherFetchAllTests.swift`, `RangeFetcherFinalizeTests.swift`, `RangeFetcherConcurrencyTests.swift`, `RangeFetcherRegistryTests.swift`
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift` (drop dead members), `ios/PatataTube/Sources/SettingsView.swift` (the "Cache all videos" button must pass HLS master URLs), `ios/README.md`

**Interfaces:**
- Consumes: everything from Tasks 2-7.
- Produces: a `CacheManager` with no MP4 code, and a one-shot `purgeLegacyMP4Cache()` run at init.

- [ ] **Step 1: Delete the files**

```bash
cd /Users/grillermo/c/patatatube
git rm ios/PatataTubeKit/Sources/PatataTubeKit/RangeFetcher.swift \
       ios/PatataTubeKit/Sources/PatataTubeKit/RangeFetcherRegistry.swift \
       ios/PatataTubeKit/Sources/PatataTubeKit/CaptureManager.swift \
       ios/PatataTubeKit/Sources/PatataTubeKit/CapturedDownload.swift \
       ios/PatataTubeKit/Sources/PatataTubeKit/CapturedRanges.swift \
       ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerRangeDownloadTests.swift \
       ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerCaptureStateTests.swift \
       ios/PatataTubeKit/Tests/PatataTubeKitTests/CapturedDownloadManifestTests.swift \
       ios/PatataTubeKit/Tests/PatataTubeKitTests/CapturedDownloadStoreTests.swift \
       ios/PatataTubeKit/Tests/PatataTubeKitTests/CapturedRangesTests.swift \
       ios/PatataTubeKit/Tests/PatataTubeKitTests/CaptureManagerSchemeTests.swift \
       ios/PatataTubeKit/Tests/PatataTubeKitTests/RangeFetcherTests.swift \
       ios/PatataTubeKit/Tests/PatataTubeKitTests/RangeFetcherFetchAllTests.swift \
       ios/PatataTubeKit/Tests/PatataTubeKitTests/RangeFetcherFinalizeTests.swift \
       ios/PatataTubeKit/Tests/PatataTubeKitTests/RangeFetcherConcurrencyTests.swift \
       ios/PatataTubeKit/Tests/PatataTubeKitTests/RangeFetcherRegistryTests.swift
```

- [ ] **Step 2: Strip the dead members from `CacheManager`**

Remove: `RangeDownloadTask`, `CacheManagerCancellationFencing`, `CacheManagerCancellationFence`, `capturedStore`, `capturedManifestProgress`, `downloadTasks`, `fetcherRegistry`, `captureManager`, `captureAsset`, `finalizeCapture`, `registerCaptureProgress`, `testFetcher`, `hasDownloadTask`, `clearRangeDownloadAttempt`, `completeRangeDownloadAttempt`, `waitForRangeDownloadAttempt`, `resumeRangeDownloadWaiter`, `cachedVideoFilenames`, `filename`, `waitBeforePublication`, and the `cancellationFence` / `waitBeforePublication` init parameters (update both initializers and every test constructing them).

Add the one-shot legacy cleanup, called at the end of the designated `init`:

```swift
    /// One-shot removal of the pre-HLS cache: MP4s and range-download partials
    /// from the deleted capture stack. Nothing reads them any more, so they are
    /// pure dead weight on a device that upgraded through this change.
    private func purgeLegacyMP4Cache() {
        let flag = "hlsCacheLegacyMP4Purged"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        let contents = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        for name in contents where name.hasSuffix(".mp4") {
            try? fileManager.removeItem(at: root.appendingPathComponent(name))
        }
        try? fileManager.removeItem(at: root.appendingPathComponent(".downloads"))
        UserDefaults.standard.set(true, forKey: flag)
    }
```

- [ ] **Step 3: Fix the "Cache all videos" button**

In `ios/PatataTube/Sources/SettingsView.swift`, that button passes `model.streamURL(for: video)` (the MP4 endpoint). Change it to the HLS master and skip rows without one:

```swift
                                for video in model.store.videos {
                                    guard let url = model.hlsURL(for: video) else { continue }
```

- [ ] **Step 4: Run everything**

```bash
cd ios/PatataTubeKit && swift test 2>&1 | tail -15
cd ../PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS' -allowProvisioningUpdates build 2>&1 | tail -10
cd ../.. && python -m pytest tests/ -q
```

Expected: `swift test` fully green (no remaining references to the deleted types), app target builds, Python suite green.

- [ ] **Step 5: Rewrite the manual checklist**

In `ios/README.md`, replace the watch-to-cache checklist (the numbered list ending with "Confirm an HLS library movie does NOT auto-cache from watching (out of scope)") with:

```markdown
### HLS stream caching

1. On Wi-Fi, play a video to the end without skipping. The grid shows it as
   cached; no separate download runs afterwards.
2. Play another video, skip forward a few times, close the player at ~50%. The
   grid shows a partial ring.
3. Tap Download on that partial. Watch `log/backend.log`: segment requests
   should cover only the parts that were never fetched — no segment appears
   twice across the two phases.
4. Enable Airplane Mode. A cached video plays, exposes its subtitle tracks and
   the audio-track picker, and scrubbing inside the downloaded region works.
5. In Airplane Mode, open the partial from step 2: the downloaded region plays;
   seeking past it stops rather than crashing.
6. Set "Watch cache limit" to 1 GB in Settings and watch enough videos partially
   to exceed it: the least recently played partial disappears from the grid while
   every explicitly downloaded video survives.
7. Switch to cellular and play an uncached video: it streams, and the grid does
   NOT start showing download progress for it.
8. Kill the app mid-download, relaunch: progress resumes rather than restarting.
9. For a video whose server-side packaging failed (`hls_status = "error"`), the
   detail view shows the error and "Retry packaging" clears it.
```

- [ ] **Step 6: Commit**

```bash
git add -A ios/ && git commit -m "refactor(ios): drop the MP4 range-capture stack

HLS packages are now the only offline format, so the range fetcher,
capture manager, sparse-file store and range algebra have no callers.
Legacy .mp4 files and .downloads partials are purged once on first launch.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

- [ ] **Step 7: Device verification**

Run the whole checklist from Step 5 on the iPad. Report results before shipping. Only then run `/deploy-ios`.

---

## Self-Review

**Spec coverage:** Decisions table → Tasks 1-8; `HLSAssetStore` → Task 2; `HLSDownloadEngine` → Task 4; `PlaybackAssetProvider` → Task 5; `CacheEvictor` + cap setting → Task 3; `CacheManager` coordinator → Task 6; deletions → Task 8; data model → Task 2; state mapping → Task 6; flows (play / playback ends / download tapped / offline / invalidation) → Tasks 6-7; concurrency (one session per identifier, `DownloadConcurrencyGate` reuse) → Tasks 4, 6; backend status + rebuild → Task 1; error table → Tasks 1, 5, 6, 7; testing → Tasks 2-6 unit, Task 8 manual; rollout steps 0-6 → Tasks 0-8.

**Known deviations from the spec, deliberate:**
- The spec described one download session; the plan uses two (`fillahead` Wi-Fi-only and `manual`), because `allowsCellularAccess` is fixed per session and the spec requires Wi-Fi-only fill-ahead *and* cellular-allowed explicit downloads.
- `hls_error_msg` is a new DB column, not named in the spec's backend section; it is what makes the spec's "surface a real error" requirement possible.

**Placeholders:** none — every code step carries the code. Task 0's spike outputs are recorded into the spec, and the two places that depend on its answer (Task 4's `makeAsset` resume source; the `session.allTasks` fallback) both state what to do either way.

**Type consistency:** `cacheKey` format is `"\(id)"` / `"\(id):\(versionId)"` everywhere; `HLSCacheEntry` field names match between Tasks 2, 3, 4, 6; `HLSDownloading` method names match between the protocol (Task 4), `FakeHLSDownloader` (Task 4) and `CacheManager` (Task 6); `PlaybackAssetDecision` cases match between Task 5's implementation and Task 6's `switch`; `setTempCacheCap(bytes:)` is defined in Task 6 and called in Tasks 3/7 (Task 3 notes the deferral explicitly).
