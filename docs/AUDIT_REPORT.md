# GrimmLink / Grimmory Release-Candidate Audit Report

> Historical report: bridge-related findings describe an older implementation and are not the current plugin contract. See `docs/PLUGIN_SCOPE.md`.

Audit date: 2026-05-01 Asia/Bangkok
Auditor: Claude (Cowork mode)

Scope follows `HANDOFF.md` "Good Next Steps For Audit" focus areas:

1. Prompt 8-10 regression review
2. Docs vs behavior mismatch
3. Backend endpoints vs plugin contract
4. Release workflow correctness

This audit performed read-only review only. No code or docs were modified.

## Repository State Verified

| Repo | Branch | HEAD | Working tree |
|---|---|---|---|
| `grimmory` (backend) | `feature/OPF-KOreader-plugin` | `7d0e4dc0fb7ef7dc689562e7819666d064258ffd` | clean |
| `grimmlink` (plugin) | `feature/grimmlink-adaptation` | `d6fc9e0bc7fb26f5ebdde777c5dd3ea6413dca2f` | clean (CRLF diff seen via Linux sandbox is line-ending churn, not real changes; Windows-side `git status` is clean per HANDOFF.md) |

Branch + commit hashes match `HANDOFF.md` exactly. Latest commit messages match.

## Severity Summary

- Critical / Blocker: 0
- Medium: 0
- Low / cosmetic / doc nit: 3

No release-blocking findings. Release-candidate state is consistent with the handoff.

## 1. Prompt 8-10 Regression Review

### 1.1 Safe defaults (verified against `grimmlink.koplugin/main.lua` `DEFAULTS` table)

| Setting | Default | Code line | Doc claim location | Match |
|---|---|---|---|---|
| `two_way_shelf_delete_sync` | `false` | 51 | `PLUGIN_SCOPE.md` line 31, `README.md` line 44 | OK |
| `delete_sdr_on_book_delete` | `false` | 53 | `PLUGIN_SCOPE.md` line 32, `README.md` line 45 | OK |
| `web_reader_bridge_enabled` | `false` | 66 | `PLUGIN_SCOPE.md` line 33, `README.md` line 46 | OK |
| `cfi_conversion_enabled` | `false` | 67 | `PLUGIN_SCOPE.md` line 34, `README.md` line 47 | OK |
| `auto_update_enabled` | `false` | 60 | `PLUGIN_SCOPE.md` line 35, `README.md` line 48 | OK |
| `check_update_on_startup` | `false` | 61 | `PLUGIN_SCOPE.md` line 36, `README.md` line 49 | OK |
| `update_repo` | `"0xstillb/grimmlink"` | 63 | `RELEASE.md` line 7 | OK |

### 1.2 Shelf Sync deletion guards (`grimmlink_shelf_sync.lua`)

`ShelfSync:deleteLocalBook` enforces two layered guards (lines 149-157):

1. `entry.downloaded_by_grimmlink ~= 1` -> skip (only delete tracked downloads)
2. `not isPathUnderDirectory(entry.local_path, download_dir)` -> skip (refuse to delete outside download dir)

`.sdr` deletion requires explicit `delete_sdr` flag (line 168). Two-way delete behavior in `syncShelf` is gated on `opts.two_way_delete_sync` (line 244 and line 346).

`main.lua` line 2451 wires `two_way_delete_sync = self.two_way_shelf_delete_sync` and `delete_sdr = self.delete_sdr_on_book_delete`, so plugin defaults propagate correctly.

Result: shelf-sync deletion guards intact. Membership-only contract preserved.

### 1.3 Annotation merge / dedupe (`grimmlink_annotations.lua`)

`Annotations:compareLocalAndRemote` (lines 394-410) classifies remote item as one of:

- `exact_duplicate` -> mark dedup, no overwrite
- `local_newer` -> skip
- `remote_newer_safe` -> overwrite only when `isSafeRemoteOverwrite` true
- `conflict` -> keep both untouched, save merge state

`Annotations:isSafeRemoteOverwrite` (lines 383-392) defines compatibility as:

- text: `local_text == remote_text` OR either side empty
- note: `local_note == remote_note` OR `local_note == ""`

`updateLocalItemFromRemote` (lines 521-549) uses `remote_value or local_value` so empty/nil remote fields cannot blank a populated local field.

