# iOS Clear Cache Quick Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add four iOS home-screen quick actions (long-press app icon) that each clear one category of cached/persisted state — Videos, Covers, Lists, Reset Settings — with no confirmation dialogs.

**Architecture:** New public bulk-clear methods on the testable `PatataTubeKit` core (`CacheManager`, `VideoListCache`/`VideoStore`), driven by four thin `AppModel` methods. Home-screen shortcuts are declared statically in the generated `Info.plist` (via `project.yml`) and routed through a programmatic `UISceneDelegate` + a `QuickActionRouter` singleton that `RootView` observes.

**Tech Stack:** Swift 6, SwiftUI (App lifecycle), swift-testing (`@Test`), XcodeGen.

## Global Constraints

- Deployment target iOS 17.0; `SWIFT_VERSION` 6.0.
- Kit tests use **swift-testing** (`import Testing`, `@Test`, `#expect`), NOT XCTest. Build/run the kit standalone with `cd ios/PatataTubeKit && swift build` / `swift test`.
- All filesystem deletes are best-effort `try?` — never throw to the user (matches existing `CacheManager` idiom).
- The generated `ios/PatataTube/Sources/Info.plist` is **overwritten by XcodeGen** from `project.yml` `targets.PatataTube.info.properties`. Plist changes go in `project.yml`, then `xcodegen generate`.
- Cache file naming (source of truth), all inside `CacheManager.root` = `Documents/videos/`:
  - Videos: `{id}.mp4`, `{id}.v{ver}.mp4`
  - Resume: `{id}.resume`, `{id}:*.resume`
  - Segment manifests: owned by `segmentedStore` (`SegmentedDownloadStore`)
  - Completion history: `download-completions.json` (`DownloadCompletionHistoryStore`)
  - Previews: `{id}.preview.*`; posters: `poster.{hash}.*`
  - Video-list JSON: separate root `Caches/video-lists/{classification|all}.json` (`VideoListCache`)

---

## File Structure

- `ios/PatataTubeKit/Sources/PatataTubeKit/DownloadActivity.swift` — add `DownloadCompletionHistoryStore.clear()`.
- `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift` — add `clearAllVideos()`, `clearAllCovers()`.
- `ios/PatataTubeKit/Sources/PatataTubeKit/VideoListCache.swift` — add `clear()` to protocol + impl.
- `ios/PatataTubeKit/Sources/PatataTubeKit/VideoStore.swift` — add `clearListCache()`.
- `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift` — new tests.
- `ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoStoreTests.swift` — new test.
- `ios/PatataTube/Sources/QuickActions.swift` — **new**: `QuickAction` enum + `QuickActionRouter` + `SceneDelegate`.
- `ios/PatataTube/Sources/AppModel.swift` — add `clearVideos()`, `clearCovers()`, `clearLists()`, `resetSettings()`, `handle(_:)`.
- `ios/PatataTube/Sources/PatataTubeApp.swift` — `AppDelegate.application(_:configurationForConnecting:options:)`; `RootView` observes the router.
- `ios/PatataTube/project.yml` — add `UIApplicationShortcutItems`.

---

### Task 1: List-cache clearing (`VideoListCaching.clear` + `VideoStore.clearListCache`)

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/VideoListCache.swift`
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/VideoStore.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoStoreTests.swift`

**Interfaces:**
- Produces: `VideoListCaching.clear()`; `VideoStore.clearListCache()` (`@MainActor`, empties published `videos` and wipes the on-disk list cache).

- [ ] **Step 1: Write the failing test**

Append to `VideoStoreTests.swift` (uses the existing `tempCache()` helper returning a real `VideoListCache(root:)`, and the existing API stub pattern — mirror `loadSavesResponseToCache` at line 257 for how `api`/`cache` are built):

```swift
@MainActor @Test func clearListCacheEmptiesVideosAndDiskCache() async {
    let cache = tempCache()
    let api = StubAPI(videos: [sampleVideo(id: 1), sampleVideo(id: 2)])
    let store = VideoStore(api: api, cache: cache)
    await store.load()
    #expect(!store.videos.isEmpty)
    #expect(cache.load(classification: nil) != nil)

    store.clearListCache()

    #expect(store.videos.isEmpty)
    #expect(cache.load(classification: nil) == nil)
}
```

Use whatever the file's existing helpers are named for the API stub and sample video (grep the file for the constructor used at line 257 and reuse it verbatim — do NOT invent `StubAPI`/`sampleVideo` if the file names them differently).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter clearListCacheEmptiesVideosAndDiskCache`
Expected: FAIL — `value of type 'VideoStore' has no member 'clearListCache'`.

- [ ] **Step 3: Add `clear()` to the protocol + `VideoListCache`**

In `VideoListCache.swift`, add to the protocol:

