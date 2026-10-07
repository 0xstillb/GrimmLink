# GrimmLink for CrossPoint

Experimental CrossPoint SD-card client for the GrimmLink API. It keeps the firmware service-agnostic: no CrossPoint firmware rebuild is required.

## v0.2 scope

Two complementary modes are included:

- **On-device:** browse Regular and Magic Grimmory shelves on the reader and fetch EPUB books one at a time through `device.json`.
- **Web Shelf Sync:** open the CrossPoint File Transfer / Settings web UI from a phone or PC, choose a Grimmory shelf, preview the reconciliation plan, then press **Sync Shelf**. The EPUB bytes travel directly from Grimmory to the X4 Pro SD card through CrossPoint's `/api/fetch`; the phone/PC only hosts the browser-side `plugin.js`.

Web Shelf Sync:
- filters the selected shelf to EPUB;
- lists the configured local destination on the X4 Pro;
- identifies managed books by their `.meta.json` sidecars;
- downloads missing EPUBs;
- writes ownership + shelf identity into sidecars;
- skips already-managed books;
- can optionally remove books no longer in the selected shelf.

Removal is **off by default**. A file is eligible for removal only when its sidecar has `source: "grimmlink"`, `managed: true`, and the same `shelf_type` + `shelf_id` as the shelf being synced. Manually copied books and older manual-download sidecars are therefore not deletion candidates.

## Install

Copy this directory to:

`/.crosspoint/plugins/grimmlink/`

Then copy `config.example.json` to `config.json` and edit:

- `server`: Grimmory base URL, without a trailing slash.
- `username`: Grimmory username.
- `auth_key`: MD5 of the Grimmory password, matching GrimmLink v1 authentication.
- `dest_dir`: optional destination, default `/GrimmLink`.

## Use on the X4 Pro

Open **Settings -> System -> Plugins -> GrimmLink**. Navigate Regular or Magic shelves and fetch an EPUB. This path is intentionally one-book-at-a-time and never removes local books.

## Use Shelf Sync from a phone or PC

1. Put the X4 Pro and phone/PC on the same network.
2. Start CrossPoint File Transfer / web server on the X4 Pro.
3. Open the CrossPoint web UI from the phone/PC.
4. Open the GrimmLink card.
5. Choose **Regular** or **Magic**, then choose a shelf.
6. Press **Preview** to inspect downloads/removal candidates.
7. Press **Sync Shelf**.
8. Leave **Remove GrimmLink-managed books...** unchecked for download-only sync. Enable it only when you want the selected shelf mirrored.

The browser must remain open while the sync is running. It orchestrates the requests, but book payloads are downloaded by the X4 Pro directly to SD.

## Safety invariants

- A failed/invalid Grimmory shelf request stops the run before removal.
- Unsupported/PDF entries are skipped.
- Downloads are staged by CrossPoint before replacing the destination file.
- Removal is opt-in.
- Removal is limited to GrimmLink-owned files from the exact selected shelf.
- Local-only/unmanaged books are never removal candidates.
- No firmware changes are required.

## Compatibility note

The web mode uses generic CrossPoint web-server endpoints already present in the firmware: `/api/files`, `/download`, `/delete`, `/api/relay`, `/api/fetch`, and `/api/plugin-fs`. The integration stays in the SD plugin rather than adding GrimmLink-specific firmware code.
