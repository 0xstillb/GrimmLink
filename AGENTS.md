# GrimmLink — Codex Instructions

## Git Workflow

### PRs must target `origin` only — NEVER `upstream`

- `origin` = `0xstillb/GrimmLink` ← PRs go here
- `upstream` = `WorldTeacher/BookLoreSync-plugin` ← never open PRs here

Always pass `--repo 0xstillb/GrimmLink` explicitly when creating PRs:

```bash
gh pr create --repo 0xstillb/GrimmLink --base main ...
```

Before pushing, ensure local and remote main are aligned:

```bash
git fetch origin --tags
git rev-parse HEAD
git rev-parse origin/main
```

Both commit hashes must match after push.

## Release Workflow

CI (`release.yml`) จัดการทุกอย่างอัตโนมัติเมื่อ push tag — **ห้าม manual create release เด็ดขาด**

### Mandatory docs update before release

ถ้ามีคำสั่งแนว `commit push releases` (หรือ release equivalent) ต้องอัปเดต `README.md` ให้สอดคล้องกับโค้ดและ workflow ล่าสุดก่อน commit/push/tag ทุกครั้ง

```bash
# 1. update CHANGELOG.md ใส่ version ใหม่ — ต้องทำก่อน tag เสมอ
# 1.5 update README.md ให้สะท้อน behavior/API/workflow ล่าสุด
# 2. commit + push ถึง main
git add CHANGELOG.md README.md
git commit -m "chore: bump version to v<X.Y.Z>"
git push origin main

# 3. push tag → CI จัดการทุกอย่าง (generate-version, zip, release)
git tag v<X.Y.Z>
git push origin v<X.Y.Z>
```

Quick verification after tag push:

```bash
git ls-remote --tags origin v<X.Y.Z>
gh release view v<X.Y.Z> --repo 0xstillb/GrimmLink
```

### Version sync rule (mandatory)

`plugin_version.lua` และ `_meta.lua` ต้องถือว่าเป็น source-of-truth จาก `origin/main` หลัง release workflow รันเสร็จเสมอ

หลังปล่อย tag และ CI ผ่านแล้ว ต้อง sync local กลับให้ตรงแบบนี้:

```bash
git fetch origin --tags
git pull --ff-only origin main
git rev-parse HEAD
git rev-parse origin/main
```

ทั้งสอง hash ต้องตรงกัน และ `grimmlink.koplugin/plugin_version.lua` ต้องสะท้อน tag ล่าสุดบน remote

CI จะทำให้เอง:
- รัน `generate-version.sh`
- สร้าง `grimmlink.koplugin.zip` และ `grimmlink-v<X.Y.Z>.zip`
- สร้าง GitHub Release พร้อม assets และ changelog
- sync `grimmlink.koplugin/plugin_version.lua` + `_meta.lua` กลับเข้า `origin/main` อัตโนมัติ
