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

## Auto-Update

Auto-update is intentionally disabled for GrimmLink MVP.

It must not point to the original `WorldTeacher/BookLoreSync-plugin` releases.

Legacy upstream documentation and tests remain in this repository for reference only:

- `docs/content/`
- `legacy/upstream-bookloresync-tests/`

## Later Phases Only

Not part of the current MVP:

- Web Reader Bridge
- EPUB CFI conversion
- rating sync
- highlights/notes sync
- bookmarks sync
- shelf/library sync beyond the current Shelf Sync MVP

These remain later-phase work and are not the source of truth for the current plugin behavior.
