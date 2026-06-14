# GrimmLink Release Checklist

## 1. Install / Upgrade

1. Confirm backup/snapshot exists for KOReader data partition.
2. Install/upgrade `grimmlink.koplugin` from release ZIP.
3. Restart KOReader.
4. Open `Tools -> GrimmLink` and verify plugin loads without errors.

## 2. Clean Install Smoke

1. Configure Local URL, Remote URL, Home SSID, Username, Password.
2. Run `Test Connection`.
3. Confirm no manual token/Bearer auth configuration is required (`x-auth-user`/`x-auth-key` only).

## 3. Core Sync Verification

1. Progress push works.
2. Progress pull works.
3. Conflict prompt appears for newer remote progress.
4. Reading session sync works.
5. Continue Reading behavior still works.
6. PDF progress uses the native progress endpoint and restores the expected page.

## 4. Metadata Sync Verification

1. `Preview Metadata` works.
2. `Sync Metadata Now` works.
3. Rebuild metadata queue for current book works.
4. Force metadata resync for current book works.
5. Failed items remain pending (per retry policy).
6. Duplicate responses do not duplicate server rows.
7. No full note/highlight text appears in logs or debug export.

## 5. Shelf Sync Verification

1. Regular shelf sync works.
2. Magic shelf sync works.
3. Add Shelf by ID / Validate Shelf ID works for both `regular` and `magic`.
4. Same book in multiple shelves downloads once/reuses local file.
5. Remove from one shelf preserves file if another shelf still tracks it.
6. Disk-space check skips only insufficient items and continues others.
7. Separate magic download directory works when enabled.

## 6. Offline / Network Verification

1. Offline manual sync prompts Wi-Fi confirmation when enabled.
2. Resume/network-triggered sync respects cooldown.
3. Duplicate sync guard prevents overlapping runs.
4. Local/remote URL switching works with home SSID logic.

## 7. Maintenance / Debug Verification

1. Clear Logs works.
2. Export GrimmLink Debug Info works and is redacted.
3. Clear pending queues (progress/sessions/metadata) works.
4. Clear synced metadata history works (local-only).
5. Clear shelf tombstones and pending shelf removals works.
6. Rebuild SimpleUI metadata cache works.
7. Re-match current book works.
8. DB status/pending counts view works.

## 8. Compatibility Verification

1. Kindle path fallback still works.
2. Async download fallback to blocking mode still works on unsupported devices.
3. Auto-update keeps user data/state.
4. Updater repo remains `0xstillb/grimmlink`.

## 9. CI / Local Commands

Run from `E:\projects\grimmory\grimmlink`:

```powershell
where luac
```

If `luac` exists:

```powershell
Get-ChildItem -Recurse grimmlink.koplugin -Filter *.lua | ForEach-Object { & luac -p $_.FullName }
```

Run grep checks:

```powershell
findstr /S /I "BookLoreSync bookloresync BookloreSync" grimmlink.koplugin\*.lua README.md CHANGELOG.md
findstr /S /I "/api/v1/books/personal-rating /api/v1/annotations /api/v2/book-notes /api/v1/book-notes /api/v1/bookmarks" grimmlink.koplugin\*.lua
findstr /S /I "delete remove unlink os.remove" grimmlink.koplugin\*.lua
findstr /S /I "payload_json note highlight x-auth-key password Authorization token" grimmlink.koplugin\*.lua
```

## 10. Rollback

1. Keep the previous plugin backup archive.
2. Reinstall previous `grimmlink.koplugin` version.
3. Restart KOReader.
4. Re-run `Test Connection` and a quick manual sync.

## 11. Grimmory Develop Docker Preview Check

1. Pull the develop preview image:
   - `docker pull ghcr.io/0xstillb/grimmory:develop`
2. Pin an immutable debug image when needed:
   - `docker pull ghcr.io/0xstillb/grimmory:develop-<sha>`
3. In compose override, set:
   - `image: ghcr.io/0xstillb/grimmory:develop`
4. Restart stack and validate GrimmLink integration endpoints:
   - auth (`/api/koreader/users/auth`)
   - progress (`/api/koreader/syncs/progress/*`)
   - metadata batch (`/api/koreader/syncs/metadata`)
   - shelf typed routes (`/api/koreader/shelves/{type}/{id}/books`)
5. Record test commit/image tag pair in QA notes before promotion to `main` release flow.

## 12. Manual Test Report Sheet (PASS/FAIL/NA)

Fill this table during device test runs.

