# iOS Toolbar Menu Consolidation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse the video-grid toolbar's scattered controls into a single `ellipsis.circle` (`⋯`) Menu, identical in both size classes.

**Architecture:** Replace the size-class-branching `.toolbar { … }` body in `VideoGridView.swift` with one trailing `ToolbarItem` holding a `Menu`. All eight actions (New video, Refresh, Autoplay, Download-all, Smaller/Bigger cells, Settings) become menu rows. Search bar and pull-to-refresh are untouched.

**Tech Stack:** SwiftUI, XcodeGen. iOS app package `ios/PatataTube` + logic package `ios/PatataTubeKit`.

## Global Constraints

- No automated iOS test target exists — verification is `xcodegen generate` + build (`swift build` for Kit; Xcode/`xcodebuild` for the app) + manual checklist.
- `AutoplayToggle` component (`ios/PatataTube/Sources/AutoplayToggle.swift`) MUST stay — still used by `EpisodesView.swift:57`. Do not delete or edit it.
- Do not touch `.searchable(...)`, `.refreshable { await store.load() }`, or any grid/playback/download/error-banner logic.
- `docs/` is force-tracked in this repo (broad `.gitignore` on `docs`, but spec/plan files are committed with `git add -f`). App source under `ios/` is tracked normally.

---

### Task 1: Consolidate toolbar into a single `⋯` menu

**Files:**
- Modify: `ios/PatataTube/Sources/VideoGridView.swift:8` (remove `horizontalSizeClass` env var)
- Modify: `ios/PatataTube/Sources/VideoGridView.swift:125-179` (replace entire `.toolbar { … }` body)

**Interfaces:**
- Consumes (all already present in this view — no new symbols):
  - `showSettings: Bool` (`@State`), `showUpload: Bool` (`@State`)
  - `store.refreshLibrary() async`, `store.isLoading: Bool`
  - `model.autoplay: Bool` (bindable via `$model.autoplay`)
  - `downloadAll() async` (private func), `downloadingAll: Bool` (`@State`)
  - `cellSize: Double` (`@AppStorage`), `minCellSize`, `maxCellSize`, `cellSizeStep` (constants)
- Produces: nothing new (pure UI restructure).

- [ ] **Step 1: Remove the unused size-class environment var**

Delete line 8:

```swift
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
```

- [ ] **Step 2: Replace the entire `.toolbar { … }` block**

Current block spans from `.toolbar {` (line 125) through its closing `}` (line 179). Replace the whole thing with:

```swift
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showUpload = true
                        } label: { Label("New video", systemImage: "plus") }

                        Button {
                            Task { await store.refreshLibrary() }
                        } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .disabled(store.isLoading)

                        Toggle(isOn: $model.autoplay) {
                            Label("Autoplay", systemImage: "play.circle")
                        }

                        Divider()

                        Button {
                            Task { await downloadAll() }
                        } label: { Label("Download all", systemImage: "arrow.down.circle") }
                        .disabled(downloadingAll)

                        Button {
                            cellSize = max(cellSize - cellSizeStep, minCellSize)
                        } label: { Label("Smaller cells", systemImage: "minus.magnifyingglass") }
                        .disabled(cellSize <= minCellSize)

                        Button {
                            cellSize = min(cellSize + cellSizeStep, maxCellSize)
                        } label: { Label("Bigger cells", systemImage: "plus.magnifyingglass") }
                        .disabled(cellSize >= maxCellSize)

                        Divider()

                        Button {
                            showSettings = true
                        } label: { Label("Settings", systemImage: "gear") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
```

Leave the modifiers that follow the toolbar exactly as they are (`.refreshable`, `.sheet(isPresented: $showSettings)`, `.sheet(isPresented: $showUpload)`, `.fullScreenCover`, `.task`, `.overlay`).

- [ ] **Step 3: Regenerate the Xcode project and build**

Run:

```bash
cd ios/PatataTube && xcodegen generate
xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS' build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`. If `xcodebuild` scheme/destination differs locally, opening `PatataTube.xcodeproj` in Xcode and building (⌘B) is the fallback — a clean compile is the gate.

If the build fails with "cannot find 'horizontalSizeClass'" anywhere else, grep for stray references:

```bash
rg -n "horizontalSizeClass" ios/PatataTube/Sources/
```

Expected: no matches (the only two uses were the two branches removed in this task).

- [ ] **Step 4: Manual verification (run on iPad + narrow width)**

Launch the app (or run in Simulator). Confirm:
1. iPad / regular width: nav bar shows the search bar + a single `⋯` button; no gear, no separate +/refresh/autoplay/size buttons.
2. Narrow width (Split View or iPhone sim): identical single `⋯` button.
3. Tap `⋯` → menu shows, top-to-bottom: New video, Refresh, Autoplay (checkmark row), ──, Download all, Smaller cells, Bigger cells, ──, Settings.
4. Each row works: New video + Settings open their sheets; Refresh reloads (row disabled while `store.isLoading`); Autoplay toggles and its checkmark tracks `model.autoplay`; Download all downloads uncached videos (disabled while running); Smaller/Bigger cells resize the grid and disable at min/max.
5. Search bar and pull-to-refresh still work.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTube/Sources/VideoGridView.swift ios/PatataTube/PatataTube.xcodeproj
git commit -m "feat(ios): consolidate grid toolbar into a single overflow menu"
```

(If `xcodegen generate` did not change `project.pbxproj`, just commit `VideoGridView.swift`.)

---

## Self-Review

**Spec coverage:**
- Single `⋯` menu, both size classes → Task 1 Steps 1-2 (removes branching + env var).
- Menu contents/order/grouping (New video, Refresh, Autoplay, ──, Download-all, cell −/+, ──, Settings) → Step 2 code block, matches spec table.
- Autoplay as inline menu `Toggle` with `play.circle`, `AutoplayToggle` untouched → Step 2 + Global Constraints.
- Delete leading gear, size-class branches, separate items, `@Environment` line → Steps 1-2.
- Refresh/Download-all `.disabled` state kept, spinner dropped → Step 2.
- Search / pull-to-refresh untouched → Step 2 note + Global Constraints.
- Testing = manual checklist → Step 4.

No gaps.

**Placeholder scan:** No TBD/TODO; full replacement code shown; exact commands given. Clean.

**Type consistency:** All symbols (`showUpload`, `showSettings`, `store.refreshLibrary`, `store.isLoading`, `model.autoplay`, `downloadAll`, `downloadingAll`, `cellSize`, `minCellSize`, `maxCellSize`, `cellSizeStep`) verified against `VideoGridView.swift` as it stands. No new types introduced.
