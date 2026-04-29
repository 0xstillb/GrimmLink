# GrimmLink Plugin Test Plan

## Current Automated Test Target

The active GrimmLink automated tests live under:

- `grimmlink.koplugin/test/`

The repository root `test/` directory still contains legacy upstream BookLoreSync tests and should be treated as reference/archive material until a later cleanup pass.

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

## Explicit Non-Goals For This Test Phase

- Web Reader Bridge
- EPUB CFI conversion
- rating sync
- highlights/notes sync
- bookmarks sync
- shelf sync

If any of those appear during GrimmLink MVP testing, treat that as drift from scope rather than as a missing MVP feature.
