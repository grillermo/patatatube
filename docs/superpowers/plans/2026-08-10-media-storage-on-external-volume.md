# Move videos/ and data/hls/ to /Volumes/Media/patatatube

Date: 2026-08-10

## Goal

Free ~132 GB on the boot volume by serving downloaded MP4s and HLS packages
from the external Media volume instead of the repo.

Current sizes / capacity:

| Path | Size |
|---|---|
| `videos/` | 4.5 G |
| `data/hls/` | 128 G |
| `data/previews/` | 77 M (stays local) |
| `data/watch_later.sqlite` | 788 K (stays local) |
| boot volume free | 89 G |
| `/Volumes/Media` free | 852 G |

Target root: `/Volumes/Media/patatatube` (capital `M` matches the existing
`LIBRARY_MOVIES_DIR` / `LIBRARY_TV_DIR` entries; the FS is case-insensitive so
`/Volumes/media` resolves to the same place).

Not moving: the sqlite DB (locking over an external volume risks corruption)
and `data/previews/` (small).

## Design

### 1. One env-driven media root, no symlinks

New module `paths.py` holding every media directory, read from env at import
time (matching how `db.py`/`hls.py` already read env):

```python
MEDIA_ROOT   = Path(os.getenv("MEDIA_ROOT", "."))
VIDEOS_DIR   = Path(os.getenv("VIDEOS_DIR", str(MEDIA_ROOT / "videos")))
HLS_DIR      = Path(os.getenv("HLS_DIR", str(MEDIA_ROOT / "data/hls")))
```

Defaults with `MEDIA_ROOT` unset are byte-identical to today (`videos`,
`data/hls`), so tests and a fresh checkout keep working on relative paths with
no env at all.

Call sites to repoint at `paths`:

- `downloader.py:15` `VIDEOS_DIR = Path("videos")`
- `router.py:34` `VIDEOS_DIR = Path("videos")` (used at `:538`, `:631`, `:704`, `:1061`)
- `promote.py:20` `VIDEOS_DIR = Path("videos")`
- `main.py:9,34` imports `VIDEOS_DIR` from `router` and `mkdir`s it
- `hls.py:28` `HLS_DIR = Path(os.getenv("HLS_DIR", "data/hls"))` → from `paths`

Re-exporting `VIDEOS_DIR` from each of those modules keeps existing imports
(`from router import ... VIDEOS_DIR`) working unchanged.

`promote.py:99`'s comment about `videos/` and `/Volumes/Media` being different
filesystems stops being true once both live on Media — but the copy-then-
`os.replace` dance is still correct (and still required whenever `MEDIA_ROOT` is
left local), so the code does not change; only the comment gets a note.

### 2. Fail fast when the volume is unmounted

Without a guard, `VIDEOS_DIR.mkdir(parents=True)` on an unmounted volume
silently recreates the tree on the boot disk and re-fills the space this change
just freed — the exact failure being fixed.

`paths.ensure_media_root()`:

- no-op when `MEDIA_ROOT` is unset/`.` (the local default),
- otherwise: if `MEDIA_ROOT` is not an existing directory, or
  `os.stat(MEDIA_ROOT).st_dev == os.stat("/").st_dev` (i.e. it resolved onto the
  boot disk because nothing is mounted there), raise `RuntimeError` naming the
  path.

Called from `main.py` startup (replacing the bare `VIDEOS_DIR.mkdir`) and from
`converter.py`'s startup, so both the web worker and the ffmpeg runner refuse to
start against a missing volume rather than corrupting layout. The `./serve`
supervisor loop will restart-crash-loop with the error in `log/backend.log`,
which is the intended loud failure.

### 3. Config

`.env.example` gains, next to the existing `LIBRARY_*` block:

```
# Root for downloaded MP4s and HLS packages. Unset = repo-relative
# (videos/, data/hls). Set to an external volume to keep them off the boot disk.
MEDIA_ROOT=/Volumes/Media/patatatube
# Optional per-directory overrides (default to $MEDIA_ROOT/videos, $MEDIA_ROOT/data/hls)
#VIDEOS_DIR=
#HLS_DIR=
```

Local `.env` gets the real `MEDIA_ROOT=/Volumes/Media/patatatube`.

`serve:84`'s `--reload-exclude 'videos/*'` still matters only for a local
`MEDIA_ROOT`; leave it.

`.gitignore` needs no change (`videos/`, `data/` stay ignored, and are simply
empty afterwards).

### 4. Tests

- New `tests/test_paths.py`: defaults with no env match today's literals;
  `MEDIA_ROOT` composes both subdirs; explicit `VIDEOS_DIR`/`HLS_DIR` win over
  `MEDIA_ROOT`; `ensure_media_root` raises for a nonexistent root and for one
  whose `st_dev` equals `/`'s, and is a no-op when unset.
- Existing tests reload `db`/`main` after setting env (the `client` fixture
  pattern) — same pattern applies, `paths` joins the reload list where a test
  needs a temp media root.
- Full `python -m pytest tests/` must stay green. No iOS test run: nothing in
  `ios/` changes — the app only ever sees URL paths, never filesystem paths.

## Migration (data)

Run with the server stopped. In-flight requests explicitly not a concern.

1. Preflight: `df -h /Volumes/Media` (needs ≥ 133 G free; currently 852 G),
   confirm `/Volumes/Media` `st_dev` differs from `/`.
2. `mkdir -p /Volumes/Media/patatatube/data`
3. `rsync -aH --info=progress2 videos/ /Volumes/Media/patatatube/videos/`
4. `rsync -aH --info=progress2 data/hls/ /Volumes/Media/patatatube/data/hls/`
   (128 G over the external bus — expect this to be the long pole. `rsync`
   rather than `mv` so a failure leaves the originals intact; it is also
   resumable by re-running.)
5. Verify before deleting anything: file counts and total bytes match on both
   sides (`find … | wc -l`, `du -sk`), and spot-check that one video's
   `master.m3u8` plus its segments are present.
6. Only then delete the originals: `rm -rf videos/* data/hls/*` (keep the
   directories so a `MEDIA_ROOT`-unset run still behaves).
7. Restart `./serve`; confirm in `log/backend.log` that startup passed the
   mount guard, then smoke-test: `/api/videos` lists, `/videos/{id}/stream`
   returns 206 on a Range request, `/videos/{id}/hls/master.m3u8` serves, and a
   fresh `/api/videos/{id}/prepare` writes its output under the new root.

Rollback: unset `MEDIA_ROOT` in `.env` and restart — but only before step 6,
since that is the irreversible one.

## Order of work

1. `paths.py` + its tests (TDD).
2. Repoint `downloader`, `router`, `promote`, `hls`, `main`, `converter`.
3. Run `python -m pytest tests/` — green with no env set.
4. `.env.example` + CLAUDE.md note (a "Storage layout" line under Conventions).
5. Data migration steps above.
6. Post-migration smoke test.
