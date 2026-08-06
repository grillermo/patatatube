# Show Episode Download-All Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an accessible show-scoped toolbar button that downloads eligible episodes sequentially in displayed order while preserving existing per-row controls and error handling.

**Architecture:** `EpisodesView` owns the toolbar state, a view-lifetime eligibility poll, and the unstructured batch task. Two small internal static helpers keep eligibility and sequential queue semantics deterministic in tests; the existing `onDownload(Video)` closure remains the only download implementation and no shared batch coordinator is introduced.

**Tech Stack:** Swift 6.0, SwiftUI, PatataTubeKit, swift-clocks 1.1.0, Swift Testing, ViewInspector 0.10.3, XcodeGen, Xcode 26.3, iOS 17.0 deployment target, iOS 26.3 simulator.

## Global Constraints

- The batch is scoped to `show.episodes`; do not use `store.videos` or the active global filter.
- Preserve `show.episodes` order, which `ShowGroup` already sorts by season and episode.
- Start only episodes whose current ID/version cache state is exactly `.notCached`; skip `.cached` and `.downloading`.
- Await each batch-started download before starting the next one.
- Continue after `onDownload` returns `false`, including individual cancellation.
- Keep `VideoGridView.download(_:)` and the supplied `onDownload(Video)` closure responsible for preparation, cache writes, cancellation classification, and user-visible errors.
- Keep the existing per-row `DownloadButton` behavior unchanged.
- The toolbar uses `arrow.down.circle`, the accessibility label `Download all episodes`, and a disabled `ProgressView` while the batch runs.
- Disable the toolbar button when no show episode is `.notCached`.
- Leaving `EpisodesView` stops only the eligibility observation task; an already-started batch continues.
- Do not add cancel-all, aggregate progress, automatic retries, parallel batch downloads, or a shared global/show coordinator.
- Deployment target remains iOS 17.0; add no dependencies and do not edit generated `PatataTube.xcodeproj` files by hand.
- Every shell command is prefixed with `rtk` per repository instructions.

## File Structure

- `ios/PatataTube/Sources/EpisodesView.swift` — add the local batch helper, toolbar state, cache-eligibility observation, toolbar control, and show-scoped sequential loop.
- `ios/PatataTube/Tests/EpisodesViewTests.swift` — cover filtering, ordering, sequential execution, failure continuation, toolbar accessibility/state, eligibility refresh, and navigation-away lifetime.
- `ios/README.md` — add manual checks for the show-scoped batch behavior.
- No changes to `VideoGridView.swift`, `ShowsView.swift`, `CacheManager.swift`, `DownloadButton.swift`, or `project.yml` are required.

---

### Task 1: Show-scoped sequential batch routine

**Files:**
- Create: `ios/PatataTube/Tests/EpisodesViewTests.swift`
- Modify: `ios/PatataTube/Sources/EpisodesView.swift:24`

**Interfaces:**
- Consumes: `[Video]`, `(Video) -> CacheState`, and `(Video) async -> Bool`.
- Produces: `EpisodesView.hasEligibleEpisode(in:currentCacheState:) -> Bool` and `EpisodesView.downloadEligibleEpisodes(_:currentCacheState:onDownload:) async`.

- [ ] **Step 1: Write the failing batch tests**

Create `ios/PatataTube/Tests/EpisodesViewTests.swift` with:

