---
created: 2026-11-21T07:08:46Z
branch: remove-plex
trigger: manual
restored: false
topic: remove-plex-movies-tv
---

# Handoff: Remove the Plex Movies/TV feature from PatataTube

## Goal
Execute `docs/superpowers/plans/2026-11-20-remove-plex-movies-tv.md`: Plex was uninstalled from the
macmini (movies/TV now play in Infuse), so every trace of the Plex-backed Movies/TV feature goes —
iOS tabs/screens, SSR nav links, API endpoints, the `convert` job kind, and the library DB rows,
table and columns. Part A (iOS) ships before Part B (backend) reaches production.

## Current State
- All code tasks done and committed on branch `remove-plex`, worktree
  `~/c/patatatube/.worktrees/remove-plex` (on immunemac). **Not merged into `main`.**
  - `2d6af2d` A1 kit · `5261290` A2 app · `8f02840` B1 media_probe · `3873d3e` B2+B4 backend+SSR ·
    `bc90f24` B3 db purge · `2c44080` B5 docs
- Backend: `MEDIA_ROOT=. ./python_env/bin/python -m pytest tests/ -q` → 540 passed (baseline was 692;
  the drop is deleted library tests).
- iOS: `swift build`, `swift build --build-tests`, app `xcodebuild build` and `build-for-testing`
  all succeed. **No iOS tests have been run** — the user started `swift test`, then cancelled it.
- Migration verified on a snapshot of the macmini prod DB: 556 library rows purged, 239 downloads
  kept, `sum(resume_secs)` and `sum(play_count)` unchanged, idempotent on a second run.
- Not started: A3 (deploy iOS), B6 (macmini production cutover), Caddyfile comments (B6 step 8).

## Key Decisions
- Worktree instead of main — executing-plans default; deploy (CLAUDE.local.md) must happen from main.
- Part B kept unmerged until iOS is installed — git-sync carries main to the macmini; plan's ordering hazard.
- Also deleted `VideoPreparationTracker`, `PendingAutoDownloadStore`, `SingleOptionsMenu`,
  `OptionsScope.named`, `AppModel.showScope`, `VideoStore.ensureReady/chooseVersion/chooseAudio/chooseSubtitle`,
  `ConversionJob.showTitle`, `DownloadButtonIdentity.audioLanguage`, and the player's
  `applyAudioSelection/applySubtitleSelection` — all fed only by library rows / `/prepare`.
- `Video.chosenVersionId` and all `versionId` plumbing kept (plan Decision 4).
- `media_probe.probe_source` imports `downloader._probe_media` lazily — top-level import is circular
  (downloader → services → hls → media_probe).
- B4 (SSR) folded into the B2 commit — router's `build_videos_page` call changes signature in the same step.
- `db.active_jobs` no longer selects `show_title`; `PROGRESS_JOB_KINDS = ("hls",)`; `JOB_KINDS` drops `convert`.
- `_migrate_classifications_to_groups` no longer writes `plex_kind`; old tv/movies classifications become unsorted.
- `VideoPlayerView.markReady` closure annotated `@MainActor` — build failed with a region-isolation
  data-race error once surrounding code changed.
- Generic job tests switched from kind `"convert"` to `"hls"`.

## Modified Files
98 files changed vs `main` (`git diff --stat main...remove-plex`). Main ones: `router.py`, `db.py`,
`converter.py`, `hls.py`, `media_probe.py` (new), `views/serializers.py`, `views/render.py`,
`views/templates/*`, `services.py`, `sd.py`, `check_subtitles.py`, `CLAUDE.md`, `.env.example`,
`ios/PatataTubeKit/Sources/PatataTubeKit/{Feed,Video,VideoStore,APIClient,RestorationState,RestorationResolver,ResumeDecision,GroupStore,ConversionJob,CacheManager}.swift`,
`ios/PatataTube/Sources/{RootTabView,VideoGridView,VideoCell,VideoRow,VideoPlayerView,PlaybackSource,DownloadButton,OptionsMenu,AppModel,SkeletonGrid,AudioMiniPlayerBar,GroupsView}.swift`.
Deleted: `plex.py`, `library.py`, `version_namer.py`, `relabel_versions.py`, iOS `ShowsView`,
`EpisodesView`, `MovieDetailView`, `MovieCell`, `MovieRow`, `MediaTab`, `ShowGroup`, and their tests.

## Failed Approaches
- immunemac's `python_env` is broken (python3.13 missing). Built a uv venv at `$TMPDIR/patatatube-venv`
  and symlinked the worktree's `python_env` to it (symlink excluded via `.git/info/exclude`).
- CLAUDE.md's simulator udids belong to another machine; here use iPhone 16e `965B1EAE-E589-4D19-A104-73DDBA7DE444`.
- xcodebuild rewrites `ios/PatataTubeKit/Package.resolved` — `git checkout` it before committing.
- Reading the macmini DB with `mode=ro` / `sqlite3 -readonly` fails ("unable to open database file", WAL);
  a normal connection + `backup()` works.
- A greedy regex over `tests/test_render.py` call sites mangled them — edit those call sites literally.

## Files to Read
- `docs/superpowers/plans/2026-11-20-remove-plex-movies-tv.md` (Tasks A3 and B6 remain)
- `CLAUDE.local.md` (deploy policy: deploy from the release branch, standing go-ahead)
- `~/c/server/Caddyfile` (two comments, B6 step 8)

## Next Steps
1. Ask the user whether to run the iOS tests (`swift test`, `swift test -c release`, and the
   `PatataTubeTests` xcodebuild target with udid `965B1EAE-…`) — they cancelled the last attempt.
2. Merge `remove-plex` into `main` and ship iOS with `./deploy` (Task A3); the user verifies on device
   (Videos grid, no tab bar, group opens, playback, mini player, pull-to-refresh).
3. Only after the user confirms the app is installed, and with explicit OK for the production restart,
   run Task B6 on the macmini: record library ids, back up the DB, `./serve`, verify migration, delete
   orphaned HLS dirs + non-`dl*` posters (HLS dir may need tmux pane `directory:1.2`), drop `PLEX_` lines
   from `.env`, smoke test, update Caddyfile comments.
4. Remove the worktree after merge; offer to delete `$TMPDIR/patatatube-venv` and `$TMPDIR/plexrm/`.

## Open Questions
- Run the iOS tests before deploying, or skip them?
- Was the `markReady` data-race error pre-existing on main, or triggered by these changes? (Fix is safe either way.)
