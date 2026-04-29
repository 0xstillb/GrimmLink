# GrimmLink

KOReader Companion for Grimmory

This repository is the dedicated KOReader plugin home for GrimmLink. It started as a fork of `WorldTeacher/BookLoreSync-plugin`, and it is now being adapted for Grimmory-specific backend support and GrimmLink branding.

## Current Scope

The current GrimmLink MVP focuses on:

- KOReader authentication with `x-auth-user` and `x-auth-key`
- book matching by hash against Grimmory
- KOReader-native progress pull and push
- EPUB progress syncing as KOReader-native data
- reading session upload and offline batch replay
- Moon+ Reader-like local/remote progress comparison

Not part of the current MVP:

- Web Reader bridge
- EPUB CFI conversion
- rating sync
- highlights, notes, or bookmarks sync
- shelf or library sync

## Repository Layout

- `grimmlink.koplugin/`: active plugin package for KOReader
- `docs/`: legacy upstream documentation and future cleanup surface
- `test/`: legacy upstream tests that may be trimmed or replaced later

## Installation

1. Copy the plugin package into KOReader's `plugins` directory:

   ```bash
   cp -r grimmlink.koplugin {your_koreader_installation}/plugins/
   ```

2. Fully restart KOReader.

3. In KOReader, configure:
   - Grimmory server URL
   - username
   - auth key
   - device name / device ID

## Notes

- Auto-update should remain disabled until GrimmLink has its own release channel.
- GrimmLink sends KOReader-native EPUB progress only. It does not convert to EPUB CFI and does not bridge into Grimmory Web Reader fields.
- This repo is now separate from the main Grimmory server repository so plugin work can evolve independently.
