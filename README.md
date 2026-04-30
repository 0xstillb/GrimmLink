# GrimmLink

KOReader Companion for Grimmory

This repository is the dedicated KOReader plugin home for GrimmLink.

## Current Scope

GrimmLink currently supports:

- KOReader authentication with `x-auth-user` and `x-auth-key`
- book matching by hash against Grimmory
- KOReader-native progress pull and push
- reading session upload and offline batch replay
- Moon+ Reader-like local/remote progress comparison
- Shelf Sync with safe tracked-download deletion rules only
- Annotation push sync plus safe remote pull / two-way merge
- Auto Update using `0xstillb/grimmlink` releases only
- Prompt 8 Web Reader Bridge
  - `web_reader_bridge_enabled = false` by default
  - `cfi_conversion_enabled = false` by default
  - Web Reader Bridge is optional and does not replace native KOReader sync
  - EPUB CFI conversion is best-effort only
  - failed conversion falls back cleanly and does not block reading

## Important Safety Rules

- Shelf Sync is shelf membership sync only, not library delete sync
- GrimmLink never deletes Grimmory library/server files
- GrimmLink never deletes Grimmory book records
- raw KOReader location/page/xpointer remains preserved
- local user annotations are not deleted or silently overwritten during merge
- Auto Update never points to `WorldTeacher/BookLoreSync-plugin`

## Web Reader Bridge Notes

- pulls Web Reader progress on book open only when enabled
- pushes bridge progress on close/suspend/manual sync when enabled
- prompts before using newer remote Web Reader progress
- keeps KOReader-native progress working independently when bridge is disabled
- does not require EPUB CFI conversion for normal KOReader-native sync

## Installation

1. Copy `grimmlink.koplugin` into KOReader's `plugins` directory.
2. Fully restart KOReader.
3. Configure:
   - Grimmory server URL
   - username
   - auth key
   - device name / device ID

## CI

CI lives in `.github/workflows/ci.yml` and must pass before release.

It checks:

- Lua syntax
- active plugin tests
- updater repo safety
- accidental packaging artifacts

The workflow does not require:

- a real KOReader runtime
- a real Grimmory server
- secrets
- real GitHub update installs

## Repository Layout

- `grimmlink.koplugin/`: active plugin package
- `grimmlink.koplugin/test/`: active automated test surface
- `docs/PLUGIN_SCOPE.md`: current feature/safety scope
- `docs/TEST_PLAN.md`: current runtime and CI verification plan
- `docs/RELEASE.md`: release checklist

## Next Step

- Prompt 9 Full Integration / Runtime Test
