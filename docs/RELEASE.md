# GrimmLink MVP Release Checklist

## Release Summary

- Release name:
- Release date:
- Plugin branch:
- Backend branch:

## Included In MVP

- [ ] GrimmLink branding is visible in the plugin UI
- [ ] Grimmory server URL can be configured
- [ ] `x-auth-user` and `x-auth-key` auth works
- [ ] hash-based book matching works
- [ ] KOReader-native progress pull works
- [ ] KOReader-native progress push works
- [ ] reading session upload works
- [ ] batch pending session upload works
- [ ] offline queue works
- [ ] Moon+ Reader-like conflict dialog works
- [ ] Shelf Sync downloads books from a selected Grimmory shelf
- [ ] Shelf Sync uses `shelf_sync_map` for tracked GrimmLink downloads
- [ ] `two_way_shelf_delete_sync` defaults to OFF
- [ ] `delete_sdr_on_book_delete` defaults to OFF

## Excluded From MVP

- [ ] Web Reader Bridge
- [ ] EPUB CFI conversion
- [ ] rating sync
- [ ] highlights/notes sync
- [ ] bookmarks sync
- [ ] shelf/library sync beyond the current Shelf Sync MVP

## Auto-Update Safety

- [ ] updater is disabled for MVP
- [ ] no updater path points to `WorldTeacher/BookLoreSync-plugin`
- [ ] future updater work is tracked separately from MVP rollout

## Compatibility Notes

- [ ] plugin targets Grimmory backend endpoints documented for GrimmLink MVP
- [ ] plugin remains in this dedicated repository
- [ ] backend implementation remains in the separate `grimmory` repository

## Known Limitations

- raw remote jump depends on KOReader runtime methods available on the device
- some legacy upstream docs/tests remain in the repository as reference material under `docs/content/` and `legacy/upstream-bookloresync-tests/`
- active GrimmLink MVP source of truth is `grimmlink.koplugin/` and the top-level docs in `docs/`
- shelf deletions never use a library delete endpoint or server-side file deletion

## Annotation Sync (Prompt 6)

- New plugin module: `grimmlink_annotations.lua`.
- New plugin DB migration 4 adds `pending_annotations` queue and
  `annotation_sync_state` table.
- Per-kind toggles all default OFF until the user explicitly opts in.
- KOReader xpointer / page is preserved as raw `koreaderPos` / `page`.
  No EPUB CFI conversion. No Web Reader bridge.
- Backend tables: `koreader_annotations`, `koreader_bookmarks` (separate
  from the existing CFI-based `annotations` / `book_marks`).
- Rating reuses the existing `user_book_progress.personal_rating` column.

## Later Phase Roadmap

- Hardcover rating sync
- shelf/library sync beyond current Shelf Sync MVP

## Phase 6 - Web Reader Bridge

This remains a later dedicated phase only.

- keep KOReader-native progress separate from Grimmory Web Reader progress
- treat EPUB CFI conversion as best-effort future work
- do not block GrimmLink MVP release on Web Reader Bridge work
