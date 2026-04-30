# GrimmLink Plugin Scope

## Current Role

GrimmLink is the KOReader Companion plugin for Grimmory.

Backend implementation belongs in the separate `grimmory` repository.

## Current Scope

- Grimmory server URL configuration
- `x-auth-user` and `x-auth-key` authentication
- hash-based book matching
- KOReader-native progress pull/push
- reading session upload and offline replay
- Moon+ Reader-like conflict dialog
- Shelf Sync with safe tracked-download deletion rules
- annotation push sync plus safe remote pull / merge
- opt-in auto-update from `0xstillb/grimmlink`
- optional Prompt 8 Web Reader Bridge

## Web Reader Bridge (Prompt 8)

- `web_reader_bridge_enabled = false` by default
- `cfi_conversion_enabled = false` by default
- bridge reads/writes separate Web Reader progress endpoints
- bridge does not replace native KOReader `/syncs/progress`
- failed conversion must not block reading or native sync
- raw KOReader location/page/xpointer remains preserved

Conflict rules:

- KOReader newer: push to bridge when enabled and safe
- Web Reader newer: prompt before jump
- both changed: show `Use KOReader`, `Use Web Reader`, `Ignore`
- uncertain conversion: keep both sides and avoid a silent overwrite

## Important Backend Contract

Active endpoint families:

- `/api/koreader/users/auth`
- `/api/koreader/books/by-hash/{bookHash}`
- `/api/koreader/syncs/progress/{bookHash}`
- `/api/koreader/books/{bookId}/web-progress`
- `/api/koreader/books/{bookId}/cfi/resolve`
- `/api/v1/reading-sessions/**`
- shelf sync endpoints
- annotation/bookmark/rating endpoints

## Safety Invariants

- Shelf Sync is shelf membership sync only
- no Grimmory library/server files are deleted
- no Grimmory book records are deleted
- annotation pull never silently overwrites a local user note/highlight
- Web Reader Bridge is optional and default OFF
- EPUB CFI conversion is best-effort and default OFF
- Auto Update uses `0xstillb/grimmlink` only, never the old BookLoreSync repo

## Out Of Scope

- Hardcover rating sync
- large unrelated refactors
- deleting user settings/database/cache/downloaded books/.sdr during updates
- Prompt 9 runtime closeout work
