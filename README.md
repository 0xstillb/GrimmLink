# GrimmLink

KOReader Companion for Grimmory

This repository is the dedicated KOReader plugin home for GrimmLink. It started as a fork of `WorldTeacher/BookLoreSync-plugin`, and it is now being adapted for Grimmory-specific backend support and GrimmLink branding.

## Current Scope

GrimmLink currently supports:

- KOReader authentication with `x-auth-user` and `x-auth-key`
- book matching by hash against Grimmory
- KOReader-native progress pull and push
- EPUB progress syncing as KOReader-native data
- reading session upload and offline batch replay
- Moon+ Reader-like local/remote progress comparison
- **Shelf Sync** — download books from a selected Grimmory shelf to a local KOReader folder
  - shelf selection via in-plugin picker
  - safe local mapping (`shelf_sync_map`) — tracks GrimmLink-downloaded files
  - skip already-downloaded books
  - two-way shelf delete sync (`two_way_shelf_delete_sync`, default off)
  - optional `.sdr` sidecar deletion (`delete_sdr_on_book_delete`, default off)
  - configurable download directory
- **Annotation Sync** — push KOReader highlights, notes, bookmarks and personal rating to Grimmory (Prompt 6)
  - per-kind toggles: `annotations_sync_enabled`, `bookmarks_sync_enabled`, `rating_sync_enabled` (all default off)
  - capture-on-close hook + manual `Sync Annotations Now` action
  - offline queue (`pending_annotations`) — survives restart, retried on next sync
  - server-side dedupe via stable `dedupeKey` (md5 of book + kind + position + text)
  - raw KOReader xpointer / page is preserved — no EPUB CFI conversion
  - never bridges into Web Reader CFI tables

Not yet implemented:

- Web Reader bridge
- EPUB CFI conversion
- Hardcover rating sync
- magic shelf (dynamic filter-based shelf) support

## Repository Layout

- `grimmlink.koplugin/`: active plugin package for KOReader
- `grimmlink.koplugin/test/`: active GrimmLink MVP test surface
- `docs/PLUGIN_SCOPE.md`: current GrimmLink MVP scope and integration notes
- `docs/TEST_PLAN.md`: current manual and backend/plugin integration test plan
- `docs/RELEASE.md`: current MVP release checklist and known limitations
- `docs/content/`: legacy upstream BookLoreSync documentation retained as reference only
- `legacy/upstream-bookloresync-tests/`: legacy upstream test suite retained as reference only

## Installation

1. Copy the plugin package into KOReader's `plugins` directory:

   ```bash
   cp -r grimmlink.koplugin {your_koreader_installation}/plugins/
   ```

2. Fully restart KOReader.

3. In KOReader, configure:
   - Grimmory server URL
   - username
   - auth key
   - device name / device ID

## Notes

- Auto-update should remain disabled until GrimmLink has its own release channel.
- GrimmLink sends KOReader-native EPUB progress only. It does not convert to EPUB CFI and does not bridge into Grimmory Web Reader fields.
- This repo is now separate from the main Grimmory server repository so plugin work can evolve independently.
- The active GrimmLink MVP source of truth is `grimmlink.koplugin/` plus the top-level docs listed above. Legacy upstream docs/tests under `docs/content/` and `legacy/upstream-bookloresync-tests/` are not the authoritative MVP contract.
