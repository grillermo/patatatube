# Resumable Offline Downloads (iOS) Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the iOS app's offline MP4 cache resume an interrupted download from where it stopped (auto, on the next re-tap) instead of restarting from 0%.

**Architecture:** Rewrite `CacheManager` from the async convenience call `session.download(for:)` to a `URLSessionDownloadDelegate`-backed `URLSessionDownloadTask`. The delegate bridges completion back to `async`/`await` via a per-id `CheckedContinuation`, updates real progress, and on interruption persists opaque resume data to `{id}.resume` on disk. The next `download(id:)` reuses that data via `downloadTask(withResumeData:)`. Public API is unchanged; the injected dependency changes from `URLSession` to `URLSessionConfiguration` (a delegate can only be set at session creation).

**Tech Stack:** Swift, `URLSession`/`URLSessionDownloadDelegate`, Swift Testing (`import Testing`), SwiftPM (`PatataTubeKit` package).

**Spec:** `docs/superpowers/specs/2026-07-07-resumable-offline-download-design.md`

---

## File Structure

- **Modify:** `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift` — the whole download engine is rewritten; the rest of the class (`localURL`, `cachedPreviewURL`, `state`, `cachePreview`, backup exclusion) stays.
- **Modify:** `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift` — helper returns a `URLSessionConfiguration` instead of a `URLSession`; call sites pass `configuration:`; one new assertion (no `.resume` after success).
- **Modify:** `ios/README.md` — add one manual-test line for the resume round-trip.

No caller changes: `VideoGridView.swift` and `SettingsView.swift` use `download(id:from:preview:bearerToken:)` and `state(for:)`, both unchanged. `AppModel` constructs `CacheManager()` with no args (verify in Task 1).

**Build/test commands** (run from repo root):
- Build: `cd ios/PatataTubeKit && swift build`
- Test all: `cd ios/PatataTubeKit && swift test`
- One test: `cd ios/PatataTubeKit && swift test --filter CacheManagerTests`

Note: `swift test` requires macOS with the Swift toolchain. Foundation's `URLSession` delegate + `URLProtocol` mocks work under swift-corelibs-foundation but timing differs from Apple's; keep delegate logic tolerant of ordering.

---

## Chunk 1: CacheManager rewrite

### Task 1: Confirm callers and construction (no code change)

**Files:**
- Read: `ios/PatataTube/Sources/AppModel.swift`
- Read: `ios/PatataTube/Sources/VideoGridView.swift`
- Read: `ios/PatataTube/Sources/SettingsView.swift`

- [ ] **Step 1: Grep every CacheManager construction and call**

Run:
```bash
grep -rn "CacheManager(\|cache\.download\|cache\.state\|cache\.localURL\|cache\.cachedPreviewURL" ios/PatataTube/Sources ios/PatataTubeKit
```
Expected: only no-arg `CacheManager()` (or `root:`-only) constructions in app code; all download/state calls use the public methods we keep. Confirm **no app-code call passes `session:`**. If any do, they must switch to `configuration:` — note them and include in Task 5.

- [ ] **Step 2: Confirm the test file is the only `session:` caller**

Run:
```bash
grep -rn "session:" ios/PatataTubeKit
```
Expected: matches only inside `Tests/PatataTubeKitTests/CacheManagerTests.swift` (the `mockDownloadSession()` helper). This confirms the init-signature change is contained.

No commit (read-only task).

---

### Task 2: Update the test helper to inject a configuration

Do this first so the suite compiles against the new init while we rewrite the class. TDD note: the existing behavior tests ARE our regression suite — they must stay green through the rewrite.

**Files:**
- Modify: `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift:30-34` (helper) and every `CacheManager(root:...,session:...)` call site.

- [ ] **Step 1: Replace the session helper with a configuration helper**

Replace:
```swift
private func mockDownloadSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockDownloadProtocol.self]
    return URLSession(configuration: config)
}
```
with:
```swift
private func mockDownloadConfig() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockDownloadProtocol.self]
    return config
}
```

- [ ] **Step 2: Update all construction sites**

Replace every `CacheManager(root: ..., session: mockDownloadSession())` and
`CacheManager(session: mockDownloadSession())` with the `configuration:` form, e.g.:
```swift
let manager = CacheManager(root: root, configuration: mockDownloadConfig())
```
There are 6 construction sites (lines ~45, 51, 66, 86, 101, 117). Update each.

- [ ] **Step 3: Verify the test file no longer references the old symbols**

Run:
```bash
grep -n "mockDownloadSession\|session:" ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift
```
Expected: no matches.

- [ ] **Step 4: Commit**

```bash
git add ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift
git commit -m "test: inject URLSessionConfiguration into CacheManager tests"
```

