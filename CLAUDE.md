# GrimmLink — Claude Instructions

## Git Workflow

### PRs must target `origin` only — NEVER `upstream`

- `origin` = `0xstillb/grimmlink` ← PRs go here
- `upstream` = `WorldTeacher/BookLoreSync-plugin` ← never open PRs here

Always pass `--repo 0xstillb/grimmlink` explicitly when creating PRs:

```bash
gh pr create --repo 0xstillb/grimmlink --base main ...
```

## Release Workflow

CI (`release.yml`) จัดการทุกอย่างอัตโนมัติเมื่อ push tag — **ห้าม manual create release เด็ดขาด**

```bash
# 1. update CHANGELOG.md ใส่ version ใหม่
# 2. commit + push ถึง main
git add CHANGELOG.md
git commit -m "chore: bump version to v<X.Y.Z>"
git push origin main

# 3. push tag → CI จัดการทุกอย่าง (generate-version, zip, release)
git tag v<X.Y.Z>
git push origin v<X.Y.Z>
```

CI จะทำให้เอง:
- รัน `generate-version.sh`
- สร้าง `grimmlink.koplugin.zip` และ `grimmlink-v<X.Y.Z>.zip`
- สร้าง GitHub Release พร้อม assets และ changelog
