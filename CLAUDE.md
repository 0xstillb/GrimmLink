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

ทำตามลำดับนี้ทุกครั้ง:

```bash
# 1. merge ถึง main แล้ว pull
git pull origin main

# 2. tag
git tag v<X.Y.Z>
git push origin v<X.Y.Z>

# 3. generate version files (ต้อง tag ก่อนเสมอ)
bash generate-version.sh
git add grimmlink.koplugin/plugin_version.lua grimmlink.koplugin/_meta.lua
git commit -m "chore: generate version files for v<X.Y.Z>"
git push origin main

# 4. สร้าง zip ด้วย git archive เท่านั้น (ห้ามใช้ PowerShell Compress-Archive)
git archive --format=zip v<X.Y.Z> grimmlink.koplugin/ -o grimmlink.koplugin.zip

# 5. create release พร้อม attach zip
gh release create v<X.Y.Z> grimmlink.koplugin.zip \
  --repo 0xstillb/grimmlink \
  --title "v<X.Y.Z>" \
  --notes "..."

# 6. ลบ zip ทิ้ง
rm grimmlink.koplugin.zip
```
