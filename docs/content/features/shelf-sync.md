+++
title = "Shelf Sync"
description = "Download books from a Grimmory shelf directly to your KOReader device."
weight = 5
+++

# Shelf Sync

Shelf Sync allows GrimmLink to download books from a selected Grimmory shelf to a local folder on your KOReader device.

---

## How it works

1. GrimmLink fetches the book list for the selected shelf from Grimmory.
2. For each book not yet present locally, GrimmLink downloads the file to the configured download directory.
3. A local database mapping (`shelf_sync_map`) tracks every book downloaded by GrimmLink, including the server book ID, local path, and last-seen timestamp.
4. On subsequent syncs, already-downloaded books are skipped (unless the file is missing or significantly differs in size).
5. Optionally, books removed from the Grimmory shelf can be deleted locally — but only files previously downloaded and tracked by GrimmLink.

---

## Prerequisites

- GrimmLink must be configured and connected (server URL, username, auth key).
- The Grimmory user must own or have access to the shelf.
- Sufficient local storage in the download directory.

---

## Setting up Shelf Sync

1. Open **Tools → GrimmLink → Shelf Sync → Enable Shelf Sync** and toggle it on.
2. Open **Tools → GrimmLink → Shelf Sync → Select Shelf** — GrimmLink fetches available shelves from Grimmory and shows a picker.
3. Optionally set a custom **Download Directory** (leave empty to auto-detect a `books/` subdirectory in KOReader's data directory).
4. Optionally enable **Use Original Filename** (default: on) to save files with the server's original filename.
5. Optionally enable **Auto-sync on Resume** (default: off) to run shelf sync silently on device resume.

---

## Triggering Shelf Sync

| Method | How |
|--------|-----|
| **Manual** | **Tools → GrimmLink → Sync Shelf Now** |
| **Auto on resume** | Enable via **Tools → GrimmLink → Shelf Sync → Auto-sync on Resume** |

---

## Download directory

Books are saved to the configured download directory. If no directory is configured, GrimmLink auto-detects one:

| Priority | Source |
|----------|--------|
| 1 | Configured `download_dir` setting (if set and accessible) |
| 2 | `<KOReader data dir>/books/` |
| 3 | `<KOReader data dir>` |
| 4 | KOReader settings directory (last resort) |

### Filenames

When **Use Original Filename** is enabled, GrimmLink uses the filename stored in Grimmory (sanitized for filesystem safety). When disabled, GrimmLink derives the filename from the book title and ID (e.g., `Dune_42.epub`).

Filename collisions are resolved by appending a counter suffix (e.g., `Dune_42_2.epub`).

---

## Removing books from the shelf

If **Delete Removed Books** is enabled (default: off), books that were previously downloaded by GrimmLink but are no longer present in the Grimmory shelf will be deleted from the local download directory during the next sync.

> **Warning:** Enabling this setting permanently deletes local files. Only files previously downloaded and tracked by GrimmLink are affected. User files not tracked by GrimmLink are never deleted.

When **Delete .sdr When Removing** is also enabled (default: off), GrimmLink also removes the `.sdr` sidecar directory for deleted books.

---

## Local mapping

GrimmLink tracks all downloaded books in the `shelf_sync_map` SQLite table:

| Field | Description |
|-------|-------------|
| `book_id` | Grimmory book ID |
| `shelf_id` | Grimmory shelf ID |
| `remote_filename` | Original server filename |
| `remote_title` | Book title at download time |
| `remote_author` | Book author at download time |
| `remote_format` | File format (e.g., EPUB) |
| `remote_file_size_kb` | File size at download time (KB) |
| `local_path` | Absolute local path on device |
| `downloaded_at` | Timestamp of download |
| `last_seen_in_shelf_at` | Timestamp of last shelf sync where this book appeared |
| `downloaded_by_grimmlink` | Always 1 for GrimmLink-managed files |

---

## Known limitations

- Only regular Grimmory shelves are supported. Magic shelves (dynamic filter-based shelves) are not supported.
- Sync is synchronous — the plugin UI shows a message but does not provide per-book progress.
- No automatic retry for individual failed downloads — re-run Sync Shelf Now to retry.
- No file integrity verification after download (no MD5 check).
- Push side (local deletion → shelf removal) is not implemented in this version.