```swift
import Clocks
import PatataTubeKit
import SwiftUI
import Testing
import ViewInspector
@testable import PatataTube

private func episode(_ id: Int, season: Int, number: Int) -> Video {
    Video(
        id: id,
        url: "/episode/\(id)",
        title: "Episode \(number)",
        platform: nil,
        sourceKey: nil,
        previewUrl: nil,
        classification: "tv",
        position: id,
        status: "done",
        errorMsg: nil,
        streamPath: "/videos/\(id)/stream",
        source: "library",
        showTitle: "The Show",
        season: season,
        episode: number
    )
}

private func show(from episodes: [Video]) -> ShowGroup {
    ShowGroup.group(episodes).first!
}

private actor EpisodeDownloadProbe {
    private var activeCount = 0
    private var maximumActiveCount = 0
    private var startedIDs: [Int] = []

    func download(_ video: Video) async -> Bool {
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        startedIDs.append(video.id)
        await Task.yield()
        activeCount -= 1
        return video.id != 1
    }

    func snapshot() -> (startedIDs: [Int], maximumActiveCount: Int) {
        (startedIDs, maximumActiveCount)
    }
}

@Suite("Episode download all batch", .serialized)
@MainActor
struct EpisodesDownloadAllBatchTests {
    @Test func skipsIneligibleEpisodesRunsInOrderAndContinuesAfterFalse() async {
        let grouped = show(from: [
            episode(4, season: 2, number: 1),
            episode(3, season: 1, number: 3),
            episode(1, season: 1, number: 1),
            episode(2, season: 1, number: 2),
        ])
        let states: [Int: CacheState] = [
            1: .notCached,
            2: .cached,
            3: .downloading(0.4),
            4: .notCached,
        ]
        let probe = EpisodeDownloadProbe()

        #expect(EpisodesView.hasEligibleEpisode(
            in: grouped.episodes,
            currentCacheState: { states[$0.id] ?? .notCached }
        ))

        await EpisodesView.downloadEligibleEpisodes(
            grouped.episodes,
            currentCacheState: { states[$0.id] ?? .notCached },
            onDownload: { await probe.download($0) }
        )

        let snapshot = await probe.snapshot()
        #expect(snapshot.startedIDs == [1, 4])
        #expect(snapshot.maximumActiveCount == 1)
        #expect(!EpisodesView.hasEligibleEpisode(
            in: grouped.episodes,
            currentCacheState: { _ in .cached }
        ))
    }
}
```

- [ ] **Step 2: Run the focused test and verify the missing-helper failure**

Run from `ios/PatataTube`:

```bash
rtk xcodegen generate
rtk xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3' -only-testing:PatataTubeTests/EpisodesDownloadAllBatchTests
```

Expected: project generation succeeds, then test compilation fails because `EpisodesView` has no members named `hasEligibleEpisode` or `downloadEligibleEpisodes`.

- [ ] **Step 3: Add the minimal eligibility and sequential-runner helpers**

Insert these methods in `EpisodesView` immediately before `private func row(for:)`:

```swift
    @MainActor
    static func hasEligibleEpisode(
        in episodes: [Video],
        currentCacheState: (Video) -> CacheState
    ) -> Bool {
        episodes.contains { currentCacheState($0) == .notCached }
    }

    @MainActor
    static func downloadEligibleEpisodes(
        _ episodes: [Video],
        currentCacheState: (Video) -> CacheState,
        onDownload: (Video) async -> Bool
    ) async {
        for episode in episodes {
            guard currentCacheState(episode) == .notCached else { continue }
            _ = await onDownload(episode)
        }
    }
```

Do not call the helpers from the view yet; Task 2 wires them to the toolbar after their queue semantics are green.

- [ ] **Step 4: Run the focused test and verify it passes**

Run:

```bash
rtk xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3' -only-testing:PatataTubeTests/EpisodesDownloadAllBatchTests
```

Expected: `** TEST SUCCEEDED **`; the observed start order is `[1, 4]`, maximum batch concurrency is one, cached/downloading episodes are skipped, and the `false` result for episode 1 does not block episode 4.

- [ ] **Step 5: Commit the tested batch routine**

```bash
rtk git add ios/PatataTube/Sources/EpisodesView.swift ios/PatataTube/Tests/EpisodesViewTests.swift
rtk git commit -m "feat(ios): add sequential show episode batch"
```

---

### Task 2: Episode-list toolbar control and eligibility observation

**Files:**
- Modify: `ios/PatataTube/Tests/EpisodesViewTests.swift`
- Modify: `ios/PatataTube/Sources/EpisodesView.swift:1-104`

**Interfaces:**
- Consumes: the Task 1 helpers, `EnvironmentValues.continuousClock`, `AppModel.cache.state(for:versionId:)`, and the existing `onDownload(Video)` closure.
- Produces: a top-bar-trailing download-all button; an internal `currentCacheState` initializer seam used only by tests; a view-lifetime eligibility observer; and an unstructured sequential batch task.

- [ ] **Step 1: Append failing toolbar and lifetime tests**

Append the following to `ios/PatataTube/Tests/EpisodesViewTests.swift`:

