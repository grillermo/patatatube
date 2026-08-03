# Video groups: replacing classifications with a first-class group

**Date:** 2026-08-03
**Status:** approved, not yet implemented

## Problem

`db.CLASSIFICATIONS = ["children", "adults", "anabel", "asmr", "tv", "movies"]` is a
hardcoded list that conflates three unrelated things:

1. **User-facing groups** of downloaded videos (children/adults/anabel/asmr). These are
   arbitrary buckets the user invented. Adding a fifth requires editing `db.py`,
   `MediaTab.videoGroups`, and shipping a new build of the iOS app.
2. **Plex media types** (tv/movies). These are not buckets — they are a different kind of
   thing entirely, with their own tabs, their own scan source (`plex.py`), their own
   directories, and their own playback rules.
3. **A verb.** Setting `classification = "tv"` on a download does not classify it; it
   *moves the file into Plex and deletes the row* (`services.apply_classification` ->
   `promote.promote_to_plex`). One column write means two incompatible operations
   depending on the value.

The group's emoji cover lives in a separate `group_covers` table keyed by the same
strings, so a group's identity is split across a Python constant, a Swift constant, and a
SQLite table with no relationship between them.

## Goal

One concept — a **group** — that is a row in a table, with a name, a label, a cover, and a
position. Adding a group becomes an INSERT that the iOS Videos tab picks up on its next
refresh. The word "classification" disappears from the codebase. Plex TV and Plex Movies
become explicitly *not* groups.

## Non-goals

- **No group CRUD UI.** Create/rename/delete are token-gated API endpoints only. No
  buttons in the iOS app or the SSR page this round.
- **No group deletion semantics.** Because there is no delete UI, the delete endpoint is
  out of scope; `DELETE /api/groups/{id}` is not implemented. Decide it when a UI needs it.
- **No backward-compatible API aliases.** `/api/classifications` is removed, not
  deprecated. Self-hosted, single user, one client.
- **No unrelated refactoring** of `db.py`, `router.py`, or `VideoGridView.swift`, all of
  which are large. Touch only what the group concept reaches.

## Decisions

| Question | Decision |
|---|---|
| Are tv/movies groups? | No. Their own hardcoded axis, internally "Plex TV" / "Plex Movies". |
| Group CRUD UI | None for now. API only. |
| FK shape | `videos.group_id INTEGER` referencing `groups(id)`. |
| Wire identity | ids everywhere — API, iOS routes, persisted keys. |
| `groups` columns | `id, name, label, emoji, position, created_at, updated_at`. |
| SSR page | Full port. No aliases. |
| Promote action | Dedicated `POST /api/videos/{id}/promote`. |
| Offline group list | Mirrored in UserDefaults, same pattern as today's covers. |
| Migration | Auto-seed 4 groups, backfill, drop old column; wipe stale iOS state. |
| Delivery | One plan, phased server -> iOS, one branch. |

## 1. Data model

```sql
CREATE TABLE groups (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  name       TEXT NOT NULL UNIQUE,   -- slug: "asmr"
  label      TEXT NOT NULL,          -- display: "ASMR"
  emoji      TEXT,                   -- NULL = placeholder tile
  position   INTEGER NOT NULL,       -- display order, ASC
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

ALTER TABLE videos ADD COLUMN group_id  INTEGER REFERENCES groups(id);
ALTER TABLE videos ADD COLUMN plex_kind TEXT;   -- 'tv' | 'movies' | NULL
-- videos.classification dropped
```

`group_id` and `plex_kind` are mutually exclusive. Both NULL means an unsorted download —
the honest representation of what `serialize_video`'s current `or "children"` fallback
hides. Nullability is the discriminator; no `kind` column.

`db.CLASSIFICATIONS` and `db.VIDEO_GROUPS` are **deleted**. Replacements:

- `db.list_groups() -> list[dict]` (ordered by `position`, then `id`)
- `db.get_group(group_id) -> dict | None`
- `db.create_group(name, label, emoji=None, position=None) -> dict`
- `db.update_group(group_id, *, label=None, emoji=..., position=None) -> dict | None`
- `db.PLEX_KINDS = ("tv", "movies")` — deliberately not a group concept, and deliberately
  not named `CLASSIFICATIONS`.

`set_video_classification` becomes `set_video_group(video_id, group_id)`.
`get_all_videos(classification)` becomes `get_all_videos(group_id=None, plex_kind=None)`.
`get_group_covers` / `set_group_cover` are removed; the emoji is a `groups` column.

## 2. Migration

Runs inside `init_db()`, following the existing idempotent-guard convention. Every step is
a no-op on a second run.

