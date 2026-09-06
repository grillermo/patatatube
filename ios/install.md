# Installing PatataTube on your devices

The primary route: a **signed ad-hoc build** installed straight from Safari over
an `itms-services://` link. No AltStore, no AltServer, no cable, no Mac awake —
tap a bookmark on the phone and the newest release installs itself.

This needs the **paid Apple Developer Program** ($99/yr). The free tier cannot
sign for ad-hoc distribution, which is why this repo used to route everything
through AltStore (`altstore.md` — still works, still published on every deploy).

## What changes with a paid membership

|                     | Free Apple ID (old) | Paid program (now) |
|---------------------|---------------------|--------------------|
| Signature lifetime  | 7 days              | **1 year**         |
| Sideloaded app cap  | 3                   | unlimited          |
| Needs a computer to install | yes (AltServer) | **no**       |
| Install mechanism   | AltStore re-signs on-device | Safari link |

The catch that replaces the weekly refresh: an ad-hoc provisioning profile only
covers **devices registered on the portal at build time**. Register a new phone
and you must re-run `./deploy` before that phone can install anything.

---

## Part 1 — one-time Apple setup

### 1.1 Find your Team ID

1. Go to <https://developer.apple.com/account>.
2. Scroll to **Membership details**.
3. Copy the **Team ID** — 10 characters, like `A1B2C3D4E5`.

Enrolling *may* create a team distinct from the old free "Personal Team" — or may
keep the same identifier, as it did here. Don't assume; read it off the
certificate once one exists:

```bash
security find-certificate -c "Apple Development" -p \
  | openssl x509 -noout -subject -nameopt sep_multiline,utf8 | grep OU=
```

The `OU` field **is** the Team ID.

### 1.2 Put the Team ID in the project

`ios/PatataTube/project.yml`, under `targets.PatataTube.settings.base`:

```yaml
        DEVELOPMENT_TEAM: A1B2C3D4E5    # <- your Team ID
```

That one line is the source of truth — `ipa_builder.rb` reads it for both the
archive and the ad-hoc export, so a build and its signature can never disagree.
(`PATATATUBE_TEAM_ID=... ./deploy` overrides it for a one-off.)

### 1.3 Sign in to Xcode

Xcode → **Settings** → **Accounts** → **+** → **Apple ID** → sign in with the
Apple ID you enrolled.

Confirm the paid team appears in the list (not just "Personal Team"). This is
what lets `xcodebuild -allowProvisioningUpdates` create the distribution
certificate and the ad-hoc profile on its own.

Automatic signing stops short of two things, which are 1.4 and 1.5 below: it
registers neither App IDs nor devices.

### 1.4 Register the App ID

Automatic signing creates certificates silently but **refuses to create App
IDs**. Skip this and the export fails with:

```
error: exportArchive Automatic signing cannot register bundle identifier "com.patatatube.app".
error: exportArchive No profiles for 'com.patatatube.app' were found
```

> Automatic signing cannot register bundle identifiers with Apple. Register your
> bundle identifier on https://developer.apple.com/account and then try again.

Note this does **not** break archiving — an archive is happy with the team's
wildcard `iOS Team Provisioning Profile: *`. Only distribution needs the explicit
App ID, so the failure lands at the very last step.

1. <https://developer.apple.com/account/resources/identifiers/list> → **+**
2. **App IDs** → **Continue** → type **App** → **Continue**
3. Description: `PatataTube`
4. Bundle ID: **Explicit**, exactly `com.patatatube.app` (must match
   `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`)
5. Capabilities: **none.** `UIBackgroundModes: audio` is an Info.plist key, not
   an entitlement — leave everything unchecked
6. **Continue** → **Register**

### 1.5 Register every device

You need each device's **UDID** — a 25- or 40-character identifier. It is not
shown in Settings, so get it from the Mac, once per device:

1. Connect the device by cable, unlock it, tap **Trust**.
2. Xcode → **Window** → **Devices and Simulators** → select the device.
3. Copy the **Identifier** field.

(Finder works too: select the device in the sidebar, then click the text under
its name repeatedly until the UDID appears; right-click → Copy.)

Then for each one:

1. <https://developer.apple.com/account/resources/devices/list> → **+**
2. Platform **iOS**, any name you like, paste the UDID → **Continue** →
   **Register**.

Do all three devices now. The limit is 100 iPhones + 100 iPads per membership
year, and **removing a device doesn't free the slot until the yearly renewal**,
so don't register devices you don't own.

---

## Part 2 — publish a release

Nothing new here:

```bash
./deploy                 # bump patch (2.5.13 -> 2.5.14)
./deploy minor           # or: major / patch
./deploy 2.6.0           # or an explicit version
```

