# Installing PatataTube via AltStore

Sideload the app onto your iPad without an Apple Developer account, with AltStore keeping the signature refreshed automatically in the background.

## Two kinds of "automatic"

1. **Re-signing** — free Apple ID signing expires every **7 days**. AltStore re-signs and reinstalls the *current* build automatically before it expires — but only if **AltServer is running on your Mac** and the iPad can reach it (USB or same Wi-Fi). This keeps the installed binary alive; it does not ship new code.
2. **Updates (new code)** — this repo is also an **AltStore source**: a JSON manifest AltStore polls in the background. When `./deploy` publishes a newer version, AltStore installs it on the iPad automatically, no cable, no rebuild-by-hand.

Set up the source once (below), then just run `./deploy` whenever you change app code.

## Publishing a new version — `./deploy`

From the repo root:

```bash
./deploy                 # bump patch (1.0.0 -> 1.0.1)
./deploy minor           # or: major / patch
./deploy 1.4.2           # or an explicit version
```

`./deploy` bumps the version in `ios/PatataTube/project.yml`, builds a fresh `.ipa`, creates a **GitHub Release** hosting that `.ipa`, regenerates `ios/apps.json` (the source manifest) to point at it, then commits and pushes. Requirements: `xcodegen`, full Xcode, and an authenticated `gh` CLI (`gh auth login`).

## Add the source on the iPad (one time)

1. In the AltStore app: **Sources** tab → **+** (top-right) → paste the source URL:

   ```
   https://raw.githubusercontent.com/grillermo/patatatube/main/ios/apps.json
   ```

2. Add it, then open **PatataTube** from that source and install once.
3. From then on, each `./deploy` shows up as an available update — AltStore installs it on its next background refresh (or pull-to-refresh **My Apps** to force it). AltServer must be reachable (see below), same as re-signing.

> `ios/apps.json` doesn't exist until the first `./deploy` runs — deploy generates it. Run `./deploy` once before adding the source.

The rest of this doc covers the AltServer + AltStore install that both mechanisms depend on, plus the fully manual `.ipa` path (`ruby ios/refresh-ipa.rb`) if you'd rather sideload by hand.

## 1. Install AltServer on your Mac

1. Download AltServer from [altstore.io](https://altstore.io) (Mac version).
2. Open the installer, drag `AltServer.app` to Applications.
3. Launch it — it lives in the menu bar (icon may be hidden under the `⌃` chevron).
4. Menu bar icon → **Preferences** → enable "Open at Login" so it's always running.

AltServer needs Apple's mobile device drivers to talk to iOS devices over USB/Wi-Fi. If you don't already have them (from Xcode or iTunes), install the **Apple Devices** app from the Mac App Store, or classic iTunes.

## 2. Install AltStore on the iPad

1. Connect iPad to Mac via USB cable, unlock it, tap **Trust** on the iPad if prompted.
2. Menu bar → AltServer icon → **Install AltStore** → select your iPad.
3. Enter an Apple ID and password when prompted.
   - Recommended: use a spare/secondary Apple ID, not your main one — AltStore stores credentials in the macOS keychain and uses this account's free-tier signing cert.
4. Wait for "Installation Succeeded". The AltStore app icon appears on the iPad home screen.
5. On the iPad: **Settings → General → VPN & Device Management** → tap the developer profile (your Apple ID email) → **Trust**.

## 3. Enable Wi-Fi sync (needed for cable-free background refresh)

1. Keep iPad connected via USB, open **Finder** on the Mac.
2. Select the iPad in Finder's sidebar → General tab.
3. Check **"Show this iPad when on Wi-Fi"**, click Apply.
4. Unplug the cable. Confirm the iPad still shows in Finder's sidebar within a few seconds (Mac and iPad must be on the same Wi-Fi network).

Without this step, AltServer can only see the iPad over USB, and background refresh won't fire wirelessly.

## 4. Build the PatataTube .ipa

From `ios/PatataTube`:

```bash
xcodegen generate
open PatataTube.xcodeproj
```

In Xcode:

1. Plug in the iPad (or just pick it as a build destination — doesn't need to stay plugged in for this step).
2. Scheme `PatataTube` → destination: your iPad (not simulator, not "Any iOS Device" for a quick local build — but "Any iOS Device (arm64)" works for archiving).
3. **Product → Archive**.

Do **not** use **Distribute App → Development → Export** — on a free Apple ID that path fails with *"Team (Personal Team) is not enrolled in the Apple Developer Program"*. That export flow requires paid enrollment. Instead, package the `.app` into an `.ipa` by hand — AltStore re-signs it anyway, so it doesn't need to be signed for distribution here:

4. In the Organizer window, right-click your archive → **Show in Finder**.
5. Right-click the `.xcarchive` → **Show Package Contents** → navigate to `Products/Applications/`. You'll find `PatataTube.app`.
6. Copy `PatataTube.app` into a work folder.
7. In that folder, create a directory named exactly `Payload` (capital P) and move `PatataTube.app` inside it.
8. Zip the `Payload` folder, then rename `Payload.zip` → `PatataTube.ipa`.

No paid Apple Developer account required — AltStore re-signs the `.ipa` itself using the free Apple ID from step 2.

## 5. Sideload the .ipa

Get the `.ipa` onto the iPad (AirDrop it to the Files app, or use iCloud Drive), then either:

- **On the iPad**: open AltStore → **My Apps** tab → tap **+** (top-left) → pick the `.ipa` from Files.
- **From the Mac**: AltServer menu bar icon → **Install .ipa** → select the file → pick the iPad.

First install takes a minute (uploading + signing). PatataTube then appears as a normal app icon on the iPad.

## 6. Confirm background auto-refresh is working

1. On the iPad: **Settings → General → Background App Refresh** → make sure it's ON globally and ON for AltStore specifically.
2. Open the AltStore app at least once — it schedules background refresh checks (roughly daily) from then on.
3. Requirements for a refresh to succeed, at any given time:
   - AltServer running on the Mac (menu bar icon visible).
   - iPad and Mac on the same Wi-Fi network (or iPad plugged into the Mac via USB).
   - The Wi-Fi sync pairing from step 3 still valid (re-pair via Finder if you ever see "AltServer not found" errors in AltStore).
4. You can force a manual check anytime: AltStore app → **My Apps** → pull down to refresh, or tap the app's row → **Refresh**.

If the Mac is asleep, off, or off the network when the 7-day expiry hits, the app greys out on the iPad ("Unable to Verify App") until AltServer becomes reachable again and a refresh succeeds — nothing is lost, it just needs a live AltServer to re-sign.

## Notes

- Max 3 sideloaded apps active at once on a free Apple ID (Apple's per-account app ID limit) — AltStore itself counts as one.
- Re-run steps 4–5 (rebuild + reinstall) whenever app code changes; step 6's auto-refresh only re-signs the existing binary, it doesn't rebuild your code.
- Keep the Mac's IP/network stable — AltServer relies on local network discovery (Bonjour) to find the iPad for wireless refresh.
