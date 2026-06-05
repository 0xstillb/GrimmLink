# GrimmLink Project Guide

KOReader companion plugin for Grimmory.
This file is the developer-facing project snapshot for the current `main` branch.

## Project Identity

- Repo: `https://github.com/0xstillb/GrimmLink`
- Local path: `E:\projects\grimmory\grimmlink`
- Runtime: KOReader Lua environment
- Plugin root: `grimmlink.koplugin/`

## What GrimmLink Does

- Sync reading progress between KOReader and Grimmory.
- Sync reading sessions.
- Sync metadata (rating, highlights/notes, bookmarks) as upload batches.
- Sync shelves (regular/magic), including downloads.
- Provide maintenance, diagnostics, and queue recovery tools.

## Current Connection Model (Important)

- Routing policy is local-first and no longer depends on SSID matching.
- If local transport fails recently, GrimmLink can temporarily prefer remote.
- API fallback is one-way for runtime safety:
  - local primary can fallback to remote
  - remote primary does not fallback back to local
- `Test Connection` temporarily disables fallback to avoid long double-wait tests.

## Connection UX (Current)

- `Setup Connection` flow asks:
  - Local URL
  - Home URL Nickname (optional)
  - Remote URL
  - Remote URL Nickname (optional)
  - Username
  - Password
- `Test Connection` is concise.
- `Test Connection with Diagnostics` includes route/failure details.
- Active server label behavior:
  - shows nickname when configured
  - otherwise falls back to `Local` or `Remote`

## Timeouts and Wake Behavior (Current)

- Runtime request timeouts:
  - local: `2s`
  - remote: `1s`
- Test auth timeouts:
  - local: `1.5s`
  - remote/fallback source: `0.8s`
- Resume smoothing:
  - delay resume network refresh by `1.0s`
  - delay auto shelf sync on resume by `4.0s`
  - suppress immediate network-connected auto-sync during `12s` grace after resume

## Main Runtime Hooks

- `onReaderReady`: start reading session flow.
- `onSuspend`: end session safely.
- `onResume`: delayed refresh/sync scheduling to reduce wake lag.
- `onNetworkConnected`: optional auto pending sync with grace and cooldown handling.

## API Client Design Notes

File: `grimmlink.koplugin/grimmlink_api_client.lua`

- Uses LuaSocket HTTP/HTTPS requests.
- Returns structured request details for diagnostics:
  - `used_url`
  - `fallback_attempted`
  - `fallback_success`
- Tracks last primary transport failure via `getLastPrimaryFailure()`.
- Supports separate `fallback_timeout`.

Known caveat:
- First DNS resolution on some networks/devices may still exceed request timeout expectations.

## Backend Endpoints Used

- `GET /api/grimmlink/v1/auth`
- `GET /api/grimmlink/v1/books/by-hash/{hash}`
- `GET /api/grimmlink/v1/syncs/progress/{hash}`
- `PUT /api/grimmlink/v1/syncs/progress`
- `POST /api/grimmlink/v1/reading-sessions`
- `POST /api/grimmlink/v1/reading-sessions/batch`
- `POST /api/grimmlink/v1/syncs/metadata`
- `POST /api/grimmlink/v1/syncs/metadata/batch`
- `GET /api/grimmlink/v1/shelves`
- `GET /api/grimmlink/v1/shelves/{type}/{id}/books`
- `GET /api/grimmlink/v1/shelves/{id}/books` (fallback path)
- `GET /api/grimmlink/v1/books/{bookId}/download`
- `POST /api/grimmlink/v1/shelves/{type}/{id}/books/{bookId}/remove`
- `POST /api/grimmlink/v1/shelves/{id}/books/{bookId}/remove` (fallback path)
- `GET /api/grimmlink/v1/books/read-statuses`
- `PUT /api/grimmlink/v1/books/{bookId}/status`
- `GET /api/grimmlink/v1/books/{bookId}/pdf-progress`
- `PUT /api/grimmlink/v1/books/{bookId}/pdf-progress`

## High-Level Module Map

- `main.lua`: plugin entrypoint, menu/UI, session/progress/sync orchestration.
- `grimmlink_api_client.lua`: transport, auth headers, fallback behavior.
- `grimmlink_database.lua`: queues, cache, plugin settings, migrations.
- `grimmlink_shelf_sync.lua`: shelf planning, download, cleanup.
- `grimmlink_updater.lua`: update checks/install from GitHub releases.
- `grimmlink_file_logger.lua`: file logger and cleanup.
- `test/*.lua`: busted tests with KOReader stubs.

## Menu Overview

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

Connection submenu:
- Setup Connection
- Local URL
- Remote URL
- Username
- Password
- Test Connection
- Test Connection with Diagnostics

## Testing

- Test framework: `busted`
- Common command:
  - `busted test/main_helpers_spec.lua test/api_client_spec.lua`
- Current workstream passed local tests during development.

## Release Workflow (Must Follow)

- Do not create GitHub releases manually.
- Update `CHANGELOG.md` first.
- Commit and push `main`.
- Create and push version tag `vX.Y.Z`.
- CI (`release.yml`) generates assets and publishes release.

## Git Rules for This Repo

- Use `origin` repo for PRs and release flow:
  - `0xstillb/GrimmLink`
- Do not target `upstream` (`WorldTeacher/BookLoreSync-plugin`) for PRs.

## Current Version Context

- Latest release in this workstream: `v1.4.3`
- `CHANGELOG.md` contains the detailed delta list for this version.
