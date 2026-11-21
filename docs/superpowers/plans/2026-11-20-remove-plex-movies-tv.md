# Remove the Plex Movies/TV feature — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** PatataTube keeps only its video list (downloads and groups). Every trace of the Plex-backed Movies and TV feature goes: the iOS tabs and screens, the SSR nav links, the API endpoints, the converter job kind, and the database rows, table and columns.

**Architecture:** Two parts that ship one after the other. **Part A (iOS)** ships first. It stops the app from asking for anything Plex-shaped, and the server keeps answering the old fields in the meantime: every library field on `Video` is `decodeIfPresent`, so nothing breaks while the old backend runs. **Part B (backend, SSR, DB)** ships second. It deletes the code paths, then an idempotent `init_db` step deletes the library rows and drops the `video_versions` table and the dead `videos` columns. HLS packaging stays, because downloads use it too. Its probe helpers move out of `library.py` into a new `media_probe.py` before `library.py` is deleted.

**Tech Stack:** FastAPI + SQLite (`db.py` idempotent migration runner), Jinja2 SSR, pytest; SwiftUI app + PatataTubeKit SwiftPM package, XcodeGen.

---

## Background: why this exists

Plex Media Server was uninstalled from the macmini on 2026-11-20. Movies and TV now play on the Apple TV through Infuse, which reads `/Volumes/Media/media` over SMB. The same day, `/Volumes/Media/media/{movies,tv}` was reorganized into `Title (Year)/…` folders. So every `source_path` PatataTube stored for a library row is stale. `/api/library/scan` cannot run at all: it calls `http://localhost:32400`, and nothing listens there any more. The owner does not want the feature back in PatataTube.

Live state on the macmini before this work: 62 `movies` rows (34 live) and 494 `tv` rows (374 live), all `source='library'`. 548 cached poster files sit in `data/previews/`. Only the `dl<id>.*.jpg` ones belong to downloads; the rest are Plex posters keyed by rating key.

## Decisions (made by the plan author; change here, not mid-task)

1. **The tab bar goes away.** With only Videos left, a one-item `TabView` is pure chrome. `RootTabView` renders the Videos `VideoGridView` directly, and `AudioMiniPlayerBar` docks at the bottom edge (no `tabBarHeight` padding).
2. **`MediaTab` is deleted, not shrunk to one case.** `RestorationState.tab` goes with it. Old restoration blobs that carry `"tab"` still decode, because Codable ignores unknown keys.
3. **`Route.show` and `Route.movie` are deleted.** A restoration blob whose `path` holds one of them fails to decode. `RestorationStore.load()` already falls back to the default state on `try?` failure, so the user lands at the Videos root once. That is accepted, and pinned by a test (Task A1).
4. **`versionId` plumbing in `CacheManager` / `StreamProxy` / `PlayerState` stays in Part A.** It is about 100 call sites in the riskiest code in the app (offline cache file naming, the stream proxy). For downloads it is always `nil`. `Video.chosenVersionId` stays as a decoded field, which the server sends as absent, so it stays nil. Removing it is the optional **Task A5**, done only if the owner asks.
5. **Library rows are deleted, not tombstoned.** Their watch progress has no use without the feature. `deleted_at` only ever existed for library tombstones (downloads delete their row), so the column is dropped with the rest.
6. **The `source` column is dropped.** After the purge, every row is `'download'`, and the discriminator means nothing.
7. **HLS keeps its subtitle support** (`subtitles.py`, the sidecar/embedded discovery). It runs for downloads too, and trimming shared playback code is out of scope. Only the library-only *inputs* go: `audio_lang` and `subtitle_source_path`.
8. **`audio_lang` / `subtitle_lang` columns are dropped.** Only the library audio/subtitle pickers ever wrote them.

## File map

**Part A — iOS**

| File | Change |
|---|---|
| `ios/PatataTubeKit/Sources/PatataTubeKit/Feed.swift` | Remove `PlexKind` and `Feed.plex` |
| `ios/PatataTubeKit/Sources/PatataTubeKit/MediaTab.swift` | Delete |
| `ios/PatataTubeKit/Sources/PatataTubeKit/ShowGroup.swift` | Delete |
| `ios/PatataTubeKit/Sources/PatataTubeKit/RestorationState.swift` | Remove `Route.show`, `Route.movie`, `RestorationState.tab` |
| `ios/PatataTubeKit/Sources/PatataTubeKit/ResumeDecision.swift` | Drop the `plexKind` parameter |
| `ios/PatataTubeKit/Sources/PatataTubeKit/GroupStore.swift` | Drop the Plex branch of `remembersPosition(for:)` |
| `ios/PatataTubeKit/Sources/PatataTubeKit/VideoStore.swift` | Drop `.plex` switch arms, `refreshLibrary()`, the `isPlexItem` guard |
| `ios/PatataTubeKit/Sources/PatataTubeKit/APIClient.swift` | Drop `scanLibrary`, `ScanResult`, `chooseVersion`, `chooseAudio`, `chooseSubtitle`, `prepare` |
| `ios/PatataTubeKit/Sources/PatataTubeKit/Video.swift` | Drop Plex/library fields (keep `chosenVersionId`, see Decision 4) |
| `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift` | Comment at ~483 only (Plex thumb version) |
| `ios/PatataTubeKit/Tests/PatataTubeKitTests/{ShowGroupTests,MediaTabTests,APIClientLibraryTests}.swift` | Delete |
| other `PatataTubeKitTests/*.swift` listed in Task A1 | Drop Plex cases / arguments |
| `ios/PatataTube/Sources/RootTabView.swift` | No `TabView`; one `VideoGridView` |
| `ios/PatataTube/Sources/{ShowsView,EpisodesView,MovieDetailView,MovieCell,MovieRow}.swift` | Delete |
| `ios/PatataTube/Sources/VideoGridView.swift` | Drop `tab`/`selectedTab`/`activation`, the shows/movies grids, `.show`/`.movie` destinations, library readiness branches |
| `ios/PatataTube/Sources/{VideoCell,AudioMiniPlayerBar,SkeletonGrid,AppModel,PlaybackSource,OptionsMenu,MemoryProbe,SettingsView,DownloadButton}.swift` | Drop Plex/library branches and comments |
| `ios/PatataTube/Tests/EpisodesViewTests.swift` | Delete |
| other `ios/PatataTube/Tests/*.swift` listed in Task A2 | Drop Plex fixtures |

**Part B — backend / SSR / DB**

| File | Change |
|---|---|
| `media_probe.py` | **Create**: `probe_source`, `plan_conversion`, `ConversionPlan`, `audio_track_list`, `select_audio_indices`, `allowed_audio_langs` moved verbatim from `library.py` |
| `tests/test_media_probe.py` | **Create**: the probe/plan tests moved out of `tests/test_library.py` |
| `plex.py`, `library.py`, `version_namer.py`, `relabel_versions.py` | Delete |
| `tests/test_plex.py`, `tests/test_library.py`, `tests/test_version_namer.py` | Delete |
| `db.py` | Purge step, drop guards/functions for library columns, `video_versions` |
| `router.py` | Drop library routes and branches |
| `converter.py` | Drop the `convert` job kind and its recovery |
| `hls.py` | Import from `media_probe`; drop `audio_lang` / `subtitle_source` inputs |
| `services.py`, `sd.py`, `downloader.py`, `check_subtitles.py`, `classifier.py`, `ffmpeg_progress.py`, `subtitles.py` | Drop library branches / comments |
| `views/serializers.py`, `views/render.py`, `views/templates/_macros.html`, `views/templates/videos_page.html`, `assets/app/offline.js` | Drop Plex nav, `plex_kind`, versions |
| `CLAUDE.md`, `README.md`, `.env.example` | Docs/config |
| `~/c/server/Caddyfile` (other repo) | Two comments only |

