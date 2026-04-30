# GrimmLink Plugin Test Plan

## CI Gate

The branch CI workflow in `.github/workflows/ci.yml` must pass before release.

Current CI checks:

- Lua syntax via `luac -p`
- active plugin tests via `./run_tests.sh`
- updater source guard for `0xstillb/grimmlink`
- failure if release ZIP artifacts are committed

The workflow does not require:

- a real KOReader runtime
- a real Grimmory server
- secrets
- real GitHub update installs

## Local Checks

Run when the toolchain is available:

- `git diff --check`
- `./run_tests.sh`
- optional standalone Lua syntax pass (`luac -p`)

If `lua`, `luac`, `luajit`, or `busted` are unavailable locally, rely on CI and
record that limitation in the release notes.

## Core Runtime Checks

1. Install `grimmlink.koplugin`.
2. Configure Grimmory server URL, KOReader username, `x-auth-key`, device name, and device ID.
3. Run **Test Connection**.
4. Open a matched book.
5. Verify native progress pull on open.
6. Read forward and close or suspend.
7. Verify native progress push or offline queue behavior.
8. Reopen with a meaningful local/remote difference and verify:
   - `Use Local`
   - `Use Remote`
   - `Ignore`

## Offline Queue Checks

- sessions queue while offline
- queue replay preserves ordering when back online
- manual **Sync Pending Now** flush works
- duplicate replay does not create duplicate session uploads

## Shelf Sync Checks

- shelf selection persists
- tracked shelf downloads are created in the configured directory
- two-way shelf delete sync stays OFF by default
- `.sdr` deletion stays OFF by default
- only GrimmLink-tracked files are removed
- no Grimmory library/server file delete path is used
- no Grimmory book record delete path is used

## Annotation / Bookmark / Rating Checks

- remote missing locally -> safe import
- duplicate remote item -> skip
- local note edited after last remote version -> keep local, mark conflict
- suspend/close capture runs before pending sync replay
- raw KOReader xpointer/page survives push + pull
- no Web Reader annotation fields are written

## Web Reader Bridge Checks

- `web_reader_bridge_enabled` defaults to `false`
- `cfi_conversion_enabled` defaults to `false`
- with bridge disabled, native KOReader sync behavior is unchanged
- with bridge enabled, plugin pulls Web Reader progress on open
- with bridge enabled, plugin pushes bridge progress on close/suspend/manual sync
- if Web Reader progress is newer, plugin prompts before jumping
- if both sides changed, plugin offers `Use KOReader`, `Use Web Reader`, `Ignore`
- if CFI conversion fails, bridge falls back safely without blocking reading
- if conversion is disabled, percentage/page/raw-location fallback still works when possible

## Auto-Update Checks

- updater source repo is `0xstillb/grimmlink`
- release assets accepted by the updater are:
  - `grimmlink.koplugin.zip`
  - `grimmlink-vX.Y.Z.zip`
- install requires explicit confirmation
- restart prompt appears after successful install
- settings/database/cache/downloaded books remain untouched
- updater backup/rollback path remains available

## Release Packaging Checks

- `.github/workflows/release.yml` exists
- tagged release builds `grimmlink.koplugin.zip`
- tagged release also publishes `grimmlink-vX.Y.Z.zip`
- no ZIP artifacts are committed into the repository
- `grimmlink.koplugin/plugin_version.lua` is rewritten by the tagged release workflow

## Known Local Limitation

This workspace may lack a local Lua toolchain, so final runtime Lua validation
may need to happen in CI or on a KOReader-capable machine.
