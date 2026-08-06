# Movie Detail Three-Dot Menu + Delete Cached — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a three-dot toolbar menu to `MovieDetailView` with a "Delete cached" item that wipes every cached MP4 for the movie.

**Architecture:** Two new `CacheManager` methods in the PatataTubeKit SwiftPM package (`hasAnyCached`, `removeAllCached`), TDD'd with the existing swift-testing `CacheManagerTests` suite. Then a SwiftUI `.toolbar` `Menu` in the app's `MovieDetailView` that calls them. The existing download button is not touched.

**Tech Stack:** Swift / SwiftUI, SwiftPM, swift-testing (`@Test`, `#expect`).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-20-movie-detail-menu-delete-cached-design.md`
- Do NOT modify the existing download button, Play button, or version/audio pickers in `MovieDetailView`.
- `removeAllCached` must keep preview images (`{id}.preview.*`) and show posters (`poster.*`).
- Menu item is always visible, disabled (grayed) when nothing cached.
- No confirmation dialog.
- `docs/` is gitignored in this repo — commit code only, never force-add docs.

---

### Task 1: CacheManager.hasAnyCached / removeAllCached

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift` (add methods near `removeCached`, ~line 98)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift` (append inside `struct CacheManagerTests`)

**Interfaces:**
- Consumes: existing `CacheManager` internals (`root`, `fileManager`), test helpers `tempRoot()`, `mockDownloadConfig()` already in the test file.
- Produces: `public func hasAnyCached(id: Int) -> Bool` and `public func removeAllCached(id: Int)` — Task 2 calls both.

Cache filename scheme (existing): video `"{id}.mp4"` or `"{id}.v{versionId}.mp4"`; resume data `"{id}.resume"` or `"{id}:{versionId}.resume"`; preview `"{id}.preview.{ext}"`; poster `"poster.{hash}.{ext}"`.

- [ ] **Step 1: Write the failing tests**

Append inside `struct CacheManagerTests` in `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift`:

```swift
    @Test func hasAnyCachedFindsBaseAndVersionedFiles() throws {
        let root = tempRoot()
        let manager = CacheManager(root: root, configuration: mockDownloadConfig())
        #expect(manager.hasAnyCached(id: 21) == false)

        try Data([0x01]).write(to: root.appendingPathComponent("21.v3.mp4"))
        #expect(manager.hasAnyCached(id: 21))

        try Data([0x01]).write(to: root.appendingPathComponent("2.mp4"))
        #expect(manager.hasAnyCached(id: 2))
        // id 2 must not match 21.v3.mp4; id 1 must not match either file.
        #expect(manager.hasAnyCached(id: 1) == false)
    }

    @Test func hasAnyCachedIgnoresPreviewFiles() throws {
        let root = tempRoot()
        let manager = CacheManager(root: root, configuration: mockDownloadConfig())
        try Data([0x01]).write(to: root.appendingPathComponent("22.preview.jpg"))
        #expect(manager.hasAnyCached(id: 22) == false)
    }

    @Test func removeAllCachedDeletesVideosAndResumeDataKeepsPreviews() throws {
        let root = tempRoot()
        let manager = CacheManager(root: root, configuration: mockDownloadConfig())
        let keep = ["23.preview.jpg", "poster.abc123.jpg", "24.mp4", "24:1.resume"]
        let remove = ["23.mp4", "23.v1.mp4", "23.v12.mp4", "23.resume", "23:4.resume"]
        for name in keep + remove {
            try Data([0x01]).write(to: root.appendingPathComponent(name))
        }

        manager.removeAllCached(id: 23)

        for name in remove {
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path),
                    "should have deleted \(name)")
        }
        for name in keep {
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path),
                    "should have kept \(name)")
        }
        #expect(manager.state(for: 23) == .notCached)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios/PatataTubeKit && swift test --filter CacheManagerTests`
Expected: compile FAILURE — `value of type 'CacheManager' has no member 'hasAnyCached'` (and `removeAllCached`).

- [ ] **Step 3: Implement the methods**

In `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift`, directly below the existing `removeCached(id:versionId:)` (after ~line 98), add:

```swift
    /// True when any cached MP4 (any version) exists for this video.
    public func hasAnyCached(id: Int) -> Bool {
        !cachedVideoFilenames(id: id).isEmpty
    }

    /// Deletes every cached MP4 and resume file for this video, all versions.
    /// Preview images and show posters are kept — small, still useful offline.
    public func removeAllCached(id: Int) {
        let contents = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        let resumes = contents.filter {
            $0 == "\(id).resume" || ($0.hasPrefix("\(id):") && $0.hasSuffix(".resume"))
        }
        for name in cachedVideoFilenames(id: id) + resumes {
            try? fileManager.removeItem(at: root.appendingPathComponent(name))
        }
    }

    private func cachedVideoFilenames(id: Int) -> [String] {
        let contents = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        return contents.filter {
            $0 == "\(id).mp4" || ($0.hasPrefix("\(id).v") && $0.hasSuffix(".mp4"))
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios/PatataTubeKit && swift test --filter CacheManagerTests`
Expected: all CacheManagerTests PASS, including the 3 new tests.

- [ ] **Step 5: Run the full Kit suite**

Run: `cd ios/PatataTubeKit && swift test`
Expected: PASS, no regressions.

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift
git commit -m "feat: CacheManager.hasAnyCached and removeAllCached across versions

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Three-dot menu in MovieDetailView

**Files:**
- Modify: `ios/PatataTube/Sources/MovieDetailView.swift` (toolbar modifiers, after `.navigationBarTitleDisplayMode(.inline)` ~line 114)

**Interfaces:**
- Consumes: `model.cache.hasAnyCached(id: Int) -> Bool` and `model.cache.removeAllCached(id: Int)` from Task 1; existing `@State` vars `activeDownloadID`, `downloadPhase`, `observedCacheState`, `progress` and computed `currentVideo`.
- Produces: UI only, nothing downstream.

No app test target exists (per `ios/README.md`) — verification is compile + manual.

- [ ] **Step 1: Add the toolbar menu**

In `ios/PatataTube/Sources/MovieDetailView.swift`, insert between `.navigationBarTitleDisplayMode(.inline)` and `.task(id: downloadPollKey)`:

```swift
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        model.cache.removeAllCached(id: currentVideo.id)
                        // Flip the download button back to the arrow now,
                        // instead of waiting for the 500ms cache poll.
                        activeDownloadID = nil
                        withAnimation {
                            downloadPhase = .idle
                            observedCacheState = .notCached
                            progress = 0
                        }
                    } label: {
                        Label("Delete cached", systemImage: "trash")
                    }
                    .disabled(!model.cache.hasAnyCached(id: currentVideo.id))
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
```

- [ ] **Step 2: Verify the Kit still builds and the app compiles**

Run:
```bash
cd ios/PatataTubeKit && swift build
cd ../PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```
Expected: both succeed (`BUILD SUCCEEDED`). If no simulator SDK is installed, fall back to `swift build` in PatataTubeKit plus opening the project in Xcode and building there.

- [ ] **Step 3: Manual smoke check (device/simulator)**

Per `ios/README.md` checklist style:
1. Open a movie detail with nothing cached → three-dot menu top right, "Delete cached" grayed out.
2. Download the movie → menu item becomes enabled (red).
3. Tap "Delete cached" → download button flips from green checkmark back to the down-arrow immediately; poster preview still shows.
4. Re-download → works.

- [ ] **Step 4: Commit**

```bash
git add ios/PatataTube/Sources/MovieDetailView.swift
git commit -m "feat: three-dot menu on movie detail with delete-cached action

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