---

# Part A — iOS (ship first)

Per `CLAUDE.md`: **never run the iOS tests unless the owner asks.** Every task below ends with a *build*. The tests that would cover it are named so the owner can run them.

### Task A1: PatataTubeKit — remove Plex types and library API

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/Feed.swift`
- Delete: `ios/PatataTubeKit/Sources/PatataTubeKit/MediaTab.swift`, `ShowGroup.swift`
- Modify: `RestorationState.swift`, `ResumeDecision.swift`, `GroupStore.swift`, `VideoStore.swift`, `APIClient.swift`, `Video.swift`, `CacheManager.swift` (comment)
- Delete tests: `Tests/PatataTubeKitTests/ShowGroupTests.swift`, `MediaTabTests.swift`, `APIClientLibraryTests.swift`
- Modify tests: `FeedTests.swift`, `ResumeDecisionTests.swift`, `GroupStoreTests.swift`, `VideoStoreTests.swift`, `VideoTests.swift`, `RestorationStoreTests.swift`, `RestorationResolverTests.swift`, `APIClientReadTests.swift`, `PlaybackQueueTests.swift`, `ResumePositionAPITests.swift`, `QueueNavigatorTests.swift`, `PlaybackPositionReporterTests.swift`, `CacheManagerTests.swift`, `CacheManagerConcurrencyGateTests.swift`, `APIClientJobsTests.swift`, `VideoHashableTests.swift`

- [ ] **Step 1: Pin the legacy-restoration fallback with a test** (add to `RestorationStoreTests.swift`)

```swift
@Test func legacyShowRouteFallsBackToDefaultState() throws {
    let defaults = UserDefaults(suiteName: "legacyShowRoute-\(UUID().uuidString)")!
    // A blob written by a build that still had the TV tab.
    let legacy = #"{"feed":null,"path":[{"show":{"title":"Bluey"}}],"search":"","scrollAnchors":{},"tab":"tv"}"#
    defaults.set(Data(legacy.utf8), forKey: RestorationStore.defaultsKey)
    let store = RestorationStore(defaults: defaults)
    #expect(store.load() == RestorationState.empty)
}

@Test func legacyTabKeyIsIgnored() throws {
    let defaults = UserDefaults(suiteName: "legacyTab-\(UUID().uuidString)")!
    let legacy = #"{"feed":{"group":{"id":3}},"path":[{"group":{"id":3}}],"search":"","scrollAnchors":{},"tab":"videos"}"#
    defaults.set(Data(legacy.utf8), forKey: RestorationStore.defaultsKey)
    let store = RestorationStore(defaults: defaults)
    #expect(store.load().path == [.group(id: 3)])
}
```

Before writing them, open `RestorationStore.swift` and use its real key constant, initializer and empty-state name in place of `defaultsKey`, `init(defaults:)` and `.empty`. Lines 19–54 hold `load()` / `loadLocked()`.

- [ ] **Step 2: `Feed.swift`, whole file after the change**

```swift
import Foundation

/// What a grid is showing.
///
/// This type is the single place that knows two spellings: the wire spelling
/// (`queryItems`) and the persistence spelling (`storageKey`). Nothing else
/// should build either by hand.
public enum Feed: Codable, Hashable, Sendable {
    case all
    case group(id: Int)

    public var queryItems: [URLQueryItem] {
        switch self {
        case .all: return []
        case .group(let id): return [URLQueryItem(name: "group_id", value: String(id))]
        }
    }

    /// Key for anything persisted per-feed: the cached list file name, the
    /// per-feed autoplay/randomize/cell-size preferences, scroll anchors.
    public var storageKey: String {
        switch self {
        case .all: return "all"
        case .group(let id): return "group:\(id)"
        }
    }

    /// `nil` for anything else, including the `plex:tv` / `plex:movies` keys
    /// older builds persisted; their cached lists are simply never read again.
    public init?(storageKey: String) {
        if storageKey == "all" {
            self = .all
        } else if storageKey.hasPrefix("group:"), let id = Int(storageKey.dropFirst(6)) {
            self = .group(id: id)
        } else {
            return nil
        }
    }
}
```

In `FeedTests.swift`, replace every Plex case with this one:

```swift
@Test func legacyPlexStorageKeyNoLongerDecodes() {
    #expect(Feed(storageKey: "plex:tv") == nil)
    #expect(Feed(storageKey: "plex:movies") == nil)
}
```

- [ ] **Step 3: `RestorationState.swift`**: the `Route` enum becomes

```swift
public enum Route: Codable, Hashable, Sendable {
    case group(id: Int)  // VideoGroup.id
    case downloads
}
```

Delete the `tab` property, its doc comment, the `tab:` init parameter, and `tab: nil` in the empty state. Update the file's header comment (line 5 mentions `ShowGroup`) to say "never a `Video`".

- [ ] **Step 4: `ResumeDecision.swift`**: the `decide` function becomes

```swift
    /// A video prompts only when the user turned "Remember position" on for its
    /// group (`GroupStore.remembersPosition`). Position is recorded for every
    /// video, so the flag is what decides whether that recorded position may
    /// interrupt the next tap.
    public static func decide(
        resumeSecs: Double,
        remembersPosition: Bool = false,
        minimumSecs: Double = ResumeDecision.defaultMinimumSecs
    ) -> ResumeDecision {
        guard remembersPosition else { return .playFromStart }
        guard resumeSecs >= minimumSecs else { return .playFromStart }
        return .ask(secs: resumeSecs)
    }
```

Also change the type's doc comment line "Plex rows and opted-in Videos rows prompt" to "Opted-in groups prompt". In `ResumeDecisionTests.swift`, delete every test whose name or body mentions `plexKind: .tv` / `.movies`. Remove the `plexKind: nil,` argument from the remaining calls.

- [ ] **Step 5: `GroupStore.swift`** (~line 81): delete `if video.plexKind != nil { return true }` and the "always for Plex items" clause of its doc comment. In `GroupStoreTests.swift`, delete the tests built on a Plex video.

- [ ] **Step 6: `APIClient.swift`**: delete, both from `protocol VideoAPI` (lines ~21–40) and from the concrete client:
  - `struct ScanResult` and `scanLibrary()`
  - `chooseVersion(id:versionId:)`, `chooseAudio(id:lang:)`, `chooseSubtitle(id:lang:)`
  - `prepare(id:bulk:)`

  Then delete their stubs from every test double. `grep -rn "func scanLibrary\|func chooseVersion\|func chooseAudio\|func chooseSubtitle\|func prepare(" ios/` lists them all. Delete `APIClientLibraryTests.swift`.

- [ ] **Step 7: `VideoStore.swift`**:
  - Line ~219 and ~286: delete both `case .plex: break` arms (the switch is now exhaustive over `.all` / `.group`).
  - Line ~306: delete `guard !previous.isPlexItem else { return }`.
  - Lines ~432–460: `refresh()` becomes the body below; delete `refreshLibrary()` and its doc comment.

```swift
    /// Pull-to-refresh. Runs in its own unstructured task because SwiftUI
    /// cancels a `.refreshable` action as soon as the view re-renders -- and
    /// `load()` re-renders it itself by flipping `isLoading`. The cancelled
    /// fetch then returned silently with the server's answer thrown away, so a
    /// pull never showed a new video while leaving the group and coming back
    /// (the same request, from a `.task`) did.
    public func refresh() async {
        await Task { await load() }.value
    }