```swift
public protocol VideoListCaching: Sendable {
    func save(_ videos: [Video], classification: String?)
    func load(classification: String?) -> [Video]?
    func clear()
}
```

And to `VideoListCache`:

```swift
    public func clear() {
        try? fileManager.removeItem(at: root)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }
```

- [ ] **Step 4: Add `clearListCache()` to `VideoStore`**

In `VideoStore.swift` (this type is `@MainActor`):

```swift
    /// Wipes the on-disk offline list cache and empties the in-memory list.
    /// The next `load()` repopulates both from the server.
    public func clearListCache() {
        cache?.clear()
        videos = []
    }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd ios/PatataTubeKit && swift test --filter clearListCacheEmptiesVideosAndDiskCache`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/VideoListCache.swift ios/PatataTubeKit/Sources/PatataTubeKit/VideoStore.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoStoreTests.swift
git commit -m "feat(ios): VideoStore.clearListCache wipes offline list cache"
```

---

### Task 2: `CacheManager.clearAllVideos()` + history clear

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/DownloadActivity.swift:117-159` (add `clear()`)
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift` (add method near `removeAllCached` at line 456)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift`

**Interfaces:**
- Consumes: existing `cancel(id:versionId:)` (line 399), `activeDownloads()` (line 269) returning `[DownloadActivity]` with `videoID`/`versionID`, `segmentedStore.manifests()` / `.remove(cacheKey:)`, `cachedVideoFilenames(id:)` pattern (line 469).
- Produces: `CacheManager.clearAllVideos()` (public); `DownloadCompletionHistoryStore.clear()` (internal `mutating`).

- [ ] **Step 1: Write the failing test**

Append to `CacheManagerTests.swift` (uses existing `tempRoot()` helper at line 1147). Seed files directly into the manager's root, then assert:

```swift
@Test func clearAllVideosRemovesVideosAndKeepsCovers() throws {
    let root = tempRoot()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let files = [
        "1.mp4", "2.v5.mp4", "1.resume", "2:5.resume",
        "download-completions.json",
        "1.preview.jpg", "poster.abc123.jpg",
    ]
    for name in files {
        try Data("x".utf8).write(to: root.appendingPathComponent(name))
    }
    let manager = CacheManager(root: root)

    manager.clearAllVideos()

    let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
    #expect(!remaining.contains("1.mp4"))
    #expect(!remaining.contains("2.v5.mp4"))
    #expect(!remaining.contains("1.resume"))
    #expect(!remaining.contains("2:5.resume"))
    #expect(!remaining.contains("download-completions.json"))
    #expect(remaining.contains("1.preview.jpg"))
    #expect(remaining.contains("poster.abc123.jpg"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter clearAllVideosRemovesVideosAndKeepsCovers`
Expected: FAIL — `value of type 'CacheManager' has no member 'clearAllVideos'`.

- [ ] **Step 3: Add `clear()` to `DownloadCompletionHistoryStore`**

In `DownloadActivity.swift`, after `prune(...)` (line 149):

```swift
    mutating func clear() {
        entries = []
        try? fileManager.removeItem(at: url)
    }
```

- [ ] **Step 4: Add `clearAllVideos()` to `CacheManager`**

In `CacheManager.swift`, right after `removeAllCached(id:)` (line 467):

```swift
    /// Clears every downloaded video: cancels in-flight downloads, removes all
    /// MP4s + resume files + segment manifests + completion history. Preview
    /// images and show posters are kept (see `clearAllCovers()`).
    public func clearAllVideos() {
        for activity in activeDownloads() {
            cancel(id: activity.videoID, versionId: activity.versionID)
        }
        let contents = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        for name in contents where name.hasSuffix(".mp4") || name.hasSuffix(".resume") {
            try? fileManager.removeItem(at: root.appendingPathComponent(name))
        }
        for manifest in segmentedStore.manifests() {
            segmentedStore.remove(cacheKey: manifest.cacheKey)
        }
        lock.withLock { completionHistory.clear() }
    }
```

Note: `completionHistory` is a `private var` (line 155), mutated under `lock` to match how the rest of the file guards mutable state. `activeDownloads()` and `cancel(...)` take their own locks, so call them BEFORE entering any `lock.withLock` block (as written above — they are outside the lock).

- [ ] **Step 5: Run test to verify it passes**

