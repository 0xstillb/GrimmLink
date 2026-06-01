# GrimmLink Plugin Test Plan

This plan is the release gate for the current connection model (local-first, no SSID dependency) and recent wake/latency tuning.

## 0) Scope

- Verify connection setup UX and connection-test responsiveness.
- Verify wake/sleep behavior does not feel blocked by GrimmLink network work.
- Verify shelf sync refactor safety (planning, cleanup, pending removals, magic shelf paths).
- Verify release hygiene (tests, docs, tags).

## 1) Test Environment

- KOReader device (or emulator) with GrimmLink installed.
- Grimmory reachable from:
  - Local URL (LAN), example: `http://192.168.x.x:6060`
  - Remote URL (WAN), example: `https://example.com`
- Valid KOReader username + key/password.
- At least one book already matched in Grimmory.
- Optional: one regular shelf + one magic shelf with known books.

## 2) Pre-Flight (Mandatory)

Run before device QA:

- `git diff --check`
- `./run_tests.sh` (or `busted test`)
- confirm no release ZIPs are committed
- confirm docs updated (`README.md`, `CHANGELOG.md`, this file when behavior changes)

Pass criteria:

- tests green
- no whitespace errors
- no accidental release artifacts in git

## 3) Smoke Test (10-15 Minutes)

1. Open `Tools -> GrimmLink -> Connection -> Setup Connection`.
2. Enter Local URL, Remote URL, Username, Password.
3. Run `Test Connection`.
4. Open a matched book, read forward, close.
5. Run `Sync Pending Now`.

Pass criteria:

- setup saves successfully
- connection test returns clear result dialog (success or actionable failure)
- session/progress sync does not crash

## 4) Connection Test Matrix (Critical)

### CONN-01 Local Healthy

- Condition: device on LAN, local URL reachable.
- Action: `Test Connection`.
- Expect:
  - `Result: success`
  - `Active server` shows local nickname if set, else `Local`
  - completion feels fast (target around local timeout profile)

### CONN-02 Local Down, Remote Healthy

- Condition: break local endpoint, keep remote reachable.
- Action: `Test Connection`.
- Expect:
  - no freeze perception beyond timeout window
  - clear failure/success messaging with active route info
  - if fallback path is used by runtime, messaging remains understandable

### CONN-03 No Internet

- Condition: Wi-Fi off / disconnected.
- Action: `Test Connection`.
- Expect:
  - short message: `No network connection`
  - no long diagnostic wall in normal mode

### CONN-04 Diagnostics View

- Action: `Test Connection with Diagnostics`.
- Expect:
  - header is concise
  - includes `Result`, `Active server`, `Duration`
  - includes truncated/testable URL display and route/failure reason

## 5) Wake/Sleep Responsiveness Matrix

### WAKE-01 Resume Without Network

- Condition: device offline.
- Action: sleep -> wake 10 rounds.
- Expect:
  - no long UI stall on wake
  - no spam dialogs

### WAKE-02 Resume With Network (Sync Disabled)

- Condition: `sync_on_network_connected = false`.
- Action: sleep -> wake 10 rounds.
- Expect:
  - no noticeable blocking on wake
  - no unexpected pending sync kick-off

### WAKE-03 Resume With Network (Sync Enabled)

- Condition: `sync_on_network_connected = true`.
- Action: sleep -> wake 10 rounds.
- Expect:
  - grace window prevents immediate duplicate trigger after resume
  - pending sync starts only after delay logic, without UI lockup

## 6) Shelf Sync Regression Matrix

### SHELF-01 Plan/Resume Safety

- Use a shelf with many books.
- Trigger sync and interrupt once.
- Re-run sync.
- Expect:
  - planning resumes safely
  - no duplicate local DB mapping corruption

### SHELF-02 Cleanup Safety

- Remove books from synced shelf remotely.
- Run shelf sync cleanup.
- Expect:
  - only GrimmLink-tracked items are touched
  - `.sdr` deletion respects setting

### SHELF-03 Pending Removals

- Force temporary remove failure (network/offline), then recover.
- Re-run sync.
- Expect:
  - pending removals retry and clear on success

### SHELF-04 Magic Shelf Directory Moves

- Enable separate magic directory.
- Sync and validate moved files.
- Disable separate magic directory and sync again.
- Expect:
  - files move to correct target path both directions
  - local DB `local_path` stays consistent

## 7) Progress/Session/Metadata Regression

- Open -> pull progress path works.
- Read -> close/suspend -> pending/session created.
- `Sync Pending Now` replays once without duplicates.
- Metadata batch sync still works for rating/highlights/bookmarks.

## 8) Release Gate Checklist

Before `commit push releases`:

1. `CHANGELOG.md` updated for target version.
2. `README.md` updated for latest behavior/endpoints/workflow.
3. `docs/TEST_PLAN.md` reflects current runtime behavior.
4. Commit and push to `origin/main`.
5. Tag and push `vX.Y.Z` (CI creates release assets automatically).

Quick verify:

- `git ls-remote --tags origin vX.Y.Z`
- `gh release view vX.Y.Z --repo 0xstillb/GrimmLink`

## 9) Exit Criteria

Release candidate is approved only when:

- automated tests pass
- all sections in this plan pass (or have documented risk acceptance)
- no unresolved P1/P2 regressions
- local and GitHub version/tag state are aligned
