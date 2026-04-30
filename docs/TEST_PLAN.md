# GrimmLink Plugin Test Plan

## Current Automated Test Target

The active GrimmLink automated tests live under:

- `grimmlink.koplugin/test/`

Legacy upstream BookLoreSync tests now live under:

- `legacy/upstream-bookloresync-tests/`

They should be treated as reference/archive material and are not part of the active GrimmLink MVP gate.

## MVP Verification Goals

- verify Grimmory auth integration
- verify hash-based book matching
- verify KOReader-native progress pull and push
- verify reading session upload and batch replay
- verify offline queue behavior
- verify Moon+ Reader-like conflict flow
- verify no Web Reader bridge or EPUB CFI behavior is introduced

## Backend Integration Checks

Expected backend endpoints:

- `GET /api/koreader/users/auth`
- `GET /api/koreader/books/by-hash/{bookHash}`
- `GET /api/koreader/syncs/progress/{bookHash}`
- `PUT /api/koreader/syncs/progress`
- `POST /api/v1/reading-sessions`
- `POST /api/v1/reading-sessions/batch`
- `GET /api/koreader/shelves`
- `GET /api/koreader/shelves/{shelfId}/books`
- `GET /api/koreader/books/{bookId}/download`
- `POST /api/koreader/shelves/{shelfId}/books/{bookId}/remove`

## Manual KOReader Runtime Checks

1. Install `grimmlink.koplugin` into KOReader's plugins directory.
2. Configure:
   - Grimmory server URL
   - username
   - auth key
   - device name
   - device ID
3. Run `Test Connection`.
4. Open a book that exists in Grimmory.
5. Confirm hash match succeeds.
6. Confirm remote progress is pulled when available.
7. Read forward and close the book.
8. Confirm local progress is pushed or queued.
9. Reopen with a meaningful local/remote difference.
10. Verify:
   - `Use Local`
   - `Use Remote`
   - `Ignore`
11. Repeat with the server offline, then use `Sync Pending Now`.

## Expected Sync Semantics

- percentage is treated as `0..100`
- raw KOReader location is preferred for remote jump
- page fallback is allowed if raw jump is unavailable
- percentage fallback is allowed only as a last safe option
- reading must continue even if sync fails

## Offline Queue Checks

- progress queue survives restart
- session queue survives restart
- failed requests remain queued
- retry count increases on repeated failures
- manual sync flushes pending items when online

## Shelf Sync Checks

- shelf selection persists in settings
- shelf sync downloads missing books into the configured or auto-detected download directory
- already-downloaded GrimmLink-managed files are skipped
- local shelf deletions only remove tracked files when `two_way_shelf_delete_sync` is enabled
- local shelf deletions never call the library delete API
- shelf removals never delete user-added files
- `.sdr` removal only happens when `delete_sdr_on_book_delete` is enabled
- public shelves remain read-only from the plugin's perspective unless the backend authorizes a membership mutation

## Explicit Non-Goals For This Test Phase

- Web Reader Bridge
- EPUB CFI conversion
- rating sync
- highlights/notes sync
- bookmarks sync
- shelf sync

If any of those appear during GrimmLink MVP testing, treat that as drift from scope rather than as a missing MVP feature.