| ID | Area | Test Case | Result | Evidence / Log Ref | Notes |
|---|---|---|---|---|---|
| T00 | Baseline | Pull latest `ghcr.io/0xstillb/grimmory:develop` and restart stack | pass |  |  |
| T01 | Baseline | `grimmory` container status is `healthy` | pass |  |  |
| T02 | Baseline | No immediate startup exception in last 2m logs | pass |  |  |
| T03 | Core | GrimmLink plugin loads without crash | pass |  |  |
| T04 | Core | `Test Connection` works | pass |  |  |
| T05 | Core | Progress push works | pass |  |  |
| T06 | Core | Progress pull works | pass |  |  |
| T07 | Core | Conflict prompt appears/works | pass |  |  |
| T08 | Core | Long-press `Sync This Book` works | pass |  |  |
| T09 | Core | Long-press `Toggle Tracking` works | pass |  |  |
| T10 | Core | Tracking disabled skips auto sync/session/metadata | pass |  |  |
| T11 | Session | Reading session sync works online | pass |  |  |
| T12 | Session | Session queues while offline | pass |  |  |
| T13 | Session | Queued sessions flush when online | pass |  |  |
| T14 | Metadata | `Preview Metadata` works | pass |  |  |
| T15 | Metadata | `Sync Metadata Now` works | pass |  |  |
| T16 | Metadata | `metadata_sync_enabled` toggle works | pass |  |  |
| T17 | Metadata | `rating_sync_enabled` toggle works | pass |  |  |
| T18 | Metadata | `annotations_sync_enabled` toggle works | pass |  |  |
| T19 | Metadata | `bookmarks_sync_enabled` toggle works | pass |  |  |
| T20 | Metadata | Failed metadata remains pending | pass |  |  |
| T21 | Metadata | Logs/export redact note/highlight/auth key/token/payload_json |  |  |  |
| T22 | Shelf | Regular shelf sync works | pass |  |  |
| T23 | Shelf | Magic shelf sync works | pass |  |  |
| T24 | Shelf | Regular+Magic both enabled flow works without stuck state | pass |  |  |
| T25 | Shelf | Same book in multiple shelves downloads once/reuses file | pass |  |  |
| T26 | Shelf | Removed from one shelf but kept by other shelf -> file remains | pass |  |  |
| T27 | Shelf | No server/library file deletion behavior | pass |  |  |
| T28 | Download | Low disk space path: item skipped, sync continues |  |  |  |
| T29 | Download | No disk-space API path: sync continues without crash |  |  |  |
| T30 | Reader | EPUB downloaded via shelf opens in KOReader | pass |  |  |
| T31 | Reader | PDF downloaded via shelf opens in KOReader | pass |  |  |
| T32 | Network | `ask_wifi_before_sync` behavior works | pass |  |  |
| T33 | Network | `sync_on_network_connected` behavior works | pass |  |  |
| T34 | Network | `network_sync_cooldown_seconds` respected | pass |  |  |
| T35 | Network | Duplicate sync guard prevents overlap |  |  |  |
| T36 | Network | Local/remote URL switching works |  |  |  |
| T37 | Network | Home SSID logic works |  |  |  |
| T38 | Maintenance | `Clear Logs` works (with confirmation) |  |  |  |
| T39 | Maintenance | `Export GrimmLink Debug Info` works and redacts secrets/content |  |  |  |
| T40 | Maintenance | Clear pending progress queue works |  |  |  |
| T41 | Maintenance | Clear pending sessions queue works |  |  |  |
| T42 | Maintenance | Clear pending metadata queue works |  |  |  |
| T43 | Maintenance | Clear synced metadata history works (local-only) |  |  |  |
| T44 | Maintenance | Clear shelf tombstones works |  |  |  |
| T45 | Maintenance | Clear pending shelf removals works |  |  |  |
| T46 | Maintenance | Rebuild SimpleUI metadata cache works |  |  |  |
| T47 | Maintenance | Rebuild/Force metadata resync for current book works |  |  |  |
| T48 | Maintenance | Re-match current book works |  |  |  |
| T49 | Maintenance | DB status / pending counts view works |  |  |  |
| T50 | Compatibility | Kindle/e-ink path fallback works |  |  |  |
| T51 | Compatibility | Async download fallback to blocking works |  |  |  |
| T52 | Compatibility | Auto-update preserves settings/db/queues |  |  |  |
| T53 | Compatibility | Update repo remains `0xstillb/grimmlink` |  |  |  |

### Failure Evidence Capture

Use these commands whenever a case fails and attach output with test ID.

```bash
docker logs --since 2m grimmory 2>&1 | grep -E "debugId=|KOReader|magic shelf|LazyInitializationException|ERROR|Exception"
```

```bash
docker logs --since 2m grimmory 2>&1 > /tmp/grimmory_fail.log
```