```swift
@MainActor
private final class EpisodeCacheStateSource {
    var values: [Int: CacheState]
    private(set) var readCount = 0

    init(_ values: [Int: CacheState]) {
        self.values = values
    }

    func read(_ video: Video) -> CacheState {
        readCount += 1
        return values[video.id] ?? .notCached
    }
}

@MainActor
private final class EpisodeDownloadGate {
    private(set) var startedIDs: [Int] = []
    private var continuations: [Int: CheckedContinuation<Bool, Never>] = [:]
    private var bufferedResults: [Int: Bool] = [:]

    func wait(for video: Video) async -> Bool {
        startedIDs.append(video.id)
        if let result = bufferedResults.removeValue(forKey: video.id) {
            return result
        }
        return await withCheckedContinuation { continuation in
            continuations[video.id] = continuation
        }
    }

    func finish(_ videoID: Int, result: Bool) {
        if let continuation = continuations.removeValue(forKey: videoID) {
            continuation.resume(returning: result)
        } else {
            bufferedResults[videoID] = result
        }
    }
}

@MainActor
private func eventually(
    _ message: String,
    condition: @escaping @MainActor () -> Bool
) async {
    for _ in 0..<100 {
        if condition() { return }
        await Task.yield()
    }
    Issue.record(Comment(rawValue: message))
}

@MainActor
private func downloadAllButton<V: View>(
    in sut: V
) throws -> InspectableView<ViewType.Button> {
    try sut.inspect().find(ViewType.Button.self) { button in
        try button.accessibilityLabel().string() == "Download all episodes"
    }
}

@Suite("Episode download all view", .serialized)
@MainActor
struct EpisodesDownloadAllViewTests {
    @Test func toolbarIsAccessibleAndTracksEligibility() async throws {
        let grouped = show(from: [episode(1, season: 1, number: 1)])
        let source = EpisodeCacheStateSource([1: .notCached])
        let clock = TestClock()
        let sut = EpisodesView(
            show: grouped,
            onPlay: { _, _ in },
            onDownload: { _ in true },
            currentCacheState: { source.read($0) }
        )
        .environmentObject(AppModel())
        .environment(\.continuousClock, clock)

        ViewHosting.host(view: sut)
        defer { ViewHosting.expel() }

        await eventually("Eligibility observation never read cache state") {
            source.readCount > 0
        }
        await eventually("Eligible show never enabled download all") {
            guard let button = try? downloadAllButton(in: sut) else { return false }
            return (try? button.isDisabled()) == false
        }

        var button = try downloadAllButton(in: sut)
        #expect(try button.accessibilityLabel().string() == "Download all episodes")

        source.values[1] = .cached
        await clock.advance(by: .milliseconds(500))
        await eventually("Fully cached show never disabled download all") {
            guard let button = try? downloadAllButton(in: sut) else { return false }
            return (try? button.isDisabled()) == true
        }

        button = try downloadAllButton(in: sut)
        #expect(try button.isDisabled())
    }

    @Test func activeBatchShowsSpinnerDisablesAndRecoversAfterFalse() async throws {
        let grouped = show(from: [episode(1, season: 1, number: 1)])
        let source = EpisodeCacheStateSource([1: .notCached])
        let gate = EpisodeDownloadGate()
        let clock = TestClock()
        let sut = EpisodesView(
            show: grouped,
            onPlay: { _, _ in },
            onDownload: { await gate.wait(for: $0) },
            currentCacheState: { source.read($0) }
        )
        .environmentObject(AppModel())
        .environment(\.continuousClock, clock)

        ViewHosting.host(view: sut)
        defer { ViewHosting.expel() }

        await eventually("Eligible show never enabled download all") {
            guard let button = try? downloadAllButton(in: sut) else { return false }
            return (try? button.isDisabled()) == false
        }
        try downloadAllButton(in: sut).tap()
        await eventually("Batch never started the first episode") {
            gate.startedIDs == [1]
        }

        var button = try downloadAllButton(in: sut)
        #expect(try button.isDisabled())
        #expect((try? button.find(ViewType.ProgressView.self)) != nil)

        gate.finish(1, result: false)
        await eventually("Failed episode left the batch button disabled") {
            guard let button = try? downloadAllButton(in: sut) else { return false }
            return (try? button.isDisabled()) == false
        }

        button = try downloadAllButton(in: sut)
        #expect((try? button.find(ViewType.Image.self)) != nil)
    }

    @Test func removingEpisodeViewDoesNotCancelStartedBatch() async throws {
        let grouped = show(from: [
            episode(2, season: 1, number: 2),
            episode(1, season: 1, number: 1),
        ])
        let source = EpisodeCacheStateSource([1: .notCached, 2: .notCached])
        let gate = EpisodeDownloadGate()
        let sut = EpisodesView(
            show: grouped,
            onPlay: { _, _ in },
            onDownload: { await gate.wait(for: $0) },
            currentCacheState: { source.read($0) }
        )
        .environmentObject(AppModel())

        ViewHosting.host(view: sut)
        await eventually("Eligible show never enabled download all") {
            guard let button = try? downloadAllButton(in: sut) else { return false }
            return (try? button.isDisabled()) == false
        }
        try downloadAllButton(in: sut).tap()
        await eventually("Batch never started episode 1") {
            gate.startedIDs == [1]
        }

        ViewHosting.expel()
        gate.finish(1, result: true)
        await eventually("Leaving the view cancelled the remaining batch") {
            gate.startedIDs == [1, 2]
        }
        gate.finish(2, result: true)
    }
}
```

