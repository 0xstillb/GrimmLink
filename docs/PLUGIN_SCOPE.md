# GrimmLink Plugin Scope

## Runtime Role

GrimmLink is the stable KOReader companion plugin for Grimmory.

- active repository: `0xstillb/grimmlink`
- active package path: `grimmlink.koplugin`
- backend implementation lives in the separate `grimmory` repository

## Stable Scope

The supported stable scope includes:

- Grimmory Server URL, Username, and Password configuration
- internal `x-auth-user` and `x-auth-key` generation
- hash-based book matching
- KOReader-native progress pull/push
- reading session upload and offline replay
- Shelf Sync with tracked-download safety rules
- PDF-only Web Reader Bridge
- opt-in auto-update

## Required Safe Defaults

- `pdf_web_reader_bridge_enabled = false`
- `two_way_shelf_delete_sync = false`
- `delete_sdr_on_book_delete = false`
- `auto_update_enabled = false`
- `check_update_on_startup = false`

## Backend Contract

Active endpoint families:

- `/api/grimmlink/v1/auth`
- `/api/grimmlink/v1/books/by-hash/{bookHash}`
- `/api/grimmlink/v1/syncs/progress/{bookHash}`
- `/api/grimmlink/v1/syncs/progress`
- `/api/grimmlink/v1/books/{bookId}/pdf-progress`
- `/api/grimmlink/v1/reading-sessions`
- `/api/grimmlink/v1/reading-sessions/batch`
- `/api/grimmlink/v1/syncs/metadata`
- `/api/grimmlink/v1/syncs/metadata/batch`
- Shelf Sync endpoints

## Safety Invariants

- Shelf Sync is shelf membership sync only
- no Grimmory library/server files are deleted
- no Grimmory book records are deleted
- local Shelf Sync deletion only targets GrimmLink-tracked downloads
- `.sdr` deletion stays optional and default OFF
- native KOReader sync remains independent of the PDF Web Reader Bridge
- PDF Web Reader Bridge stays optional and default OFF
- remote progress is never applied silently
- EPUB Web Reader Bridge is intentionally out of scope

## Out Of Scope

- EPUB CFI conversion
- `/api/grimmlink/v1/books/{bookId}/cfi/resolve`
- `/api/grimmlink/v1/books/{bookId}/web-progress`
- any automatic EPUB Web Reader Bridge flow
- new major sync features
- library delete behavior
- book-record delete behavior
- updater behavior that removes user content
