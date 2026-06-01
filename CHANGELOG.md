# Changelog

# [Unreleased]

### Notes
- Ongoing development branch.

# [v1.4.5]

### Fixes
- Fixed `normalizePercent` NaN handling in `grimmlink_util.lua` so CI/runtime behavior is consistent under Lua 5.1 (`tonumber("NaN")` now returns `nil` outcome in normalization flow).
- Confirmed plugin test suite and CI guard checks pass after the fix.

# [v1.4.4]

### Features
- Added queue/action modularization:
  - `grimmlink_pending_sync.lua`
  - `grimmlink_progress_sync.lua`
  - `grimmlink_matching.lua`
  - `grimmlink_deletion.lua`
  - `grimmlink_menu_actions.lua`
  - `grimmlink_util.lua`
- Added context-aware GrimmLink top-level menu behavior while reading:
  - focused reading-mode actions (`Pull Remote Progress`, `Manual Reading Status`, `Sync Summary`)
  - reduced top-level clutter in reader context.

### Improvements
- Refactored large menu construction paths to reduce duplication and improve maintainability.
- Moved Maintenance menu builder and status/reader menu helpers into `grimmlink_menu_actions.lua`.
- Standardized utility delegation and queue counter helpers to simplify core flow code.

### Fixes
- Hardened menu action/test environment compatibility (`ffi/util` fallback in menu-actions module tests).
- Added and expanded tests for extracted modules and menu behavior.
- Preserved CI guard compatibility for updater repo, endpoint policy, naming policy, and logging safety checks.

# [v1.4.3]

### Features
- Connection setup now includes both Local URL and Remote URL in one flow, with optional nickname fields inline (`Home URL Nickname`, `Remote URL Nickname`).
- Added friendly target labeling in connection tests: `Active server` now prefers configured nickname, then falls back to `Local`/`Remote`.
- Added split test modes:
  - `Test Connection`: concise output
  - `Test Connection with Diagnostics`: extended route/failure details
- Added richer debug export for connection routing and recent test outcomes.

### Fixes
- Reworked URL routing to local-first policy without requiring SSID detection; temporary remote fallback is driven by recent local transport failures/cooldown.
- Fixed fallback stickiness by keeping primary URL stable and preventing unintended permanent server URL switching.
- Prevented `Test Connection` from double-wait behavior by disabling fallback retry during the test attempt.
- Reduced perceived UI freeze during connection tests:
  - shorter auth test timeouts
  - immediate `Testing connection...` popup with explicit duration output
- Reduced wake/resume lag by deferring resume-time network work and adding a post-resume grace window to avoid duplicate immediate network-trigger sync.
- Updated connection menu structure to reduce extra items by moving nickname input into Local/Remote URL edit flows.

# [v1.4.0]