What each run now does, on top of the old behaviour:

1. Archives **signed** for your team (previously `CODE_SIGNING_ALLOWED=NO`).
2. Exports with `method: release-testing` (Xcode 15.3+'s name for ad-hoc),
   re-signing against a profile that embeds every registered device's UDID.
3. Has `xcodebuild` emit the OTA `manifest.plist` and commits it to
   `ios/manifest.plist` — generated by the export, so it always describes the
   binary actually being uploaded.
4. Regenerates `docs/install.html` and publishes it via GitHub Pages.
5. Still cuts the GitHub Release and still updates the AltStore source
   (`ios/apps.json`), so the old route keeps working in parallel.

The first run will take longer than usual: Xcode creates the certificate and
profile before it can export.

---

## Part 3 — install on a device

**In Safari** (Chrome and in-app browsers cannot start an install), open:

```
https://grillermo.github.io/patatatube/install.html
```

Tap **Install PatataTube** → **Install** on the system prompt. The icon appears
on the Home Screen with a progress ring.

Then, once per device, make updating a one-tap affair: **Share → Add to Home
Screen** on that install page. The URL never changes between releases, so from
then on the bookmark is your update button.

If iOS shows *"Untrusted Enterprise Developer"* (it normally will not for an
ad-hoc build): **Settings → General → VPN & Device Management** → your team →
**Trust**.

## Part 4 — updating

1. Tap the Home Screen bookmark.
2. Tap **Install**.

It installs over the existing app: downloads, resume positions, credentials and
settings are all preserved (same bundle ID, same data container).

There is deliberately **no update notification** — nothing polls for you. Tapping
when nothing is new just reinstalls the current version, which is harmless. If
you want to be told, the AltStore route (`altstore.md`) still does that, and both
routes are published by the same `./deploy`.

---

## Maintenance

**Adding a device later.** Register its UDID (1.5), then run `./deploy`. The
already-published `.ipa` cannot install on it — ad-hoc profiles are baked at
build time.

**Once a year.** The distribution certificate and the ad-hoc profile both expire
after 12 months, and installed apps stop launching when the profile does. Renew
the membership, then run `./deploy` — Xcode reissues both automatically. Worth a
calendar reminder a week before the membership renews.

**`./deploy` needs to be online.** The distribution certificate is *cloud
managed* — its private key is not in the local keychain (`security find-identity`
lists only the Apple Development one), so the export signs through Apple's
service. That means a deploy needs network access and a live Xcode account
session; it cannot sign offline. Nothing to configure, just don't expect a
release from a plane.

**The iPad currently on AltStore.** Nothing to uninstall. Install from the Safari
link over the top; the bundle ID is unchanged so it adopts the existing data and
the 7-day expiry stops applying. You can then delete AltStore and stop running
AltServer.

## Troubleshooting

**"Unable to Install" / the icon greys out mid-install.** Almost always an
unregistered device. Check the UDID is in the portal, then re-run `./deploy` —
registering alone is not enough.

**Export fails with a signing error.** The Apple ID for the team in
`project.yml` is not in Xcode → Settings → Accounts, or `DEVELOPMENT_TEAM` is
still the old Personal Team ID. Verify with:

```bash
security find-identity -v -p codesigning     # expect an "Apple Distribution" line
```

**Safari says it cannot connect to raw.githubusercontent.com.** The manifest is
fetched by iOS itself over HTTPS; a VPN or content blocker on the device can
break it. Turn it off for the install.

**The install page shows an old version.** GitHub Pages takes ~1 minute to
rebuild after `./deploy` pushes. The **Install button still works immediately** —
it points at `ios/manifest.plist`, which is live the moment the push lands.

**The install page 404s and the Pages build failed.** Check `docs/.nojekyll`
exists and is committed. Without it, Pages runs everything in `docs/` through
Jekyll, and Liquid aborts the whole build on the `{{` inside code blocks in
`docs/superpowers/plans/*.md` — a failure that has nothing to do with
`install.html` but takes it down with it:

```
Liquid Exception: Liquid syntax error (line 615): Variable '{{ ...
```

`./deploy` creates the file, so this only bites before the first deploy. Confirm
with `gh run list --limit 1` and `gh api repos/grillermo/patatatube/pages/builds
-q '.[0].status'`.

**Escape hatch.** If signing is broken and a release has to go out anyway:

```bash
PATATATUBE_UNSIGNED=1 ./deploy
```

builds the old unsigned `.ipa` and publishes it through the AltStore route only.
`ios/manifest.plist` and the install page are left **untouched**, still offering
the last signed release — which is the honest answer, since an unsigned build
cannot be installed from Safari at all.
