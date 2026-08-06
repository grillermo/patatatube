# iPhone 16e Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the PatataTube iOS app install and run well on an iPhone 16e, delivered through the existing AltStore source, with a full iPhone UI pass.

**Architecture:** The app is currently iPad-only (`TARGETED_DEVICE_FAMILY: "2"` in `ios/PatataTube/project.yml`) — an iPad-only .ipa cannot be installed on an iPhone at all, so the core change is flipping the target to universal and adding iPhone orientation keys. The UI is SwiftUI with adaptive grids, so most layout already scales; the one known compact-width problem is the grid toolbar (5 trailing icons won't fit an iPhone nav bar). Distribution is unchanged: `./deploy` builds the .ipa, publishes a GitHub Release, and regenerates `ios/apps.json`; AltStore on the phone re-signs on device with the user's own Apple ID.

**Tech Stack:** SwiftUI (Swift 6.0), XcodeGen, xcodebuild, AltStore/AltServer, Ruby deploy script (`./deploy`).

## Global Constraints

- Deployment target stays `iOS: "17.0"` (iPhone 16e ships iOS 18.x — fine).
- `SWIFT_VERSION: "6.0"`, `CODE_SIGN_STYLE: Automatic`, `DEVELOPMENT_TEAM: Q3WS4MWCW3` — do not change.
- `project.pbxproj` is generated — never edit it by hand; edit `ios/PatataTube/project.yml` and run `xcodegen generate`.
- Signing team is a **free personal team**: AltStore re-signs on device (7-day expiry, refreshed by AltServer), max 3 sideloaded apps per Apple ID on the phone (AltStore itself counts as one).
- iPad must keep working; layout changes to shared views are allowed but must be verified on an iPad simulator too.
- No iOS test target exists — verification is `xcodebuild` builds, simulator smoke tests, and the manual checklist in `ios/README.md`.
- Do NOT run `./deploy` without the user's go-ahead (it pushes to GitHub and publishes a release).

---

### Task 1: Universal device family + iPhone orientations

**Files:**
- Modify: `ios/PatataTube/project.yml` (settings.base block)

**Interfaces:**
- Produces: an app target that builds for iPhone destinations. Every later task depends on this.

- [ ] **Step 1: Edit project.yml**

In `ios/PatataTube/project.yml`, change the device family and add iPhone orientations next to the existing `~ipad` key:

```yaml
        TARGETED_DEVICE_FAMILY: "1,2"
        INFOPLIST_KEY_UISupportedInterfaceOrientations~iphone: UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight
```

(`TARGETED_DEVICE_FAMILY` was `"2"`. Keep the existing `INFOPLIST_KEY_UISupportedInterfaceOrientations~ipad` line as-is. Landscape is included so `VideoPlayerView` can rotate fullscreen on the phone.)

- [ ] **Step 2: Regenerate the project**

Run: `cd ios/PatataTube && xcodegen generate`
Expected: `Created project at .../PatataTube.xcodeproj`

- [ ] **Step 3: Verify the generated project targets iPhone**

Run: `grep TARGETED_DEVICE_FAMILY ios/PatataTube/PatataTube.xcodeproj/project.pbxproj`
Expected: `TARGETED_DEVICE_FAMILY = "1,2";`

- [ ] **Step 4: Build for the iPhone 16e simulator (this is the failing→passing check for this task)**

Run:
```bash
cd ios/PatataTube && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube \
  -destination 'platform=iOS Simulator,name=iPhone 16e' build | tail -5
```
Expected: `** BUILD SUCCEEDED **`. (Before Step 1 this destination is not even eligible for the target.)

- [ ] **Step 5: Verify orientations landed in the built Info.plist**

Run:
```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData -path '*iphonesimulator/PatataTube.app' -newer ios/PatataTube/project.yml | head -1)
plutil -p "$APP/Info.plist" | grep -A6 -i orientation
```
Expected: a `UISupportedInterfaceOrientations` array containing `UIInterfaceOrientationPortrait`, `UIInterfaceOrientationLandscapeLeft`, `UIInterfaceOrientationLandscapeRight` (plus the separate `~ipad` set with four entries).

- [ ] **Step 6: Regression build for iPad**

Run:
```bash
cd ios/PatataTube && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' build | tail -3
```
(If that simulator name doesn't exist, pick any iPad from `xcrun simctl list devices available | grep iPad`.)
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
git add ios/PatataTube/project.yml
git commit -m "feat(ios): make app universal so it installs on iPhone"
```

Note: `project.pbxproj` is checked in (it's referenced by CLAUDE.md as generated but it exists in the repo); if `git status` shows it modified, include it in the commit.

---

### Task 2: Compact-width toolbar in VideoGridView

The grid's nav bar has 1 leading + 5 trailing buttons plus a search field. On an iPhone (compact horizontal size class) that overflows. Collapse download-all and the two zoom buttons into a single overflow `Menu` on compact width; keep refresh and upload as direct buttons. iPad keeps the current layout.

**Files:**
- Modify: `ios/PatataTube/Sources/VideoGridView.swift` (property block ~line 6-27, `.toolbar` block lines 95-127)

**Interfaces:**
- Consumes: Task 1's universal target (to build/run on iPhone sim).
- Produces: no API changes — view-internal only.

- [ ] **Step 1: Add the size-class environment property**

In `VideoGridView`, next to the other properties at the top:

```swift
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
```

- [ ] **Step 2: Replace the `.toolbar { ... }` block**

Replace the whole existing `.toolbar` modifier (lines 95–127) with:

```swift
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gear") }
                }
                if horizontalSizeClass == .compact {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
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
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                } else {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            Task { await downloadAll() }
                        } label: {
                            if downloadingAll { ProgressView() }
                            else { Image(systemName: "arrow.down.circle") }
                        }
                        .disabled(downloadingAll)
                        Button {
                            cellSize = max(cellSize - cellSizeStep, minCellSize)
                        } label: { Image(systemName: "minus.magnifyingglass") }
                        .disabled(cellSize <= minCellSize)
                        Button {
                            cellSize = min(cellSize + cellSizeStep, maxCellSize)
                        } label: { Image(systemName: "plus.magnifyingglass") }
                        .disabled(cellSize >= maxCellSize)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await store.refreshLibrary() }
                    } label: {
                        if store.isLoading { ProgressView() }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showUpload = true } label: { Image(systemName: "plus") }
                }
            }
