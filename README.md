<p align="center">
  <h1 align="center">GrimmLink</h1>
  <p align="center">KOReader companion plugin for <a href="https://github.com/0xstillb/grimmory">Grimmory Fork by 0xStillb</a></p>
</p>

> **Requires [Grimmory](https://github.com/0xstillb/grimmory)** -- a self-hosted book server with KOReader sync API. GrimmLink is designed exclusively for Grimmory.

<p align="center">
  <img src="https://img.shields.io/badge/platform-KOReader-blue" alt="Platform">
  <img src="https://img.shields.io/badge/language-Lua-purple" alt="Language">
  <img src="https://img.shields.io/github/v/release/0xstillb/grimmlink?label=release" alt="Release">
  <img src="https://img.shields.io/github/license/0xstillb/grimmlink" alt="License">
</p>

---

## What is GrimmLink?

GrimmLink syncs your reading progress, sessions, and library between [KOReader](https://koreader.rocks/) and [Grimmory Fork by 0xStillb](https://github.com/0xstillb/grimmory) server. It supports EPUB, PDF, CBZ, and other KOReader-compatible formats.

### Key Features

- **Progress Sync** -- Pull remote progress on book open, push on close/suspend. You are always prompted before jumping to a remote position.
- **PDF Web Reader Bridge** -- Sync PDF page positions between KOReader and Grimmory's web reader (optional, disabled by default).
- **Reading Sessions** -- Track and upload reading sessions with offline replay for failed uploads.
- **Shelf Sync** -- Download books from Grimmory shelves with progress bar, async/blocking fallback, and large file support.
- **Auto Update** -- In-app updater with opt-in startup checks.

---

## Installation

1. Download `grimmlink.koplugin.zip` from the [latest release](https://github.com/0xstillb/grimmlink/releases/latest).
2. Extract into KOReader's `plugins/` directory.
3. Restart KOReader.
4. Open **Tools > GrimmLink** and configure:
   - Grimmory Server URL
   - KOReader Username
   - Password
5. Run **Test Connection** to verify.

> The plugin generates `x-auth-key` internally from your password. You never need to enter an auth key, token, or MD5 hash.

---

## Configuration

| Setting | Default | Description |
|---|---|---|
| `pdf_web_reader_bridge_enabled` | `false` | Enable PDF-only Web Reader Bridge |
| `two_way_shelf_delete_sync` | `false` | Mirror tracked shelf deletions into local cleanup |
| `delete_sdr_on_book_delete` | `false` | Remove `.sdr` sidecars when deleting a tracked book |
| `auto_update_enabled` | `false` | Allow in-app updater to install updates |
| `check_update_on_startup` | `false` | Check for updates during startup |

---

## How It Works

### Progress Sync (all formats)

```
KOReader Device A ──push──> Grimmory Server <──pull── KOReader Device B
```

- Pulls remote progress when a book opens
- Prompts before jumping to newer remote progress
- Pushes local progress on close, suspend, or manual sync
- Queues failed uploads for later replay

### PDF Web Reader Bridge

```
KOReader ──push──> Grimmory Server <──push── Grimmory Web Reader
    |                                              |
    <──────────── pull (prompted) ─────────────────>
```

- Only runs for PDF files
- Uses `/api/koreader/books/{bookId}/pdf-progress`
- Requires **Sync with Grimmory Reader** enabled in Grimmory web settings

### Shelf Sync

- Downloads shelf books to local storage with visual progress bar
- **Async download** (curl/wget subprocess) on devices that support it -- non-blocking UI
- **Blocking fallback** (LuaSocket) for devices without curl/wget (e.g. iReader) -- with per-second progress updates
- Handles large files (200MB+) with auto-scaled timeouts and cancellation support
- Only removes local files that GrimmLink downloaded and tracked
- Never deletes Grimmory library files or server records

---

## Project Structure

```
grimmlink.koplugin/
  main.lua                  # Plugin entry point and UI
  grimmlink_api_client.lua  # HTTP client for Grimmory API
  grimmlink_database.lua    # Local SQLite storage
  grimmlink_shelf_sync.lua  # Shelf download and cleanup
  grimmlink_updater.lua     # In-app update mechanism
  plugin_version.lua        # Version metadata
  _meta.lua                 # KOReader plugin descriptor
  test/                     # Unit tests
docs/                       # Documentation site (Zola)
```

---

## Branch Structure

| Branch | Purpose |
|---|---|
| `main` | Production branch, all releases are tagged here |
| `idea/*` | Experimental / concept branches |
| `archive/*` | Historical branches kept for reference |
| `backup` | Snapshot of previous codebase |

---

## Credits

GrimmLink is a fork of [BookLoreSync](https://github.com/WorldTeacher/BookLoreSync-plugin) by WorldTeacher.

---

## License

See [LICENSE](LICENSE) for details.