(The suite will not build until Task 3 lands the new init — that's expected; these two tasks form one compilable unit. Do not run `swift test` between Task 2 and Task 3.)

---

### Task 3: Rewrite CacheManager onto a download delegate

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift` (replace the whole file).

- [ ] **Step 1: Replace the file with the delegate-backed implementation**

```swift
import Foundation

public enum CacheState: Equatable, Sendable {
    case notCached
    case downloading(Double)
    case cached
}

public final class CacheManager: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let root: URL
    private let fileManager = FileManager.default
    private let lock = NSLock()

    // All three keyed while a download for an id is active.
    private var inFlight: [Int: Double] = [:]                       // id -> progress 0...1
    private var continuations: [Int: CheckedContinuation<URL, Error>] = [:]
    private var idByTask: [Int: Int] = [:]                          // taskIdentifier -> id

    private lazy var session: URLSession = URLSession(
        configuration: configuration, delegate: self, delegateQueue: nil)
    private let configuration: URLSessionConfiguration

    public init(root: URL? = nil, configuration: URLSessionConfiguration = .default) {
        self.root = root ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("videos")
        self.configuration = configuration
        super.init()
        try? fileManager.createDirectory(at: self.root, withIntermediateDirectories: true)
        // Visible in the Files app (Documents), but keep it out of iCloud/device
        // backups — these MP4s (and .resume scratch files) are re-downloadable.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = self.root
        try? dir.setResourceValues(values)
    }

    public func localURL(for id: Int) -> URL {
        root.appendingPathComponent("\(id).mp4")
    }

    private func resumeURL(for id: Int) -> URL {
        root.appendingPathComponent("\(id).resume")
    }

    /// Local file URL of a cached preview image, or nil if none is cached.
    public func cachedPreviewURL(for id: Int) -> URL? {
        let prefix = "\(id).preview."
        let contents = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        guard let name = contents.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return root.appendingPathComponent(name)
    }

    public func state(for id: Int) -> CacheState {
        if fileManager.fileExists(atPath: localURL(for: id).path) { return .cached }
        return lock.withLock {
            inFlight[id].map { .downloading($0) } ?? .notCached
        }
    }

    public func download(id: Int, from remote: URL, preview: URL? = nil,
                         bearerToken: String? = nil) async throws {
        // Resume from a prior partial transfer if we have opaque resume data.
        let resumeData = try? Data(contentsOf: resumeURL(for: id))

        let destination: URL = try await withCheckedThrowingContinuation { continuation in
            let task: URLSessionDownloadTask
            if let resumeData {
                task = session.downloadTask(withResumeData: resumeData)
            } else {
                var request = URLRequest(url: remote)
                if let bearerToken {
                    request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
                }
                task = session.downloadTask(with: request)
            }
            lock.withLock {
                inFlight[id] = 0
                continuations[id] = continuation
                idByTask[task.taskIdentifier] = id
            }
            task.resume()
        }
        _ = destination

        // Best-effort: a missing preview must not fail the cached video.
        if let preview { try? await cachePreview(id: id, from: preview, bearerToken: bearerToken) }
    }

    // MARK: URLSessionDownloadDelegate

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                           totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        lock.withLock {
            if let id = idByTask[downloadTask.taskIdentifier] { inFlight[id] = progress }
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {
        // Runs on the delegate queue; the temp file is gone once this returns,
        // so move it synchronously here.
        let id: Int? = lock.withLock { idByTask[downloadTask.taskIdentifier] }
        guard let id else { return }

        // Preserve the existing bad-status contract.
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            finish(id: id, taskIdentifier: downloadTask.taskIdentifier,
                   result: .failure(APIError.badStatus(http.statusCode)))
            return
        }

        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let dest = localURL(for: id)
            try? fileManager.removeItem(at: dest)
            try fileManager.moveItem(at: location, to: dest)
            try? fileManager.removeItem(at: resumeURL(for: id))   // clean scratch on success
            finish(id: id, taskIdentifier: downloadTask.taskIdentifier, result: .success(dest))
        } catch {
            finish(id: id, taskIdentifier: downloadTask.taskIdentifier, result: .failure(error))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           didCompleteWithError error: Error?) {
        guard let error else { return }   // success already resolved in didFinishDownloadingTo
        let id: Int? = lock.withLock { idByTask[task.taskIdentifier] }
        guard let id else { return }

        if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? data.write(to: resumeURL(for: id))     // keep for the next re-tap
        } else {
            // Stale/unresumable failure: drop scratch so the next tap is a clean start.
            try? fileManager.removeItem(at: resumeURL(for: id))
        }
        finish(id: id, taskIdentifier: task.taskIdentifier, result: .failure(error))
    }

    // Resolves the continuation for `id` exactly once and clears its bookkeeping.
    private func finish(id: Int, taskIdentifier: Int, result: Result<URL, Error>) {
        let continuation: CheckedContinuation<URL, Error>? = lock.withLock {
            let c = continuations.removeValue(forKey: id)
            inFlight[id] = nil
            idByTask[taskIdentifier] = nil
            return c
        }
        continuation?.resume(with: result)
    }

    private func cachePreview(id: Int, from remote: URL, bearerToken: String? = nil) async throws {
        var request = URLRequest(url: remote)
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.badStatus(http.statusCode)
        }
        let ext = remote.pathExtension.lowercased()
        let safeExt = (1...4).contains(ext.count) && ext.allSatisfy(\.isLetter) ? ext : "jpg"
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("\(id).preview.\(safeExt)")
        try? fileManager.removeItem(at: destination)
        try data.write(to: destination)
    }
}
```

Implementation notes for the worker:
- `finish` both resolves the continuation and clears `continuations`/`inFlight`/`idByTask`, so both delegate callbacks (`didFinishDownloadingTo` for success, `didCompleteWithError` for failure) are safe: whichever the platform delivers first resolves once; the second finds no continuation and no-ops.
- `session` is `lazy` so `self` is fully initialized before it is passed as the delegate.
- `cachePreview` still uses `session.data(for:)`; the delegate ignores non-download tasks, so this is fine.

- [ ] **Step 2: Build**

Run: `cd ios/PatataTubeKit && swift build`
Expected: builds with no errors.

- [ ] **Step 3: Run the CacheManager regression suite**

Run: `cd ios/PatataTubeKit && swift test --filter CacheManagerTests`
Expected: all existing tests PASS (success caches file, bad-status throws `APIError.badStatus(404)`, preview caching, preview-failure-still-caches, bearer token seen twice).

If `downloadThrowsOnBadStatus` fails: confirm the mock returns a 404 `HTTPURLResponse` and that `didFinishDownloadingTo` reads `downloadTask.response` (URLProtocol delivers the response even for 404, so the file "downloads" then we reject on status).

- [ ] **Step 4: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift
git commit -m "feat: resumable offline downloads via URLSessionDownloadDelegate"
```

