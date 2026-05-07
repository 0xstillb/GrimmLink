# GrimmLink

GrimmLink is the KOReader companion plugin for Grimmory.

Stable minimal scope:

- Server URL, Username, and Password authentication
- hash-based book matching
- native KOReader progress sync for EPUB, PDF, CBX, and other supported book types
- reading session upload with offline replay
- shelf sync with tracked-download safety rules
- PDF-only Web Reader Bridge
- opt-in auto update

## Important Notes

- The plugin generates `x-auth-key` internally from the entered Password.
- The user never types an auth key, token, or MD5 hash.
- EPUB Web Reader Bridge is intentionally out of scope.
- PDF Web Reader Bridge is optional and disabled by default.
- Remote progress is never applied silently. The user is prompted before jumping to newer remote progress.

## Install

1. Download the latest release asset for `grimmlink.koplugin`.
2. Extract the archive into KOReader's `plugins/` directory.
3. Restart KOReader.
4. Open `Tools -> GrimmLink`.
5. Configure:
   - Grimmory Server URL
   - KOReader Username
   - Password
6. Run `Test Connection`.

## Safe Defaults

| Setting | Default | What it does |
|---|---|---|
| `pdf_web_reader_bridge_enabled` | `false` | Enables the PDF-only Web Reader Bridge. |
| `two_way_shelf_delete_sync` | `false` | Mirrors tracked shelf deletions into local cleanup. |
| `delete_sdr_on_book_delete` | `false` | Also removes local `.sdr` sidecars when deleting a tracked book. |
| `auto_update_enabled` | `false` | Allows the in-app updater to install GrimmLink updates. |
| `check_update_on_startup` | `false` | Checks for updates during startup when auto-update is enabled. |

## Core Behavior

### Native KOReader sync

- Pull remote progress when a book opens.
- Prompt before jumping to newer remote progress.
- Push local progress on close, suspend, or manual sync.
- Queue failed progress and session uploads for later replay.

### PDF Web Reader Bridge

- Only runs for PDF files.
- Uses `/api/koreader/books/{bookId}/pdf-progress` only.
- Supports KOReader -> Web Reader pushes.
- Supports Web Reader -> KOReader prompts before jumping.

### Shelf Sync

- Downloads shelf books to local storage.
- Never deletes Grimmory library files or records.
- Only removes local files that GrimmLink downloaded and tracked.

## Release Note

> EPUB Web Reader Bridge is intentionally disabled/out of scope. KOReader-to-KOReader sync remains supported for EPUB via native KOReader progress. PDF Web Reader Bridge supports page-based sync between KOReader and Grimmory Web Reader. Authentication uses Server URL, Username, and Password; the plugin generates x-auth-key internally. Remote progress is never applied silently; the user is prompted before jumping to newer remote progress.

## Repository Layout

| Path | Purpose |
|---|---|
| `grimmlink.koplugin/` | Active plugin package |
| `grimmlink.koplugin/test/` | Stable unit tests |
| `docs/PLUGIN_SCOPE.md` | Scope and safety boundaries |
| `docs/TEST_PLAN.md` | Manual and CI verification guidance |

## Credits

GrimmLink is a fork and adaptation of the upstream BookLoreSync plugin by WorldTeacher.