```

  In `VideoStoreTests.swift`, delete the tests for `refreshLibrary`, the scan, and `.plex` feeds.

- [ ] **Step 8: `Video.swift`**: delete these stored properties, together with their `CodingKeys` cases, init parameters, assignments and `decodeIfPresent` lines: `plexKind`, `source`, `showTitle`, `season`, `episode`, `summary`, `showPreviewUrl`, `versions`, `subtitleTracks`, `sourceFilename`, `audioLang`, `subtitleLang`. Delete `isLibrary`, `isPlexItem`, the `RawGroupCodingKeys.plexKind` case, `withChosenVersion(_:)` (both overloads), and the `VideoVersion`, `AudioTrack` and `SubtitleTrack` types, if nothing outside the deleted views uses them (`grep -rn "VideoVersion\|AudioTrack\b\|SubtitleTrack" ios/` after Task A2 tells). **Keep `chosenVersionId`** (Decision 4).

  `VideoTests.swift`: delete the library/plex decoding tests and add

```swift
@Test func decodesALegacyLibraryPayloadWithoutTheRemovedFields() throws {
    // The old backend still sends these until Part B ships; they must be ignored.
    let json = #"{"id":7,"url":"","status":"done","plex_kind":"tv","show_title":"Bluey","season":1,"episode":2,"versions":[{"id":1,"label":null,"status":"done","is_chosen":true}],"source":"library"}"#
    let video = try JSONDecoder.patatatube.decode(Video.self, from: Data(json.utf8))
    #expect(video.id == 7)
}
```

  Use whatever decoder the existing `VideoTests` use, in place of `JSONDecoder.patatatube`.

- [ ] **Step 9: delete `MediaTab.swift`, `ShowGroup.swift`, `ShowGroupTests.swift`, `MediaTabTests.swift`**, and fix the remaining test fixtures that pass `plexKind:` / `showTitle:` / `versions:` to `Video(...)`. `grep -rln "plexKind\|showTitle\|versions:" ios/PatataTubeKit/Tests` lists them.

- [ ] **Step 10: build the package**

Run: `cd ios/PatataTubeKit && swift build`
Expected: `Build complete!`. Errors in `ios/PatataTube/` are not built here and belong to Task A2.

Covering tests (owner runs): `swift test` and `swift test -c release` in `ios/PatataTubeKit`.

- [ ] **Step 11: commit**

```bash
git add -A ios/PatataTubeKit
git commit -m "ios(kit): drop the Plex feed, tabs, show grouping and library API

Plex is gone from the macmini; movies and TV play through Infuse now.
The kit keeps decoding the old server's library fields as unknown keys,
so this ships before the backend cut."
```

### Task A2: App target — one Videos screen, no Movies/TV

**Files:**
- Modify: `ios/PatataTube/Sources/RootTabView.swift`
- Delete: `ios/PatataTube/Sources/ShowsView.swift`, `EpisodesView.swift`, `MovieDetailView.swift`, `MovieCell.swift`, `MovieRow.swift`
- Modify: `VideoGridView.swift`, `VideoCell.swift`, `AudioMiniPlayerBar.swift`, `SkeletonGrid.swift`, `AppModel.swift`, `PlaybackSource.swift`, `OptionsMenu.swift`, `MemoryProbe.swift`, `SettingsView.swift`, `DownloadButton.swift`, `PlaybackProbe.swift`
- Delete test: `ios/PatataTube/Tests/EpisodesViewTests.swift`
- Modify tests: `VideoGridViewTests.swift`, `DownloadsViewTests.swift`, `PiPSessionTests.swift`, `PlayerViewControllerTests.swift`, `AudioHandoverTests.swift`, `VideoRowAudioTests.swift`

- [ ] **Step 1: `RootTabView.swift`**: replace the `body`'s `TabView` with the single grid, and delete `selection`, `activation`, `tabBarHeight` and `selectionBinding`:

```swift
/// The app's root: the Videos grid with its own navigation stack, and the
/// audio mini player docked under it.
struct RootTabView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: VideoStore

    var body: some View {
        ZStack(alignment: .bottom) {
            VideoGridView(groups: model.groups, api: model.api)
            AudioMiniPlayerBar(audio: model.audio)
        }
        // The restore button on the PiP float re-opens the full-screen player.
        .modifier(PictureInPictureRestoreCover(pip: model.pip, audio: model.audio))
        // Covers the grid and the mini player bar alike. An open full-screen
        // player draws its own copy above this one.
        .overlay {
            if model.sleepScreenShown {
                SleepScreen { model.sleepScreenShown = false }
            }
        }
    }
    // PictureInPictureRestoreCover stays exactly as it is.
}
```

  The `onAppear` (restore `tab`) and `onChange(of: selection)` (switch feed) blocks go away entirely: the Videos tab never had a feed of its own, so the grid's own restoration already does the work.

- [ ] **Step 2: `VideoGridView.swift`: tab plumbing.** Delete the `tab`, `selectedTab` and `activation` properties (lines ~27–29, ~149–163), the matching init parameters, and their pass-through at ~126–137 and ~335–336. The new init is `init(groups: GroupStore, api: APIClient)`. Then resolve each former guard:
  - `guard selectedTab == tab else { return }` (~44, 52, 59, 87, 100, 925): delete the line. There is only one stack now, so no write can come from an inactive tab.
  - `.onChange(of: activation)` (~62–77) and `.onChange(of: selectedTab)` (~78–86): delete both blocks.
  - `$0.tab = tab` (~54, 71): delete.
  - `if tab == .videos` / `guard tab == .videos` (~347, 428, 784, 837, 882, 894): keep the body and drop the condition.
  - Initial load (~768–790): delete the `restoredTab` read and its "other tab" early return. Keep the group-restoration path. Delete the `else if let feed = tab.feed` branch.

- [ ] **Step 3: `VideoGridView.swift`: Movies/TV content.**
  - The `switch tab` at ~454–470 collapses to the Videos grid body that was its `.videos` arm. Delete the `.tv` (`ShowsView`) and `.movies` (`moviesGrid`) arms.
  - Delete `moviesGrid` (~495 to its closing brace).
  - `SkeletonGrid(...)` at ~449–451: drop the `&& tab != .videos` condition's TV/Movies purpose. Read the surrounding lines and keep the skeleton only where the Videos grid used it before. Drop `showsTextBars:` (Step 6 removes the parameter).
  - `destination(for:)` (~651–700): delete the `.show` and `.movie` cases (`EpisodesView`, `MovieDetailView`).
  - ~864–866: delete the `if store.feed == .plex(.tv)` branch of the visible-ids computation.
  - Search filter (~306, ~309): delete the `showTitle` and `versions` label matches.
  - ~282–284 (`withChosenVersion`): the `PlayerState` restore returns `stored` unchanged. Read the function and drop the `versionID` re-application.
  - Resume (~1068): `ResumeDecision.decide(resumeSecs: secs, remembersPosition: …)`. Delete the `plexKind:` argument. Update the comment at ~1061 ("tv/movies rows, and Videos rows that remember") to "Videos rows that remember".
  - Library readiness (~950, ~1006, ~1107, and the `prepare` calls they guard): every `video.isLibrary && video.status != "done"` branch is unreachable for downloads. Delete the branch and keep the download path. With `prepare` gone from the API (Task A1), any call left is a compile error that points at what to delete.
  - `pendingAutoDownloads` / `PendingAutoDownloadStore` (~193): it exists for "conversions this device asked for". Check with `grep -rn PendingAutoDownload ios/`. If its only writer was the library prepare path, delete the store, its file and its tests too.

- [ ] **Step 4: delete `ShowsView.swift`, `EpisodesView.swift`, `MovieDetailView.swift`, `MovieCell.swift`, `MovieRow.swift`** and `Tests/EpisodesViewTests.swift`. Then regenerate the project so they leave `project.pbxproj`:

Run: `cd ios/PatataTube && xcodegen generate`
Expected: `Created project at …/PatataTube.xcodeproj`

- [ ] **Step 5: `VideoCell.swift`**:
  - `isPlexItem` letterboxing (~35–37, ~54): always the 16:9 fill path.
  - Version picker (~119–132): delete.
  - `if !video.isPlexItem` around "Send to Yoto" (~134): keep the body, drop the condition. Update the `onSendToYoto` doc comment (~29).
  - Info sheet (~214, ~225, ~228–235): delete the "Show title", "Chosen version" and "Versions" rows/section.

- [ ] **Step 6: small call sites.**
  - `AudioMiniPlayerBar.swift:135`: `AuthedImage(path: video.previewUrl, fill: true)`.
  - `SkeletonGrid.swift`: delete the `showsTextBars` parameter and the 2:3 poster branch. Update the header comment to "every cell uses a 16:9 frame".
  - `AppModel.swift:56, 77`: comments drop the `"plex:tv"` / movies examples. `:227–233`: delete `guard video.plexKind == nil else { return }` and the "Plex items have no badge" line.
  - `PlaybackSource.swift:43`: delete the `"is_library"` DevLog meta entry. `:67`: drop the `!(video.isLibrary && video.status != "done")` clause. `:85–92`: delete the "library not converted" branch.
  - `OptionsMenu.swift:47, 85, 208` and `MemoryProbe.swift:11`, `DownloadButton.swift:288`: comment-only edits removing TV/Movies/EpisodesView/library wording.
  - `SettingsView.swift:97` and `PlaybackProbe.swift:33`: these read `video.chosenVersionId`, which stays (Decision 4). No change.

- [ ] **Step 7: fix the app test fixtures.** `grep -rn "plexKind\|showTitle\|MediaTab\|\.tv\b\|\.movies\b\|tab:" ios/PatataTube/Tests` lists every fixture to edit: drop the arguments, and delete tests that only exercised TV/Movies.

- [ ] **Step 8: build the app**

Run: `cd ios/PatataTube && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

