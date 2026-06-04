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

กฎนี้รวมถึงส่วน version ใน `README.md` ด้วยทุกครั้ง:

- badge ด้านบน `version-v<X.Y.Z>`
- section `## Version`
- ค่า `Version`, `Type`, `Commit`, `Build`

ทั้งหมดต้องตรงกับ GitHub Release ล่าสุดและค่าจาก `grimmlink.koplugin/plugin_version.lua` บน `origin/main` ก่อน commit/push/tag เสมอ

```bash
# 1. update CHANGELOG.md ใส่ version ใหม่ — ต้องทำก่อน tag เสมอ
# 1.5 update README.md ให้สะท้อน behavior/API/workflow ล่าสุด
#     และ sync badge + Version section ให้ตรง release/latest plugin_version.lua
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

`README.md` ต้อง sync ตาม source-of-truth นี้ด้วยในสองจุด:

- version badge ด้านบน
- บล็อก `## Version`

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

## Code Layout + File Edit Rules

### `main.lua` must stay thin

`grimmlink.koplugin/main.lua` ต้องทำหน้าที่เป็น composition root เท่านั้น:

- โหลด dependency/module
- เก็บ shared helpers ที่ใช้ข้ามหลาย controller จริงๆ
- install controller ต่างๆ
- เก็บ lifecycle/runtime wiring ระดับบน

ห้ามย้าย business logic ก้อนใหญ่กลับไปกองใน `main.lua` อีก ยกเว้นเป็น orchestration ระดับบนที่ยังไม่มี owner ชัดเจน

ถ้ามี logic ใหม่ที่ชัดว่าเป็นเรื่องใดเรื่องหนึ่ง ให้เพิ่มหรือขยาย controller ที่ตรงโดเมนแทน เช่น:

- progress/session -> controller เฉพาะ
- tracking/current-context -> tracking controller
- pending sync scheduling/replay -> pending sync controller
- maintenance/admin/debug actions -> maintenance/diagnostics controller

### Generated files are not hand-maintained sources

ไฟล์ต่อไปนี้ถือเป็น generated/release-synced files:

- `grimmlink.koplugin/plugin_version.lua`
- `grimmlink.koplugin/_meta.lua`

กฎ:

- อย่าใส่ manual edits ลงสองไฟล์นี้แล้วคาดหวังว่าจะอยู่ถาวร ถ้ายังไม่ได้แก้ generator ต้นทาง
- ถ้าต้องเปลี่ยนรูปแบบหรือ field ของไฟล์พวกนี้ ให้แก้ที่ `generate-version.sh` ก่อน
- หลัง release ต้องถือค่าบน `origin/main` เป็น source-of-truth ของสองไฟล์นี้เสมอ

### Docs and tests must move with structure changes

ถ้ามีการแยก controller, ย้าย ownership ของ method, หรือเปลี่ยน behavior ที่ผู้ใช้มองเห็นได้:

- อัปเดต `README.md` ให้สะท้อน structure/behavior/workflow ล่าสุด
- อัปเดต `CHANGELOG.md`
- เพิ่มหรือปรับ tests ที่ครอบ behavior ใหม่หรือ wiring ใหม่

อย่างน้อยต้อง rerun:

```bash
busted.cmd test
```

และถ้าแตะ wiring/helpers กลาง ให้ rerun:

```bash
busted.cmd test/main_helpers_spec.lua
```

### Device QA artifacts must stay out of release commits

ไฟล์ชั่วคราวจาก ADB/device QA, smoke tests, screenshots, JSON command fixtures, helper scripts สำหรับทดสอบเฉพาะรอบ:

- ห้ามปล่อยปนเข้า release commit โดยไม่ตั้งใจ
- ถ้าจำเป็นต้องมีไว้ชั่วคราว ให้เก็บใน temp path และลบก่อนจบงาน
- อย่า stage `.agents/`, screenshots, หรือ scratch files เว้นแต่ตั้งใจ commit มันจริงๆ

### Keep edits narrow and ownership-driven

เวลาแก้โค้ด:

- แก้ไฟล์ owner ที่ตรงกับปัญหาก่อน
- อย่ากระจาย helper ซ้ำหลายไฟล์ถ้ายังใช้ shared helper เดิมได้
- อย่าผสม refactor โครงสร้างกับ behavior change โดยไม่จดใน changelog/tests
- ถ้าปัญหาเกิดจาก release automation, generator, หรือ CI sync ให้แก้ต้นทาง ไม่ใช่แค่แก้ output file ปลายทาง
