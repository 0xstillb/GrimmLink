# Changelog

# [v1.3.3]

### Features
- SimpleUI top menu: GrimmLink now registers a quick action button — add it via Settings → Quick Actions

# [v1.3.2]

### Fixes
- Kindle compatibility: lfs fallback `attributes()` now checks `test -d` before `io.open()` — on Linux `io.open()` succeeds on directories causing shelf sync to resolve the wrong download path
- Kindle compatibility: shelf sync now downloads books to `/mnt/us/documents/Book/` so Kindle's native library indexes them automatically

# [v1.3.1]

### Fixes
- Kindle compatibility: make `lfs` (LuaFileSystem) optional so the plugin loads on Kindle KOReader builds where the module is unavailable — previously caused "GrimmLink is still starting up" on every action

# [v1.2.0]

### Features
- Series metadata support for SimpleUI browsing — books with series info are now organized in SimpleUI's "Browse by Series"
- Redesigned menu structure with grouped settings and `keep_menu_open` on toggles
- Redesigned shelf sync completion dialog with aligned labels and bullet points

### Fixes
- Database migration crash when adding series columns (ljsqlite3 PRAGMA compatibility)
- Lazy-load SQ3 and json modules to avoid startup crashes on missing dependencies
- Fixed bookinfo_cache path and directory trailing-slash matching
- Wrapped db:init() in pcall to prevent cascading init failures
- Fixed Unicode em-dash mojibake on KOReader e-ink display
- Resolved empty download_dir causing metadata index to not be created

# [v1.1.0]

### Features
- Shelf sync with automatic book downloading
- Two-way delete sync
- Fast sync with configurable cache duration
- PDF web reader bridge for progress sync
- Auto-update from GitHub releases

# [v1.0.0]

- Initial release — reading progress and session sync with Grimmory server