Also build the test target, which silently rots otherwise (CLAUDE.md):
Run: `xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,id=08D1BCF0-862E-44C7-9A2B-3EF107A4FB69' build-for-testing 2>&1 | tail -3`
Expected: `** TEST BUILD SUCCEEDED **`

Covering tests (owner runs): the `PatataTubeTests` target via `xcodebuild … test` with that udid.

- [ ] **Step 9: commit**

```bash
git add -A ios/PatataTube
git commit -m "ios: one Videos screen; drop the TV and Movies tabs and their views

Movies and TV moved to Infuse on the Apple TV. With one tab left the
tab bar was pure chrome, so the Videos grid is the root now."
```

### Task A3: Ship the iOS build

- [ ] **Step 1:** Ask the owner whether to run the iOS tests now (CLAUDE.md forbids starting them unasked).
- [ ] **Step 2:** Ship it with the `deploy-ios` skill once A1–A2 are committed on the release branch. `CLAUDE.local.md` is the owner's standing go-ahead, so don't ask. Deploy once, here, not after each task.
- [ ] **Step 3:** After install, check on the device: the app opens on the Videos grid, with no tab bar. A group opens, a video plays, the mini player docks at the bottom, and pull-to-refresh works.

### Task A5 (optional, only if asked): remove the `versionId` plumbing

Out of scope by Decision 4. It covers `Video.chosenVersionId`, every `versionId:` / `versionID:` parameter in `CacheManager` (63 uses), `StreamProxy` (36), `PlayerState.versionID`, and the `_v<id>` suffix in `offlineHLSDir`. Write a separate plan if wanted. Cached files written with a nil version id already have no suffix, so no on-disk migration is needed.

---

# Part B — backend, SSR, DB (after Part A is installed)

Run backend tests from the repo root with `MEDIA_ROOT=.` (CLAUDE.md: an external `MEDIA_ROOT` masks failures):

```bash
MEDIA_ROOT=. python -m pytest tests/ -q
```

Record the baseline failure count **before** Task B1, so later runs compare against it.

### Task B1: Move the shared probe helpers into `media_probe.py`

HLS (used by downloads) imports `audio_track_list`, `plan_conversion`, `probe_source` and `select_audio_indices` from `library`, so they need a home before `library.py` goes.

**Files:**
- Create: `media_probe.py`
- Create: `tests/test_media_probe.py`
- Modify: `hls.py:21`

- [ ] **Step 1: write the failing import test**: `tests/test_media_probe.py`

```python
import media_probe


def _probe(vcodec="h264", width=1920, container="mov,mp4,m4a,3gp,3g2,mj2", audio=(("aac", "eng"),)):
    streams = [{"codec_type": "video", "codec_name": vcodec, "width": width}]
    for codec, lang in audio:
        streams.append({"codec_type": "audio", "codec_name": codec, "tags": {"language": lang}})
    return {"streams": streams, "format": {"format_name": container}}


def test_compatible_mp4_is_passthrough():
    plan = media_probe.plan_conversion(_probe())
    assert plan.passthrough is True
    assert plan.audio_langs == ["eng"]


def test_mkv_with_dts_reencodes_audio_and_copies_video():
    plan = media_probe.plan_conversion(_probe(container="matroska,webm", audio=(("dts", "spa"),)))
    assert plan.passthrough is False
    assert plan.video_args[:2] == ["-c:v", "copy"]
    assert plan.audio_args == ["-c:a:0", "aac", "-b:a:0", "128k", "-ac:a:0", "2"]


def test_select_audio_falls_back_to_first_stream(monkeypatch):
    monkeypatch.setenv("LIBRARY_AUDIO_LANGS", "eng,spa")
    assert media_probe.select_audio_indices(_probe(audio=(("aac", "jpn"),)), ["eng"]) == [0]


def test_audio_track_list_defaults_to_und():
    probe = {"streams": [{"codec_type": "audio", "codec_name": "aac"}]}
    assert media_probe.audio_track_list(probe) == [{"lang": "und", "title": ""}]
```

Then move into this file every test from `tests/test_library.py` that calls `plan_conversion`, `select_audio_indices`, `audio_track_list` or `allowed_audio_langs`, with `library.` → `media_probe.`.

- [ ] **Step 2: run it, expect failure**

Run: `MEDIA_ROOT=. python -m pytest tests/test_media_probe.py -q`
Expected: `ModuleNotFoundError: No module named 'media_probe'`

- [ ] **Step 3: create `media_probe.py`.** Its docstring is `"""ffprobe → iPad-compatible conversion plan, shared by HLS packaging."""`. Move **verbatim** from `library.py` lines 1–163: the imports it needs (`os`, `dataclass`, `field`, `Path`, `from downloader import _probe_media`), `IPAD_MAX_WIDTH`, `_COMPAT_VIDEO`, `_COMPAT_AUDIO`, `_REENCODE_VIDEO_ARGS`, `_SCALE_ARGS`, `ConversionPlan`, `_first_stream`, `allowed_audio_langs`, `_audio_streams`, `audio_track_list`, `select_audio_indices`, `plan_conversion`, `probe_source`. Leave `conversion_target`, `temp_target_for` and `FFMPEG_BIN` behind (library-only). Keep the `LIBRARY_AUDIO_LANGS` env name: HLS reads it through `plan_conversion` for downloads too, and renaming it is churn.

- [ ] **Step 4: `hls.py:21`** becomes