1. `CREATE TABLE IF NOT EXISTS groups`.
2. If `groups` is empty, seed the four defaults with labels and positions:
   `(children, "Children", 0)`, `(adults, "Adults", 1)`, `(anabel, "Anabel", 2)`,
   `(asmr, "ASMR", 3)`. Seeding is unconditional on a fresh DB, not gated on the old
   column existing — a brand-new install must still get the four groups.
3. Add `group_id` and `plex_kind` columns if `PRAGMA table_info(videos)` lacks them.
4. If `videos.classification` still exists, backfill:
   - `UPDATE videos SET group_id = (SELECT id FROM groups WHERE groups.name = videos.classification) WHERE classification NOT IN ('tv','movies')`
   - `UPDATE videos SET plex_kind = classification WHERE classification IN ('tv','movies')`
5. If `group_covers` exists, `UPDATE groups SET emoji = (SELECT emoji FROM group_covers WHERE group_covers.name = groups.name)`, then `DROP TABLE group_covers`.
6. `ALTER TABLE videos DROP COLUMN classification` (SQLite 3.35+; Python 3.13 ships well
   past that). Guarded on the column still being present.

A classification value with no matching group (hand-edited DB) leaves `group_id` NULL —
the row becomes unsorted rather than failing the migration.

## 3. Backend surface

| Old | New |
|---|---|
| `GET /api/classifications` -> `{classifications: [str]}` | `GET /api/groups` -> `{groups: [{id,name,label,emoji,position}]}` |
| `GET /api/group-covers` | folded into `GET /api/groups` |
| `POST /api/group-covers/{name}` | `PATCH /api/groups/{id}` (label / emoji / position) |
| — | `POST /api/groups` (create; token-gated, no UI) |
| `POST /api/videos/{id}/classify {classification}` | `POST /api/videos/{id}/group {group_id}` |
| classify with `tv`/`movies` -> Plex move | `POST /api/videos/{id}/promote {kind}` |
| `GET /api/videos?classification=children` | `GET /api/videos?group_id=3`, `?plex_kind=tv` |

Auth is unchanged: the `/api/*` writes stay `_check_token`-gated; the SSR form endpoint
stays ungated, as today.

`services.apply_classification` splits in two, which is the point of the refactor:

```python
def set_group(video_id: int, group_id: int) -> bool:
    """Pure column write. False when the group does not exist."""

def promote(video_id: int, kind: str) -> bool:
    """Hand a download to Plex. Raises promote.PromotionError -> 409."""
```

`promote` keeps every existing guarantee: `PromotionError` leaves the row and the file
untouched, and the caller returns 409.

Other backend edits:

- `plex.py` scan rows emit `plex_kind` instead of `classification`.
- `promote.py`: `PROMOTED_CLASSIFICATIONS` -> `PLEX_KINDS`, `dest_dir(classification)` ->
  `dest_dir(kind)`, log strings updated. The env vars (`LIBRARY_TV_DIR`,
  `LIBRARY_MOVIES_DIR`) do not change.
- `/upload/file`'s tv/movies rejection is deleted — a `group_id` cannot name a Plex kind,
  so the case is structurally impossible rather than validated against.
- `views/serializers.py`: emits `group_id: int | null` and `plex_kind: str | null`; the
  `or "children"` fallback is removed.
- SSR: `views/render.py:build_videos_page(videos, groups, current_group_id, current_plex_kind)`;
  `views/templates/videos_page.html` and `_macros.html` iterate group dicts;
  `assets/app/videos.js` posts `group_id`. The classify dropdown gains a separate
  "Move to Plex" pair of options posting to `/promote`. Filter links become
  `?group_id=N` and `?plex_kind=tv`.

## 4. iOS: `Feed` replaces the stringly-typed filter

`VideoStore.filter: String?` is where the classification concept lives on the client — it
is sometimes a group name, sometimes `"tv"`, sometimes nil. It becomes:

```swift
public enum PlexKind: String, Codable, Hashable, Sendable { case tv, movies }

public enum Feed: Codable, Hashable, Sendable {
    case all
    case group(id: Int)
    case plex(PlexKind)
}

public struct VideoGroup: Codable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let label: String
    public let emoji: String?
    public let position: Int
}
```

`Feed.queryItems` is the single place that knows the wire spelling; `Feed.storageKey`
(`"all"` / `"group:3"` / `"plex:tv"`) is the single place that knows the persistence
spelling. `MediaTab.filter` returns a `Feed`. `MediaTab.videoGroups` and
`MediaTab.label(forGroup:)` are **deleted** — the list and the labels are server data.

`Route.group(name: String)` -> `Route.group(id: Int)`.

## 5. iOS stores

- **`GroupStore`** (new) replaces `GroupCoverStore` outright: the emoji is a field on the
  group now, not a parallel table, so one store covers both. It mirrors `[VideoGroup]` as
  a single JSON blob in UserDefaults, so `GroupsView` renders instantly and offline, then
  refreshes from `GET /api/groups` in `.task` — the same offline-first contract the covers
  have today.
