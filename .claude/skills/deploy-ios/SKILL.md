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
- Ruby, xcodegen and full Xcode (for `ios/ipa_builder.rb`).
- On `main`.

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
2. Picks a free version (skips past existing `v*` tags and published `.ipa`s).
3. `git add -A && git commit` (skipped if nothing pending), `git push github main`.
4. `exec ./deploy <version>` — bumps, builds, publishes `PatataTube-X.Y.Z.ipa`,
   `patatatube-icon.png`, `patatatube-manifest.plist` and the install page,
   then commits `Release iOS vX.Y.Z`, tags it and pushes.

The install page URL is printed at the end and never changes:
`https://files.chiq.me/files/3cf25ffc-754e-4a19-b4e1-bcc84cf02bd4-Install_PatataTube.html`

## Release notes — always write them

They appear under "What's new" on the install page.

- `--summary "..."` — the headline. Without it: `What's new in X.Y.Z:`.
- `--note "..."` — one bullet, repeatable.
- Without either, `./deploy` uses the commit subjects since the last `v*` tag.

Read what changed (`git log --oneline $(git describe --tags --abbrev=0 --match 'v*')..HEAD`)
and write 2–5 bullets from the iPad user's side. Skip backend-only and tooling commits.

## Instrumented builds (`--instrumented`)

Compiles the app with **`DEVLOG`** (`ios/PatataTubeKit/Sources/PatataTubeKit/DevLog.swift`):
it records taps, player state, proxy requests, cache transitions and downloads,
and POSTs them to `/api/devlog` → **`log/ios.jsonl`** on the server. The
install page marks the version `[DEVLOG]`. Ship a plain build over it once the
bug is understood.

## Gotchas

- **A push that "fails" may have succeeded.** git-sync's global post-commit
  hook pushes the instant a commit lands, so our push can lose the race
  (`cannot lock ref 'refs/heads/main'`). Both the driver and `./deploy` check
  the remote before failing.
- **The remote is named `github`, not `origin`.**
- **Publishing happens before the commit.** If the push fails afterwards, the
  build is already live; push the commit and tag by hand.
- **Ad-hoc profiles embed device UDIDs at build time**: a newly registered
  device needs a fresh deploy before it can install.
- `PATATATUBE_UNSIGNED=1` is refused: an unsigned `.ipa` cannot be installed OTA.
