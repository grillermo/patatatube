# Movie Portrait Grid Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Movies tab in the iOS app shows portrait 2:3 poster cards (like the TV shows grid); tapping a movie pushes a detail page with poster, summary, Play, Download and version picker.

**Architecture:** New `MovieCell` (a deliberate fork of `VideoCell` — per spec, do NOT parametrize `VideoCell`) rendered by `VideoGridView` when `store.filter == "movies"`. The poster area is a `NavigationLink(value: video)`; a `navigationDestination(for: Video.self)` on the grid pushes the new `MovieDetailView`. `Video` gains `Hashable` so it can be a navigation value.

**Tech Stack:** SwiftUI (iOS app in `ios/PatataTube/`), SwiftPM package `ios/PatataTubeKit/` (XCTest on macOS), XcodeGen.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-19-movie-portrait-grid-design.md`
- iOS app only — no backend / web changes.
- Portrait cards apply **only** on the "movies" filter tab. The "all" tab keeps 16:9 letterboxed `VideoCell` for movies (existing `isPoster` logic in `VideoCell` stays untouched).
- `VideoCell.swift` must not be modified.
- `docs/` is gitignored; commit plan/spec docs with `git add -f`.
- Kit tests: `cd ios/PatataTubeKit && swift test`. App compile check: `cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`.

---

### Task 1: `Video` becomes `Hashable`

`NavigationLink(value:)` / `navigationDestination(for:)` require the value type to be `Hashable`. `Video` contains `[VideoVersion]` and `[SubtitleTrack]`, so those two must also conform. All conformances are synthesized (every stored property is already `Hashable`).

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/Video.swift:1` (`VideoVersion`), `:15` (`SubtitleTrack`), `:29` (`Video`)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoHashableTests.swift` (new)

**Interfaces:**
- Consumes: existing `Video`, `VideoVersion`, `SubtitleTrack` structs.
- Produces: `Video: Hashable`, `VideoVersion: Hashable`, `SubtitleTrack: Hashable`. Tasks 2 and 4 rely on `Video` being usable as a `NavigationLink` value.

- [ ] **Step 1: Write the failing test**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoHashableTests.swift`:

```swift
import XCTest
@testable import PatataTubeKit

final class VideoHashableTests: XCTestCase {
    func testVideoIsHashable() {
        let video = Video(id: 1, url: "https://example.com", title: "A Movie",
                          platform: nil, sourceKey: nil, previewUrl: nil,
                          classification: "movies", position: nil, status: "done",
                          errorMsg: nil, streamPath: "/videos/1/stream",
                          versions: [VideoVersion(id: 1, label: "1080p", status: "done", isChosen: true)],
                          subtitleTracks: [SubtitleTrack(language: "en", name: "English", default: true, forced: false)])
        XCTAssertEqual(Set([video, video]).count, 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter VideoHashableTests`
Expected: **compile error** — `Set` requires `Video: Hashable` (something like "type 'Video' does not conform to protocol 'Hashable'").

- [ ] **Step 3: Add the conformances**

In `ios/PatataTubeKit/Sources/PatataTubeKit/Video.swift`, change the three declaration lines only:

```swift
public struct VideoVersion: Codable, Equatable, Hashable, Sendable, Identifiable {
```

```swift
public struct SubtitleTrack: Codable, Equatable, Hashable, Sendable {
```

```swift
public struct Video: Codable, Identifiable, Equatable, Hashable, Sendable {
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios/PatataTubeKit && swift test`
Expected: all tests PASS (run the full suite, not just the filter, to catch regressions).

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/Video.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoHashableTests.swift
git commit -m "feat(ios): make Video Hashable for navigation values"
```

---

### Task 2: `MovieCell` — portrait fork of `VideoCell`

Fork `VideoCell` into a movie-specific card. Differences from the parent (everything else copied verbatim):

1. No `onPlay` closure and no play icon overlay — the poster is a `NavigationLink(value: video)` that pushes the detail page.
2. Artwork aspect is `2:3` portrait with `fill: true` (Plex movie posters are natively 2:3 — no letterboxing), replacing 16:9 + the `isPoster` letterbox logic.
3. `VideoInfoView` is NOT copied — `MovieCell` reuses the one declared in `VideoCell.swift` (same module).

No automated iOS test target exists (see CLAUDE.md); verification is compiling the app target.

**Files:**
- Create: `ios/PatataTube/Sources/MovieCell.swift`
- Reference (do not modify): `ios/PatataTube/Sources/VideoCell.swift`

**Interfaces:**
- Consumes: `Video` (now `Hashable`, Task 1), `CacheState` / `VideoInfoView` / `AuthedImage` (existing).
- Produces: `struct MovieCell: View` with initializer parameters, in order: `video: Video`, `cacheState: CacheState`, `currentCacheState: @Sendable () -> CacheState`, `cachedPreviewURL: URL?` (default `nil`), `localFileURL: URL?` (default `nil`), `classifications: [String]`, `onDownload: () async -> Bool`, `onCancel: () -> Void`, `onMoveUp: () -> Void`, `onMoveDown: () -> Void`, `onClassify: (String) -> Void`, `onChooseVersion: (Int) -> Void`, `onDelete: () -> Void`. Task 4 instantiates this.

- [ ] **Step 1: Create the file**

Create `ios/PatataTube/Sources/MovieCell.swift` with exactly:

```swift
// ios/PatataTube/Sources/MovieCell.swift
import SwiftUI
import PatataTubeKit

