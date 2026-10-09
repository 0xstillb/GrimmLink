# GrimmLink for CrossPoint — SD plugin

Mobile-first **Light / Dark** GrimmLink Shelf Sync for X4 Pro, with a calm minimalist UI.
Runs in the CrossPoint Settings / File Manager web interface. The firmware stays unmodified.

## Two modes

| Reader screen | Phone / PC browser |
|---|---|
| \`device.json\`: navigate Regular/Magic shelves and download one EPUB at a time | \`plugin.js\` + \`style.css\`: Home, Shelves, Books, Preview, Sync, Complete, History and Settings |

- **Web Sync:** Choose a Regular or Magic Shelf, preview a verified EPUB-only plan, and press **เริ่ม Sync**.
- The **X4 Pro fetches EPUB bytes directly to SD** via CrossPoint's \`/api/fetch\`. The phone/PC runs the sync orchestration; keep its browser tab open until completion.
- Sync progress is currently shown **per completed book**, not live download byte percentage.
- Manual Sync only; no background or automatic boot sync.
- Dark/light choice and limited Sync history are saved in that browser's localStorage, **not shared across browsers**.
- The homepage uses a CSS-generated bookshelf illustration (no external image requests).
- Book thumbnails currently use soft CSS placeholders. The existing GrimmLink v1 Shelf API has **no confirmed authenticated cover-image transport suitable for the CrossPoint browser plugin**; actual BookLore/Grimmory covers are intentionally not claimed as working yet.

## Install on SD

Place these files at:

\`/.crosspoint/plugins/grimmlink/\`

\`\`\`text
grimmlink/
├── manifest.json
├── plugin.js
├── style.css
├── device.json
├── config.json          ← create this yourself, do not commit credentials
└── README.md
\`\`\`

Copy \`config.example.json\` to \`config.json\`:

\`\`\`json
{
  "server": "https://your-grimmory-server.example",
  "username": "your-username",
  "auth_key": "md5-of-your-password",
  "dest_dir": "/GrimmLink"
}
\`\`\`

Use a trusted Wi-Fi network: CrossPoint's file-transfer web interface and locally served configuration are not a public-facing authenticated application.

**To open Web Shelf Sync:**
1. Connect X4 Pro and phone/PC to the same network, start **File Transfer** on X4 Pro.
2. Open its on-screen address (or \`http://crosspoint.local/settings\` if mDNS works).
3. Find the **GrimmLink** plugin card under Settings.
4. Select Shelf → review Preview → start Sync.

## Local file structure

Web Sync uses **one folder per shelf** to avoid filename conflicts across shelves:

\`\`\`text
/GrimmLink/
├── regular-7/
│   ├── gl-123-Book Title.epub
│   └── gl-123-Book Title.epub.meta.json
└── magic-4/
    └── gl-456-Other Book.epub
\`\`\`

The on-device \`device.json\` manual downloader still saves into \`/GrimmLink\` directly and does not delete any books. Its navigation relies on the CrossPoint XML catalog routes in the separate Grimmory experimental branch; this is **not** a prerequisite for the web browser Shelf Sync.

## Safety and error handling

- **Remove is off by default** on every Preview.
- Removal only considers files with readable sidecars containing \`source: "grimmlink"\`, \`managed: true\`, and the **exact selected Shelf type/id** in its own folder.
- Corrupt/unknown sidecars disable removal. Files copied manually are preserved.
- A filename collision with a non-managed file blocks Sync to avoid overwrites.
- Remote Shelf enumeration uses bounded \`limit/offset\` pages (12 books/page) to fit CrossPoint's 32 KB relay response cap. Repeated IDs, invalid pages or oversized responses abort Sync.
- The server is rechecked **before any removal**; if the Shelf membership changed, deletion is cancelled.
- If any fetch, validation or sidecar write fails, the Sync stops. Files already downloaded remain; deletion does not proceed.
- The cancel button stops **after the currently downloading book**.
- PDFs and unsupported book formats are skipped.
- KOSync reading progress remains managed by CrossPoint's native KOReader sync mechanism, independent of this browser UI.
- Do not enable deletion until you have verified the first download-only sync on your X4 Pro.

## Source/API dependencies

Uses only existing CrossPoint browser/SD APIs:
\`/api/status\`, \`/api/files\`, \`/download\`, \`/delete\`,
\`/api/relay\`, \`/api/fetch\`, \`/api/plugin-fs\`.

Uses GrimmLink:
\`/api/grimmlink/v1/shelves?type=...\`,
\`/api/grimmlink/v1/shelves/{type}/{id}/books?limit=12&offset=...\`,
\`/api/grimmlink/v1/books/{id}/download\`.

No X4 Pro firmware fork or new Grimmory endpoint is required for the **web** experience.

## Verification

Browser JS syntax, API contract review and simulated Web Shelf Sync have been checked; real-world mobile/device QA is still required with X4 Pro + Grimmory. Run any included browser mock tests with Node.js. This feature branch is experimental; no release/merge is implied.