Run: `cd ios/PatataTubeKit && swift test --filter clearAllVideosRemovesVideosAndKeepsCovers`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/DownloadActivity.swift ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift
git commit -m "feat(ios): CacheManager.clearAllVideos clears every downloaded video"
```

---

### Task 3: `CacheManager.clearAllCovers()`

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift` (after `clearAllVideos`)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift`

**Interfaces:**
- Produces: `CacheManager.clearAllCovers()` (public).

- [ ] **Step 1: Write the failing test**

Append to `CacheManagerTests.swift`:

```swift
@Test func clearAllCoversRemovesImagesAndKeepsVideos() throws {
    let root = tempRoot()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let files = ["1.preview.jpg", "poster.abc123.png", "1.mp4", "1.resume"]
    for name in files {
        try Data("x".utf8).write(to: root.appendingPathComponent(name))
    }
    let manager = CacheManager(root: root)

    manager.clearAllCovers()

    let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
    #expect(!remaining.contains("1.preview.jpg"))
    #expect(!remaining.contains("poster.abc123.png"))
    #expect(remaining.contains("1.mp4"))
    #expect(remaining.contains("1.resume"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter clearAllCoversRemovesImagesAndKeepsVideos`
Expected: FAIL — no member `clearAllCovers`.

- [ ] **Step 3: Add `clearAllCovers()` to `CacheManager`**

```swift
    /// Clears every cached preview image and show poster. Videos, resume data,
    /// manifests, and history are kept (see `clearAllVideos()`).
    public func clearAllCovers() {
        let contents = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        for name in contents where name.contains(".preview.") || name.hasPrefix("poster.") {
            try? fileManager.removeItem(at: root.appendingPathComponent(name))
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios/PatataTubeKit && swift test --filter clearAllCoversRemovesImagesAndKeepsVideos`
Expected: PASS.

- [ ] **Step 5: Run the whole kit suite to confirm no regressions**

Run: `cd ios/PatataTubeKit && swift test`
Expected: PASS (all existing + 3 new tests).

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift
git commit -m "feat(ios): CacheManager.clearAllCovers clears preview + poster images"
```

---

### Task 4: `AppModel` clear methods + quick-action routing + shortcut items

App-shell wiring. No unit-test target for this layer — verified by a clean `xcodegen generate` + build, then the manual checklist. Fold all wiring into one task since it has a single deliverable (working quick actions) and no intermediate test cycle.

**Files:**
- Create: `ios/PatataTube/Sources/QuickActions.swift`
- Modify: `ios/PatataTube/Sources/AppModel.swift`
- Modify: `ios/PatataTube/Sources/PatataTubeApp.swift`
- Modify: `ios/PatataTube/project.yml`

**Interfaces:**
- Consumes: `AppModel.cache` (`CacheManager`), `AppModel.store` (`VideoStore`), `AppModel.credentials` (`CredentialStore`), `Task 1–3` methods, `DownloadStreamSettings.defaultCount`, `SimultaneousDownloadSettings.defaultCount`.
- Produces: `QuickAction` enum, `QuickActionRouter.shared`, `SceneDelegate`, `AppModel.handle(_:)`.

- [ ] **Step 1: Create `QuickActions.swift`**

```swift
// ios/PatataTube/Sources/QuickActions.swift
import UIKit

/// The four home-screen quick actions. Raw value matches the
/// `UIApplicationShortcutItem.type` declared in project.yml.
enum QuickAction: String {
    case clearVideos = "com.patatatube.clearVideos"
    case clearCovers = "com.patatatube.clearCovers"
    case clearLists = "com.patatatube.clearLists"
    case resetSettings = "com.patatatube.resetSettings"

    init?(shortcutItem: UIApplicationShortcutItem) {
        self.init(rawValue: shortcutItem.type)
    }
}

/// Bridges shortcut delivery (scene delegate, non-SwiftUI) into SwiftUI.
/// RootView observes `pending` and dispatches to AppModel.
@MainActor
final class QuickActionRouter: ObservableObject {
    static let shared = QuickActionRouter()
    @Published var pending: QuickAction?
    private init() {}
}

/// Programmatically installed via AppDelegate.configurationForConnecting so
/// SwiftUI's WindowGroup still owns the window; this only forwards shortcuts.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let item = connectionOptions.shortcutItem,
           let action = QuickAction(shortcutItem: item) {
            Task { @MainActor in QuickActionRouter.shared.pending = action }
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        guard let action = QuickAction(shortcutItem: shortcutItem) else {
            completionHandler(false)
            return
        }
        Task { @MainActor in QuickActionRouter.shared.pending = action }
        completionHandler(true)
    }
}
```

- [ ] **Step 2: Add clear methods + `handle(_:)` to `AppModel`**

In `AppModel.swift`, add inside the class (after `saveSettings()`):

```swift
    func handle(_ action: QuickAction) async {
        switch action {
        case .clearVideos: await clearVideos()
        case .clearCovers: await clearCovers()
        case .clearLists: await clearLists()
        case .resetSettings: resetSettings()
        }
    }

    func clearVideos() async {
        cache.clearAllVideos()
        await store.load()
    }

    func clearCovers() async {
        cache.clearAllCovers()
        await store.load()
    }

    func clearLists() async {
        store.clearListCache()
        await store.load()
    }

    /// Logs out (Keychain token + base URL) and resets download settings to
    /// defaults. Leaves cached files untouched.
    func resetSettings() {
        credentials.token = nil
        credentials.baseURL = nil
        tokenText = ""
        baseURLText = ""
        downloadStreamCount = DownloadStreamSettings.defaultCount
        downloadConcurrency = SimultaneousDownloadSettings.defaultCount
        downloadSettings.save(downloadStreamCount)
        simultaneousSettings.save(downloadConcurrency)
        cache.setMaxConcurrentDownloads(downloadConcurrency)
    }