### Features
- Added Shelf Sync v2 schema + migration (`shelf_type`) for multi-shelf-safe tracking in `shelf_sync_map`, `pending_shelf_removals`, and `shelf_sync_tombstones`
- Added Magic Shelf API support in GrimmLink (`/api/koreader/shelves/{shelfType}/{shelfId}/books`) with regular-endpoint fallback
- Added regular/magic shelf picker groups and typed shelf labels (`[Regular]`, `[Magic]`)
- Added optional separate Magic Shelf download directory settings
- Added multi-shelf local-delete safety: keep local file when the book is still tracked by another synced shelf
- Added rule-based magic shelf remove handling support path (backend may return unsupported; no server/library file deletion)
- Added local metadata extractor foundation for KOReader DocSettings (rating, highlights/notes, bookmarks)
- Added local pending metadata queue with stable dedupe keys and synced-history tracking
- Added metadata batch upload worker (`syncPendingMetadata`) targeting Grimmory `POST /api/koreader/syncs/metadata`
- Added Metadata Sync settings: enable switch plus per-type toggles for rating, highlights/notes, and bookmarks
- Added metadata retry/drop policy: retry failed items with max retry cap, drop invalid items with safe logging
- Added `Preview Metadata` menu action showing rating/count diagnostics and pending metadata total
- Added file logger rotation/cleanup with sensitive-value redaction and new `Clear Logs` maintenance action
- Added `Export GrimmLink Debug Info` with redacted connection/auth fields and queue diagnostics
- Added per-book tracking state (default enabled) and tracking-aware sync guards for open/close/session/metadata flows
- Added guarded FileManager long-press integration for per-book actions when hold-menu APIs are available
- Added conservative network QoL settings for manual/offline sync confirmation and resume-triggered pending sync cooldown
- Added Maintenance/Data Management actions for local queues/history/tombstones with confirmation prompts and DB status counters
- Added current-book maintenance helpers: rebuild metadata queue, force metadata resync, and re-match current book
- Added manual KOReader read-status UI with backend capability detection and status labels (Reading/Read/Unread/On Hold/Abandoned/Re-reading)
- Added explicit shelf ID validation/save flow with selectable shelf type (`regular`/`magic`) using KOReader shelf APIs
- Added per-book disk-space checks before shelf downloads with safe skip-and-continue behavior when storage is insufficient
- Added KOReader backend endpoints for supported manual statuses and manual status updates
- Added CI guards for forbidden legacy endpoints, legacy naming drift, risky secret logging, and plugin structure validation

### Notes
- Metadata sync is upload-only in this phase (KOReader/GrimmLink -> Grimmory)
- No metadata pull-to-KOReader behavior yet
- No deletion sync behavior in this phase
- Shelf sync local cleanup only applies to GrimmLink-managed local files; server/library files are never deleted
- Simultaneous regular+magic auto-run is currently partial: when both are enabled, regular shelf runs first
- If free-space checks are unavailable on a device build, shelf download proceeds with a safe warning (no crash/no forced block)

# [v1.3.3]

### Features
- Settings Tab: inject a dedicated GrimmLink tab into the KOReader menu bar (toggleable via Settings → Settings Tab; takes effect after restart)
- Reader menu: new "Pull Remote Progress" item opens the local/remote conflict dialog for the current book
- Update install: replaced silent toast with a ConfirmBox offering "Restart Now" or "Later"

# [v1.3.2]

### Fixes
- Kindle compatibility: lfs fallback `attributes()` now checks `test -d` before `io.open()` — on Linux `io.open()` succeeds on directories causing shelf sync to resolve the wrong download path
- Kindle compatibility: shelf sync now downloads books to `/mnt/us/documents/Book/` so Kindle's native library indexes them automatically

# [v1.3.1]

### Fixes
- Kindle compatibility: make `lfs` (LuaFileSystem) optional so the plugin loads on Kindle KOReader builds where the module is unavailable — previously caused "GrimmLink is still starting up" on every action

# [v1.2.0]

### Features
- Series metadata support for SimpleUI browsing — books with series info are now organized in SimpleUI's "Browse by Series"
- Redesigned menu structure with grouped settings and `keep_menu_open` on toggles
- Redesigned shelf sync completion dialog with aligned labels and bullet points

### Fixes
- Database migration crash when adding series columns (ljsqlite3 PRAGMA compatibility)
- Lazy-load SQ3 and json modules to avoid startup crashes on missing dependencies
- Fixed bookinfo_cache path and directory trailing-slash matching
- Wrapped db:init() in pcall to prevent cascading init failures
- Fixed Unicode em-dash mojibake on KOReader e-ink display
- Resolved empty download_dir causing metadata index to not be created

# [v1.1.0]

### Features
- Shelf sync with automatic book downloading
- Two-way delete sync
- Fast sync with configurable cache duration
- PDF web reader bridge for progress sync
- Auto-update from GitHub releases

# [v1.0.0]

- Initial release — reading progress and session sync with Grimmory server
