<p align="center">
  <h1 align="center">GrimmLink</h1>
  <p align="center">KOReader companion plugin for <a href="https://github.com/0xstillb/grimmory">Grimmory (0xstillb fork)</a></p>
</p>

> GrimmLink is built specifically for Grimmory (not a universal sync plugin).

<p align="center">
  <img src="https://img.shields.io/badge/platform-KOReader-blue" alt="Platform">
  <img src="https://img.shields.io/badge/language-Lua-purple" alt="Language">
  <img src="https://img.shields.io/github/v/release/0xstillb/grimmlink?label=release" alt="Release">
  <img src="https://img.shields.io/github/license/0xstillb/grimmlink" alt="License">
</p>

---

## What Is GrimmLink?

GrimmLink is a KOReader plugin that connects local reading (EPUB/PDF/CBZ and more) to Grimmory for:

- progress push/pull sync
- reading session sync
- metadata sync (upload-only: rating/highlight/note/bookmark)
- shelf sync (regular + magic shelf) with file download
- maintenance and debug tools for queue visibility and recovery

---

## Core Capabilities

### 1) Progress Sync

- Pull remote progress when opening a book.
- Push local progress when closing/suspending/manual sync.
- Show a conflict prompt before jumping to another location.
- Support Grimmory read status flow (`UNREAD`, `READING`, `READ`, plus backend-supported custom statuses).
- For EPUB/reflowable formats, sync uses KOReader-native location/progress as the source of truth (percentage is not authoritative).
- For fixed-page formats (PDF/CBZ), page/percentage sync remains available.
- PDF web reader bridge remains PDF-only; no EPUB CFI/web bridge conversion.

### 2) Reading Session Sync

- Track local reading sessions.
- Upload when online.
- Keep sessions in queue and retry when connection returns.

### 3) Metadata Sync (Upload-only)

- Collect rating/highlight/note/bookmark from KOReader.
- Send in batch to:
  - `/api/koreader/syncs/metadata`
- Auth headers:
  - `x-auth-user`
  - `x-auth-key`
- No Bearer token.
- No metadata pull-back into KOReader in current phase.
- No annotation/bookmark deletion sync in current phase.

### 4) Shelf Sync (Regular + Magic)

- Sync regular shelf and magic shelf.
- Support private shelf ID with validation.
- Download files with progress dialog/cancel.
- Use async path with blocking fallback based on device capability.
- Refresh KOReader book info/cover cache automatically after download.
- Use local tombstone/queue for safe local deletion handling.
- Never delete server/library files in Grimmory.

### 5) Maintenance / Debug / Recovery

- clear logs
- export debug info (redacted)
- clear pending queues (progress/session/metadata)
- clear local metadata synced history
- clear shelf tombstones/pending removals
- rebuild SimpleUI metadata cache
- rebuild/force metadata resync per book
- re-match current book
- show DB status/pending counts

All local destructive actions are confirmation-gated.

---

## Main Menu Overview

`Tools -> GrimmLink`

- Enable GrimmLink
- Connection
- Sync Progress Now
- Sync Shelf Now
- Sync Metadata Now
- Pull Remote Progress
- Manual Reading Status
- Toggle Tracking (Current Book)
- Advanced Setting
- Status / About

Notes:

- `Preview Metadata` is under `Advanced Setting -> Metadata Sync`.

---

## GrimmLink vs KoSync

KoSync is KOReader's baseline progress sync between devices.
GrimmLink is an end-to-end Grimmory integration.

| Topic | GrimmLink | KoSync |
|---|---|---|
| Goal | Direct Grimmory integration | General KOReader progress sync |
| Auth | `x-auth-user` + `x-auth-key` | KoSync auth model |
| Progress push/pull | Yes | Yes |
| Reading sessions | Yes | Usually no |
| Metadata (rating/highlight/note/bookmark) | Yes (upload-only) | Usually no |
| Shelf sync + file download | Yes (regular/magic/private ID) | No |
| Manual reading status menu | Yes (backend capability aware) | No |
| Maintenance queues/debug export | Yes | More limited |
| Grimmory-specific API | Native | Not designed for Grimmory |

Short version:

- If you only need KOReader-to-KOReader position sync, KoSync may be enough.
- If you need full Grimmory workflow (shelf + metadata + sessions + maintenance), use GrimmLink.

---

## Installation

1. Download `grimmlink.koplugin.zip` from the [latest release](https://github.com/0xstillb/grimmlink/releases/latest).
2. Extract it into KOReader `plugins/`.
3. Restart KOReader.
4. Open `Tools -> GrimmLink -> Connection`.
5. Enter:
   - Grimmory Server URL
   - Username
   - Password
6. Tap Test Connection.

Notes:

- The plugin computes `x-auth-key` internally from your password.
- Users do not need to provide token/bearer keys manually.

---

## Important Settings

| Setting | Default | Meaning |
|---|---|---|
| `metadata_sync_enabled` | `false` | Enable metadata sync |
| `rating_sync_enabled` | `true` | Upload rating |
| `annotations_sync_enabled` | `true` | Upload highlights/notes |
| `bookmarks_sync_enabled` | `true` | Upload bookmarks |
| `sync_regular_shelf_enabled` | `false` | Enable regular shelf sync |
| `sync_magic_shelf_enabled` | `false` | Enable magic shelf sync |
| `ask_wifi_before_sync` | `true` | Ask before Wi-Fi sync when currently offline |
| `sync_on_network_connected` | `false` | Auto sync when network returns |
| `network_sync_cooldown_seconds` | `300` | Prevent over-frequent sync |
| `send_reflowable_percentage` | `false` | Internal guard: do not send reflowable percentage as authoritative progress |
| `auto_update_enabled` | `false` | Enable auto updates |
| `check_update_on_startup` | `false` | Check updates at KOReader startup |

---

## Privacy / Logging Policy

GrimmLink avoids writing sensitive data or full content into logs/debug export:

- no password logs
- no `x-auth-key` logs
- no bearer/authorization token logs
- no full `payload_json` dump
- no full highlight/note content export

Debug export focuses on counters, queue status, and safe diagnostic metadata.

---

## Delete Policy

- Only local files downloaded and tracked by GrimmLink can be deleted by GrimmLink.
- If a book is still tracked by another shelf, GrimmLink will not delete that file.
- Grimmory server/library files and records are never deleted.

---

## Known Limitations

- Metadata sync is upload-only.
- Annotation/bookmark pull-back from Grimmory is not implemented yet.
- Annotation/bookmark deletion sync is not implemented yet.
- Some manual read statuses depend on backend capability.
- EPUB web bridge / CFI conversion remains out of scope.

---

## Project Structure

```text
grimmlink.koplugin/
  main.lua
  grimmlink_api_client.lua
  grimmlink_database.lua
  grimmlink_shelf_sync.lua
  grimmlink_updater.lua
  plugin_version.lua
  _meta.lua
  test/
```

---

## Credits

GrimmLink started from ideas in the BookLoreSync plugin and was extended to fit Grimmory workflows.

---

## License

See [LICENSE](LICENSE).

