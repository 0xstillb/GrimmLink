# GrimmLink Audit-Fix Report

> Historical report: bridge-related changes describe an older implementation and are not the current plugin contract. See `docs/PLUGIN_SCOPE.md`.

Date: 2026-05-01 Asia/Bangkok
Editor: Claude (Cowork mode)
Scope: Close all findings raised in `AUDIT_REPORT.md` (F-1, F-2, F-3). All three were Low severity; no blockers.

## Repository State

| Repo | Branch | HEAD before fix |
|---|---|---|
| `grimmlink` | `feature/grimmlink-adaptation` | `d6fc9e0` |

Not committed. Diff is staged in the working tree only, per the "do not touch git without explicit instruction" policy in `HANDOFF.md`.

## Findings Closed

### F-1 (code) — log-message mojibake

- **File:** `grimmlink/grimmlink.koplugin/grimmlink_shelf_sync.lua` line 155
- **Before:** `"... skip delete â€" outside download directory:"` (UTF-8 em-dash bytes interpreted as Latin-1)
- **After:** `"... skip delete — outside download directory:"` (em-dash `U+2014`, matching line 150)
- **Mid-edit incident:** the first Edit pass replaced the ASCII double-quotes around the string with smart quotes (`U+201C` / `U+201D`), which would have broken Lua syntax. Detected via `xxd` byte-level inspection and cleaned up with `sed`. Final byte-level check confirms both quotes are `0x22` (ASCII) and the em-dash is `e2 80 94` (U+2014).

### F-2 (doc) — two conflict dialogs not flagged in plugin docs

- **File:** `grimmlink/docs/TEST_PLAN.md` line 74
- **Added:** A one-line note at the top of the "Web Reader Bridge Checks" section stating that the bridge conflict dialog is intentionally a separate dialog from the native KOReader sync conflict dialog above, and that the buttons (`Use KOReader` / `Use Web Reader` / `Ignore`) differ on purpose so users can tell the two flows apart.

### F-3 (doc) — auto-update double-gate not explained

- **File:** `grimmlink/README.md` line 102
- **Added:** A one-line note in the "Auto Update" section stating that startup update checks require both `auto_update_enabled = true` and `check_update_on_startup = true`, and that flipping only `check_update_on_startup` will not trigger a check on its own.

## Diff Summary

```
README.md                                   | 2 ++
docs/TEST_PLAN.md                           | 2 ++
grimmlink.koplugin/grimmlink_shelf_sync.lua | 2 +-
3 files changed, 5 insertions(+), 1 deletion(-)
```

## Verification

- **Byte-level:** `sed -n '155p' ... | xxd` confirmed quotes are ASCII `0x22` and the em-dash is `e2 80 94` (U+2014).
- **Smart-quote sweep:** `grep -nP '[\xe2][\x80][\x9c\x9d\x98\x99]'` across `README.md`, `docs/TEST_PLAN.md`, `docs/PLUGIN_SCOPE.md`, `docs/RELEASE.md`, and `grimmlink_shelf_sync.lua` — no leftover smart quotes.
- **Local Lua toolchain:** unavailable on this machine (per `HANDOFF.md` > "Plugin local toolchain"). `luac -p` syntax validation must be done by Plugin CI after the commit is pushed.

## Out-of-Scope Items Confirmed Untouched

Per `HANDOFF.md` > "Things Not To Do Unless Explicitly Asked":

- No PR opened, closed, or recreated.
- No `git reset --hard`, `git clean -fd`, or `git checkout .` was run.
- The unrelated untracked `.claude/` directory in `grimmlink` was left alone.
- No backend (`grimmory`) files were modified — all three findings live in the plugin repo.
- No Grimmory server/library files or book records were touched.
- No commit was made.

## Safety Invariants Preserved

All invariants listed in `HANDOFF.md` > "Safety Invariants To Preserve" remain intact:

- Shelf Sync deletion policy unchanged (only the log-message text was edited).
- Annotation merge / dedupe logic unchanged.
- Updater logic unchanged (only README wording added).
- Web Reader Bridge default-OFF behavior unchanged.
- Native KOReader sync independent of bridge — unchanged.
- No deletion of Grimmory server or library files.
- No deletion of book records.

## Recommended Next Steps

1. Review the three-file diff and, if it looks good, commit. Suggested message: `fix: clean up shelf sync log mojibake and clarify bridge/auto-update docs`.
2. After push, wait for Plugin CI to confirm `luac -p` passes (this is the substitute for the local syntax check that is unavailable on this machine).
3. When ready to publish, follow the existing release-tag flow; `generate-version.sh` will populate `plugin_version.lua` automatically per `.github/workflows/release.yml`.

## Sign-Off

All three audit findings closed. No safety invariants regressed. Release-candidate state in `HANDOFF.md` remains consistent except for the three intended cosmetic / doc improvements above.
