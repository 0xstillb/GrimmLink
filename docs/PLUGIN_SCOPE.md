# GrimmLink Plugin Scope

## Runtime Role

GrimmLink is the KOReader Companion plugin for Grimmory.

- active repository: `0xstillb/grimmlink`
- active package path: `grimmlink.koplugin`
- backend implementation lives in the separate `grimmory` repository

## MVP Scope

The release-candidate scope includes:

- Grimmory server URL configuration
- `x-auth-user` and `x-auth-key` authentication
- hash-based book matching
- KOReader-native progress pull/push
- reading session upload and offline replay
- local/remote conflict prompting
- Shelf Sync with tracked-download safety rules
- annotation, bookmark, and rating sync
- opt-in auto-update from `0xstillb/grimmlink`
- optional Web Reader Bridge
- optional best-effort EPUB CFI conversion for bridge flows

## Required Safe Defaults

These defaults are part of the supported contract:

- `two_way_shelf_delete_sync = false`
- `delete_sdr_on_book_delete = false`
- `web_reader_bridge_enabled = false`
- `cfi_conversion_enabled = false`
- `auto_update_enabled = false`
- `check_update_on_startup = false`

## Backend Contract

Active endpoint families:

- `/api/koreader/users/auth`
- `/api/koreader/books/by-hash/{bookHash}`
- `/api/koreader/syncs/progress/{bookHash}`
- `/api/koreader/books/{bookId}/web-progress`
- `/api/koreader/books/{bookId}/cfi/resolve`
- `/api/v1/reading-sessions/**`
- Shelf Sync endpoints
- annotation/bookmark/rating endpoints

## Safety Invariants

- Shelf Sync is shelf membership sync only
- no Grimmory library/server files are deleted
- no Grimmory book records are deleted
- local Shelf Sync deletion only targets GrimmLink-tracked downloads
- `.sdr` deletion stays optional and default OFF
- annotation pull never silently overwrites a local user note/highlight
- native KOReader sync remains independent of the Web Reader Bridge
- Web Reader Bridge stays optional and default OFF
- EPUB CFI conversion stays best-effort and default OFF
- Auto Update uses the GrimmLink release repo only
- updater installs must preserve settings, database, cache, downloaded books, and `.sdr`

## Web Reader Bridge

The bridge is additive, not a replacement for native sync:

- bridge reads/writes separate Web Reader progress endpoints
- bridge never replaces native KOReader `/syncs/progress`
- failed conversion must not block reading or native sync
- raw KOReader location/page/xpointer remains preserved

Conflict rules:

- KOReader newer: push to bridge when enabled and safe
- Web Reader newer: prompt before jump
- both changed: show `Use KOReader`, `Use Web Reader`, `Ignore`
- uncertain conversion: keep both sides and avoid silent overwrite

## Out Of Scope

- new major sync features
- Hardcover sync expansion
- library delete behavior
- book-record delete behavior
- updater behavior that removes user content
- large unrelated refactors
