# Persistent Library Cover Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist each successfully displayed library movie or TV-show cover on device, independently of the MP4 download state.

**Architecture:** `CacheManager` remains the owner of files in the app’s cache directory. It gains a public movie-cover write API alongside its existing movie-cover lookup API; the existing show-poster API is used with `ShowGroup.id` instead of a remote URL. SwiftUI cover views give `AuthedImage` an `onNetworkLoad` callback that persists the bytes after the current image has rendered.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, Foundation, CryptoKit.

## Global Constraints

- Persist a cover only after its first successful network response; never couple it to MP4 download state.
- Movie-cover disk keys use `Video.id`; show-cover disk keys use `ShowGroup.id`.
- Retain the current in-memory `ImageMemoryCache` as the fastest lookup layer.
- Preserve existing disk images when cached MP4s are deleted.
- Cache writes are best-effort and must not suppress a successfully loaded image.

---

## File Structure

- `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift` owns deterministic cover filenames, disk lookup, and disk writes.
- `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift` verifies movie-ID and show-ID cover persistence independently of video downloads.
- `ios/PatataTube/Sources/MovieCell.swift` persists a movie cover after `AuthedImage` fetches it.
- `ios/PatataTube/Sources/MovieDetailView.swift` uses the same movie-ID cache path and persistence callback.
- `ios/PatataTube/Sources/ShowsView.swift` resolves and stores TV artwork with `ShowGroup.id`.

### Task 1: Add cache-manager cover persistence APIs

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift:40-64`
- Modify: `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift:166-205, 384-411`

**Interfaces:**
- Produces: `public func storePreview(_ data: Data, for id: Int, path: String)`.
- Produces: existing `cachedPreviewURL(for:)` and `storeShowPoster(_:for:)`, used with `Video.id` and `ShowGroup.id` respectively.

- [ ] **Step 1: Write failing cache-manager tests**

Add these tests to `CacheManagerTests`:

```swift
@Test func previewStoreAndLookupUsesMovieID() throws {
    let manager = CacheManager(root: tempRoot(), configuration: mockDownloadConfig())
    #expect(manager.cachedPreviewURL(for: 44) == nil)

    manager.storePreview(Data([0xAA, 0xBB]), for: 44,
                         path: "/videos/44/preview.jpg")

    let url = try #require(manager.cachedPreviewURL(for: 44))
    #expect(url.lastPathComponent == "44.preview.jpg")
    #expect(try Data(contentsOf: url) == Data([0xAA, 0xBB]))
    #expect(manager.cachedPreviewURL(for: 45) == nil)
}

@Test func showPosterStoreAndLookupUsesShowID() throws {
    let manager = CacheManager(root: tempRoot(), configuration: mockDownloadConfig())
    manager.storeShowPoster(Data([0x01]), for: "Bluey")

    let url = try #require(manager.cachedShowPosterURL(for: "Bluey"))
    #expect(try Data(contentsOf: url) == Data([0x01]))
    #expect(manager.cachedShowPosterURL(for: "Other Show") == nil)
}
```

- [ ] **Step 2: Run the new movie-cover test and verify it fails**

Run: `rtk proxy zsh -lc 'cd ios/PatataTubeKit && swift test --filter CacheManagerTests.previewStoreAndLookupUsesMovieID'`

Expected: compilation failure because `CacheManager.storePreview(_:for:path:)` does not exist.

- [ ] **Step 3: Implement the minimal movie-cover writer**

In `CacheManager`, add a public best-effort writer beside `cachedPreviewURL(for:)`:

```swift
public func storePreview(_ data: Data, for id: Int, path: String) {
    try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    let destination = root.appendingPathComponent("\(id).preview.\(safeExt(from: path))")
    try? fileManager.removeItem(at: destination)
    try? data.write(to: destination)
}
```

Refactor the private `cachePreview(id:from:bearerToken:)` method to call
`storePreview(data, for: id, path: remote.absoluteString)` after receiving a
successful HTTP response. Do not change its best-effort caller in `download`.

- [ ] **Step 4: Run the cache-manager suite and verify it passes**

Run: `rtk proxy zsh -lc 'cd ios/PatataTubeKit && swift test --filter CacheManagerTests'`

Expected: all `CacheManagerTests` pass, including the new movie and show key tests.

- [ ] **Step 5: Commit the cache-manager API**

```bash
rtk git add ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift
rtk git commit -m "feat(ios): persist library cover images"
```

### Task 2: Persist images fetched while browsing

**Files:**
- Modify: `ios/PatataTube/Sources/MovieCell.swift:26-30`
- Modify: `ios/PatataTube/Sources/MovieDetailView.swift:34-42`
- Modify: `ios/PatataTube/Sources/ShowsView.swift:39-54`

**Interfaces:**
- Consumes: `CacheManager.storePreview(_:for:path:)` from Task 1.
- Consumes: `CacheManager.cachedShowPosterURL(for:)` and `storeShowPoster(_:for:)` with `ShowGroup.id`.
- Consumes: `AuthedImage.onNetworkLoad`, which receives only successfully fetched image data.

- [ ] **Step 1: Confirm Task 1's disk-cache behavior test is green before wiring views**

Run: `rtk proxy zsh -lc 'cd ios/PatataTubeKit && swift test --filter CacheManagerTests.previewStoreAndLookupUsesMovieID'`

Expected: PASS. This behavior-level test proves the callback destination can
persist and subsequently resolve a movie cover; the views only supply their
existing successful network bytes to that API.

- [ ] **Step 2: Wire persistent callbacks into every browsing cover surface**

Change `MovieCell`’s overlay to pass a callback that writes only a first-time
network fetch to the movie’s cache entry:

```swift
AuthedImage(path: video.previewUrl, localFileURL: cachedPreviewURL,
            onNetworkLoad: { data in
                guard let path = video.previewUrl,
                      model.cache.cachedPreviewURL(for: video.id) == nil else { return }
                model.cache.storePreview(data, for: video.id, path: path)
            })