- [ ] **Step 2: Run the view tests and verify they fail before the toolbar exists**

Run from `ios/PatataTube`:

```bash
rtk xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3' -only-testing:PatataTubeTests/EpisodesDownloadAllViewTests
```

Expected: test compilation fails because the `EpisodesView` initializer has no `currentCacheState` argument; no toolbar implementation has been added yet.

- [ ] **Step 3: Replace `EpisodesView.swift` with the local toolbar implementation**

Replace `ios/PatataTube/Sources/EpisodesView.swift` with:

```swift
// ios/PatataTube/Sources/EpisodesView.swift
import Clocks
import SwiftUI
import PatataTubeKit

/// Episode list for one show, sectioned by season.
struct EpisodesView: View {
    let show: ShowGroup
    let onPlay: (Video, [Video]) -> Void
    let onDownload: (Video) async -> Bool
    private let cacheStateOverride: ((Video) -> CacheState)?

    @EnvironmentObject var model: AppModel
    @Environment(\.continuousClock) private var clock
    @State private var downloadingAll = false
    @State private var canDownloadAll = false

    init(
        show: ShowGroup,
        onPlay: @escaping (Video, [Video]) -> Void,
        onDownload: @escaping (Video) async -> Bool,
        currentCacheState: ((Video) -> CacheState)? = nil
    ) {
        self.show = show
        self.onPlay = onPlay
        self.onDownload = onDownload
        self.cacheStateOverride = currentCacheState
    }

    var body: some View {
        List {
            ForEach(show.seasons(), id: \.number) { season in
                Section("Season \(season.number)") {
                    ForEach(season.episodes) { episode in
                        row(for: episode)
                    }
                }
            }
        }
        .navigationTitle(show.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { @MainActor in
                        await downloadAll()
                    }
                } label: {
                    if downloadingAll {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.down.circle")
                    }
                }
                .disabled(downloadingAll || !canDownloadAll)
                .accessibilityLabel("Download all episodes")
            }
        }
        .task {
            await observeDownloadAllEligibility()
        }
    }

    @MainActor
    static func hasEligibleEpisode(
        in episodes: [Video],
        currentCacheState: (Video) -> CacheState
    ) -> Bool {
        episodes.contains { currentCacheState($0) == .notCached }
    }

    @MainActor
    static func downloadEligibleEpisodes(
        _ episodes: [Video],
        currentCacheState: (Video) -> CacheState,
        onDownload: (Video) async -> Bool
    ) async {
        for episode in episodes {
            guard currentCacheState(episode) == .notCached else { continue }
            _ = await onDownload(episode)
        }
    }

    private func currentCacheState(for episode: Video) -> CacheState {
        if let cacheStateOverride {
            return cacheStateOverride(episode)
        }
        return model.cache.state(
            for: episode.id,
            versionId: episode.chosenVersionId
        )
    }

    private func observeDownloadAllEligibility() async {
        while !Task.isCancelled {
            canDownloadAll = Self.hasEligibleEpisode(
                in: show.episodes,
                currentCacheState: currentCacheState(for:)
            )
            do {
                try await clock.sleep(for: .milliseconds(500))
            } catch {
                return
            }
        }
    }

    private func downloadAll() async {
        downloadingAll = true
        defer {
            canDownloadAll = Self.hasEligibleEpisode(
                in: show.episodes,
                currentCacheState: currentCacheState(for:)
            )
            downloadingAll = false
        }
        await Self.downloadEligibleEpisodes(
            show.episodes,
            currentCacheState: currentCacheState(for:),
            onDownload: onDownload
        )
    }

    private func row(for episode: Video) -> some View {
        HStack(spacing: 12) {
            Button {
                onPlay(episode, show.episodes)
            } label: {
                HStack(spacing: 12) {
                    AuthedImage(
                        path: episode.previewUrl,
                        localFileURL: model.cache.cachedPreviewURL(for: episode.id)
                    )
                    .frame(width: 120, height: 68)
                    .background(.secondary.opacity(0.2))
                    .cornerRadius(6)
                    .clipped()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("E\(episode.episode ?? 0) — \(episode.title ?? "Untitled")")
                            .font(.subheadline)
                        if let summary = episode.summary {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play episode")

            DownloadButton(
                identity: DownloadButtonIdentity(
                    videoID: episode.id,
                    versionID: episode.chosenVersionId,
                    audioLanguage: episode.audioLang
                ),
                currentCacheState: {
                    currentCacheState(for: episode)
                },
                onDownload: { await onDownload(episode) },
                onCancel: {
                    model.cache.cancel(
                        id: episode.id,
                        versionId: episode.chosenVersionId
                    )
                }
            )
        }
    }
}
```