```

- [ ] **Step 3: Wire the scene delegate + router observation in `PatataTubeApp.swift`**

Add to `AppDelegate` (inside the class):

```swift
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
```

In `PatataTubeApp.body`, add an `.onReceive` to the `RootView` (alongside the existing `.onChange(of: scenePhase)`):

```swift
                .onReceive(QuickActionRouter.shared.$pending.compactMap { $0 }) { action in
                    Task {
                        await model.handle(action)
                        QuickActionRouter.shared.pending = nil
                    }
                }
```

- [ ] **Step 4: Declare the shortcut items in `project.yml`**

In `ios/PatataTube/project.yml`, under `targets.PatataTube.info.properties`, add a sibling key to `UIApplicationSceneManifest`:

```yaml
        UIApplicationShortcutItems:
          - UIApplicationShortcutItemType: com.patatatube.clearVideos
            UIApplicationShortcutItemTitle: Clear Videos
            UIApplicationShortcutItemIconType: UIApplicationShortcutIconTypeShare
          - UIApplicationShortcutItemType: com.patatatube.clearCovers
            UIApplicationShortcutItemTitle: Clear Covers
            UIApplicationShortcutItemIconType: UIApplicationShortcutIconTypeShare
          - UIApplicationShortcutItemType: com.patatatube.clearLists
            UIApplicationShortcutItemTitle: Clear Lists
            UIApplicationShortcutItemIconType: UIApplicationShortcutIconTypeShare
          - UIApplicationShortcutItemType: com.patatatube.resetSettings
            UIApplicationShortcutItemTitle: Reset Settings
            UIApplicationShortcutItemIconType: UIApplicationShortcutIconTypeShare
```

(`UIApplicationShortcutItemIconType` uses the built-in system icon enum — no SF Symbol string needed. `...Share` is a neutral built-in; adjust per taste. To use SF Symbols instead, replace with `UIApplicationShortcutItemSFSymbolName: film` etc.)

- [ ] **Step 5: Regenerate the project and build**

Run:
```bash
cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO
```
Expected: `BUILD SUCCEEDED`. Confirm the generated `Sources/Info.plist` now contains a `UIApplicationShortcutItems` array with four entries.

- [ ] **Step 6: Manual verification (per `ios/README.md`)**

On device/simulator:
1. Long-press the app icon → four actions appear: Clear Videos, Clear Covers, Clear Lists, Reset Settings.
2. Cache some videos + covers, then **Clear Videos** (cold: from a killed app; warm: from background) → `.mp4`s gone, covers still show, login intact, list reloads.
3. **Clear Covers** → poster/preview images refetch, downloaded videos remain playable offline.
4. **Clear Lists** → list repopulates from server; offline (airplane mode) it empties.
5. **Reset Settings** → Settings shows empty server URL + token (logged out), stepper values back to defaults (2 / 3).

- [ ] **Step 7: Commit**

```bash
git add ios/PatataTube/Sources/QuickActions.swift ios/PatataTube/Sources/AppModel.swift ios/PatataTube/Sources/PatataTubeApp.swift ios/PatataTube/project.yml ios/PatataTube/PatataTube.xcodeproj
git commit -m "feat(ios): four clear-cache home-screen quick actions"
```

---

## Self-Review

**Spec coverage:** Videos (Task 2), Covers (Task 3), Lists (Task 1), Reset Settings incl. logout + settings defaults (Task 4 `resetSettings`) — all four actions covered. Static shortcut items (Task 4 step 4), scene-delegate cold+warm delivery (Task 4 step 1/3), no confirmations (no dialog anywhere) — covered.

**Placeholder scan:** All steps carry concrete code/commands. The one soft spot — reusing the existing API-stub/sample-video helper names in Task 1 test — is called out explicitly with a grep instruction rather than inventing names, since those helper names live in the test file and vary.

**Type consistency:** `clearAllVideos()`, `clearAllCovers()`, `clearListCache()`, `clear()`, `resetSettings()`, `handle(_:)`, `QuickAction`, `QuickActionRouter.shared.pending` — names identical across defining and consuming tasks. `DownloadActivity.videoID`/`versionID` match the struct (DownloadActivity.swift:4-5). `completionHistory` mutated under `lock` matches its `private var` declaration.
