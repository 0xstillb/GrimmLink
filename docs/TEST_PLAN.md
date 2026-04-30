# GrimmLink Plugin Test Plan

## CI Gate

The plugin CI workflow in `.github/workflows/ci.yml` must pass before release.

Current CI checks:

- Lua syntax via `luac -p`
- active plugin tests via `./run_tests.sh`
- updater safety guard for `0xstillb/grimmlink`
- failure if active code references `WorldTeacher/BookLoreSync-plugin`
- failure if release ZIP artifacts are committed

The workflow does not require:

- a real KOReader runtime
- a real Grimmory server
- secrets
- real GitHub update installs

## Manual KOReader Checks

1. Install `grimmlink.koplugin`.
2. Configure server URL, username, auth key, device name, and device ID.
3. Run `Test Connection`.
4. Open a matched book.
5. Verify native progress pull works.
6. Read forward, close, and verify native progress push or queue behavior.
7. Reopen with a meaningful local/remote difference and verify:
   - `Use Local`
   - `Use Remote`
   - `Ignore`

## Shelf Sync Checks

- shelf selection persists
- tracked shelf downloads are created in the configured directory
- two-way shelf delete sync stays OFF by default
- `.sdr` deletion stays OFF by default
- only GrimmLink-tracked files are removed
- no library delete endpoint is ever called

## Annotation Merge Checks

- remote missing locally -> safe import
- duplicate remote item -> skip
- local note edited after last remote version -> keep local, mark conflict
- raw KOReader xpointer/page survives push + pull
- no Web Reader annotation fields are written

## Web Reader Bridge Checks (Prompt 8)

- `web_reader_bridge_enabled` defaults to `false`
- `cfi_conversion_enabled` defaults to `false`
- with bridge disabled, KOReader-native sync behavior is unchanged
- with bridge enabled, plugin pulls Web Reader progress on open
- with bridge enabled, plugin pushes bridge progress on close/suspend/manual sync
- if Web Reader progress is newer, plugin prompts before jumping
- if both sides changed, plugin offers `Use KOReader`, `Use Web Reader`, `Ignore`
- if CFI conversion fails, bridge falls back safely without blocking reading
- if conversion is disabled, percentage/page fallback still works when possible

## Auto-Update Checks

- updater source repo is `0xstillb/grimmlink`
- install requires explicit confirmation
- restart prompt appears after successful install
- settings/database/cache/downloaded books/.sdr remain untouched

## Known Local Limitation

This workspace currently lacks a local Lua toolchain, so runtime Lua validation
must happen in CI or on a KOReader-capable machine.