---

### Task 4: Add a regression test for resume-file cleanup on success

We cannot unit-test true byte-level resume (opaque resume data needs a real ranged transfer), but we CAN pin the invariant that a successful download leaves no `.resume` scratch behind.

**Files:**
- Modify: `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift`

- [ ] **Step 1: Write the failing test**

Add inside the `CacheManagerTests` struct:
```swift
@Test func successfulDownloadLeavesNoResumeFile() async throws {
    let root = tempRoot()
    let manager = CacheManager(root: root, configuration: mockDownloadConfig())
    MockDownloadProtocol.handler = { req in
        (jsonResponse(req.url!), Data([0x01, 0x02]))
    }
    try await manager.download(id: 21, from: URL(string: "https://srv.test/videos/21/stream")!)

    let resumeFile = root.appendingPathComponent("21.resume")
    #expect(!FileManager.default.fileExists(atPath: resumeFile.path))
    #expect(manager.state(for: 21) == .cached)
}
```

- [ ] **Step 2: Run it**

Run: `cd ios/PatataTubeKit && swift test --filter successfulDownloadLeavesNoResumeFile`
Expected: PASS (the `removeItem(at: resumeURL)` on the success path is a no-op when no scratch exists, and no scratch is created on success).

- [ ] **Step 3: Commit**

```bash
git add ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift
git commit -m "test: successful download leaves no resume scratch file"
```

---

### Task 5: Full suite + manual-test doc

**Files:**
- Modify: `ios/README.md` (append to the manual test checklist).

- [ ] **Step 1: Run the entire Kit suite**

Run: `cd ios/PatataTubeKit && swift test`
Expected: all suites PASS (CacheManager, APIClient, VideoStore, ShowGroup, Credential, Video, Scaffold). No compile warnings introduced by the rewrite.

- [ ] **Step 2: Add the manual resume test to the README**

Find the manual test checklist in `ios/README.md` and add:
```markdown
- [ ] **Resume offline download:** Start caching a large video for offline; mid-transfer enable Airplane Mode (or force-quit the app). Re-enable network and tap download again on the same video. It must finish and play — and should resume, not restart (verify via fewer bytes transferred / faster finish on a large file, or Xcode's network logs). A `{id}.resume` scratch file may appear in the app's Documents/videos while paused and must be gone after success.
```
If no checklist heading exists, add a `## Manual tests` section with this item.

- [ ] **Step 3: Commit**

```bash
git add ios/README.md
git commit -m "docs: manual test for resumable offline downloads"
```

- [ ] **Step 4: (Manual, on device/simulator — human) Verify resume end to end**

Follow the README step just added. This is the only check that exercises real resume data; automated tests cannot. Record the result in the PR/commit notes.

---

## Done criteria

- `swift build` and `swift test` pass in `ios/PatataTubeKit`.
- `download(id:from:preview:bearerToken:)`, `state(for:)`, `localURL`, `cachedPreviewURL` keep their signatures; no app-code caller changed.
- Interrupting a download writes `{id}.resume`; the next `download(id:)` resumes from it; success deletes it.
- Manual device test confirms a real interrupted download resumes rather than restarting.