```python
from media_probe import audio_track_list, plan_conversion, probe_source, select_audio_indices
```

  and its module docstring line 4 says ``media_probe.plan_conversion`` instead of ``library.plan_conversion``.

- [ ] **Step 5: run, expect pass**

Run: `MEDIA_ROOT=. python -m pytest tests/test_media_probe.py tests/test_hls.py -q`
Expected: all pass.

- [ ] **Step 6: commit**

```bash
git add media_probe.py tests/test_media_probe.py tests/test_library.py hls.py
git commit -m "Move ffprobe planning helpers out of library.py

HLS packaging for downloads uses them; library.py is about to go."
```

### Task B2: Delete the library modules, the convert job kind and the library routes

**Files:**
- Delete: `plex.py`, `library.py`, `version_namer.py`, `relabel_versions.py`, `tests/test_plex.py`, `tests/test_library.py`, `tests/test_version_namer.py`
- Modify: `converter.py`, `router.py`, `services.py`, `sd.py`, `downloader.py`, `check_subtitles.py`, `hls.py`, `classifier.py`, `ffmpeg_progress.py`, `views/serializers.py`
- Modify tests: `tests/test_api.py`, `tests/test_converter.py`, `tests/test_jobs.py`, `tests/test_hls.py`, `tests/test_services.py`, `tests/test_serializers.py`, `tests/test_sd.py`, `tests/test_groups.py`, `tests/test_downloader.py`

- [ ] **Step 1: write the failing tests**: add to `tests/test_api.py`, using the module's existing `client` / auth-header fixtures:

```python
@pytest.mark.parametrize("method,path", [
    ("post", "/api/library/scan"),
    ("post", "/api/videos/1/version"),
    ("post", "/api/videos/1/audio"),
    ("post", "/api/videos/1/subtitle"),
    ("post", "/api/videos/1/prepare"),
    ("post", "/videos/1/version"),
])
def test_library_endpoints_are_gone(client, auth_headers, method, path):
    response = getattr(client, method)(path, headers=auth_headers, json={})
    assert response.status_code in (404, 405)


def test_group_named_tv_is_allowed_now(client, auth_headers):
    response = client.post("/api/groups", headers=auth_headers,
                           json={"name": "tv", "label": "TV"})
    assert response.status_code == 201
```

and to `tests/test_serializers.py`:

```python
def test_serialized_video_has_no_library_fields():
    data = serialize_video({"id": 1, "url": "https://x/y", "status": "done", "play_count": 0})
    for key in ("plex_kind", "source", "show_title", "season", "episode", "summary",
                "show_preview_url", "subtitle_tracks", "versions", "chosen_version_id",
                "audio_lang", "subtitle_lang", "source_filename"):
        assert key not in data
    assert data["unwatched"] is True
    assert data["hls_path"] == "/videos/1/hls/master.m3u8"
```

- [ ] **Step 2: run, expect failure**

Run: `MEDIA_ROOT=. python -m pytest tests/test_api.py -k "library_endpoints_are_gone or tv_is_allowed" tests/test_serializers.py -q`
Expected: FAIL. The routes still answer, `tv` is rejected with 400, and `plex_kind` is still in the payload.

- [ ] **Step 3: `converter.py`**: delete `import library`, `_handle_convert`, the `"convert"` entry of `JOB_HANDLERS`, the `if job["kind"] == "convert"` branch of `cleanup_orphan` (the `elif` after it becomes `if`), and the two lines in `recover_orphans` that call `db.recover_exhausted_convert_versions()` / `db.recover_jobless_converting_versions()` (keep `sweep_exhausted_jobs`). In `_handle_hls` drop `subtitle_source=payload.get("subtitle_source_path"),`. Update the `_handle_normalize` comment "a normalize job is rare compared to convert" to "…compared to hls".

- [ ] **Step 4: `hls.py`**: in `prepare` and `build_hls_package`, drop the `audio_lang` and `subtitle_source` parameters and their uses. `prepare` no longer reads `video.get("audio_lang")`. `_discover_for_package(source, probe, subtitle_source)` becomes `_discover_for_package(source, probe)`, searching only `source`. Delete the docstring paragraph at ~222 about `library.convert_library_video` passing `-sn`. Update `tests/test_hls.py` call sites to match.

- [ ] **Step 5: `router.py`**:
  - Delete `import plex`, `import library`.
  - Delete these handlers whole: `POST /videos/{video_id}/version` (~966), `POST /api/videos/{video_id}/version` (~1103), `/audio` (~1110), `/subtitle` (~1147), `POST /api/library/scan` (~1279), `POST /api/videos/{video_id}/prepare` (~1328) and its `PrepareRequest` model (~217, which holds `audio_lang`).
  - `video_preview` (~637): delete the library half (`kind` param, rating-key cache) and `_build_preview` (~605). The handler becomes:

```python
@router.get("/videos/{video_id}/preview")
async def video_preview(video_id: int, request: Request):
    _check_token_or_query(request)
    video = db.get_video(video_id)
    if not video:
        raise HTTPException(status_code=404, detail="No preview")
    return await _download_preview(video)
```

  - `stream_video` (~733): delete the `if video.get("source") == "library":` branch. Keep the `else` body, dedented.
  - `stream_sd_video` (~765): `if not video or not video.get("sd_ready"):`.
  - `_resolve_hls_source` (~781): keep only the download half. Delete `_resolve_subtitle_source` (~802). In `hls_asset` the payload is just `{"source_path": str(source)}`.
  - Every `if not video or video.get("deleted_at"):` becomes `if not video:` (the column is gone after Task B3; `grep -n deleted_at router.py`).
  - `api_create_group` (~1009): delete the `PLEX_KINDS` check.
  - `api_videos` (~1088) becomes:

```python
@router.get("/api/videos")
async def api_videos(group_id: int | None = None):
    return [serialize_video(v) for v in db.get_all_videos(group_id=group_id)]
```

  - `/api/video/{id}/delete` (~1229–1253): delete the library guard and the `converted_path` unlinks.
  - `GET /` / `/videos` (~1467–1487): drop the `plex_kind` query param, and call `build_videos_page(videos, db.list_groups(), group_id)`.
  - `/yoto` (~1229): drop the `or video.get("plex_kind")` clause.

- [ ] **Step 6: `services.py`**: delete `choose_version`. In `set_group`, the guard becomes `if db.get_group(group_id) is None or not video:`. Delete `import hls` if nothing else in the file uses it.

- [ ] **Step 7: `sd.py:71` and `:160`**: drop the `video.get("source") == "library"` clauses.

- [ ] **Step 8: `downloader.py:519`**: `if db.get_group_by_name(name) is None:`.

- [ ] **Step 9: `check_subtitles.py`**: delete the `version` argument and the library branches (lines ~105–117, ~135, ~149). The tool only inspects downloads: stream source is `VIDEOS_DIR / video["filename"]`, and subtitle source is the same file. Drop `video.get("deleted_at")` (~133).

- [ ] **Step 10: comments.** `classifier.py:93` drops "Same reason plex.py passes it on every call.", and `ffmpeg_progress.py:4` names only `hls.build_hls_package`.

- [ ] **Step 11: `views/serializers.py`**: delete `from library import allowed_audio_langs`, `_audio_tracks`, `_subtitle_tracks`, and the library halves of `_hls_ready` / `preview_url_for`. `serialize_video` becomes:

```python
def _hls_ready(video: dict) -> bool:
    """Whether an HLS package can be served for this row. Pure check — never
    touches the filesystem, because this runs once per row in the list endpoint."""
    return video.get("status") == "done"


def preview_url_for(video: dict) -> str | None:
    """Where to fetch this row's poster/thumbnail image from.

    YouTube rows carry an external thumbnail URL straight in the column.
    Twitter and file-upload rows have none, so the preview endpoint grabs a
    frame out of the downloaded mp4.
    """
    external = video.get("preview_url")
    if external:
        return external
    if video.get("status") == "done":
        return f"/videos/{video['id']}/preview"
    return None


def serialize_video(video: dict) -> dict:
    data = {
        "id": video["id"],
        "url": video["url"],
        "title": video.get("title"),
        "platform": video.get("platform"),
        "source_key": video.get("source_key"),
        # The YouTube channel, when known. The clients search on it; the same
        # string is also written into the mp4's `artist` tag at download time.
        "channel": video.get("channel"),
        "preview_url": preview_url_for(video),
        "group_id": video.get("group_id"),
        "position": video.get("position"),
        "resume_secs": video.get("resume_secs") or 0,
        "status": video["status"],
        # Announced and never played -- the same rule the group badge counts
        # (db._UNPLAYED_WHERE), so the dots in a group add up to its badge.
        "unwatched": video.get("play_count") == 0 and video["status"] == "done",
        "error_msg": video.get("error_msg"),
        "stream_path": f"/videos/{video['id']}/stream",
    }
    if _hls_ready(video):
        data["hls_path"] = f"/videos/{video['id']}/hls/master.m3u8"
    if video.get("platform") == "upload":
        # `url` temporarily holds the local upload path until the background
        # processor moves it into videos/{id}.mp4 — never expose it.
        data["url"] = ""
    return data
```

  The `import json` at the top goes if unused.

- [ ] **Step 12: delete the modules and their tests**

```bash
git rm plex.py library.py version_namer.py relabel_versions.py tests/test_plex.py tests/test_library.py tests/test_version_namer.py
```