- **`GroupPosterStore`** keys move from `<name>` to `group:<id>`.
- **`AppModel`**: `autoplayByClassification`, `randomizeByClassification`,
  `cellSizeByClassification` rekey to `Feed.storageKey` and lose the "Classification"
  in their names.
- **`ResumeDecision.decide(classification:)`** -> `decide(plexKind:)`. It prompted for
  exactly tv/movies, which is now literally "is a Plex item", so the name list disappears.
- **`VideoListCache`** filenames key off `Feed.storageKey`.
- **`Video`** decodes `group_id` and `plex_kind` instead of `classification`.

**Stale persisted state is discarded, not migrated.** Every affected UserDefaults key gets
a new spelling (`selectedFeed` replacing `selectedClassification`, a new restoration blob
key, `groups` replacing `groupCover:*`). Old keys are orphaned and never read. A launch
after upgrade lands on the Videos tab root with default per-feed prefs. This is cheaper
and less risky than translating name-keyed blobs to ids for a single user.

## 6. iOS views

- **`GroupsView`**: `ForEach(groupStore.groups)` ordered by `position`; label from
  `group.label`, art from `group.emoji`. The cover picker now `PATCH`es
  `/api/groups/{id}` and stays optimistic-with-revert exactly as it is today. No
  create/rename/delete affordances.
- **`VideoCell`** menu: the group picker lists server groups and posts `…/group`; a
  separate **Move to Plex > TV / Movies** section posts `…/promote`. Two verbs, two menus
  — the UI stops implying they are the same action.
- **`VideoCell.isPlexItem`** = `video.plexKind != nil`. The `classification == "children"`
  special case at `VideoCell.swift:39` survives as a `group.name == "children"` check
  against the resolved group; names stay stable even though ids are the wire identity.
- **`VideoGridView`**: its hardcoded `classifications` default array is deleted; the group
  list comes from `GroupStore`.

## 7. Testing

**Python.** Migration is the risky part and gets the most coverage:

- `init_db` on a pre-migration DB seeds four groups, backfills `group_id` for each of the
  four names, sets `plex_kind` for tv/movies rows, folds `group_covers.emoji` in, and
  drops `classification` and `group_covers`.
- `init_db` twice is a no-op; the second run neither reseeds nor errors.
- `init_db` on an empty DB seeds the four groups.
- A classification value with no group leaves `group_id` NULL.
- `services.set_group` rejects an unknown group id; `services.promote` still raises
  `PromotionError` and changes nothing on failure.
- Endpoint tests for `GET/POST/PATCH /api/groups`, `POST …/group`, `POST …/promote`,
  and the `?group_id=` / `?plex_kind=` filters, following the existing `client` fixture
  pattern (reload `db` then `main` after setting env).
- `tests/test_render.py` and `test_serializers.py` updated to the new shapes.

**Swift.** `swift test` in both debug and release, per CLAUDE.md:

- `Feed` round-trips through Codable and produces the right query items and storage keys.
- `GroupStore` mirrors, applies a server list, and survives a corrupt/absent blob.
- `Route.group(id:)` encodes and restores.
- Existing `ResumeDecisionTests`, `MediaTabTests`, `VideoTests`, `VideoStoreTests`
  updated.

## 8. Delivery

One branch, six phases, server first:

1. **DB + migration** — `groups` table, accessors, backfill, drops. Python tests.
2. **Backend** — `services` split, router endpoints, serializer.
3. **SSR** — `render.py`, templates, `videos.js`.
4. **iOS Kit** — `Feed`, `VideoGroup`, `GroupStore`, `APIClient`, `Video`,
   `ResumeDecision`, `VideoListCache`. `swift build` + both `swift test` configs.
5. **iOS app** — `GroupsView`, `VideoGridView`, `VideoCell`, `AppModel`, restoration.
6. **Docs** — rewrite the CLAUDE.md sections that document the hardcoded
   `CLASSIFICATIONS` / `MediaTab.videoGroups` sync this refactor deletes, plus the
   promote and group-cover paragraphs.

Phases 1-3 leave the deployed server ahead of the installed app. Acceptable: self-hosted,
single user, and the app is rebuilt from the same branch.

## Risks

- **The column drop is irreversible.** Take a copy of `data/watch_later.sqlite` before the
  first run against real data. The backfill is a join on a name that has never been
  constrained, so a typo'd historical value silently becomes an unsorted row — phase 1
  should report the count of rows it could not match.
- **`--reload` does not restart the converter** (CLAUDE.md), so phase 1 needs a full
  `./serve` restart before the queue sees the new schema.
- **`VideoGridView.swift` is large and touched in phase 5.** Keep the edits to the filter
  plumbing; resist rewriting it.
