# GrimmLink MVP Release Checklist

## Included

- [ ] KOReader auth works
- [ ] hash-based matching works
- [ ] native progress pull/push works
- [ ] reading session upload works
- [ ] shelf sync safety rules remain intact
- [ ] annotation merge safety remains intact
- [ ] auto-update still uses `0xstillb/grimmlink` only
- [ ] CI passes on the plugin branch
- [ ] Prompt 8 Web Reader Bridge is present but default OFF
- [ ] Prompt 8 EPUB CFI conversion is present but default OFF

## Safety

- [ ] no user settings/database/cache are deleted
- [ ] no downloaded books are deleted by updater
- [ ] no `.sdr` files are deleted by updater
- [ ] no shelf sync path deletes Grimmory library/server files
- [ ] no shelf sync path deletes Grimmory book records
- [ ] bridge failure never blocks reading
- [ ] failed CFI conversion falls back safely

## CI Gate

- [ ] `.github/workflows/ci.yml` passes
- [ ] Lua syntax checks pass
- [ ] active plugin tests pass
- [ ] updater safety checks pass
- [ ] no packaging artifacts are committed

## Web Reader Bridge

- [ ] bridge reads/writes only the dedicated Web Reader bridge endpoints
- [ ] native KOReader progress still works independently when bridge is disabled
- [ ] remote-newer bridge state prompts before jump
- [ ] conflict flow offers `Use KOReader`, `Use Web Reader`, `Ignore`
- [ ] raw KOReader location/page/xpointer remains preserved

## Known Limitations

- real KOReader runtime validation is still required on device
- EPUB CFI conversion is best-effort, not guaranteed exact
- local development here may rely on CI for Lua syntax/runtime checks

## Next Phase

- Prompt 9 Full Integration / Runtime Test
