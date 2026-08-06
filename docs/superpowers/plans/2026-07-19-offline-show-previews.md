# Offline Show Previews Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** TV tab works offline — ShowsView posters and EpisodesView episode thumbnails render from the on-device cache for downloaded shows.

**Architecture:** `CacheManager` (PatataTubeKit) gains a show-poster cache keyed by the raw `showPreviewUrl` string (file `poster.{sha256-prefix16}.{ext}` next to the existing `{id}.preview.{ext}` files). Posters are fetched best-effort during episode download and lazily backfilled from `ShowsView` when an already-downloaded show is viewed online. The SwiftUI views pass the cached file URL into the existing `AuthedImage(localFileURL:)` local-first path.

**Tech Stack:** Swift 5 / SwiftUI, SwiftPM package `PatataTubeKit` (swift-testing `@Test` suite), CryptoKit SHA-256, XcodeGen app target.

**Spec:** `docs/superpowers/specs/2026-07-19-offline-show-previews-design.md`

## Global Constraints

- Poster cache key is the **raw** `showPreviewUrl` string exactly as it appears in `Video.showPreviewUrl` / `ShowGroup.posterPath` — never the resolved absolute URL.
- Poster filename: `poster.{first 16 hex chars of SHA-256(key)}.{safeExt}`; safeExt rule identical to `cachePreview`: 1–4 alphabetic chars from the URL path extension, else `jpg`.
- Poster fetch and store are always best-effort: a poster failure must never fail a video download or crash a view.
- Existing `download(...)` call sites must keep compiling unchanged (new parameters get defaults).
- Kit tests run with `cd ios/PatataTubeKit && swift test`. App has no test target; app tasks are verified by building:
  `cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`

---

