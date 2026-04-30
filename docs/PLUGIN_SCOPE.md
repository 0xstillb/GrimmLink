# GrimmLink Plugin Scope

## Current Role

GrimmLink is the KOReader Companion plugin for Grimmory.

This repository is the dedicated plugin repo. Backend code and backend API implementation belong in the separate `grimmory` repository.

## Current MVP Scope

- Grimmory server URL configuration
- `x-auth-user` and `x-auth-key` authentication
- Book matching by hash
- KOReader-native progress pull on book open
- KOReader-native progress push on close, suspend, and manual sync
- EPUB progress sync as KOReader-native progress only
- Reading session upload
- Batch upload of pending reading sessions
- Offline queue for progress and sessions
- Moon+ Reader-like local/remote progress comparison
- Conflict dialog:
  - `Use Local`
  - `Use Remote`
  - `Ignore`
- Shelf Sync:
  - list shelves and shelf books
  - download missing shelf books to the local KOReader folder
  - mirror shelf removals to tracked local files only when `two_way_shelf_delete_sync` is enabled
  - remove local shelf members from Grimmory through the KOReader shelf-remove endpoint, never by deleting library records
  - treat public shelves as readable, but not writable unless the backend grants owner/admin mutation access

## Current Backend Contract

The GrimmLink MVP plugin currently targets these Grimmory endpoints:

- `GET /api/koreader/users/auth`
- `GET /api/koreader/books/by-hash/{bookHash}`
- `GET /api/koreader/syncs/progress/{bookHash}`
- `PUT /api/koreader/syncs/progress`
- `POST /api/v1/reading-sessions`
- `POST /api/v1/reading-sessions/batch`

The plugin does not currently call `GET /api/v1/reading-sessions/book/{bookId}`.

## Important EPUB Rule

EPUB progress in GrimmLink means KOReader-native EPUB progress.

GrimmLink:

- sends raw KOReader progress/location
- sends percentage in the `0..100` scale
- sends `currentPage` and `totalPages` if available
- sends `device` and `deviceId`
- does not generate EPUB CFI
- does not bridge into Grimmory Web Reader progress fields

## Conflict Rules

The current plugin treats local and remote progress as significantly different when any of these thresholds are met:

- percentage differs by at least `1%`
- page differs by at least `5`
- raw location differs

Behavior:

- local newer: push local silently when practical
- remote newer: prompt before jumping
- both changed: show conflict dialog

## Offline Queue

Current queue behavior:

- pending progress is queued locally by `bookHash`
- pending sessions are queued locally and grouped for batch upload
- retry happens on reconnect, resume, or manual `Sync Pending Now`
- failed auth or offline state must not block reading

## Auto-Update (Prompt 7B / Prompt 7B-R)

GrimmLink now includes an opt-in auto-update flow for the active
`grimmlink.koplugin` package.

- Release source is fixed to `0xstillb/grimmlink`.
- The updater must never point to `WorldTeacher/BookLoreSync-plugin`.
- Installed version is read from `grimmlink.koplugin/plugin_version.lua`.
- Supported release assets are:
  - `grimmlink.koplugin.zip`
  - `grimmlink-vX.Y.Z.zip`
- Default settings:
  - `auto_update_enabled = false`
  - `check_update_on_startup = false`
  - `update_channel = stable`
  - `update_repo = 0xstillb/grimmlink`
  - `allow_prerelease_updates = false`
- Update checks may happen on startup only when the user enables both
  `auto_update_enabled` and `check_update_on_startup`.
- Manual `Check for Updates` is available from `About & Updates`.
- Download/install always requires explicit user confirmation.
- The updater replaces only the plugin package. It must preserve:
  - settings
  - database
  - cache
  - downloaded books
  - `.sdr` files
- If GitHub API access, download, extraction, or install fails, the current
  GrimmLink plugin remains usable.
- Restart KOReader after a successful update so the new plugin code is loaded.

Legacy upstream documentation and tests remain in this repository for reference only:

- `docs/content/`
- `legacy/upstream-bookloresync-tests/`

## Annotation Sync (Prompt 6 / Prompt 7A)

GrimmLink's MVP also includes opt-in sync for KOReader highlights, notes,
bookmarks and personal rating against `/api/koreader/books/{bookId}/...`
endpoints in Grimmory.

- Per-kind toggles default OFF; user must explicitly enable each:
  - `annotations_sync_enabled` (highlights + notes)
  - `bookmarks_sync_enabled`
  - `rating_sync_enabled`
- Capture happens on book close (`annotations_capture_on_close`, default ON
  but only effective when at least one kind is enabled).
- Items are queued in the `pending_annotations` table and flushed on
  `syncPendingNow` / suspend / resume / "Sync Annotations Now" menu action.
- Prompt 7A also pulls remote annotations/bookmarks back into KOReader using
  the KOReader-native endpoints and preserves raw `koreaderPos` / `page`.
- Remote pull uses conservative merge rules:
  - exact duplicate: skip
  - remote exists, local missing: import into KOReader when a safe local store exists
  - remote newer than local: update only when the local note/text is still safe to touch
  - uncertain match / both changed: keep the local user item untouched and cache a conflict instead of silently overwriting
- Stable client-computed `dedupeKey` (md5 of book + kind + KOReader pos +
  text) prevents duplicates on the server.
- Raw KOReader xpointer / page is preserved as `koreaderPos` / `page` on the
  wire and in the new server-side `koreader_annotations` /
  `koreader_bookmarks` tables. No EPUB CFI conversion is performed.
- Local user annotations are never deleted during pull. Web Reader fields are
  never written in this phase.
- Rating is mapped from KOReader's 0..5 star summary to Grimmory's 1..10
  `personal_rating` (0 = "no rating", skipped).

Reading is never blocked — capture and sync run after the document closes
and any failure is logged + retried.

## Later Phases Only

Not part of the current MVP:

- Web Reader Bridge (Prompt 8)
- EPUB CFI conversion (Prompt 8)
- Hardcover rating sync
- shelf/library sync beyond the current Shelf Sync MVP

These remain later-phase work and are not the source of truth for the current plugin behavior.
