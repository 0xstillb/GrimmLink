# Changelog

# [Unreleased]

# [v1.5.2]

### Fixes
- Fixed disabling the separate Magic Shelf folder so confirming "Move Magic Shelf files back to the shared folder" can move files even when duplicate Magic Shelf mappings for the same book are stored in the local shelf map.

### Tests
- Added shelf-sync coverage for moving Magic Shelf-only files back to the shared download directory, including duplicate mapping ordering.

# [v1.5.1]

### Fixes
- Fixed Kindle/legacy-database shelf sync failures where `pending_shelf_removals` could still be on the pre-`shelf_type` schema and crash with `no such column: shelf_type`.
- Made schema repair fail fast when shelf sync table migrations do not complete, instead of silently continuing with an incompatible database schema.
- Made pending queue replay resilient to single-step crashes so one broken queue no longer blocks the rest of the pending sync pass.
- Added async shelf-download fallback to blocking downloads when curl/wget startup or monitoring fails on-device.
- Fixed shelf-sync snapshot fast-path so stale local shelf mappings still run cleanup instead of being skipped when the snapshot token is unchanged.
- Fixed two-way regular-shelf deletions when `download_dir` is blank by resolving the auto-managed `/Book` directory before applying local delete safety checks.
- Fixed stale orphan shelf mappings from previously selected shelves so they no longer block local cleanup for the currently selected Regular/Magic shelves.

### Improvements
- Added short follow-up pending-sync rounds after resume/network reconnect so large offline backlogs can drain in smaller slices on e-readers.
- Increased pending shelf-removal drain throughput during shelf sync so large shelves clear queued removals faster on low-power devices.

### Tests
- Added coverage for pending-sync step isolation and summary reporting.
- Added helper-spec coverage for batched pending-sync follow-ups and async-download fallback to blocking shelf downloads.

# [v1.5.0]

### Improvements
- Ignored `.agents/` in `.gitignore` so local agent workflow files stay out of normal git status and release commits.

# [v1.4.11]

### Improvements
- Updated `generate-version.sh` so release sync no longer regenerates the deprecated `_meta.lua.name` field.

# [v1.4.10]

### Improvements
- Extracted progress snapshot, push/pull, pending-progress replay, and PDF bridge helpers into `grimmlink_progress_controller.lua`.
- Extracted reading session lifecycle and pending-session replay helpers into `grimmlink_session_controller.lua`.
- Extracted updater, queue cleanup, database status, and maintenance menu actions into `grimmlink_maintenance_controller.lua`.
- Extracted runtime shell, tracking/context helpers, and pending-sync orchestration so `main.lua` now acts as a composition root.
- Added a whitelist-based device debug command hook so GrimmLink functions can be exercised from ADB via command/result files.
- Removed the deprecated `_meta.lua.name` field so KOReader no longer warns about GrimmLink plugin metadata during startup.

### Tests
- Confirmed progress payload, conflict/apply, offline queue, and PDF bridge coverage after controller extraction.
- Confirmed session open/close, pending-session replay, and lifecycle callback coverage after controller extraction.
- Confirmed updater flow, queue cleanup prompts, quick cleanup, and startup update-check coverage after maintenance extraction.
- Re-ran helper specs and full plugin suite after the final main.lua cleanup.
- Added coverage for device debug command execution, result-file processing, and lifecycle-triggered command checks.

# [v1.4.9]

### Improvements
- Extracted lifecycle and dispatcher wiring into `grimmlink_lifecycle_controller.lua` without changing sync core behavior.
- Extracted shelf sync orchestration, progress UI, shelf cache, and shelf picker helpers into `grimmlink_shelf_controller.lua`.

### Tests
- Added lifecycle callback coverage for reader ready, close/suspend, end-of-book prompts, resume sync scheduling, teardown, and dispatcher actions.
- Confirmed shelf sync orchestration remains covered by focused helper and shelf sync specs after controller extraction.

