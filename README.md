# GrimmLink

A KOReader companion plugin for [Grimmory (0xstillb fork)](https://github.com/0xstillb/grimmory).

GrimmLink is designed specifically for Grimmory workflows: reading sync, session sync, metadata upload, shelf download/sync, and recovery tooling.

## At A Glance

- Two-way reading progress sync (push + pull)
- Reading session sync with retry queues
- Metadata upload sync (rating/highlights/notes/bookmarks)
- Shelf sync (Regular + Magic) with safe local file handling
- First-run setup wizard for core connection/device onboarding
- Settings backup/restore for GrimmLink configuration
- Historical import from KOReader `statistics.sqlite3`
- Local diagnostics bundle export with redacted secrets
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
- Historical KOReader session import
- Local diagnostics bundle export
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
- Reading Completion
- Sync Pending Now
- Pull Remote Progress
- Manual Reading Status
- Sync Summary

### First-Time Setup

- `Connection > First Run Setup Wizard` guides the minimum recommended setup
- Covers local Grimmory URL, KOReader username, password, device name, and optional `E-reader Friendly Mode`
- GrimmLink prompts once on fresh installs that do not have a working connection configured yet

### Settings Backup

- `Advanced Setting > Setup & Backup > Export Settings Backup` writes a snapshot to `KOReader/settings/Grimmlink-setting-backup/grimmlink-settings-backup.json`
- `Advanced Setting > Setup & Backup > Restore Settings Backup` defaults to the same `KOReader/settings/Grimmlink-setting-backup` location
- The backup includes connection credentials, so treat the file as sensitive

### Historical Import

- `Maintenance > Quick Actions > Import KOReader Reading History` reads KOReader's `statistics.sqlite3`
- Default path is `KOReader/settings/statistics.sqlite3`, but you can edit the path before import
- Imported history is grouped into reading sessions and queued through GrimmLink's normal `pending_sessions` pipeline
- GrimmLink keeps a local import-history dedupe record so rerunning the same import does not requeue the same sessions again
- Import does not overwrite the current live reading position; it only prepares past sessions for later sync

### Local Diagnostics Bundle

- `Status / About > Export Local Diagnostics Bundle` writes a JSON support bundle to `KOReader/settings/Grimmlink-diagnostics/grimmlink-diagnostics-bundle.json`
- The same export is also available from `Maintenance > Quick Actions`
- Includes plugin version, redacted settings snapshot, queue/database counters, connection state, and current-book context
- Passwords are redacted; usernames, URLs, SSIDs, and device IDs are reduced to safe previews

### Device Debug Hook

- GrimmLink can process a whitelist-based device debug command file for real-device QA workflows
- Command file path: `KOReader/settings/grimmlink-device-command.json`
- Result file path: `KOReader/grimmlink-device-result.json`
- Trace file path: `KOReader/grimmlink-device-trace.txt`
- Supported commands: `ping`, `queue_summary`, `current_context`, `diagnostics_bundle`, `sync_pending`

### Reading Completion Flow

- `Reading Completion` opens a current-book action menu while reading
- When KOReader fires its end-of-book flow, GrimmLink waits for KOReader's own `end of document` dialog to close before showing its completion menu
- When a book closes at `99%+` without going through that end-of-book flow, GrimmLink keeps a close-book fallback prompt
- Includes `Finish & Sync Now`, `Mark as Read`, `Set Rating`, and `Cancel`
- `Set Rating` uses a `1-10` completion score and mirrors it back into KOReader's local `1-5` star summary so the local reading UI still stays in sync
- Uses existing manual read-status support when the backend exposes `READ`
- The close-book prompt is `once per completion cycle` on the device and resets automatically if progress later drops below `95%` during a reread

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
  grimmlink_connection_controller.lua
  grimmlink_constants.lua
  grimmlink_database.lua
  grimmlink_deletion.lua
  grimmlink_diagnostics_controller.lua
  grimmlink_file_logger.lua
  grimmlink_filemanager_actions.lua
  grimmlink_lifecycle_controller.lua
  grimmlink_maintenance_controller.lua
  grimmlink_magic_shelf_controller.lua
  grimmlink_matching.lua
  grimmlink_pending_sync_controller.lua
  grimmlink_menu_actions.lua
  grimmlink_menu_builder.lua
  grimmlink_metadata_controller.lua
  grimmlink_metadata_extractor.lua
  grimmlink_pending_sync.lua
  grimmlink_progress_controller.lua
  grimmlink_progress_sync.lua
  grimmlink_reading_completion_controller.lua
  grimmlink_runtime_controller.lua
  grimmlink_settings_controller.lua
  grimmlink_session_controller.lua
  grimmlink_shelf_controller.lua
  grimmlink_shelf_sync.lua
  grimmlink_tracking_controller.lua
  grimmlink_updater.lua
  grimmlink_util.lua
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
