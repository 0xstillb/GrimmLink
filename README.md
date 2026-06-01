# GrimmLink

A KOReader companion plugin for [Grimmory (0xstillb fork)](https://github.com/0xstillb/grimmory).

GrimmLink is designed specifically for Grimmory workflows: reading sync, session sync, metadata upload, shelf download/sync, and recovery tooling.

## At A Glance

- Two-way reading progress sync (push + pull)
- Reading session sync with retry queues
- Metadata upload sync (rating/highlights/notes/bookmarks)
- Shelf sync (Regular + Magic) with safe local file handling
- Queue/DB maintenance and debug export tools

## Quick Start

1. Download `grimmlink.koplugin.zip` from [Releases](https://github.com/0xstillb/GrimmLink/releases/latest).
2. Extract into KOReader `plugins/`.
3. Restart KOReader.
4. Open `Tools -> GrimmLink -> Connection`.
5. Set Local URL, optional Remote URL, username, password.
6. Run `Test Connection with Diagnostics`.

## Connection Model

GrimmLink uses a local-first routing strategy:

- Prefer Local URL when available
- Temporarily fallback to Remote URL after recent local transport failure/cooldown
- `Test Connection` uses a single-attempt test path (no sticky fallback side effects)

Authentication headers:

- `x-auth-user`
- `x-auth-key`

No Bearer token is required.

## Core Features

### Progress Sync

- Pull remote progress for the current open book
- Push local progress on close/suspend/manual sync
- Conflict prompt when local and remote progress diverge
- Reflowable formats use KOReader-native location model as source of truth

### Reading Session Sync

- Session events are queued locally
- Automatic retry when network/API becomes available

### Metadata Sync (Upload-Only)

- Upload rating, highlights/notes, bookmarks
- Local queue + retry policy
- No metadata pull-back from Grimmory in current phase

### Shelf Sync

- Regular shelf and Magic shelf sync
- Optional separate Magic folder with safe move flow
- Shared books (Regular + Magic) remain in shared/main folder
- Local deletion safety with mapping/tombstone/retry tracking

### Maintenance & Recovery

- Queue cleanup tools
- Book info cache rebuild
- Current-book repair actions
- Redacted debug export
- DB/pending counters summary

## Menu Behavior

### Reader Top Menu (GrimmLink tab)

- GrimmLink tab is injected in Reader menu
- Current default icon: `book.opened`

### GrimmLink Top-Level Menu (context aware)

When **no book is open**:

- Enable GrimmLink
- Connection
- Sync Pending Now
- Sync Shelf Now
- Advanced Setting
- Status / About

When **a book is open**:

- Enable GrimmLink
- Sync Pending Now
- Pull Remote Progress
- Manual Reading Status
- Sync Summary

## Important Settings

| Setting | Default | Description |
|---|---|---|
| `metadata_sync_enabled` | `false` | Enable metadata sync pipeline |
| `device_name` | KOReader device model | Friendly device name sent with progress, sessions, and metadata |
| `device_id` | Generated stable ID | Stable device identifier used to distinguish readers |
| `e_reader_friendly_mode` | `false` | Enables a conservative network preset for e-reader sleep/resume workflows |
| `sync_regular_shelf_enabled` | `false` | Enable Regular shelf sync |
| `sync_magic_shelf_enabled` | `false` | Enable Magic shelf sync |
| `use_separate_magic_download_dir` | `false` | Use a separate directory for Magic-only files |
| `network_sync_cooldown_seconds` | `300` | Cooldown before next auto network sync |
| `pending_shelf_removal_retry_cooldown_seconds` | `30` | Retry cooldown for pending shelf removals |
| `auto_update_enabled` | `false` | Enable plugin auto-update checks |

## Required Grimmory API Endpoints

- `GET /api/koreader/users/auth`
- `GET /api/koreader/books/by-hash/{hash}`
- `GET /api/koreader/syncs/progress/{hash}`
- `PUT /api/koreader/syncs/progress`
- `POST /api/v1/reading-sessions`
- `POST /api/v1/reading-sessions/batch`
- `POST /api/koreader/syncs/metadata`
- `GET /api/koreader/shelves`
- `GET /api/koreader/shelves/{type}/{id}/books`
- `POST /api/koreader/shelves/{type}/{id}/books/{bookId}/remove`
- `GET /api/koreader/books/read-statuses`
- `PUT /api/koreader/books/{bookId}/status`
- `GET /api/koreader/books/{bookId}/pdf-progress`
- `PUT /api/koreader/books/{bookId}/pdf-progress`

## Safety & Privacy

- No password or raw `x-auth-key` in logs
- No full payload dumps for sensitive content
- Local destructive operations are confirmation-gated
- GrimmLink does not delete files outside its managed local scope

## Plugin Structure

```text
grimmlink.koplugin/
  main.lua
  grimmlink_api_client.lua
  grimmlink_database.lua
  grimmlink_shelf_sync.lua
  grimmlink_pending_sync.lua
  grimmlink_progress_sync.lua
  grimmlink_matching.lua
  grimmlink_deletion.lua
  grimmlink_menu_actions.lua
  grimmlink_util.lua
  grimmlink_updater.lua
  grimmlink_metadata_extractor.lua
  plugin_version.lua
  _meta.lua
  test/
```

## CI Expectations

CI must pass before release:

- Lua syntax checks
- Full test suite
- Updater repo guard (`0xstillb/grimmlink`)
- Legacy endpoint/naming guards
- Secret logging guard
- Plugin structure and packaging guards

## License

MIT