The toolbar button intentionally creates an unstructured `Task`; do not move the batch into the view-bound `.task` modifier. The `.task` modifier is only the 500 ms eligibility observer, so navigating back cancels observation but not the active queue.

- [ ] **Step 4: Run all episode download-all tests**

Run:

```bash
rtk xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3' -only-testing:PatataTubeTests/EpisodesDownloadAllBatchTests -only-testing:PatataTubeTests/EpisodesDownloadAllViewTests
```

Expected: `** TEST SUCCEEDED **`; toolbar accessibility, eligibility refresh, active spinner/disabled state, false-result recovery, and navigation-away continuation all pass.

- [ ] **Step 5: Run the complete app test target for regressions**

```bash
rtk xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3' -only-testing:PatataTubeTests
```

Expected: `** TEST SUCCEEDED **`; the new episode tests and existing shared `DownloadButton` tests all pass.

- [ ] **Step 6: Commit the toolbar behavior**

```bash
rtk git add ios/PatataTube/Sources/EpisodesView.swift ios/PatataTube/Tests/EpisodesViewTests.swift
rtk git commit -m "feat(ios): add show episode download all"
```

---

### Task 3: Manual verification documentation and final gates

**Files:**
- Modify: `ios/README.md:112-120`

**Interfaces:**
- Consumes: the completed `EpisodesView` feature and the existing Plex-library manual checklist.
- Produces: reproducible manual acceptance checks and final test/build evidence.

- [ ] **Step 1: Add the show download-all checks to the Plex checklist**

Insert these bullets immediately after the existing `"tv" tab shows one card per show...` item in `ios/README.md`:

```markdown
- [ ] Open a TV show: the episode list has an accessible top-right Download all
      control; a fully cached show leaves it disabled.
- [ ] Tap Download all with cached, active, and uncached episodes: only that
      show's uncached episodes start, in season/episode order, one at a time;
      the toolbar shows a disabled spinner and each row shows live progress.
- [ ] Cancel one active episode or let one fail: the toolbar batch continues to
      the next eligible episode; navigating back also leaves the started batch
      running.
```

- [ ] **Step 2: Regenerate the project and run the complete iOS test suite**

Run from `ios/PatataTube`:

```bash
rtk xcodegen generate
rtk xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3'
```

Expected: XcodeGen completes successfully and `xcodebuild` ends with `** TEST SUCCEEDED **` for the application and every `PatataTubeTests` test.

- [ ] **Step 3: Run a clean unsigned app build gate**

```bash
rtk xcodebuild build -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

Expected: `** BUILD SUCCEEDED **` with no Swift compile or link errors.

- [ ] **Step 4: Review the final diff for scope and whitespace errors**

Run from the repository root:

```bash
rtk git diff --check
rtk git diff --stat HEAD~2
rtk git status --short
```

Expected: `git diff --check` reports no errors; only `EpisodesView.swift`, `EpisodesViewTests.swift`, and `ios/README.md` are part of the feature; the generated Xcode project is not modified.

- [ ] **Step 5: Commit the verification checklist**

```bash
rtk git add ios/README.md
rtk git commit -m "docs(ios): add show download all verification"
```

Final commit history should contain three focused commits: sequential batch semantics, toolbar integration, and verification documentation.