Result: annotation merge never silently overwrites a non-empty user note/highlight with conflicting remote content.

### 1.4 Updater asset selection (`grimmlink_updater.lua`)

- `GITHUB_REPO = "0xstillb/grimmlink"` (line 9)
- `RELEASE_ASSET_NAME = "grimmlink.koplugin.zip"` (line 11)
- `ALTERNATE_ASSET_PATTERN = "grimmlink-v%s.zip"` (line 12)
- `Updater:normalizeRepo` (lines 79-88) force-overwrites any user-saved repo back to `GITHUB_REPO` and warns. Combined with `main.lua` lines 314-317 that re-saves the official repo into the plugin DB on init, this defends against a saved fork-hijack value.
- `getExpectedAssetNames` (lines 186-192) strips a leading `v` from the version, then formats with the pattern, yielding `grimmlink-v<X.Y.Z>.zip`. Matches both `tag_name = "v1.0.0"` and `tag_name = "1.0.0"` GitHub release shapes.
- `installDownloadedUpdate` (lines 597-638) only mutates `self.plugin_dir`. User settings (`LuaSettings`), plugin DB, downloaded books in `download_dir`, and `.sdr` directories all live outside `plugin_dir`, so the updater cannot collaterally delete them.
- Backup path retained at `DataStorage:getDataDir() .. "/grimmlink-backups"` with retention limit `BACKUP_KEEP_COUNT = 3`. `rollbackToLatestBackup` uses the most recent backup.

Result: updater asset selection correct, repo lock-down correct, user data preserved.

### 1.5 Bridge default-OFF runtime gating

Verified early-return guards at every Web Reader Bridge / CFI call site:

- `main.lua:1359` CFI conversion enter -> `if not self.cfi_conversion_enabled or not book_id or not payload then`
- `main.lua:1409` `pushWebReaderBridgeSnapshot` enter -> `if not self.web_reader_bridge_enabled or not snapshot ...`
- `main.lua:1534` `maybePullWebReaderProgress` enter -> `if not self.web_reader_bridge_enabled or not file_hash ...`
- `main.lua:1640` user-triggered bridge action -> `if not self.web_reader_bridge_enabled then`

Result: with the feature flags off (the safe default), no bridge or CFI request is made.

### 1.6 Suspend ordering (Prompt 9 fix)

`Grimmlink:onSuspend` (`main.lua:2293-2306`):

1. `endSession({ reason = "suspend" })`
2. `pcall(function() self:captureCurrentDocumentAnnotations() end)` -- annotation capture
3. `if self:isOnline() then self:syncPendingNow(true) end` -- pending sync replay AFTER capture

Order matches the Prompt 9 hardening note in `HANDOFF.md`. `onCloseDocument` (`main.lua:2278-2290`) follows the same order but gates capture on `annotations_capture_on_close`; suspend capture is unconditional, which is intentional.

## 2. Backend Endpoints vs Plugin Contract

Compared every path used by `grimmlink_api_client.lua` against the `@*Mapping` annotations in the four KOReader controllers.

| Plugin call | Backend mapping | Match |
|---|---|---|
| `GET  /api/koreader/users/auth` | `KoreaderController.java:31` | OK |
| `GET  /api/koreader/books/by-hash/{hash}` | `KoreaderController.java:56` | OK |
| `GET  /api/koreader/syncs/progress/{hash}` | `KoreaderController.java:46` | OK |
| `PUT  /api/koreader/syncs/progress` | `KoreaderController.java:63` | OK |
| `GET  /api/koreader/shelves` | `KoreaderShelfController.java:31` | OK |
| `GET  /api/koreader/shelves/{id}/books` | `KoreaderShelfController.java:42` | OK |
| `GET  /api/koreader/books/{id}/download` | `KoreaderShelfController.java:54` | OK |
| `POST /api/koreader/shelves/{sid}/books/{bid}/remove` | `KoreaderShelfController.java:66` | OK |
| `GET  /api/koreader/books/{id}/web-progress` | `KoreaderWebReaderBridgeController.java:28` | OK |
| `PUT  /api/koreader/books/{id}/web-progress` | `KoreaderWebReaderBridgeController.java:36` | OK |
| `POST /api/koreader/books/{id}/cfi/resolve` | `KoreaderWebReaderBridgeController.java:45` | OK |
| `GET  /api/koreader/books/{id}/annotations[?since=]` | `KoreaderAnnotationController.java:46` | OK |
| `POST /api/koreader/books/{id}/annotations/batch` | `KoreaderAnnotationController.java:57` | OK |
| `GET  /api/koreader/books/{id}/bookmarks[?since=]` | `KoreaderAnnotationController.java:73` | OK |
| `POST /api/koreader/books/{id}/bookmarks/batch` | `KoreaderAnnotationController.java:84` | OK |
| `GET  /api/koreader/books/{id}/rating` | `KoreaderAnnotationController.java:95` | OK |
| `PUT  /api/koreader/books/{id}/rating` | `KoreaderAnnotationController.java:103` | OK |
| `POST /api/v1/reading-sessions` | not in audited controllers (out of scope, ReadingSessions controller) | — |
| `POST /api/v1/reading-sessions/batch` | not in audited controllers (out of scope, ReadingSessions controller) | — |