- [ ] **Step 13: fix the remaining tests.** `grep -n -E "plex|library|version_id|chosen_version|show_title|PLEX_KINDS|convert" tests/*.py` lists the fixtures and cases. Delete tests that only exercised library behavior (e.g. `test_converter.py`'s convert-kind tests, `test_jobs.py`'s convert recovery, `test_groups.py`'s "tv is reserved"), and drop `source="library"` / `plex_kind` from shared fixtures.

- [ ] **Step 14: run the new tests, expect pass**

Run: `MEDIA_ROOT=. python -m pytest tests/test_api.py -k "library_endpoints_are_gone or tv_is_allowed" tests/test_serializers.py -q`
Expected: PASS. (`db.py` still has the library functions; Task B3 removes them. Nothing calls them now.)

- [ ] **Step 15: run the whole suite.** Expect the baseline count, or fewer failures.

Run: `MEDIA_ROOT=. python -m pytest tests/ -q`

- [ ] **Step 16: commit**

```bash
git add -A
git commit -m "Remove the Plex library feature from the backend

Drops plex.py, library.py, the convert job kind and the version, audio,
subtitle, prepare and library-scan endpoints. Plex is uninstalled from
the macmini; movies and TV play in Infuse now."
```

### Task B3: DB — purge library rows, drop the table and columns

**Files:**
- Modify: `db.py`
- Modify: `tests/test_db.py`

- [ ] **Step 1: write the failing migration test** (`tests/test_db.py`; reuse its temp-DB fixture, which sets `DB_PATH`):

```python
import sqlite3

import db

LIBRARY_COLUMNS = {
    "source", "source_path", "converted_path", "show_title", "season", "episode",
    "summary", "plex_rating_key", "show_rating_key", "deleted_at", "chosen_version_id",
    "audio_lang", "subtitle_lang", "preview_version", "show_preview_version", "plex_kind",
}


def _legacy_db(path):
    """A database as the pre-removal code left it: one download, one library row."""
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        CREATE TABLE videos (
            id INTEGER PRIMARY KEY AUTOINCREMENT, url TEXT NOT NULL, platform TEXT,
            source_key TEXT, title TEXT, filename TEXT, status TEXT NOT NULL DEFAULT 'queued',
            error_msg TEXT, created_at TEXT NOT NULL, source TEXT NOT NULL DEFAULT 'download',
            source_path TEXT, converted_path TEXT, plex_kind TEXT, deleted_at TEXT,
            plex_rating_key TEXT, resume_secs REAL NOT NULL DEFAULT 0
        );
        CREATE UNIQUE INDEX idx_videos_source_path ON videos(source_path);
        CREATE TABLE video_versions (id INTEGER PRIMARY KEY, video_id INTEGER NOT NULL,
            source_path TEXT NOT NULL);
        CREATE TABLE jobs (id INTEGER PRIMARY KEY, kind TEXT NOT NULL, video_id INTEGER NOT NULL,
            version_id INTEGER NOT NULL DEFAULT 0, payload TEXT, result TEXT,
            priority INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT 'queued',
            attempts INTEGER NOT NULL DEFAULT 0, error_msg TEXT, created_at TEXT NOT NULL,
            started_at TEXT, finished_at TEXT);
        INSERT INTO videos (id, url, status, created_at, resume_secs)
            VALUES (1, 'https://youtu.be/x', 'done', '2026-01-01', 42);
        INSERT INTO videos (id, url, status, created_at, source, source_path, plex_kind)
            VALUES (2, '/Volumes/Media/media/movies/a.mkv', 'done', '2026-01-01',
                    'library', '/Volumes/Media/media/movies/a.mkv', 'movies');
        INSERT INTO video_versions (video_id, source_path) VALUES (2, '/Volumes/Media/media/movies/a.mkv');
        INSERT INTO jobs (kind, video_id, created_at) VALUES ('convert', 2, '2026-01-01');
        INSERT INTO jobs (kind, video_id, created_at) VALUES ('hls', 1, '2026-01-01');
        """
    )
    conn.commit()
    conn.close()


def test_init_db_purges_the_library(tmp_path, monkeypatch):
    path = tmp_path / "legacy.sqlite"
    _legacy_db(path)
    monkeypatch.setenv("DB_PATH", str(path))

    db.init_db()
    db.init_db()  # idempotent

    conn = sqlite3.connect(path)
    columns = {r[1] for r in conn.execute("PRAGMA table_info(videos)")}
    tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    rows = conn.execute("SELECT id, resume_secs FROM videos").fetchall()
    jobs = conn.execute("SELECT kind, video_id FROM jobs").fetchall()
    conn.close()

    assert columns.isdisjoint(LIBRARY_COLUMNS)
    assert "video_versions" not in tables
    assert rows == [(1, 42)]
    assert jobs == [("hls", 1)]


def test_fresh_db_never_creates_library_columns(tmp_path, monkeypatch):
    path = tmp_path / "fresh.sqlite"
    monkeypatch.setenv("DB_PATH", str(path))
    db.init_db()
    conn = sqlite3.connect(path)
    columns = {r[1] for r in conn.execute("PRAGMA table_info(videos)")}
    conn.close()
    assert columns.isdisjoint(LIBRARY_COLUMNS)
```

- [ ] **Step 2: run, expect failure**

Run: `MEDIA_ROOT=. python -m pytest tests/test_db.py -k "purges_the_library or never_creates_library" -q`
Expected: FAIL. The columns and `video_versions` still exist.

- [ ] **Step 3: add the purge step** to `db.py`, next to `_delete_error_videos`:

```python
_LIBRARY_COLUMNS = (
    "source_path", "converted_path", "show_title", "season", "episode", "summary",
    "plex_rating_key", "show_rating_key", "deleted_at", "chosen_version_id",
    "audio_lang", "subtitle_lang", "preview_version", "show_preview_version",
    "plex_kind", "source",
)


def _purge_library(conn: sqlite3.Connection) -> int:
    """Remove the Plex Movies/TV feature's data. Idempotent: a database that
    never had it, or already lost it, passes straight through.

    Plex was uninstalled from the macmini on 2026-11-20 and the feature with
    it, so its rows, its job kind, its version table and every column only it
    wrote go. Downloads keep their resume position and play count.
    """
    columns = {row["name"] for row in conn.execute("PRAGMA table_info(videos)").fetchall()}
    removed = 0
    if "source" in columns:
        library_ids = [
            row["id"]
            for row in conn.execute("SELECT id FROM videos WHERE source = 'library'").fetchall()
        ]
        if library_ids:
            placeholders = ",".join("?" for _ in library_ids)
            conn.execute(f"DELETE FROM jobs WHERE video_id IN ({placeholders})", library_ids)
            removed = conn.execute(
                f"DELETE FROM videos WHERE id IN ({placeholders})", library_ids
            ).rowcount
    conn.execute("DELETE FROM jobs WHERE kind = 'convert'")
    conn.execute("DROP TABLE IF EXISTS video_versions")
    # DROP COLUMN refuses a column an index still covers.
    conn.execute("DROP INDEX IF EXISTS idx_videos_source_path")
    for column in _LIBRARY_COLUMNS:
        if column in columns:
            conn.execute(f"ALTER TABLE videos DROP COLUMN {column}")
    conn.commit()
    return removed
```

- [ ] **Step 4: rewire `init_db`**:
  - Delete the `ALTER TABLE … ADD COLUMN` guards for every name in `_LIBRARY_COLUMNS` (lines ~134–176 and ~182–183), together with their comments. Keep `platform`, `source_key`, `title`, `preview_url`, `position`, `hls_status`, `resume_secs`, `group_id`, `channel`, `play_count`, `sd_ready`.
  - Delete the `CREATE TABLE IF NOT EXISTS video_versions` script (~215–230), the `version_columns` block (~318–331) and the `CREATE UNIQUE INDEX … idx_videos_source_path` call (~332–334).
  - Delete the "A video is either in a group or is a Plex item" comment (~177–179). `group_id`'s guard stays.
  - Fix the `remember_position` comment (~292): "Plex rows prompt unconditionally; a group video only when its group has this on" becomes "A group video prompts only when its group has this on".
  - Replace the backfill calls at the end with:

```python
        _purge_library(conn)
        _backfill_youtube_preview_urls(conn)
        _backfill_positions(conn)
        _delete_error_videos(conn)
        _run_one_shot_backfills(conn)
```

  - `_run_one_shot_backfills`: its only body (`UPDATE video_versions SET subtitle_langs = NULL`, v1–v3) targets a dropped table. Keep the function and `SCHEMA_VERSION = 3`, drop the `if applied < 3:` block, and replace the v1–v3 comment with: `# v1–v3 cleared video_versions.subtitle_langs; that table is gone (see _purge_library). Add the next one-shot here as "if applied < 4:".`
  - `_purge_library` must run **before** `_backfill_youtube_preview_urls`, `_backfill_positions` and `_delete_error_videos`. Read those three and drop any `source = 'download'` / `deleted_at` condition they carry.

- [ ] **Step 5: delete the dead functions.** `_backfill_library_added_at`, `_backfill_video_versions`, `_video_with_versions`, `_get_video_versions`, `get_video_versions`, `get_version_labels`, `get_video_version`, `_sync_video_from_chosen`, `_ensure_chosen_version`, `set_chosen_version`, `set_audio_lang`, `set_subtitle_lang`, `set_version_audio_langs`, `set_version_subtitle_langs`, `_attach_versions`, `set_video_plex_kind`, `_incoming_versions`, `_sync_versions`, `upsert_library_video`, `tombstone_video`, `clear_missing_conversion`, `tombstone_missing_library_videos`, `get_converted_paths`, `set_library_state`, `recover_exhausted_convert_versions`, `recover_jobless_converting_versions`, and the `PLEX_KINDS` constant with its comment (lines 9–11).

  Then:
  - `get_video` (~993): return `dict(row) if row else None` (no `_video_with_versions`).
  - `get_all_videos` becomes:

```python
def get_all_videos(group_id: int | None = None) -> list[dict]:
    sql = "SELECT * FROM videos"
    params: list = []
    if group_id is not None:
        sql += " WHERE group_id = ?"
        params.append(group_id)
    sql += " ORDER BY position DESC, created_at DESC"
    with _conn() as conn:
        return [dict(r) for r in conn.execute(sql, params).fetchall()]
```

  - `_UNPLAYED_WHERE` (~831): `"play_count = 0 AND status = 'done'"`.
  - `sd_candidate_ids` / `sd_pending_ids` (~1007) and `videos_missing_channel` (~1183): drop `AND deleted_at IS NULL`.
  - `set_video_group` (~1130): drop any `plex_kind` clearing in its UPDATE (`set_video_plex_kind` is gone).
  - `enqueue_job` keeps its `version_id` parameter and the `jobs.version_id` column. The unique index `idx_jobs_pending` is keyed on it, and every remaining caller passes the default 0. Leave both.

- [ ] **Step 6: run, expect pass**

Run: `MEDIA_ROOT=. python -m pytest tests/test_db.py -q`
Expected: PASS. Then fix the `test_db.py` cases that exercised the deleted functions by deleting them (`grep -n -E "version|library|plex|tombstone|deleted_at" tests/test_db.py`).

- [ ] **Step 7: full suite**

Run: `MEDIA_ROOT=. python -m pytest tests/ -q`
Expected: the baseline count, or fewer failures.

- [ ] **Step 8: commit**

```bash
git add db.py tests/test_db.py
git commit -m "db: purge the Plex library rows, video_versions and library columns

Idempotent init_db step; downloads keep resume position and play count."
```

### Task B4: SSR page — no TV/Movies links

**Files:**
- Modify: `views/templates/_macros.html`, `views/templates/videos_page.html`, `views/render.py`, `assets/app/offline.js`
- Modify tests: `tests/test_render.py`

- [ ] **Step 1: failing test** (`tests/test_render.py`):

```python
from views.render import build_videos_page


def test_videos_page_has_no_plex_nav():
    html = build_videos_page([], [{"id": 1, "label": "Inbox", "emoji": None, "unread_count": 0}], None)
    assert "plex_kind" not in html
    assert ">TV<" not in html and ">Movies<" not in html
```

- [ ] **Step 2: run, expect failure**

Run: `MEDIA_ROOT=. python -m pytest tests/test_render.py -q`
Expected: FAIL with a `TypeError` (missing `current_plex_kind`).

- [ ] **Step 3: edits**
  - `_macros.html`: `{% macro nav(groups, current_group_id) -%}`. Delete the two `<a href="/?plex_kind=…">` lines. In `card`, delete the `data-plex-kind` attribute, and replace `{% if not v.plex_kind -%}{{ group_menu(...) }}{%- endif %}` with a plain `{{ group_menu(v, groups, current_group_id) }}`.
  - `videos_page.html`: `{{ m.nav(groups, current_group_id) }}`. Delete the "a Plex feed never has one" comment. The cookie redirect script drops its Jinja condition, so the `else{…}` branch always renders:

```html
  }else{
    var m=document.cookie.match(/(?:^|;\s*)preferred_group_id=([^;]+)/);
    if(m){window.location.replace('/?group_id='+m[1]);}
  }
```

  - `render.py`: `build_videos_page(videos, groups, current_group_id)` drops `current_plex_kind` from the signature and the render call. `_display_name`: `has_named_title = video.get("platform") in ("youtube", "upload")`.
  - `offline.js:229`: `next.title = v.title; next.group_id = v.group_id; next.status = v.status;`

- [ ] **Step 4: run, expect pass**

Run: `MEDIA_ROOT=. python -m pytest tests/test_render.py tests/test_api.py -q`

- [ ] **Step 5: commit**

```bash
git add views assets/app/offline.js tests/test_render.py
git commit -m "web: drop the TV and Movies links from the page"
```

### Task B5: Docs and config

- [ ] **Step 1: `CLAUDE.md`**: delete the two whole sections `### Plex library (library rows)` and `### Library rows are never moved by PatataTube`. In `### iOS`, rewrite the "Navigation is a `TabView` over `MediaTab`" bullet to describe the single Videos stack (`RootTabView` → one `VideoGridView`, `Feed` is all or a group). Delete the "per-show Download-all in `EpisodesView`" sentences from the Download-all bullet. In the resume-positions bullet, change "only for Plex items (`plex_kind` non-null) or videos whose **group**…" to "only for videos whose **group**…". In `### ffmpeg runs in exactly one process`, the job examples use `kind=hls`, the "`convert` and `hls` jobs" wording becomes "`hls` jobs", and `/api/videos/{id}/prepare` is dropped from the list of enqueuers. In Layering, drop `choose_version` from the `services.py` list. Then remove or reword every remaining Plex / library / TV / Movies statement. `grep -n -i -E "plex|library|tv/movies|movies|versions" CLAUDE.md` lists them: the "Send to Yoto (not on TV/Movies)" note, the `db.PLEX_KINDS` paragraph, "A Plex kind is not a group…", "Plex rows have no badge", the converter's `convert` job kind and `library.py` restart caveat (keep "Editing `converter.py` needs a full `./serve` restart"), and the mp4 `artist` tag sentence that names Plex (keep the tag, drop "and Plex"). Add one line under Architecture: `Movies and TV are not PatataTube's job: they play on the Apple TV through Infuse over SMB from /Volumes/Media/media. The Plex-backed library feature was removed on 2026-11-20 (docs/superpowers/plans/2026-11-20-remove-plex-movies-tv.md).`
- [ ] **Step 2: `README.md`**: drop the Movies/TV feature and its screenshots, if listed.
- [ ] **Step 3: `.env.example`**: delete lines 8–10 (`# Plex library integration`, `PLEX_URL`, `PLEX_TOKEN`). Reword line 12 to `# Audio languages kept when packaging HLS (ISO 639-2 codes, comma-separated)`.
- [ ] **Step 4: commit**

```bash
git add CLAUDE.md README.md .env.example
git commit -m "docs: PatataTube no longer has a Movies/TV library"
```

### Task B6: Deploy on the macmini and clean up its data

PatataTube is a production service (`~/c/server/Caddyfile` `:3050`), so the commits above go out only with the suite green. git-sync carries them to the macmini. **Ask the owner before Step 3**: it restarts the production server.

- [ ] **Step 1: record the library ids** before the migration deletes them. Their HLS packages are directories named by id:

```bash
command ssh macmini 'cd ~/c/patatatube && ./python_env/bin/python -I -c "
import sqlite3; c = sqlite3.connect(\"file:data/watch_later.sqlite?mode=ro\", uri=True)
print(\"\n\".join(str(r[0]) for r in c.execute(\"select id from videos where source=\x27library\x27\")))" > /tmp/patatatube-library-ids.txt; wc -l < /tmp/patatatube-library-ids.txt'
```

Expected: `556`, or close to it.

- [ ] **Step 2: back up the database**

```bash
command ssh macmini 'cd ~/c/patatatube && cp data/watch_later.sqlite data/watch_later.pre-plex-removal.sqlite'
```

- [ ] **Step 3: confirm git-sync delivered the commits, then restart.** A full `./serve` restart is required, because the converter does not reload.

```bash
command ssh macmini 'cd ~/c/patatatube && git log --oneline -1 && ./serve'
```

Then check `log/backend.log` for a clean start, and that the converter pane is running.

- [ ] **Step 4: verify the migration**

```bash
command ssh macmini 'cd ~/c/patatatube && ./python_env/bin/python -I -c "
import sqlite3; c = sqlite3.connect(\"file:data/watch_later.sqlite?mode=ro\", uri=True)
print(sorted(r[1] for r in c.execute(\"pragma table_info(videos)\")))
print([r[0] for r in c.execute(\"select name from sqlite_master where type=\x27table\x27\")])
print(c.execute(\"select count(*) from videos\").fetchone())"'
```

Expected: no library column names, no `video_versions`, and a count equal to the downloads alone.

- [ ] **Step 5: delete the orphaned files.** HLS directories of the purged ids, under `MEDIA_ROOT/data/hls` (`paths.HLS_DIR`), and every non-download poster in `data/previews` (download posters are `dl<id>.*.jpg`):

```bash
command ssh macmini 'cd ~/c/patatatube && HLS=$(./python_env/bin/python -I -c "import sys; sys.path.insert(0, \".\"); from dotenv import load_dotenv; load_dotenv(); import paths; print(paths.HLS_DIR.resolve())") && while read -r id; do [ -n "$id" ] && rm -rf "$HLS/$id"; done < /tmp/patatatube-library-ids.txt && find data/previews -maxdepth 1 -type f ! -name "dl*" -delete && ls data/previews | wc -l && rm /tmp/patatatube-library-ids.txt'
```

The `-I` flag ignores the script's directory, so put `.` on `sys.path` explicitly, as shown. If `paths.HLS_DIR` lives on `/Volumes/Media`, plain SSH cannot open it (macOS privacy permissions). Run that half through the tmux pane `directory:1.2` instead.

- [ ] **Step 6: drop the Plex settings from the macmini `.env`** without printing it:

```bash
command ssh macmini 'cd ~/c/patatatube && sed -i "" -E "/^(# Plex library integration|PLEX_URL=|PLEX_TOKEN=)/d" .env && grep -c -E "^PLEX_" .env || true'
```

Expected: `0`.

- [ ] **Step 7: smoke test.** The web page at `http://192.168.1.1:3050/` shows groups and no TV/Movies links. A download plays (mp4 and HLS). `/sd` still plays. On the device, the iOS app (Part A) loads groups and plays.

- [ ] **Step 8: Caddy comments** in `~/c/server/Caddyfile` (another repo, edited on this machine, synced by git-sync):
  - Line ~142: "API, SSR page, library streams and HLS packaging proxy to FastAPI" → "API, SSR page and HLS packaging proxy to FastAPI".
  - Line ~232: "Library videos (arbitrary source paths, version resolution) fall through to the app." → "A file that is not on disk yet falls through to the app."

  Validate with `caddy validate --adapter caddyfile --config <copy>` on the macmini, commit, then `./reload` there once synced.

- [ ] **Step 9: after a week with no problems**, delete the backup: `rm ~/c/patatatube/data/watch_later.pre-plex-removal.sqlite` on the macmini.

---

## Self-review notes

- **Spec coverage:** iOS (A1–A3), SSR (B4), DB (B3), backend (B1–B2), and production data on the macmini (B6) are all covered. The `versionId` plumbing is consciously deferred (A5, Decision 4).
- **Ordering hazard:** Part B before Part A would leave the installed app's TV tab calling `/api/videos?plex_kind=tv`, which would then return *every* video (the param is ignored). That is why A ships first. With A installed, the app never sends `plex_kind`.
- **Line numbers** are from commit `ef7a2ee` and drift as earlier steps delete code. Always locate code by the quoted symbol, not by the number.