/// Portrait 2:3 poster card for the "movies" filter tab. A deliberate fork of
/// VideoCell: the poster is a NavigationLink to MovieDetailView instead of a
/// play button, and the artwork fills a 2:3 frame (Plex movie posters are
/// natively 2:3) rather than being letterboxed into 16:9.
struct MovieCell: View {
    let video: Video
    let cacheState: CacheState
    let currentCacheState: @Sendable () -> CacheState
    /// Local file URL of the cached preview image, when the video is cached offline.
    var cachedPreviewURL: URL? = nil
    /// Local file URL of the cached MP4 (may not exist on disk yet).
    var localFileURL: URL? = nil
    let classifications: [String]
    /// Returns true only when the MP4 actually cached, so we don't paint a false checkmark.
    let onDownload: () async -> Bool
    let onCancel: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onClassify: (String) -> Void
    let onChooseVersion: (Int) -> Void
    let onDelete: () -> Void

    @State private var confirmingDelete = false
    @State private var showingInfo = false
    /// Tracks the button's live transition: idle → loading → done, layered over `cacheState`.
    @State private var downloadPhase: DownloadPhase = .idle
    /// Live download fraction (0...1), polled from the cache while downloading.
    @State private var progress: Double = 0
    @State private var observedCacheState: CacheState?

