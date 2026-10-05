# GrimmLink for CrossPoint

Experimental CrossPoint SD-card client for the GrimmLink API.

## Current v0.1 scope

- Runs on CrossPoint's SD-card plugin framework; no firmware rebuild is required.
- Browses one configured Grimmory shelf directly on the reader.
- Downloads EPUB files only by always saving the selected book as `.epub`.
- Writes `<book>.meta.json` with `grimmory_id` for service identity and KOSync metadata forwarding.
- Never deletes local books.
- Does not yet perform bulk shelf reconciliation/automatic downloads.

## Install

Copy this directory to:

`/.crosspoint/plugins/grimmlink/`

Then copy `config.example.json` to `config.json` and edit it with your Grimmory settings.

Required values:

- `server`: Grimmory base URL, without a trailing slash.
- `username`: Grimmory username.
- `auth_key`: MD5 of the Grimmory password, matching GrimmLink v1 authentication.
- `shelf_type`: `regular` or `magic` when supported by the server.
- `shelf_id`: numeric Grimmory shelf id.
- `dest_dir`: optional CrossPoint download directory. CrossPoint allows this config value to override the manifest default.

Open **Settings -> System -> Plugins -> GrimmLink** on the reader.

## Safety

This first version is intentionally pull-only. It never removes local files or mutates Grimmory shelf membership.

## Next step: true Shelf Sync

CrossPoint's declarative `device.json` can browse and download on-device but cannot loop over a shelf and reconcile it with local files. True bulk Shelf Sync therefore belongs in the browser-side `plugin.js` runner (or a future generic firmware primitive), while preserving this manifest as the standalone manual-download path.
