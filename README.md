<p align="center">
  <h1 align="center">GrimmLink</h1>
  <p align="center">KOReader companion plugin for <a href="https://github.com/0xstillb/grimmory">Grimmory (0xstillb fork)</a></p>
</p>

> GrimmLink ออกแบบมาสำหรับ Grimmory โดยเฉพาะ (ไม่ใช่ปลั๊กอิน universal sync)

<p align="center">
  <img src="https://img.shields.io/badge/platform-KOReader-blue" alt="Platform">
  <img src="https://img.shields.io/badge/language-Lua-purple" alt="Language">
  <img src="https://img.shields.io/github/v/release/0xstillb/grimmlink?label=release" alt="Release">
  <img src="https://img.shields.io/github/license/0xstillb/grimmlink" alt="License">
</p>

---

## GrimmLink คืออะไร

GrimmLink คือปลั๊กอิน KOReader ที่เชื่อมการอ่านบนเครื่อง (EPUB/PDF/CBZ ฯลฯ) เข้ากับ Grimmory เพื่อ:

- sync progress แบบ push/pull
- sync reading sessions
- sync metadata แบบ upload-only (rating/highlight/note/bookmark)
- sync shelf (regular + magic shelf) และดาวน์โหลดไฟล์ลงเครื่อง
- มี maintenance/debug tools สำหรับดูสถานะคิวและแก้ปัญหาได้เอง

---

## GrimmLink ทำอะไรได้บ้าง

### 1) Progress Sync

- Pull remote progress ตอนเปิดหนังสือ
- Push local progress ตอนปิด/พัก/สั่ง manual sync
- มี conflict prompt ก่อนกระโดดตำแหน่ง
- รองรับ read status flow ที่ผูกกับ Grimmory (`UNREAD`, `READING`, `READ`, และสถานะเสริมที่ backend รองรับ)

### 2) Reading Session Sync

- เก็บ session การอ่านในเครื่อง
- อัปโหลดตอนออนไลน์
- ถ้าเน็ตล่มจะค้างในคิวและ retry ภายหลัง

### 3) Metadata Sync (Upload-only)

- ดึง rating/highlight/note/bookmark จาก KOReader
- ส่ง batch ไป endpoint เดียว:
  - `/api/koreader/syncs/metadata`
- ใช้ auth header:
  - `x-auth-user`
  - `x-auth-key`
- ไม่มี Bearer token
- ไม่มี pull metadata กลับเข้า KOReader ใน phase ปัจจุบัน
- ไม่มี deletion sync ของ annotation/bookmark ใน phase ปัจจุบัน

### 4) Shelf Sync (Regular + Magic)

- เลือก sync ได้ทั้ง regular shelf และ magic shelf
- รองรับ private shelf แบบใส่ ID ตรงๆ พร้อม validate ก่อนใช้งาน
- ดาวน์โหลดไฟล์พร้อม progress dialog/cancel
- มี async + blocking fallback ตามความสามารถเครื่อง
- มี local tombstone/queue จัดการการลบฝั่ง local อย่างปลอดภัย
- ไม่ลบไฟล์ server/library ของ Grimmory

### 5) Maintenance / Debug / Recovery

- clear logs
- export debug info (redacted)
- clear pending queues (progress/session/metadata)
- clear local metadata synced history
- clear shelf tombstones/pending removals
- rebuild SimpleUI metadata cache
- rebuild/force metadata resync รายเล่ม
- re-match current book
- show DB status/pending counts

ทุก action ที่ทำลายข้อมูล local จะมี confirmation ก่อน

---

## เมนูหลักปัจจุบัน (ย่อให้ใช้ง่าย)

`Tools -> GrimmLink`

- Enable GrimmLink
- Connection
- Sync Progress Now
- Sync Shelf Now
- Sync Metadata Now
- Pull Remote Progress
- Manual Reading Status
- Toggle Tracking (Current Book)
- Advanced Setting
- Status / About

หมายเหตุ:

- `Preview Metadata` อยู่ใน `Advanced Setting -> Metadata Sync`

---

## ความต่าง GrimmLink vs KoSync

KoSync คือระบบ sync พื้นฐานของ KOReader สำหรับ reading progress ระหว่างอุปกรณ์เป็นหลัก
GrimmLink คือ integration กับ Grimmory แบบครบวงจร