    private enum DownloadPhase { case idle, loading, done }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NavigationLink(value: video) {
                ZStack {
                    Rectangle().fill(.black)
                    Text(video.title ?? video.url)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                    if video.previewUrl != nil || cachedPreviewURL != nil {
                        // scaledToFill previews report their covering size as their
                        // frame, which can exceed the cell; sizing the ZStack from the
                        // black rectangle and clipping here keeps every cell 2:3.
                        Rectangle().fill(.clear)
                            .overlay {
                                AuthedImage(path: video.previewUrl, localFileURL: cachedPreviewURL)
                            }
                            .clipped()
                    }
                    if video.status != "done" {
                        Text(video.status).font(.caption).padding(4)
                            .background(.thinMaterial).cornerRadius(4)
                    }
                }
                .aspectRatio(2.0/3.0, contentMode: .fit)
                .clipped()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack {
                downloadButton
                Spacer()
                if video.versions.count > 1 {
                    Picker("Version", selection: Binding(
                        get: { video.chosenVersionId ?? video.versions.first?.id ?? 0 },
                        set: { onChooseVersion($0) }
                    )) {
                        ForEach(video.versions) { version in
                            Text(version.label ?? "Version \(version.id)")
                                .tag(version.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                Menu {
                    Button("Info", systemImage: "info.circle") { showingInfo = true }
                    Button("Move up") { onMoveUp() }
                    Button("Move down") { onMoveDown() }
                    Divider()
                    ForEach(classifications, id: \.self) { c in
                        Button(c) { onClassify(c) }
                    }
                    Divider()
                    Button("Delete video", role: .destructive) { confirmingDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 30))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(8)
        .background(.background.secondary)
        .cornerRadius(12)
        .confirmationDialog("Delete this video?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingInfo) {
            VideoInfoView(video: video, cacheState: effectiveState,
                          cachedPreviewURL: cachedPreviewURL, localFileURL: localFileURL)
        }
        .task(id: downloadPollKey) {
            await pollCacheState()
        }
        .onChange(of: cacheState) { _, newState in
            updateObservedCacheState(newState)
        }
        .onChange(of: video.chosenVersionId) { _, _ in
            downloadPhase = .idle
            observedCacheState = nil
            progress = 0
        }
    }

    /// Local phase wins during the live tap→download→done transition; otherwise trust the parent.
    private var effectiveState: CacheState {
        let observedState = observedCacheState ?? cacheState
        switch downloadPhase {
        case .loading:
            if case .downloading = observedState { return observedState }
            return .downloading(progress)
        case .done: return .cached
        case .idle: return observedState
        }
    }

    private var downloadPollKey: String {
        "\(video.id):\(video.chosenVersionId ?? -1)"
    }

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    @ViewBuilder private var downloadButton: some View {
        switch effectiveState {
        case .cached:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                .font(.system(size: 30))
                .frame(width: 44, height: 44)
                .transition(.scale.combined(with: .opacity))
        case .downloading:
            Button {
                onCancel()
                withAnimation {
                    downloadPhase = .idle
                    observedCacheState = .notCached
                    progress = 0
                }
            } label: {
                ZStack {
                    Circle()
                        .stroke(Color.gray.opacity(0.25), lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: clampedProgress)
                        .stroke(
                            Color.accentColor,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.15), value: clampedProgress)
                }
                .frame(width: 30, height: 30)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .notCached:
            Button {
                Task {
                    withAnimation {
                        downloadPhase = .loading
                        observedCacheState = .downloading(0)
                        progress = 0
                    }
                    let ok = await onDownload()
                    withAnimation {
                        downloadPhase = ok ? .done : .idle
                        observedCacheState = ok ? .cached : .notCached
                        progress = ok ? 1 : 0
                    }
                }
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 30))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
    }

    private func pollCacheState() async {
        while !Task.isCancelled {
            let state = currentCacheState()
            updateObservedCacheState(state)

            if case .downloading = state {
                try? await Task.sleep(for: .milliseconds(150))
            } else {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func updateObservedCacheState(_ state: CacheState) {
        observedCacheState = state
        switch state {
        case .downloading(let p):
            progress = p
        case .cached:
            progress = 1
        case .notCached:
            if downloadPhase == .idle {
                progress = 0
            }
        }
    }
}
```

- [ ] **Step 2: Compile the app target**

Run:
```bash
cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```
Expected: `** BUILD SUCCEEDED **`. (XcodeGen picks up the new file automatically from `Sources/`.)

- [ ] **Step 3: Commit**

```bash
git add ios/PatataTube/Sources/MovieCell.swift
git commit -m "feat(ios): MovieCell portrait poster card, forked from VideoCell"
```

---

### Task 3: `MovieDetailView`

Netflix/Plex-style pushed page: large poster, title, summary, Play, Download-with-progress, version picker. It reads the **live** row from `VideoStore` (the pushed `Video` is a value snapshot; a version change while pushed would otherwise show stale state) and reuses the same download-phase machinery as the cells, driving cache state straight from `model.cache` since both objects are already in the environment.

**Files:**
- Create: `ios/PatataTube/Sources/MovieDetailView.swift`

**Interfaces:**
- Consumes: `Video` (`Hashable`, Task 1), `AppModel` / `VideoStore` / `CacheState` / `AuthedImage` (existing, injected via `@EnvironmentObject` — same pattern as `ShowsView`).
- Produces: `struct MovieDetailView: View` with initializer parameters, in order: `video: Video`, `onPlay: (Video) -> Void`, `onDownload: (Video) async -> Bool`. Task 4 instantiates this inside `navigationDestination`; the closures wrap `VideoGridView`'s existing `play(_:)` / `download(_:)` so the prepare-overlay and error-banner paths are shared.

- [ ] **Step 1: Create the file**

Create `ios/PatataTube/Sources/MovieDetailView.swift` with exactly:

```swift
// ios/PatataTube/Sources/MovieDetailView.swift
import SwiftUI
import PatataTubeKit

/// Pushed detail page for a single movie: poster, summary, play/download.
/// Play and download go through VideoGridView's closures so the Preparing…
/// overlay (attached to the NavigationStack, so it covers pushed views) and
/// error banner behave exactly as they do from the grid.
struct MovieDetailView: View {
    let video: Video
    let onPlay: (Video) -> Void
    /// Returns true only when the MP4 actually cached, so we don't paint a false checkmark.
    let onDownload: (Video) async -> Bool

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: VideoStore

    /// Tracks the button's live transition: idle → loading → done, layered over the cache state.
    @State private var downloadPhase: DownloadPhase = .idle
    /// Live download fraction (0...1), polled from the cache while downloading.
    @State private var progress: Double = 0
    @State private var observedCacheState: CacheState?

    private enum DownloadPhase { case idle, loading, done }

    /// The pushed Video is a value snapshot; prefer the live store row so a
    /// version change made from this page is reflected immediately.
    private var currentVideo: Video {
        store.videos.first { $0.id == video.id } ?? video
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Spacer()
                    AuthedImage(path: currentVideo.previewUrl,
                                localFileURL: model.cache.cachedPreviewURL(for: currentVideo.id),
                                fill: false)
                        .aspectRatio(2.0/3.0, contentMode: .fit)
                        .frame(maxHeight: 420)
                        .background(.secondary.opacity(0.2))
                        .cornerRadius(12)
                    Spacer()
                }

                Text(currentVideo.title ?? currentVideo.url)
                    .font(.title2.bold())

                if currentVideo.status != "done" {
                    Text(currentVideo.status).font(.caption).padding(4)
                        .background(.thinMaterial).cornerRadius(4)
                }

                if let summary = currentVideo.summary, !summary.isEmpty {
                    Text(summary).foregroundStyle(.secondary)
                }

                HStack(spacing: 16) {
                    Button {
                        onPlay(currentVideo)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .frame(minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)

                    downloadButton

                    if currentVideo.versions.count > 1 {
                        Picker("Version", selection: Binding(
                            get: { currentVideo.chosenVersionId ?? currentVideo.versions.first?.id ?? 0 },
                            set: { versionId in Task { await store.chooseVersion(id: currentVideo.id, versionId: versionId) } }
                        )) {
                            ForEach(currentVideo.versions) { version in
                                Text(version.label ?? "Version \(version.id)")
                                    .tag(version.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    Spacer()
                }
            }
            .padding()
        }
        .navigationTitle(currentVideo.title ?? "Movie")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: downloadPollKey) {
            await pollCacheState()
        }
        .onChange(of: currentVideo.chosenVersionId) { _, _ in
            downloadPhase = .idle
            observedCacheState = nil
            progress = 0
        }
    }

    private var cacheState: CacheState {
        model.cache.state(for: currentVideo.id, versionId: currentVideo.chosenVersionId)
    }

    /// Local phase wins during the live tap→download→done transition; otherwise trust the cache.
    private var effectiveState: CacheState {
        let observedState = observedCacheState ?? cacheState
        switch downloadPhase {
        case .loading:
            if case .downloading = observedState { return observedState }
            return .downloading(progress)
        case .done: return .cached
        case .idle: return observedState
        }
    }

    private var downloadPollKey: String {
        "\(currentVideo.id):\(currentVideo.chosenVersionId ?? -1)"
    }

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    @ViewBuilder private var downloadButton: some View {
        switch effectiveState {
        case .cached:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                .font(.system(size: 30))
                .frame(width: 44, height: 44)
                .transition(.scale.combined(with: .opacity))
        case .downloading:
            Button {
                model.cache.cancel(id: currentVideo.id, versionId: currentVideo.chosenVersionId)
                withAnimation {
                    downloadPhase = .idle
                    observedCacheState = .notCached
                    progress = 0
                }
            } label: {
                ZStack {
                    Circle()
                        .stroke(Color.gray.opacity(0.25), lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: clampedProgress)
                        .stroke(
                            Color.accentColor,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.15), value: clampedProgress)
                }
                .frame(width: 30, height: 30)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .notCached:
            Button {
                Task {
                    withAnimation {
                        downloadPhase = .loading
                        observedCacheState = .downloading(0)
                        progress = 0
                    }
                    let ok = await onDownload(currentVideo)
                    withAnimation {
                        downloadPhase = ok ? .done : .idle
                        observedCacheState = ok ? .cached : .notCached
                        progress = ok ? 1 : 0
                    }
                }
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 30))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
    }

    private func pollCacheState() async {
        while !Task.isCancelled {
            let state = cacheState
            updateObservedCacheState(state)

            if case .downloading = state {
                try? await Task.sleep(for: .milliseconds(150))
            } else {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func updateObservedCacheState(_ state: CacheState) {
        observedCacheState = state
        switch state {
        case .downloading(let p):
            progress = p
        case .cached:
            progress = 1
        case .notCached:
            if downloadPhase == .idle {
                progress = 0
            }
        }
    }
}
```

- [ ] **Step 2: Compile the app target**

Run:
```bash
cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add ios/PatataTube/Sources/MovieDetailView.swift
git commit -m "feat(ios): MovieDetailView with poster, summary, play/download"
```

---

### Task 4: Wire the movies tab in `VideoGridView` + manual test checklist

Render `MovieCell` when the movies filter is active, register the navigation destination, and extend the manual test checklist in `ios/README.md`.

**Files:**
- Modify: `ios/PatataTube/Sources/VideoGridView.swift:55-84` (grid branch), `:85` area (navigation destination)
- Modify: `ios/README.md` (manual test checklist section)

**Interfaces:**
- Consumes: `MovieCell` (Task 2), `MovieDetailView` (Task 3), `Video: Hashable` (Task 1), existing `play(_:)` / `download(_:)` / `store` / `model.cache` in `VideoGridView`.
- Produces: user-visible feature; nothing downstream.

- [ ] **Step 1: Add the movies grid branch**

In `ios/PatataTube/Sources/VideoGridView.swift`, the body currently branches:

```swift
if store.filter == "tv" {
    ShowsView(videos: filteredVideos,
              onPlay: { play($0) },
              onDownload: { v in Task { await download(v) } })
} else {
```

Insert a `movies` branch between them, so the chain reads `tv` → `movies` → everything else. The `movies` branch is a copy of the existing `LazyVGrid` block using `MovieCell` (no `onPlay`):

```swift
if store.filter == "tv" {
    ShowsView(videos: filteredVideos,
              onPlay: { play($0) },
              onDownload: { v in Task { await download(v) } })
} else if store.filter == "movies" {
    LazyVGrid(columns: columns, spacing: 16) {
        ForEach(filteredVideos) { video in
            let cache = model.cache
            let videoId = video.id
            let versionId = video.chosenVersionId
            MovieCell(
                video: video,
                cacheState: cache.state(for: videoId, versionId: versionId),
                currentCacheState: { cache.state(for: videoId, versionId: versionId) },
                cachedPreviewURL: model.cache.cachedPreviewURL(for: video.id),
                localFileURL: cache.localURL(for: videoId, versionId: versionId),
                classifications: classifications,
                onDownload: { await download(video) },
                onCancel: { cache.cancel(id: videoId, versionId: versionId) },
                onMoveUp: { Task { await store.move(id: video.id, direction: "up") } },
                onMoveDown: { Task { await store.move(id: video.id, direction: "down") } },
                onClassify: { c in Task { await store.classify(id: video.id, to: c) } },
                onChooseVersion: { versionId in Task { await store.chooseVersion(id: video.id, versionId: versionId) } },
                onDelete: { Task { await store.delete(id: video.id) } }
            )
        }
    }
    .padding()
} else {
```

The existing `else` block (16:9 `VideoCell` grid) stays exactly as it is.

- [ ] **Step 2: Register the navigation destination**

Still in `VideoGridView.swift`, on the `ScrollView` — directly after its closing brace, before `.navigationTitle("PatataTube")`:

```swift
            .navigationDestination(for: Video.self) { pushed in
                MovieDetailView(video: pushed,
                                onPlay: { play($0) },
                                onDownload: { await download($0) })
            }
            .navigationTitle("PatataTube")
```

(`ShowsView`'s own `navigationDestination(for: ShowGroup.self)` is keyed on a different type; the two coexist.)

- [ ] **Step 3: Compile the app target**

Run:
```bash
cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Extend the manual test checklist**

In `ios/README.md`, find the manual test checklist and append these items (match the file's existing bullet/checkbox style):

```markdown
- Movies tab shows portrait 2:3 poster cards (no letterbox bars); other tabs unchanged.
- "all" tab still shows movies as 16:9 letterboxed VideoCells.
- Tap a movie card poster → detail page with poster, title, summary.
- Play from the detail page works for an unconverted library movie (Preparing… overlay appears over the pushed page).
- Download from the detail page and from the movie card both show the progress ring and end in a green checkmark; cancel mid-download resets to the arrow.
- Version picker on the movie card and detail page switches versions; download state resets accordingly.
- Movie card ellipsis menu still offers Info / Move / classify / Delete.
```

- [ ] **Step 5: Run the Kit tests once more (regression)**

Run: `cd ios/PatataTubeKit && swift test`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTube/Sources/VideoGridView.swift ios/README.md
git commit -m "feat(ios): movies tab renders portrait MovieCell grid with detail page"
```
