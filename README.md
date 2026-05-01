# GrimmLink

> KOReader companion plugin for **Grimmory** — keeps your KOReader devices in sync with a Grimmory server for reading progress, shelves, annotations, and (optionally) Grimmory's web reader.

|  |  |
|---|---|
| Release repo | [`0xstillb/grimmlink`](https://github.com/0xstillb/grimmlink) |
| Plugin folder | `grimmlink.koplugin/` |
| Backend counterpart | the separate `grimmory` repository |
| Upstream (forked from) | [`WorldTeacher/BookLoreSync-plugin`](https://github.com/WorldTeacher/BookLoreSync-plugin) |
| License | [MIT](LICENSE) — © 2026 WorldTeacher |

**Jump to:** [Features](#features) · [Install](#install) · [Safe defaults](#safe-defaults) · [Sync behavior](#core-sync-behavior) · [Auto update](#auto-update) · [Web Reader Bridge](#web-reader-bridge) · [Credits](#credits)

---

## Features

- KOReader companion authentication (`x-auth-user` / `x-auth-key`)
- Hash-based book matching against Grimmory
- KOReader-native progress pull and push
- Reading session upload with offline queue replay
- Shelf Sync for shelf membership and tracked downloads
- Annotation, bookmark, and rating sync
- Optional auto-update from `0xstillb/grimmlink`
- Optional Web Reader Bridge for Grimmory's web reader
- Best-effort EPUB CFI conversion for bridge-only scenarios

## Install

1. Download the latest release from [`0xstillb/grimmlink/releases`](https://github.com/0xstillb/grimmlink/releases). Either asset works:
   - `grimmlink.koplugin.zip`
   - `grimmlink-vX.Y.Z.zip`
2. Extract the archive and copy `grimmlink.koplugin/` into KOReader's `plugins/` directory.
3. Fully restart KOReader.
4. Open **Tools → GrimmLink** and configure:
   - Grimmory server URL
   - KOReader username
   - KOReader password
   - device name / device ID
5. Run **Test Connection** before turning on any optional sync features.

## Safe Defaults

Every potentially destructive or networked feature ships **off**. Flip them on deliberately, not by accident.

| Setting | Default | What enabling it does |
|---|---|---|
| `two_way_shelf_delete_sync` | `false` | Lets shelf membership removals also delete locally tracked downloads. |
| `delete_sdr_on_book_delete` | `false` | Lets local book deletion also remove the matching `.sdr` sidecar. |
| `web_reader_bridge_enabled` | `false` | Enables the optional Web Reader progress bridge. |
| `cfi_conversion_enabled` | `false` | Enables best-effort EPUB CFI conversion (used by the bridge). |
| `auto_update_enabled` | `false` | Allows the in-app updater to install GrimmLink updates. |
| `check_update_on_startup` | `false` | Asks the updater to check on startup *(requires `auto_update_enabled = true`)*. |

## Core Sync Behavior

### Native KOReader progress

- Pulls remote KOReader-native progress on book open.
- Pushes KOReader-native progress on close, suspend, and manual sync.
- Keeps raw KOReader location / progress / xpointer data intact.
- Continues working even when the Web Reader Bridge is disabled.

### Offline queue

- Failed session uploads are queued locally.
- Queued work replays automatically when connectivity returns.
- **Sync Pending Now** flushes the queue manually.

## Shelf Sync

Shelf Sync is intentionally conservative:

- Membership sync only.
- Never deletes Grimmory library/server files.
- Never deletes Grimmory book records.
- Local deletion only applies to GrimmLink-tracked downloads.
- Local deletion only runs when `two_way_shelf_delete_sync` is explicitly enabled.
- `.sdr` deletion is optional and defaults to **off**.

## Annotation Sync

Supported flows:

- Annotation push
- Bookmark push
- Rating push
- Safe remote pull / two-way merge
- Duplicate prevention by stable dedupe key

Safety rules:

- Local user annotations are never silently overwritten.
- Raw KOReader xpointer / page data is preserved.
- Annotation sync does not depend on EPUB CFI conversion.

## Auto Update

The updater is locked to the official GrimmLink release source:

- Repo: [`0xstillb/grimmlink`](https://github.com/0xstillb/grimmlink)
- Accepted release assets:
  - `grimmlink.koplugin.zip`
  - `grimmlink-vX.Y.Z.zip`

> **Note:** Startup update checks require **both** `auto_update_enabled = true` **and** `check_update_on_startup = true`. Flipping only `check_update_on_startup` will not trigger a check on its own.

Update safety rules:

- Install always requires user confirmation.
- User settings are preserved.
- Local database / cache is preserved.
- Downloaded books are preserved.
- `.sdr` directories are preserved.
- The updater backs up the current plugin before replacement.

## Web Reader Bridge

The Web Reader Bridge is optional and runs **separately** from native KOReader sync:

- Disabled by default.
- Reads / writes only the dedicated web-progress endpoints.
- Prompts before applying newer remote Web Reader progress.
- Does **not** replace native KOReader `/syncs/progress`.
- Native KOReader sync keeps working independently when the bridge is off.

### EPUB CFI conversion

- Disabled by default.
- Best-effort only.
- Falls back safely to percentage / page / raw-location when conversion is not possible.
- Failed conversion never blocks reading or native sync.

## CI And Checks

Primary CI workflow: [`.github/workflows/ci.yml`](.github/workflows/ci.yml)

It verifies:

- Lua syntax
- Active plugin tests via `./run_tests.sh`
- Updater source safety (asserts the official repo, rejects fork-hijack values)
- Accidental ZIP artifact commits

The plugin CI does **not** require:

- A real KOReader runtime
- A live Grimmory server
- Secrets
- Real GitHub update installs

## Repository Layout

| Path | Purpose |
|---|---|
| `grimmlink.koplugin/` | Active plugin package |
| `grimmlink.koplugin/test/` | Active plugin test surface |
| `.github/workflows/ci.yml` | Branch CI checks |
| `.github/workflows/release.yml` | Tagged release packaging |
| `docs/PLUGIN_SCOPE.md` | Scope and safety boundaries |
| `docs/TEST_PLAN.md` | Manual and CI verification guidance |
| `docs/RELEASE.md` | Release-candidate checklist |

## Known Limitations

- KOReader device / runtime validation is still required on real hardware.
- EPUB CFI conversion is best-effort and not guaranteed exact for every EPUB.
- Local development on this machine may rely on CI for Lua runtime validation when the Lua toolchain is unavailable.

## Credits

GrimmLink is a fork and adaptation of [**BookLoreSync-plugin**](https://github.com/WorldTeacher/BookLoreSync-plugin) by [**WorldTeacher**](https://github.com/WorldTeacher) (originally developed at [`gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin`](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin)).

The upstream project pioneered the KOReader ↔ BookLore companion plugin — including the auth model, hash-based matching, native KOReader progress sync, shelf membership sync, annotation / bookmark / rating sync, and the auto-updater design. GrimmLink builds on that foundation and retargets it to the **Grimmory** backend and Web Reader.

Many thanks to WorldTeacher and the BookLore project for making this work possible.

## License

[MIT](LICENSE) — © 2026 WorldTeacher.

GrimmLink retains the upstream MIT license; modifications carry forward under the same terms.
