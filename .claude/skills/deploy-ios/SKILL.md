---
name: deploy-ios
description: Deploy, ship, or release the PatataTube iOS app. Commits all pending git changes, pushes to the remote, then runs ./deploy to bump the version, build the .ipa, cut a GitHub Release and update the AltStore source with per-build release notes. Use when asked to deploy iOS, ship the app, release a new version, or publish to AltStore.
model: sonnet
---

# deploy-ios

Ships a new PatataTube iOS build end to end. The repo's `./deploy` (Ruby)
bumps the version, builds a fresh `.ipa`, cuts a GitHub Release and rewrites
`ios/apps.json` — but it **only** commits `project.yml` + `apps.json`. Any
other pending work (Swift changes, etc.) must be committed and pushed first
or it never ships. This skill's driver does that, then hands off to `./deploy`.

Paths below are relative to the **repo root** (`/Users/grillermo/c/patatatube`).

## Prerequisites

- `gh` CLI installed and authenticated (`gh auth status`).
- Ruby (for `./deploy`), plus whatever `ios/ipa_builder.rb` needs to build the `.ipa` (macOS + Xcode toolchain).
- On the **default branch** (`main`). `./deploy` refuses any other branch because the AltStore manifest raw URL tracks `main`.

## Run (agent path)

One command does everything — commit pending changes, push, deploy:

```bash
.claude/skills/deploy-ios/deploy-ios.sh              # patch bump (1.0.3 -> 1.0.4)
.claude/skills/deploy-ios/deploy-ios.sh minor        # minor bump
.claude/skills/deploy-ios/deploy-ios.sh 1.4.2        # explicit version
.claude/skills/deploy-ios/deploy-ios.sh -m "Fix download button" minor
```

Always pass release notes (see below):

```bash
.claude/skills/deploy-ios/deploy-ios.sh minor \
  --summary "Playback survives backgrounding" \
  --note "Player restores the session once per launch, not per task restart" \
  --note "Controls reveal themselves on a restored session"
```

**Preview first without touching anything** — runs all preflight checks and
prints the plan, commits/pushes/deploys nothing:

```bash
.claude/skills/deploy-ios/deploy-ios.sh --dry-run minor
```

The driver:
1. Preflight: `gh` auth, remote `github` exists, on default branch, `./deploy` executable.
2. `git add -A && git commit` (skipped if nothing pending; message via `-m`, default "Commit pending changes before iOS deploy").
3. `git push github main`.
4. `exec ./deploy [bump]` — which bumps the version, builds the `.ipa`, makes its own commit of `project.yml`/`apps.json`, pushes, and creates the GitHub Release.

The AltStore source URL is printed at the end by `./deploy`.

## Release notes — always write them

AltStore and SideStore render each version's `localizedDescription` from
`ios/apps.json` as **"What's New"** on the iPad. A bare `Release 1.1.63` there
is useless, so `./deploy` builds a real description:

    What's new in 1.1.63:

    • Player restores the session once per launch, not per task restart
    • Controls reveal themselves on a restored session

- `--summary "..."` — the headline line. Without it: `What's new in X.Y.Z:`.
- `--note "..."` — one bullet, **repeatable**. A value with newlines (or leading
  `-`/`*`/`•`) splits into several bullets.
- Both flags go through the wrapper unchanged, in any order, and land in the
  version entry of `ios/apps.json` *and* the GitHub Release body.

**Fallback:** with no `--note`/`--summary`, `./deploy` derives bullets from the
commit subjects since the last `v*` tag (max 8, merges and `Release iOS v…` /
`Commit pending changes` noise filtered). That keeps a description from ever
degrading to the version alone — but raw commit subjects read like commit
subjects, so write the notes yourself.

**How to write them as the agent:** before deploying, read what actually
changed (`git log --oneline $(git describe --tags --abbrev=0 --match 'v*')..HEAD`
plus any uncommitted diff) and turn it into 2–5 bullets phrased from the
iPad user's side — what they will notice, not which file moved. Skip backend-only
and tooling commits; they are invisible on the device. `./deploy` prints the
final text before building, so it is visible in the run output.

## Instrumented builds (`--instrumented`)

```bash
.claude/skills/deploy-ios/deploy-ios.sh --instrumented        # patch bump, DEVLOG on
.claude/skills/deploy-ios/deploy-ios.sh --instrumented minor
```

Compiles the app with the **`DEVLOG`** condition, which switches on `DevLog`
(`ios/PatataTubeKit/Sources/PatataTubeKit/DevLog.swift`). The app then records
taps, the AVPlayer state machine, StreamProxy requests, cache-state transitions
and download lifecycle, and POSTs them to the backend's `/api/devlog`, which
appends them to **`log/ios.jsonl`** on the server. Read that file to diagnose.

Use it to reproduce a bug that only happens on the real iPad — playback failing
intermittently is the case it was built for. Without the flag every call site
compiles to nothing, so normal releases log nothing at all.

`DEVLOG` is independent of Debug/Release: the `.ipa` is a Release build either
way. `./deploy` prompts for confirmation before publishing one (skip with
`--yes`), marks the version `[DEVLOG]` in `ios/apps.json`, and prints the
command to ship a clean build afterwards.

## Gotchas

- **The remote is named `github`, not `origin`.** `git push origin` fails — there is no `origin`. Both this driver and `./deploy` push to `github`.
- **Default-branch guard is hard.** `./deploy` calls `die` if you're not on `main`; the driver checks the same thing first so you fail fast before any commit.
- **`./deploy` commits twice-over is expected.** This driver commits your pending work; `./deploy` then makes a *second* commit for the version bump + manifest. Two commits per release is normal.
- **A real run is irreversible and outward-facing** — it cuts a public GitHub Release and publishes to the AltStore source. Use `--dry-run` to rehearse. There is no undo built in (delete the release + tag manually via `gh` if needed).
- **Never leave the AltStore source on an instrumented build.** `--instrumented`
  publishes to the same public source as any other release, and AltStore will
  auto-install it on the iPad. Once the bug is understood, run a plain
  `deploy-ios.sh` to ship a clean build over it.
- **`.ipa` build needs the macOS/Xcode toolchain.** `./deploy` → `ios/ipa_builder.rb` shells out to the Xcode build; it won't produce a build on a headless Linux box.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `✗ gh not authenticated` | `gh auth login` |
| `✗ on 'X', not default 'main'` | `git switch main` (the manifest raw URL tracks `main`) |
| `✗ no git remote named 'github'` | `git remote add github git@github.com:grillermo/patatatube.git` |
| `release vX.Y.Z already exists` (from `./deploy`) | bump to a new version — pass a higher `patch/minor/major` or explicit `X.Y.Z` |