```

- [ ] **Step 3: Build for both destinations**

Run:
```bash
cd ios/PatataTube && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube \
  -destination 'platform=iOS Simulator,name=iPhone 16e' build | tail -3
```
Expected: `** BUILD SUCCEEDED **`. Repeat with the iPad destination from Task 1 Step 6.

- [ ] **Step 4: Commit**

```bash
git add ios/PatataTube/Sources/VideoGridView.swift
git commit -m "feat(ios): collapse grid toolbar into overflow menu on compact width"
```

---

### Task 3: Full iPhone pass on the iPhone 16e simulator

Visual/behavioral audit of every screen at compact width, against a live backend. This is a verification task; any defect found becomes an inline fix + its own commit, following the pattern of Tasks 1–2 (edit → build both destinations → commit).

**Files:**
- Test: whole app in the iPhone 16e simulator; possible small fixes in `ios/PatataTube/Sources/*.swift`

**Interfaces:**
- Consumes: Tasks 1–2 builds.

- [ ] **Step 1: Start the backend**

Run (repo root, background): `./serve`
Expected: uvicorn listening on `:3050`. Note the `UPLOAD_TOKEN` value from `.env` — the app needs it in Settings.

- [ ] **Step 2: Boot the simulator and install the app**

```bash
xcrun simctl boot "iPhone 16e" 2>/dev/null; open -a Simulator
APP=$(find ~/Library/Developer/Xcode/DerivedData -path '*iphonesimulator/PatataTube.app' | head -1)
xcrun simctl install "iPhone 16e" "$APP"
xcrun simctl launch "iPhone 16e" com.patatatube.app
```
Expected: app launches; the launch screen (iPad splash PNG) renders scaled but not broken.

- [ ] **Step 3: Configure server in Settings**

In the sim: tap the gear → set server URL `http://localhost:3050` and the token from `.env`. Expected: grid loads videos; no red error banner.

- [ ] **Step 4: Walk the checklist (from `ios/README.md`), portrait**

Check each; screenshot anything wrong (`xcrun simctl io "iPhone 16e" screenshot /tmp/16e-<name>.png`):
- Grid: cells render 16:9, titles legible, default cell size gives a sensible single column (~358pt wide); zoom via the new overflow menu changes column count (min 120 → 2 columns).
- Filter tabs (all/children/adults/education/tv/movies): horizontally scrollable, tappable, reload the grid.
- Search field: debounced filtering works; keyboard doesn't cover results.
- Per-cell: play, download button + progress, version picker (when >1), ellipsis menu (Info / Move / classify / Delete) — all reachable at 44pt targets.
- tv tab: `ShowsView` poster grid (adaptive 160pt minimum → 2 columns on 16e) → `EpisodesView` push.
- Player: autoplays fullscreen, tap shows AVKit controls, pull-down-to-dismiss works, auto-dismiss at end.
- Upload sheet, Settings sheet: fit the screen, keyboard behavior sane.
- Error banner: stop `./serve`, pull-to-refresh → red banner at bottom, readable.

- [ ] **Step 5: Rotate to landscape**

Expected: grid reflows to more columns; player fills screen edge-to-edge. `Cmd-→` in Simulator.

- [ ] **Step 6: iPad regression spot-check**

Install and launch on the iPad simulator (same `simctl` commands with the iPad device name and the iPad build from Task 1 Step 6). Expected: toolbar shows the original discrete buttons (regular width ⇒ `else` branch), grid unchanged.

- [ ] **Step 7: Fix-and-commit loop**

For each defect found: minimal fix in the responsible view file → rebuild both destinations → re-verify that checklist line → `git commit` with a one-line `fix(ios): ...` message. If nothing found, no commit.

---

### Task 4: Release through AltStore (`./deploy`)

**Files:**
- Modify (by the script, not by hand): `ios/PatataTube/project.yml` (version bump), `ios/apps.json`

**Interfaces:**
- Consumes: all committed work from Tasks 1–3, on branch `main` (deploy refuses other branches).
- Produces: GitHub Release `v1.0.38` (next patch) with the universal .ipa; `ios/apps.json` pointing at it.

- [ ] **Step 1: Confirm with the user before running** — deploy pushes to GitHub and publishes a release. STOP and ask.

- [ ] **Step 2: Preconditions**

Run: `gh auth status && git status --short && git rev-parse --abbrev-ref HEAD`
Expected: gh authenticated, working tree clean, branch `main`.

- [ ] **Step 3: Deploy**

Run (repo root): `./deploy`
Expected: version bumped (1.0.37 → 1.0.38), .ipa built, GitHub Release created, `apps.json` regenerated with size + sha256, commit pushed. The script prints the AltStore source URL at the end.

---

### Task 5: Install on the iPhone 16e (manual, on-device)

All steps happen on the phone/Mac by hand — free personal team constraints apply throughout.

**Interfaces:**
- Consumes: the published release from Task 4 and the existing source `https://raw.githubusercontent.com/grillermo/patatatube/main/ios/apps.json`.

- [ ] **Step 1: AltServer on the Mac** — already installed for the iPad flow (menu-bar app). Verify it's running.

- [ ] **Step 2: Install AltStore onto the iPhone 16e**

Connect the 16e by USB (first time), trust the computer, then AltServer menu-bar icon → *Install AltStore* → select the iPhone 16e → sign in with the Apple ID. Free-team notes: this uses one of the 3 sideload slots; a new App ID registration counts against the 10-per-week cap.

- [ ] **Step 3: Trust the profile on the phone**

Settings → General → VPN & Device Management → trust the developer profile for the Apple ID used.

- [ ] **Step 4: Add the source and install PatataTube**

AltStore app on the 16e → Sources tab → **+** → paste:
```
https://raw.githubusercontent.com/grillermo/patatatube/main/ios/apps.json
```
Then open PatataTube from that source → Install. Expected: v1.0.38 installs (pre-Task-1 versions would be rejected as iPad-only).

- [ ] **Step 5: Keep it alive** — AltStore refreshes signatures in the background when AltServer is reachable on the same Wi-Fi; note the 7-day expiry if the phone is away from the Mac's network for long.

---

### Task 6: Full on-device test pass

- [ ] **Step 1:** Point the app at the real server (Settings → production URL + token). Run the complete manual checklist from `ios/README.md` on the 16e — same items as Task 3 Step 4 plus device-only ones: offline playback of a cached video (airplane mode), AirPlay from the player, PWA-parity checks, background download continuation.
- [ ] **Step 2:** File anything broken as a fix loop (Task 3 Step 7 pattern) and re-deploy via Task 4 when fixes land.
