# Pending: finish OTA distribution

**v2.5.14 is published and verified.** The only thing left is tapping Install on
each device.

Last updated 2026-09-05, against version 2.5.14 / build 176.

Reference: `ios/install.md` (full guide), `ios/altstore.md` (secondary route).

---

## Verified working

The ad-hoc export was run for real against a fresh archive. Evidence:

| | |
|---|---|
| Export | `** EXPORT SUCCEEDED **` |
| Signature | `Apple Distribution: GUILLERMO SILICEO TRUEBA (Q3WS4MWCW3)` |
| `TeamIdentifier` | `Q3WS4MWCW3` |
| Profile | `iOS Team Ad Hoc Provisioning Profile: com.patatatube.app` |
| `get-task-allow` | `0` — a distribution build, not development |
| Provisioned devices | 3, confirmed to be the intended ones |
| Certificate + profile expiry | **2027-09-06** |
| `manifest.plist` | correct structure, URLs and bundle identifier |

Team ID is `Q3WS4MWCW3` — Apple kept the same identifier through enrollment, so
`project.yml:95` was already correct and never needed editing.

**Two things that cost a debugging cycle, both now fixed in the docs:**

1. Automatic signing creates certificates silently but **will not create App
   IDs**. `com.patatatube.app` had to be registered by hand on the portal. This
   does not break archiving — only distribution — so it fails at the very last
   step. (`ios/install.md` §1.4.)
2. `method: ad-hoc` is deprecated in Xcode 15.3+; the code now uses
   `release-testing`.

**One operational caveat:** the distribution certificate is *cloud managed* — its
private key is not in the local keychain, so signing goes through Apple's
service. `./deploy` needs network access and a live Xcode account session.

---

## Shipped

`v2.5.14` — <https://github.com/grillermo/patatatube/releases/tag/v2.5.14>

| Check | Result |
|---|---|
| Published `.ipa` signature | `Apple Distribution: GUILLERMO SILICEO TRUEBA (Q3WS4MWCW3)` |
| `codesign --verify --deep --strict` | OK |
| Version | 2.5.14 (build 176) |
| `ios/manifest.plist` | points at the v2.5.14 release asset |
| Release asset | HTTP 206 on a range request |
| GitHub Pages | `built` |
| Install page | HTTP 200, `text/html`, shows "Version 2.5.14 (build 176)" |

## What's left

### 1. Install on each device

**In Safari** (Chrome and in-app browsers cannot start an install):

```
https://grillermo.github.io/patatatube/install.html
```

Tap **Install PatataTube** → **Install**. Then **Share → Add to Home Screen** —
that bookmark is your permanent update button; the URL never changes.

If iOS shows *"Untrusted Enterprise Developer"*: **Settings → General → VPN &
Device Management** → your team → **Trust**.

**Developer Mode is not required.** Apple's
[docs](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
scope it to *development-signed* software and state it "doesn't affect ordinary
installation techniques, such as buying apps from the App Store or participating
in a TestFlight team." This build is signed with an **Apple Distribution**
certificate and has `get-task-allow = 0`, i.e. it is not development-signed.

If an installed app refuses to launch anyway, **Settings → Privacy & Security →
Developer Mode** is a one-toggle thing to rule out.

### 2. Retire AltStore on the iPad

Install over the top from the Safari link — same bundle ID, so it adopts the
existing data and the 7-day expiry stops applying. Then delete AltStore and stop
running AltServer at login.

The AltStore source keeps being published by every `./deploy`, so this is
reversible.

---

## Remaining risk

**The manifest's content type.** `raw.githubusercontent.com` serves `.plist` as
`text/plain`. In practice iOS accepts this and only requires HTTPS, but it is the
one assumption left that cannot be tested without a device. If **Install** does
nothing or errors immediately, this is the first suspect — serve
`ios/manifest.plist` from your own Caddy with `Content-Type: text/xml` and
repoint `OTA_MANIFEST_URL` in `deploy`. The install page and the Home Screen
bookmark don't change.

**Rollback:** `PATATATUBE_UNSIGNED=1 ./deploy` builds the old unsigned `.ipa` and
ships it over AltStore only, deliberately leaving `ios/manifest.plist` and the
install page untouched so the Safari link keeps offering the last release it can
actually install.

---

## Ongoing

- **New device** → register the UDID, then `./deploy`. Registering alone does
  nothing for already-published builds; the device list is baked into the profile
  at build time.
- **Before 2027-09-06** → certificate and profile expire and installed apps stop
  launching. Renew, `./deploy`, reinstall from the bookmark. Worth a calendar
  reminder.
- **No update notifications.** Nothing polls; you tap the bookmark when you know
  you've deployed. Tapping when nothing is new just reinstalls harmlessly. Keep
  AltStore on a device if you want to be told.