| หัวข้อ | GrimmLink | KoSync |
|---|---|---|
| เป้าหมาย | ผูกกับ Grimmory โดยตรง | sync progress ทั่วไปของ KOReader |
| Auth | `x-auth-user` + `x-auth-key` | ตามระบบ KoSync |
| Progress push/pull | มี | มี |
| Reading sessions | มี | โดยทั่วไปไม่มี |
| Metadata (rating/highlight/note/bookmark) | มี (upload-only) | โดยทั่วไปไม่มี |
| Shelf sync + ดาวน์โหลดไฟล์ | มี (regular/magic/private ID) | ไม่มี |
| Manual reading status menu | มี (ตาม backend capability) | ไม่มี |
| Maintenance queues/debug export | มี | จำกัดกว่า |
| Grimmory-specific API | ใช้โดยตรง | ไม่ได้ออกแบบมาเพื่อ Grimmory |

สรุปสั้นๆ:

- ถ้าต้องการแค่ sync ตำแหน่งอ่านระหว่าง KOReader อาจใช้ KoSync ได้
- ถ้าต้องการ workflow เต็มกับ Grimmory (shelf + metadata + sessions + maintenance) ให้ใช้ GrimmLink

---

## การติดตั้ง

1. ดาวน์โหลด `grimmlink.koplugin.zip` จาก [Release ล่าสุด](https://github.com/0xstillb/grimmlink/releases/latest)
2. แตกไฟล์ลง `plugins/` ของ KOReader
3. รีสตาร์ท KOReader
4. เข้า `Tools -> GrimmLink -> Connection`
5. ใส่:
   - Grimmory Server URL
   - Username
   - Password
6. กด Test Connection

หมายเหตุ:

- ปลั๊กอินจะคำนวณ `x-auth-key` ภายในเองจากรหัสผ่าน
- ผู้ใช้ไม่ต้องกรอก token/bearer key เอง

---

## ค่าตั้งค่าสำคัญ

| Setting | Default | ความหมาย |
|---|---|---|
| `metadata_sync_enabled` | `false` | เปิด metadata sync |
| `rating_sync_enabled` | `true` | ส่ง rating |
| `annotations_sync_enabled` | `true` | ส่ง highlights/notes |
| `bookmarks_sync_enabled` | `true` | ส่ง bookmarks |
| `sync_regular_shelf_enabled` | `false` | เปิด regular shelf sync |
| `sync_magic_shelf_enabled` | `false` | เปิด magic shelf sync |
| `ask_wifi_before_sync` | `true` | ถามก่อนใช้ Wi-Fi เมื่อสั่ง sync ตอน offline |
| `sync_on_network_connected` | `false` | sync อัตโนมัติเมื่อเน็ตกลับมา |
| `network_sync_cooldown_seconds` | `300` | กัน sync ถี่เกิน |
| `auto_update_enabled` | `false` | อัปเดตอัตโนมัติ |
| `check_update_on_startup` | `false` | เช็กอัปเดตตอนเปิด KOReader |

---

## Privacy / Logging Policy

GrimmLink ตั้งใจไม่เขียนข้อมูลลับหรือ content เต็มลง log/debug export:

- ไม่ log รหัสผ่าน
- ไม่ log `x-auth-key`
- ไม่ log bearer/authorization token
- ไม่ dump เต็มของ `payload_json`
- ไม่ export ข้อความ highlight/note เต็ม

Debug export จะเน้น counters, queue status, และข้อมูลเชิงวินิจฉัยที่ปลอดภัย

---

## Delete Policy

- ลบได้เฉพาะไฟล์ local ที่ GrimmLink ดาวน์โหลดและ track เอง
- ถ้าหนังสือยังถูก track โดย shelf อื่น จะไม่ลบไฟล์
- ไม่ลบไฟล์/records ฝั่ง Grimmory server/library

---

## Known Limitations (ปัจจุบัน)

- Metadata sync เป็น upload-only
- ยังไม่ดึง annotation/bookmark จาก Grimmory กลับเข้า KOReader
- ยังไม่มี deletion sync ของ annotation/bookmark
- ความสามารถบางสถานะอ่านขึ้นกับ backend capability

---

## โครงสร้างโปรเจกต์

```text
grimmlink.koplugin/
  main.lua
  grimmlink_api_client.lua
  grimmlink_database.lua
  grimmlink_shelf_sync.lua
  grimmlink_updater.lua
  plugin_version.lua
  _meta.lua
  test/
```

---

## Credits

GrimmLink มีจุดเริ่มต้นจากแนวคิดของ BookLoreSync plugin และพัฒนาต่อให้ตรงกับ Grimmory workflow

---

## License

ดูที่ [LICENSE](LICENSE)