Notes:

- Watermark query parameter name `?since=` matches `@RequestParam(name = "since")` on the annotation/bookmark list endpoints.
- The plugin does not call `POST /api/koreader/users/create` (account creation is intentionally out of scope for the plugin).
- `KoreaderUserController` lives at `/api/v1/koreader-users` and is for the web admin UI, not the plugin. Its absence from `API_REFERENCE.md` is correct because that doc is the GrimmLink contract.
- All four KOReader controllers share `@RequestMapping("/api/koreader")` (or sub-path under it). `KoreaderAuthFilter` handles `x-auth-user`/`x-auth-key` for the whole tree, consistent with `API_REFERENCE.md` line 11.

Result: 17/17 plugin-called endpoints map cleanly. No DTO contract drift observed at the path/method level.

## 3. Release Workflow Correctness

`grimmlink/.github/workflows/release.yml`:

- Trigger: `push.tags: ["*"]` -> any tag fires the workflow.
- `generate-version.sh` rewrites `grimmlink.koplugin/plugin_version.lua` and `_meta.lua` with the exact tag string (e.g. `v1.0.0`) before zipping. Version-type set to `release` when on a tagged commit.
- Asset 1 published: `grimmlink.koplugin.zip` (canonical, stable filename).
- Asset 2 published: `grimmlink-${VERSION}.zip` where VERSION is normalized to start with `v`. Matches updater's `ALTERNATE_ASSET_PATTERN = "grimmlink-v%s.zip"` regardless of whether the tag was pushed as `1.0.0` or `v1.0.0`.
- Both ZIPs have identical content (the second is `cp` of the first). Updater validates structure via `_validateZipStructure` (`grimmlink_updater.lua:503-516`), which checks for `grimmlink.koplugin/main.lua`, `_meta.lua`, `plugin_version.lua` inside the archive. Both zips satisfy this.
- Prerelease flag derived from substring match `alpha|beta|rc` in the ref. Aligns with updater's `allow_prerelease` setting which gates which release feed is queried.
- `softprops/action-gh-release@v3` publishes assets and `CHANGELOG.md` plus an extracted per-version body.

`grimmlink/.github/workflows/ci.yml` notable safety guards:

- Lua syntax: `find grimmlink.koplugin -type f -name '*.lua' -print0 | xargs -0 -n1 luac -p`
- Updater repo guard: explicit `git grep` rejecting `WorldTeacher/BookLoreSync-plugin` and asserting `'GITHUB_REPO = "0xstillb/grimmlink"'` is present.
- ZIP-artifact guard: `git ls-files | grep -E '(^|/)grimmlink\.koplugin\.zip$|(^|/)grimmlink-v[0-9].*\.zip$'` fails the build if a packaged zip is committed.

Result: tagged-release packaging matches asset names declared in HANDOFF.md, README.md, RELEASE.md (both repos), and the updater's `getExpectedAssetNames`. Repo lock-down enforced by CI.

## 4. Docs vs Behavior Mismatch

Cross-checked the following against code:

- `grimmory/docs/koreader-companion/API_REFERENCE.md`
- `grimmory/docs/koreader-companion/ARCHITECTURE.md`
- `grimmory/docs/koreader-companion/TEST_PLAN.md`
- `grimmory/docs/koreader-companion/RELEASE.md`
- `grimmlink/README.md`
- `grimmlink/docs/PLUGIN_SCOPE.md`
- `grimmlink/docs/TEST_PLAN.md`
- `grimmlink/docs/RELEASE.md`

No factual mismatches found. The two distinct conflict dialogs (native KOReader sync vs Web Reader Bridge) use different button labels by design:

- Native sync conflict (`main.lua:1099, 1107`): `Use Local`, `Use Remote`
- Web Reader Bridge conflict (`main.lua:1485, 1502`): `Use KOReader`, `Use Web Reader`

Both label sets are referenced separately in `grimmlink/docs/TEST_PLAN.md` (lines 42-44 vs 80) and remain consistent with the code paths they describe.

## 5. Findings

### F-1 (Low, cosmetic) -- log-message mojibake in shelf sync

**File:** `grimmlink/grimmlink.koplugin/grimmlink_shelf_sync.lua`

**Line 155** logs a message containing `â€"` (UTF-8 em-dash bytes interpreted as Latin-1) instead of the intended `—`. Compare with line 150 which uses a normal `—` correctly. Excerpt:

- Line 150: `logger.warn("GrimmLink ShelfSync: skip delete — not downloaded by GrimmLink:", entry.local_path)`
- Line 155: `logger.warn("GrimmLink ShelfSync: skip delete â€" outside download directory:", entry.local_path)`

**Impact:** Cosmetic only. Appears in logs when a tracked download has an out-of-tree `local_path`. No functional regression.

**Suggested fix:** Replace `â€"` with `—` on line 155, or replace both with `--` to avoid future encoding issues.

### F-2 (Low, doc nit) -- two distinct conflict dialogs not flagged in plugin docs

`grimmlink/docs/TEST_PLAN.md` line 42-44 ("Use Local / Use Remote / Ignore") and line 80 ("Use KOReader, Use Web Reader, Ignore") describe two different dialogs without explicitly stating they are different. A reader might reasonably wonder whether the labels were renamed.

**Impact:** None for behavior; minor reader confusion.

**Suggested fix (optional):** Add a one-line clarification at the top of "Web Reader Bridge Checks" noting that the bridge conflict dialog is intentionally separate from the native KOReader conflict dialog.

### F-3 (Low, doc nit) -- "auto-update enabled" gate

`main.lua:2231` -- the startup update check requires BOTH `auto_update_enabled` AND `check_update_on_startup` to be true:

```lua
if not self.auto_update_enabled or not self.check_update_on_startup or not self.updater then
```

This double gate is safer than either flag alone, but the docs (`PLUGIN_SCOPE.md` line 35-36, `README.md` line 48-49) list both defaults without explaining that `check_update_on_startup` is dependent on `auto_update_enabled`.

**Impact:** None for behavior. A user who flips only `check_update_on_startup` to true will see no startup check happen, which could surprise them.

**Suggested fix (optional):** Add a one-line note in `README.md` "Auto Update" section stating that startup checks require `auto_update_enabled = true`.

## 6. Out-of-Scope Items Confirmed Untouched

Per HANDOFF.md "Things Not To Do Unless Explicitly Asked":

- No PR was reopened or created.
- No `git reset --hard`, `git clean -fd`, or `git checkout .` was run.
- No book records or library files were touched.
- The unrelated `.claude/` untracked directory in `grimmlink` was left alone.

## 7. Recommendations (priority order)

1. (Optional, low effort) Fix F-1 -- single-character cleanup in a log string.
2. (Optional, doc only) Apply F-2 / F-3 doc clarifications if a doc revision is planned anyway.
3. (Out of scope here, but flagged in HANDOFF.md) The unrelated full-suite `gradlew test` failures (`epub4j_native.dll` etc.) remain non-GrimmLink and non-blocking. They should still be tracked separately for the underlying cause.
4. (When ready to publish) Tag the commit per release workflow expectations; `generate-version.sh` will populate `plugin_version.lua` automatically. Verify the resulting GitHub release contains both asset shapes before announcing.

## 8. Sign-Off

The release-candidate state is consistent with `HANDOFF.md`. All Prompt 8/9/10 safety invariants verified intact. No critical or medium findings.