# [v1.4.8]

### Features
- Added `Reading Completion` to the reader top-level GrimmLink menu for current-book finish actions in one place.
- Added a reading completion action flow with `Finish & Sync Now`, `Mark as Read`, `Set Rating`, and `Cancel`.
- Added an automatic close-book Reading Completion prompt for books finished at `99%+`.
- Added a KOReader end-of-book Reading Completion prompt that waits for KOReader's own end-of-document dialog to close first.
- Added a `First Run Setup Wizard` for core connection, credentials, device name, and recommended e-reader mode onboarding.
- Added GrimmLink settings backup/restore actions with a portable JSON backup file stored under `KOReader/settings/Grimmlink-setting-backup`.
- Added `Historical Import` from KOReader `statistics.sqlite3`, grouped into GrimmLink pending reading sessions.
- Added `Local Diagnostics Bundle` export with a redacted JSON snapshot for support/debug workflows.

### Improvements
- Reused backend-supported `READ` status actions inside the completion flow when available.
- Reused the same Reading Completion actions for the in-book menu, the KOReader end-of-book prompt, and the delayed close-book fallback prompt.
- Made the Reading Completion prompt Kindle-friendly by waiting on KOReader's `end_document` widget instead of relying only on a timing delay, while keeping local once-per-completion-cycle dedupe.
- Upgraded Reading Completion `Set Rating` to a WorldTeacher-style `1-10` score while still mirroring KOReader's local `1-5` stars for device-native display consistency.
- Auto-marked older already-configured installs as setup-complete so the first-run prompt only targets genuinely unconfigured devices.
- Added local historical-import dedupe tracking so rerunning the same KOReader history import does not requeue the same sessions repeatedly.
- Refactored major GrimmLink flows into focused controller/helper modules while preserving the existing KOReader lifecycle entrypoints.

### Fixes
- Updated metadata rating dedupe keys so changing a rating can queue a fresh metadata sync instead of being skipped as already-synced history.
- Prevented delayed Reading Completion prompts from reusing the live DocSettings object for the wrong book if another document opens immediately after close.
- Preserved exact odd completion ratings like `7/10` in metadata sync payloads instead of collapsing them to KOReader-only `1-5` star values.

### Tests
- Added Reading Completion menu coverage and current-book rating persistence tests.
- Added close-book Reading Completion prompt coverage, prompt dedupe coverage, and reread reset coverage.
- Added KOReader end-of-book prompt coverage and end-dialog wait coverage.
- Added exact `1-10` rating extraction, payload, and dedupe coverage.
- Added helper/menu coverage for first-run setup prompting, setup wizard save flow, and settings backup payload restore.
- Added diagnostics bundle path/redaction coverage, historical page-stat grouping coverage, and historical import dedupe coverage.
- Added database coverage for historical import dedupe storage helpers.
- Added helper coverage for the extracted controllers and menu builder paths.

# [v1.4.7]

### Features
- Added `E-reader Friendly Mode` under `Advanced Setting > Tracking & Network` as a conservative network preset for e-reader sleep/resume workflows.

### Improvements
- Added network mode status to debug export and Tracking & Network menu.

### Tests
- Added menu and preset coverage for E-reader Friendly Mode.
- Confirmed focused helper specs and full Lua spec suite pass locally.

# [v1.4.6]

### Features
- Added configurable Device Identity settings under `Advanced Setting > Device Identity`.
- Added editable `device_name` and `device_id` values for progress, session, and metadata sync payloads.

### Improvements
- Normalized configured device identity text by trimming extra whitespace and collapsing repeated spaces.
- Updated debug export to show the configured device name instead of only the default KOReader model.
- Documented `device_name` and `device_id` in README settings.

### Tests
- Added menu and save-flow coverage for Device Identity settings.
- Confirmed focused helper specs and full Lua spec suite pass locally.

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
