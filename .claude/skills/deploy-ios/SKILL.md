---
name: deploy-ios
description: Deploy, ship, or release the PatataTube iOS app. Commits all pending git changes, pushes to the remote, then runs ./deploy to bump the version, build the .ipa and publish it over the air on files.chiq.me with per-build release notes. Use when asked to deploy iOS, ship the app, release a new version, or publish an OTA build.
---

# deploy-ios

Ships a new PatataTube iOS build end to end, over the air only. The repo's
`./deploy` (Ruby) bumps the version, builds an ad-hoc-signed `.ipa`, publishes
it with its OTA manifest and install page to files.chiq.me, then commits, tags
and pushes the bump — but it **only** commits `project.yml`. Any other pending
work must be committed first or it is not in the build's history. This skill's
driver does that, then hands off to `./deploy`.

There is no AltStore source and no GitHub Release any more, so nothing needs
`gh`. The push is plain git over SSH.

Paths below are relative to the **repo root** (`/Users/grillermo/c/patatatube`).

## Prerequisites

- Run on the macmini: files.chiq.me's file_server serves `../file_server/files`
  on this machine, and publishing is a copy into it (`PATATATUBE_PUBLISH_DIR`
  overrides the path).
- Ruby, xcodegen and full Xcode (for `scripts/deploy/ipa_builder.rb`).
- `PATATATUBE_UPLOAD_BASE=https://files.chiq.me` in the repo `.env`, and
  `ios/PatataTube/Config/Local.xcconfig` (gitignored) with
  `PATATATUBE_BUNDLE_ID` and `DEVELOPMENT_TEAM`.
- On `main`, with a clean tree: `./deploy` refuses a dirty one. The driver
  commits pending work first.
- The login keychain unlocked. `./deploy` probes codesign first and runs
  `security unlock-keychain` if it is locked (over SSH it is), which asks for
  the login password, so an agent can't get past it alone.

## Run (agent path)

```bash
.claude/skills/deploy-ios/deploy-ios.sh --yes \
  --summary "Playback survives backgrounding" \
  --note "Player restores the session once per launch, not per task restart"
```

`--yes` is required from an agent: `./deploy` otherwise asks for confirmation
on stdin. Other forms: `minor`, `major`, or an explicit `1.4.2` as the bump;
`-m "msg"` for the pending-changes commit; `--dry-run` runs the preflight and
prints the plan without touching anything.

**The driver runs `git add -A`.** If the tree has unrelated changes the user
has not asked to ship (check `git status` first), commit the intended files
yourself and run `./deploy --yes ...` directly instead of the driver.

The driver:
1. Preflight: remote `github` exists, on `main`, `./deploy` executable, xcodegen + Xcode.
2. Picks a free version (skips past existing `patatatube-ota-v*` / legacy `v*`
   tags and published `.ipa`s).
3. `git add -A && git commit` (skipped if nothing pending), `git push github main`.
4. `exec ./deploy <version>` — bumps, builds, publishes `PatataTube-X.Y.Z.ipa`,
   `patatatube-icon.png`, `patatatube-manifest.plist` and the install page,
   then commits `Release PatataTube OTA patatatube-ota-vX.Y.Z`, tags it and
   pushes.

The install page URL is printed at the end and never changes:
`https://files.chiq.me/files/patatatube-install.html`. The old
`3cf25ffc-…-Install_PatataTube.html` is republished with it, so old bookmarks
keep working.

## Release notes — always write them

They appear under "What's new" on the install page.

- `--summary "..."` — the headline. Without it: `What's new in X.Y.Z:`.
- `--note "..."` — one bullet, repeatable.
- Without either, `./deploy` uses the commit subjects since the last
  `patatatube-ota-v*` or `v*` tag.

Read what changed (`git log --oneline $(git describe --tags --abbrev=0 --match 'patatatube-ota-v*' --match 'v[0-9]*')..HEAD`)
and write 2–5 bullets from the iPad user's side. Skip backend-only and tooling commits.

## After every deploy: ntfy

Send this once `./deploy` finishes, with the real version. Tapping the
notification starts the install; the button opens the install page.

```bash
sh ~/.claude/skills/ntfy/scripts/ntfy-send.sh -t "PatataTube" -T rocket \
  -u 'itms-services://?action=download-manifest&url=https://files.chiq.me/files/patatatube-manifest.plist' \
  -l https://files.chiq.me/files/patatatube-install.html -L "Install page" \
  "PatataTube <version> is published — tap to install"
```

On failure, send `-p high -T x "PatataTube deploy failed: <one-line reason>"`
instead.

## Diagnostics builds (`--devlog`)

`--instrumented` is the old name and still works. Compiles the app with
**`DEVLOG`** (`ios/PatataTubeKit/Sources/PatataTubeKit/DevLog.swift`) and bakes
`PatataTubeDevLogURL` = `http://<LocalHostName>.local:19485/api/devlog` into
Info.plist (`PATATATUBE_DEVLOG_URL` / `PATATATUBE_DEVLOG_PORT` override it). The
app records taps, player state, proxy requests, cache transitions and downloads,
and sends them to `scripts/devlog/server.py`, which writes **`log/devlog.jsonl`**
(uploads from `DevLog.upload` go to `log/screens/`). The install page marks the
version `[DEVLOG]`. Ship a plain build over it once the bug is understood.

Start the server before handing the build over, and check it:

```bash
scripts/devlog/server.py &
curl http://$(scutil --get LocalHostName).local:${PATATATUBE_DEVLOG_PORT:-19485}/api/devlog/health
```

## Gotchas

- **A push that "fails" may have succeeded.** git-sync can push the same
  commit at the same moment, so our push can lose the race
  (`cannot lock ref 'refs/heads/main'`). Both the driver and `./deploy` check
  the remote before failing.
- **The remote is named `github`, not `origin`.**
- **Publishing happens before the commit.** If the push fails afterwards, the
  build is already live; push the commit and tag by hand.
- **Ad-hoc profiles embed device UDIDs at build time**: a newly registered
  device needs a fresh deploy before it can install.
- `PATATATUBE_UNSIGNED=1 ./deploy` only builds: it writes
  `ios/build/PatataTube-X.Y.Z-unsigned.ipa` and publishes, commits and tags
  nothing (Safari cannot install an unsigned `.ipa`).