### Task 1: CacheManager show poster cache

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift`

**Interfaces:**
- Consumes: existing `download(id:versionId:from:preview:bearerToken:)`, `cachePreview`, mock infra in `CacheManagerTests` (`MockDownloadProtocol`, `mockDownloadConfig()`, `tempRoot()`, `jsonResponse(_:status:)`).
- Produces (used by Tasks 3–4):
  - `public func cachedShowPosterURL(for key: String) -> URL?`
  - `public func storeShowPoster(_ data: Data, for key: String)`
  - `public func download(id: Int, versionId: Int? = nil, from remote: URL, preview: URL? = nil, showPosterKey: String? = nil, showPoster: URL? = nil, bearerToken: String? = nil) async throws`

- [ ] **Step 1: Write the failing tests**

Append inside `struct CacheManagerTests` in `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift`:

```swift
    @Test func showPosterStoreAndLookup() throws {
        let manager = CacheManager(root: tempRoot(), configuration: mockDownloadConfig())
        let key = "/library/shows/bluey/poster.png"
        #expect(manager.cachedShowPosterURL(for: key) == nil)

        manager.storeShowPoster(Data([0x01, 0x02]), for: key)

        let url = try #require(manager.cachedShowPosterURL(for: key))
        #expect(url.pathExtension == "png")
        #expect(try Data(contentsOf: url) == Data([0x01, 0x02]))
        // A different key must not resolve to this poster.
        #expect(manager.cachedShowPosterURL(for: "/other/poster.png") == nil)
    }

    @Test func showPosterKeyIsStableAndExtSanitized() throws {
        let root = tempRoot()
        let manager = CacheManager(root: root, configuration: mockDownloadConfig())
        let key = "https://img.test/poster?size=big"
        manager.storeShowPoster(Data([0xAA]), for: key)
        manager.storeShowPoster(Data([0xBB]), for: key)

        let url = try #require(manager.cachedShowPosterURL(for: key))
        #expect(url.pathExtension == "jpg")
        #expect(try Data(contentsOf: url) == Data([0xBB]))
        let posters = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("poster.") }
        #expect(posters.count == 1)
    }

    @Test func downloadAlsoCachesShowPoster() async throws {
        let manager = CacheManager(root: tempRoot(), configuration: mockDownloadConfig())
        MockDownloadProtocol.handler = { req in
            let bytes: [UInt8] = req.url!.host == "img.test" ? [0xCC] : [0x00]
            return (jsonResponse(req.url!), Data(bytes))
        }
        try await manager.download(
            id: 31,
            from: URL(string: "https://srv.test/videos/31/stream")!,
            showPosterKey: "/library/shows/bluey/poster.jpg",
            showPoster: URL(string: "https://img.test/poster.jpg")!
        )
        let url = try #require(manager.cachedShowPosterURL(for: "/library/shows/bluey/poster.jpg"))
        #expect(try Data(contentsOf: url) == Data([0xCC]))
    }

    @Test func showPosterFailureStillCachesVideo() async throws {
        let manager = CacheManager(root: tempRoot(), configuration: mockDownloadConfig())
        MockDownloadProtocol.handler = { req in
            if req.url!.host == "img.test" { throw URLError(.timedOut) }
            return (jsonResponse(req.url!), Data([0x09]))
        }
        try await manager.download(
            id: 32,
            from: URL(string: "https://srv.test/videos/32/stream")!,
            showPosterKey: "k",
            showPoster: URL(string: "https://img.test/poster.jpg")!
        )
        #expect(manager.state(for: 32) == .cached)
        #expect(manager.cachedShowPosterURL(for: "k") == nil)
    }

    @Test func downloadSkipsPosterFetchWhenAlreadyCached() async throws {
        let manager = CacheManager(root: tempRoot(), configuration: mockDownloadConfig())
        manager.storeShowPoster(Data([0x01]), for: "k2")
        var posterRequests = 0
        MockDownloadProtocol.handler = { req in
            if req.url!.host == "img.test" { posterRequests += 1 }
            return (jsonResponse(req.url!), Data([0x00]))
        }
        try await manager.download(
            id: 33,
            from: URL(string: "https://srv.test/videos/33/stream")!,
            showPosterKey: "k2",
            showPoster: URL(string: "https://img.test/poster.jpg")!
        )
        #expect(posterRequests == 0)
        let url = try #require(manager.cachedShowPosterURL(for: "k2"))
        #expect(try Data(contentsOf: url) == Data([0x01]))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios/PatataTubeKit && swift test 2>&1 | tail -20`
Expected: compile FAILURE — `value of type 'CacheManager' has no member 'cachedShowPosterURL'` (storeShowPoster/showPosterKey also unresolved).

- [ ] **Step 3: Implement poster cache in CacheManager**

In `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift`:

Add import at top (after `import Foundation`):

```swift
import CryptoKit
```

Replace the existing `download` method with:

```swift
    public func download(id: Int, versionId: Int? = nil, from remote: URL, preview: URL? = nil,
                         showPosterKey: String? = nil, showPoster: URL? = nil,
                         bearerToken: String? = nil) async throws {
        _ = try await downloadVideo(id: id, versionId: versionId, from: remote, bearerToken: bearerToken)
        // Best-effort: a missing preview must not fail the cached video.
        if let preview { try? await cachePreview(id: id, from: preview, bearerToken: bearerToken) }
        // Show poster is shared across episodes: fetch once, skip when cached.
        if let showPosterKey, let showPoster, cachedShowPosterURL(for: showPosterKey) == nil {
            try? await cacheShowPoster(key: showPosterKey, from: showPoster, bearerToken: bearerToken)
        }
    }
```

Add below `cachedPreviewURL(for:)`:

```swift
    /// Local file URL of a cached show poster, or nil if none is cached.
    /// Keyed by the raw showPreviewUrl string so store and lookup always agree.
    public func cachedShowPosterURL(for key: String) -> URL? {
        let prefix = "poster.\(posterHash(key))."
        let contents = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        guard let name = contents.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return root.appendingPathComponent(name)
    }

    /// Writes poster bytes for a show. Best-effort: failures leave the poster uncached.
    public func storeShowPoster(_ data: Data, for key: String) {
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("poster.\(posterHash(key)).\(safeExt(from: key))")
        try? fileManager.removeItem(at: destination)
        try? data.write(to: destination)
    }
```

Add below the private `cachePreview` method:

```swift
    private func cacheShowPoster(key: String, from remote: URL, bearerToken: String? = nil) async throws {
        var request = URLRequest(url: remote)
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.badStatus(http.statusCode)
        }
        storeShowPoster(data, for: key)
    }

    private func posterHash(_ key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    private func safeExt(from urlString: String) -> String {
        let ext = (URL(string: urlString)?.pathExtension ?? "").lowercased()
        return (1...4).contains(ext.count) && ext.allSatisfy(\.isLetter) ? ext : "jpg"
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios/PatataTubeKit && swift test 2>&1 | tail -20`
Expected: all tests PASS (existing suite + 5 new poster tests).

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift
git commit -m "feat(ios): cache show posters in CacheManager

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: EpisodesView uses cached episode thumbnails

**Files:**
- Modify: `ios/PatataTube/Sources/EpisodesView.swift:27`

**Interfaces:**
- Consumes: existing `CacheManager.cachedPreviewURL(for:)` and `AuthedImage(path:localFileURL:)`.
- Produces: nothing new.

- [ ] **Step 1: Pass cached preview into the row thumbnail**

In `ios/PatataTube/Sources/EpisodesView.swift`, change:

```swift
            AuthedImage(path: episode.previewUrl)
```

to:

```swift
            AuthedImage(path: episode.previewUrl,
                        localFileURL: model.cache.cachedPreviewURL(for: episode.id))
```

- [ ] **Step 2: Build the app**

Run: `cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add ios/PatataTube/Sources/EpisodesView.swift
git commit -m "feat(ios): show cached episode thumbs offline in EpisodesView

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: ShowsView cached posters + lazy backfill via AuthedImage callback

**Files:**
- Modify: `ios/PatataTube/Sources/AuthedImage.swift`
- Modify: `ios/PatataTube/Sources/ShowsView.swift`

**Interfaces:**
- Consumes: `CacheManager.cachedShowPosterURL(for:)`, `CacheManager.storeShowPoster(_:for:)` (Task 1), `ShowGroup.posterPath`.
- Produces: `AuthedImage.onNetworkLoad: ((Data) -> Void)?` — fired only when the image bytes came from the network (never for local-file loads).

- [ ] **Step 1: Add network-load callback to AuthedImage**

In `ios/PatataTube/Sources/AuthedImage.swift`, add a property after `var fill: Bool = true`:

```swift
    /// Called with the raw bytes when the image was fetched from the network
    /// (never for local-file loads). Lets callers persist it to a cache.
    var onNetworkLoad: ((Data) -> Void)? = nil
```

and change the network branch of `loadImage()` from:

```swift
        if let data = try? await model.api.imageData(path: path) {
            image = UIImage(data: data)
        }
```

to:

```swift
        if let data = try? await model.api.imageData(path: path) {
            image = UIImage(data: data)
            onNetworkLoad?(data)
        }
```

- [ ] **Step 2: Use cached poster + backfill in ShowsView**

Replace `ios/PatataTube/Sources/ShowsView.swift` body pieces. Add the environment object after the `onDownload` property:

```swift
    @EnvironmentObject var model: AppModel
```

Change the poster line from:

```swift
                        AuthedImage(path: show.posterPath)
```

to:

```swift
                        AuthedImage(path: show.posterPath,
                                    localFileURL: cachedPosterURL(for: show),
                                    onNetworkLoad: { data in backfillPoster(data, for: show) })
```

Add helpers at the bottom of the struct (after `body`):

```swift
    private func cachedPosterURL(for show: ShowGroup) -> URL? {
        guard let key = show.posterPath else { return nil }
        return model.cache.cachedShowPosterURL(for: key)
    }

    /// Self-heal shows downloaded before poster caching existed: when the
    /// poster arrives over the network and at least one episode is already
    /// cached, persist it so the next launch works offline.
    private func backfillPoster(_ data: Data, for show: ShowGroup) {
        guard let key = show.posterPath,
              model.cache.cachedShowPosterURL(for: key) == nil,
              show.episodes.contains(where: {
                  model.cache.state(for: $0.id, versionId: $0.chosenVersionId) == .cached
              }) else { return }
        model.cache.storeShowPoster(data, for: key)
    }
```

- [ ] **Step 3: Build the app**

Run: `cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add ios/PatataTube/Sources/AuthedImage.swift ios/PatataTube/Sources/ShowsView.swift
git commit -m "feat(ios): offline show posters in ShowsView with lazy backfill

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: VideoGridView passes show poster to the download cache

**Files:**
- Modify: `ios/PatataTube/Sources/VideoGridView.swift:238-247` (the `download(_:)` helper)

**Interfaces:**
- Consumes: `CacheManager.download(id:versionId:from:preview:showPosterKey:showPoster:bearerToken:)` (Task 1), `Video.showPreviewUrl`.
- Produces: nothing new.

- [ ] **Step 1: Resolve poster URL and pass it to cache.download**

In `ios/PatataTube/Sources/VideoGridView.swift`, in `download(_ video: Video)`, change:

```swift
        let preview: URL?
        if let p = target.previewUrl {
            preview = p.hasPrefix("http") ? URL(string: p)
                : model.credentials.baseURL?.appendingPathComponent(
                    p.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        } else { preview = nil }
        do {
            try await model.cache.download(id: target.id, versionId: target.chosenVersionId, from: url, preview: preview,
                                           bearerToken: model.credentials.token)
            return true
```

to:

```swift
        let preview = resolveImageURL(target.previewUrl)
        let posterKey = target.showPreviewUrl
        let poster = resolveImageURL(posterKey)
        do {
            try await model.cache.download(id: target.id, versionId: target.chosenVersionId, from: url, preview: preview,
                                           showPosterKey: posterKey, showPoster: poster,
                                           bearerToken: model.credentials.token)
            return true
```

and add a helper below `download(_:)`:

```swift
    /// Absolute URL for a server image path; absolute URLs pass through.
    private func resolveImageURL(_ path: String?) -> URL? {
        guard let path else { return nil }
        if path.hasPrefix("http") { return URL(string: path) }
        return model.credentials.baseURL?.appendingPathComponent(
            path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
```

- [ ] **Step 2: Build the app**

Run: `cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Run Kit tests once more (regression)**

Run: `cd ios/PatataTubeKit && swift test 2>&1 | tail -5`
Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add ios/PatataTube/Sources/VideoGridView.swift
git commit -m "feat(ios): cache show poster when downloading an episode

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Manual verification (after all tasks)

On device/simulator: download a TV episode → enable Airplane Mode → open TV tab: show poster renders; open the show: episode thumbnail renders. For a show downloaded *before* this change: view TV tab once online, then offline poster renders (backfill).
