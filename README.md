# GrimmLink

KOReader Companion for Grimmory.

This repository is the active plugin home for GrimmLink:

- release repo: [0xstillb/grimmlink](https://github.com/0xstillb/grimmlink)
- package folder: `grimmlink.koplugin`
- backend counterpart: the separate `grimmory` repository

## What GrimmLink Does

GrimmLink currently supports:

- KOReader companion authentication with `x-auth-user` and `x-auth-key`
- hash-based book matching against Grimmory
- KOReader-native progress pull and push
- reading session upload plus offline queue replay
- Shelf Sync for shelf membership and tracked downloads
- annotation, bookmark, and rating sync
- optional auto-update from `0xstillb/grimmlink`
- optional Web Reader Bridge for Grimmory's web reader progress
- best-effort EPUB CFI conversion for bridge-only scenarios

## Install

1. Download the latest release from [0xstillb/grimmlink releases](https://github.com/0xstillb/grimmlink/releases).
2. Use either release asset:
   - `grimmlink.koplugin.zip`
   - `grimmlink-vX.Y.Z.zip`
3. Extract the archive and copy `grimmlink.koplugin` into KOReader's `plugins` directory.
4. Fully restart KOReader.
5. Open **Tools -> GrimmLink** and configure:
   - Grimmory server URL
   - KOReader username
   - `x-auth-key`
   - device name / device ID
6. Run **Test Connection** before enabling optional sync features.

## Safe Defaults

These defaults are intentional and should remain safe on a fresh install:

- `two_way_shelf_delete_sync = false`
- `delete_sdr_on_book_delete = false`
- `web_reader_bridge_enabled = false`
- `cfi_conversion_enabled = false`
- `auto_update_enabled = false`
- `check_update_on_startup = false`

## Core Sync Behavior

### Native KOReader progress

- pulls remote KOReader-native progress on book open
- pushes KOReader-native progress on close, suspend, and manual sync
- keeps raw KOReader location/progress/xpointer data intact
- continues working even when the Web Reader Bridge is disabled

### Offline queue

- failed session uploads are queued locally
- queued work can replay automatically when connectivity returns
- **Sync Pending Now** can flush queued sessions manually

## Shelf Sync

Shelf Sync is intentionally conservative:

- it is shelf membership sync only
- it never deletes Grimmory library/server files
- it never deletes Grimmory book records
- local deletion only applies to GrimmLink-tracked downloads
- local deletion only happens when `two_way_shelf_delete_sync` is explicitly enabled
- `.sdr` deletion is optional and defaults to OFF

## Annotation Sync

GrimmLink supports:

- annotation push
- bookmark push
- rating push
- safe remote pull / two-way merge
- duplicate prevention by stable dedupe key

Safety rules:

- local user annotations are not silently overwritten
- raw KOReader xpointer/page data remains preserved
- annotation sync does not depend on EPUB CFI conversion

## Auto Update

The updater is restricted to the official GrimmLink release source:

- repo: `0xstillb/grimmlink`
- expected assets:
  - `grimmlink.koplugin.zip`
  - `grimmlink-vX.Y.Z.zip`

Startup update checks require both `auto_update_enabled = true` and `check_update_on_startup = true`; flipping only `check_update_on_startup` will not trigger a check on its own.

Update safety rules:

- install always requires user confirmation
- user settings are preserved
- local database/cache are preserved
- downloaded books are preserved
- `.sdr` directories are preserved
- the updater backs up the current plugin before replacement

## Web Reader Bridge

The Web Reader Bridge is optional and separate from native KOReader sync:

- disabled by default
- only reads/writes dedicated web-progress endpoints
- prompts before applying newer remote Web Reader progress
- does not replace native KOReader `/syncs/progress`
- keeps native KOReader sync working independently when disabled

### EPUB CFI conversion

- disabled by default
- best-effort only
- safe fallback is percentage/page/raw-location based
- failed conversion must not block reading or native sync

## CI And Checks

Primary CI workflow: `.github/workflows/ci.yml`

It verifies:

- Lua syntax
- active plugin tests via `./run_tests.sh`
- updater source safety
- accidental ZIP artifact commits

The plugin CI does not require:

- a real KOReader runtime
- a live Grimmory server
- secrets
- real GitHub update installs

## Repository Layout

- `grimmlink.koplugin/`: active plugin package
- `grimmlink.koplugin/test/`: active plugin test surface
- `.github/workflows/ci.yml`: branch CI checks
- `.github/workflows/release.yml`: tagged release packaging
- `docs/PLUGIN_SCOPE.md`: scope and safety boundaries
- `docs/TEST_PLAN.md`: manual and CI verification guidance
- `docs/RELEASE.md`: release candidate checklist

## Known Limitations

- KOReader device/runtime validation is still required on real hardware
- EPUB CFI conversion is best-effort and not guaranteed exact for every EPUB
- local development on this machine may rely on CI for Lua runtime validation if the Lua toolchain is unavailable
