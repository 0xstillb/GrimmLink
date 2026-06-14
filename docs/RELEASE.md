# GrimmLink Release Candidate Checklist

## Version And Packaging

- [ ] `grimmlink.koplugin/plugin_version.lua` is valid for the current branch state
- [ ] tagged releases regenerate `plugin_version.lua` and `_meta.lua`
- [ ] canonical release asset name is `grimmlink.koplugin.zip`
- [ ] compatibility release asset name is `grimmlink-vX.Y.Z.zip`
- [ ] updater documentation matches the actual asset names
- [ ] no ZIP artifacts are committed in the repository

## Core Behavior

- [ ] KOReader auth works
- [ ] hash-based matching works
- [ ] native progress pull/push works
- [ ] reading session upload works
- [ ] offline queue replay works
- [ ] Shelf Sync safety rules remain intact
- [ ] annotation merge safety remains intact
- [ ] auto-update still uses `0xstillb/grimmlink` only
- [ ] PDF progress uses the native progress sync path

## Safety

- [ ] no Grimmory library/server file delete path exists
- [ ] no Grimmory book record delete path exists
- [ ] Shelf Sync remains shelf membership sync only
- [ ] no user settings/database/cache are deleted by the updater
- [ ] no downloaded books are deleted by the updater
- [ ] no `.sdr` files are deleted by the updater by default
- [ ] progress sync failure never blocks reading

## CI Gate

- [ ] `.github/workflows/ci.yml` exists and passes
- [ ] `.github/workflows/release.yml` exists
- [ ] Lua syntax checks pass
- [ ] active plugin tests pass
- [ ] updater source checks pass
- [ ] no packaging artifacts are committed

## Documentation Gate

- [ ] `README.md` explains install, auth, settings, and safety defaults
- [ ] `docs/PLUGIN_SCOPE.md` reflects current GrimmLink MVP scope
- [ ] `docs/TEST_PLAN.md` reflects CI plus manual runtime validation
- [ ] `docs/RELEASE.md` reflects the release candidate checklist

## Known Limitations

- real KOReader runtime validation is still required on device
- cross-reader progress may resolve to a nearby chapter or page rather than an exact visual position
- local development may rely on CI for Lua syntax/runtime checks when Lua tooling is unavailable
