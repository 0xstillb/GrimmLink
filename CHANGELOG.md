# Changelog

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