```

Apply the equivalent callback in `MovieDetailView`, using `currentVideo.id` and
`currentVideo.previewUrl`.

In `ShowsView`, change both the lookup and callback key from `show.posterPath`
to `show.id`. Remove the “at least one episode is cached” condition from
`backfillPoster`; its only guard becomes that a poster path exists and
`cachedShowPosterURL(for: show.id)` is absent:

```swift
private func cachedPosterURL(for show: ShowGroup) -> URL? {
    model.cache.cachedShowPosterURL(for: show.id)
}

private func backfillPoster(_ data: Data, for show: ShowGroup) {
    guard show.posterPath != nil,
          model.cache.cachedShowPosterURL(for: show.id) == nil else { return }
    model.cache.storeShowPoster(data, for: show.id)
}
```

- [ ] **Step 3: Run package and app tests**

Run:

```bash
rtk proxy zsh -lc 'cd ios/PatataTubeKit && swift test'
rtk proxy zsh -lc 'cd ios/PatataTube && xcodegen generate && xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1"'
```

Expected: all package and app tests pass.

- [ ] **Step 4: Commit the view wiring**

```bash
rtk git add ios/PatataTube/Sources/MovieCell.swift ios/PatataTube/Sources/MovieDetailView.swift ios/PatataTube/Sources/ShowsView.swift
rtk git commit -m "fix(ios): cache browsed library cover images"
```

### Task 3: Verify on a device or simulator

**Files:**
- Modify: `ios/README.md:118-119`

**Interfaces:**
- Consumes: the persistent disk-cache behavior from Tasks 1 and 2.
- Produces: a repeatable manual regression checklist.

- [ ] **Step 1: Add the manual regression check**

Add this checklist item in the Plex library section of `ios/README.md`:

```markdown
- [ ] Browse through movie and TV covers, return to the start, then relaunch the app; previously viewed covers appear without a loader even when their videos were never downloaded.
```

- [ ] **Step 2: Build the app**

Run: `rtk proxy zsh -lc 'cd ios/PatataTube && xcodegen generate && xcodebuild build -project PatataTube.xcodeproj -scheme PatataTube -destination "generic/platform=iOS"'`

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Perform the manual cache check**

1. Open the movies tab with network connectivity.
2. Scroll until several uncached movie covers have loaded; do not tap Download.
3. Return to the top and confirm those covers display without `ProgressView`.
4. Quit and relaunch the app, open the movies tab, and confirm the same covers display without a loader.
5. Repeat the check in the TV tab.

- [ ] **Step 4: Commit the manual test documentation**

```bash
rtk git add ios/README.md
rtk git commit -m "docs(ios): verify persistent library cover cache"
```

## Plan Self-Review

- Spec coverage: Task 1 creates per-movie and per-show disk keys; Task 2 writes artwork after first browse fetch and preserves the lookup order; Task 3 verifies the no-loader behavior across relaunches.
- Placeholder scan: no incomplete or undefined implementation steps remain.
- Type consistency: Task 1 defines `storePreview(_:for:path:)`; Task 2 calls exactly that signature. The existing `ShowGroup.id` is a `String` and matches `cachedShowPosterURL(for:)` / `storeShowPoster(_:for:)`.
