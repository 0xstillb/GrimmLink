(function () {
  'use strict';

  // Browser-side CrossPoint plugin. All library bytes go from Grimmory to the device.
  CrossPoint.registerPlugin(async function (container, api) {
    const PAGE_SIZE = 12; // Keep Grimmory relay responses below the device's 32 KB cap.
    const MAX_PAGES = 150;
    const HISTORY_KEY = 'grimmlink.crosspoint.history.v1';
    const THEME_KEY = 'grimmlink.crosspoint.theme.v1';
    const state = {
      cfg: null, view: 'home', type: 'regular', shelves: { regular: null, magic: null },
      shelf: null, books: [], plan: null, filter: 'all', query: '',
      busy: false, loading: false, cancel: false, deleteManaged: false,
      progress: { done: 0, total: 0, title: '', results: [] },
      result: null, error: '', device: null,
      theme: readPreference(THEME_KEY) || ((window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) ? 'dark' : 'light'),
      history: readHistory()
    };

    const styleLink = document.createElement('link');
    styleLink.rel = 'stylesheet';
    styleLink.href = api.pluginFile('style.css');
    document.head.appendChild(styleLink);

    const root = document.createElement('div');
    root.className = 'gl-app';
    container.replaceChildren(root);

    function readPreference(key) { try { return localStorage.getItem(key); } catch (_) { return null; } }
    function savePreference(key, value) { try { localStorage.setItem(key, value); } catch (_) {} }
    function readHistory() {
      try {
        const v = JSON.parse(localStorage.getItem(HISTORY_KEY) || '[]');
        return Array.isArray(v) ? v.slice(0, 20) : [];
      } catch (_) { return []; }
    }
    function h(value) {
      return String(value == null ? '' : value).replace(/[&<>"']/g, function (c) {
        return ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c];
      });
    }
    function base(s) { return String(s || '').replace(/\/+$/, ''); }
    function label(type) { return type === 'magic' ? 'Magic Shelves' : 'Regular Shelves'; }
    function selId(s) { return s && (s.id != null ? s.id : (s.shelfId != null ? s.shelfId : s.shelf_id)); }
    function bookId(b) { return b && (b.bookId != null ? b.bookId : (b.id != null ? b.id : b.book_id)); }
    function asList(v) {
      if (Array.isArray(v)) return v;
      if (v && Array.isArray(v.content)) return v.content;
      if (v && Array.isArray(v.items)) return v.items;
      throw new Error('Unexpected Grimmory response. No books will be removed.');
    }
    function supported(b) {
      const e = String(b.extension || '').toLowerCase().replace(/^\./, '');
      const f = String(b.fileFormat || b.file_format || '').toLowerCase().replace(/^\./, '');
      const name = String(b.fileName || b.originalFileName || '').toLowerCase();
      return e === 'epub' || f === 'epub' || ((!e && !f) && name.endsWith('.epub'));
    }
    function safeTitle(value) {
      return (String(value || 'Untitled').replace(/[\\/:*?"<>|\x00-\x1f]/g, '_')
        .replace(/^\.+/, '').replace(/[. ]+$/, '').trim() || 'Untitled').slice(0, 94);
    }
    function safeFile(b) {
      const id = String(bookId(b));
      if (!/^[0-9]+$/.test(id)) throw new Error('Book ID is invalid: ' + id);
      return 'gl-' + id + '-' + safeTitle(b.title || b.fileName || 'Book') + '.epub';
    }
    function folder(type, id) {
      if (!['regular', 'magic'].includes(type) || !/^[0-9]+$/.test(String(id))) {
        throw new Error('Unsafe shelf identity');
      }
      return state.cfg.dest_dir + '/' + type + '-' + id;
    }
    function statusLine() {
      if (state.device && state.device.device) return 'X4 Pro • ' + (state.device.ip || 'Connected');
      return state.device ? 'CrossPoint connected' : 'CrossPoint web interface';
    }
    function dateLabel(iso) {
      try { return new Date(iso).toLocaleString('th-TH', { dateStyle: 'short', timeStyle: 'short' }); }
      catch (_) { return iso; }
    }
    function fmtSize(bytes) {
      if (!(Number(bytes) > 0)) return '';
      return Number(bytes) >= 1048576 ? (Number(bytes) / 1048576).toFixed(1) + ' MB' : Math.ceil(Number(bytes) / 1024) + ' KB';
    }
    function estimate(b) {
      return Number(b.fileSize) > 0 ? Number(b.fileSize) :
        Number(b.fileSizeKb) > 0 ? Number(b.fileSizeKb) * 1024 : 0;
    }
    function cover(b, index) {
      // No unauthenticated cover endpoint has been confirmed for GrimmLink v1.
      // Show an intentional, local CSS placeholder rather than broken cover URLs.
      return '<span class="gl-cover ' + (index % 3 === 1 ? 'alt' : index % 3 === 2 ? 'third' : '') + '" aria-hidden="true">▤</span>';
    }
    function shelfIcon(type) { return '<span class="gl-shelf-art ' + (type === 'magic' ? 'magic' : '') + '" aria-hidden="true">' + (type === 'magic' ? '✧' : '▥') + '</span>'; }
    function intro(shelf) {
      return '<div class="gl-intro">' + shelfIcon(state.type) +
        '<div class="gl-grow"><h3>' + h(shelf.name || shelf.title || ('Shelf ' + selId(shelf))) + '</h3>' +
        '<div class="gl-micro">' + label(state.type) + ' · ' + state.books.length + ' เล่ม</div></div></div>';
    }
    function cardTitle(title, trailing) {
      return '<div class="gl-section-title"><h3>' + h(title) + '</h3>' + (trailing || '') + '</div>';
    }
    function alert() { return state.error ? '<div class="gl-alert error" role="alert">' + h(state.error) + '</div>' : ''; }
    function navButton(key, symbol, name) {
      const active = state.view === key || (key === 'shelves' && ['books', 'preview', 'sync', 'complete'].includes(state.view));
      return '<button type="button" data-act="nav" data-view="' + key + '" class="' + (active ? 'active' : '') +
        '"><span>' + symbol + '</span>' + h(name) + '</button>';
    }
    function bottomButton(key, symbol, name) {
      const active = state.view === key || (key === 'shelves' && ['books', 'preview', 'sync', 'complete'].includes(state.view));
      return '<button type="button" data-act="nav" data-view="' + key + '" class="' + (active ? 'active' : '') +
        '"><b>' + symbol + '</b>' + h(name) + '</button>';
    }
    function header() {
      const titles = {
        home: 'GrimmLink', shelves: label(state.type), books: state.shelf && (state.shelf.name || state.shelf.title),
        preview: 'Sync Preview', sync: 'กำลัง Sync...', complete: 'Sync Complete',
        history: 'Sync History', settings: 'Settings'
      };
      return '<div class="gl-topbar"><div><div class="gl-kicker">for X4 Pro</div><h2>' +
        h(titles[state.view] || 'GrimmLink') + '</h2><p class="gl-subtitle">' +
        h(state.view === 'home' ? 'ห้องสมุดของคุณ บน X4 Pro' : statusLine()) +
        '</p></div><div class="gl-top-actions">' +
        (state.view !== 'home' && state.view !== 'sync' ? '<button class="gl-iconbtn" data-act="back" title="ย้อนกลับ" aria-label="ย้อนกลับ">←</button>' : '') +
        '<button class="gl-iconbtn" data-act="theme" title="เปลี่ยนธีม" aria-label="เปลี่ยนธีม">' +
        (state.theme === 'dark' ? '☀' : '☾') + '</button></div></div>';
    }
    function homeScreen() {
      const selected = state.plan && state.shelf;
      const ready = selected ? state.plan.keep.length : '—';
      const missing = selected ? state.plan.download.length : '—';
      const count = selected ? state.plan.remote.length : '—';
      return '<div class="gl-home-hero"><div class="gl-hero-copy"><div class="gl-kicker">YOUR READING SPACE</div>' +
        '<h3>GrimmLink</h3><p>เชื่อมต่อห้องสมุดของคุณ<br>กับ X4 Pro อย่างเรียบง่าย</p></div>' +
        '<div class="gl-hero-art" aria-hidden="true"><span></span><span></span><span></span><span></span><span></span></div></div>' +
        '<div class="gl-panel gl-inline" style="margin-bottom:13px"><span class="' + (state.device ? 'gl-green-dot' : 'gl-red-dot') +
        '"></span><div class="gl-grow"><div class="gl-name">' + h(statusLine()) +
        '</div><div class="gl-micro">Web Shelf Sync • Download directly to SD</div></div></div>' +
        '<div class="gl-stats"><div class="gl-stat"><b>' + h(count) + '</b><span>Selected shelf</span></div>' +
        '<div class="gl-stat"><b>' + h(ready) + '</b><span>On device</span></div>' +
        '<div class="gl-stat"><b>' + h(missing) + '</b><span>Need sync</span></div></div>' +
        cardTitle('ชั้นหนังสือ', '<button class="gl-textbtn" data-act="nav" data-view="shelves">ดูทั้งหมด →</button>') +
        '<div class="gl-shelf-grid">' +
        ['regular', 'magic'].map(function (type) {
          return '<button class="gl-shelf-card" data-act="type" data-type="' + type + '">' + shelfIcon(type) +
            '<span class="gl-grow"><span class="gl-name">' + label(type) + '</span><span class="gl-micro">' +
            (type === 'regular' ? 'ชั้นหนังสือที่จัดด้วยตนเอง' : 'ชั้นหนังสือแบบอัจฉริยะ') +
            '</span></span><span class="gl-count">›</span></button>';
        }).join('') + '</div>' +
        cardTitle('Sync ล่าสุด', '<button class="gl-textbtn" data-act="nav" data-view="history">ดูประวัติ →</button>') +
        (state.history.length ? '<div class="gl-panel">' + state.history.slice(0, 2).map(function (e) {
          return '<div class="gl-history-item"><div class="gl-name">✓ ' + h(e.name) +
            '</div><div class="gl-micro">' + h(dateLabel(e.at)) + ' • ดาวน์โหลด ' + h(e.downloaded) + ' เล่ม</div></div>';
        }).join('') + '</div>' : '<div class="gl-empty">ยังไม่มีประวัติ Sync บนเบราว์เซอร์นี้</div>');
    }
    function shelvesScreen() {
      const list = state.shelves[state.type] || [];
      const query = state.query.trim().toLocaleLowerCase();
      const filtered = list.filter(function (s) { return String(s.name || s.title || '').toLocaleLowerCase().includes(query); });
      return '<div class="gl-control-row"><div class="gl-segment">' +
        ['regular', 'magic'].map(function (type) {
          return '<button data-act="type" data-type="' + type + '" class="' +
            (type === state.type ? 'active' : '') + '">' + (type === 'regular' ? 'Regular' : 'Magic') + '</button>';
        }).join('') + '</div><input class="gl-search" data-role="search" aria-label="ค้นหา Shelf" placeholder="ค้นหา Shelf..." value="' +
        h(state.query) + '"></div>' +
        (state.loading ? '<div class="gl-empty">กำลังโหลด Shelf...</div>' :
          filtered.length ? '<div class="gl-shelf-list">' + filtered.map(function (s) {
            return '<button class="gl-shelf-card" data-act="shelf" data-id="' + h(selId(s)) + '">' +
              shelfIcon(state.type) + '<span class="gl-grow"><span class="gl-name">' + h(s.name || s.title || 'Untitled') +
              '</span><span class="gl-micro">' + h(s.bookCount != null ? s.bookCount + ' เล่ม' : 'เลือกเพื่อดูหนังสือ') +
              '</span></span><span class="gl-count">›</span></button>';
          }).join('') + '</div>' : '<div class="gl-empty">ไม่พบ Shelf</div>');
    }
    function bookStatus(b) {
      if (!supported(b)) return ['ข้าม (ไม่ใช่ EPUB)', ''];
      if (!state.plan) return ['EPUB', ''];
      const id = String(bookId(b));
      if (state.plan.local.has(id)) return ['มีแล้ว', 'good'];
      if (state.plan.conflicts.some(function (entry) { return String(bookId(entry.book)) === id; })) return ['ชื่อซ้ำ', 'bad'];
      return ['ยังไม่มี', 'info'];
    }
    function booksScreen() {
      if (!state.shelf) return '<div class="gl-empty">เลือก Shelf ก่อน</div>';
      const all = state.books || [];
      const visible = all.filter(function (b) {
        const id = String(bookId(b));
        if (state.filter === 'ready') return state.plan && state.plan.local.has(id);
        if (state.filter === 'missing') return state.plan && state.plan.download.some(function (item) { return String(bookId(item)) === id; });
        if (state.filter === 'skipped') return !supported(b);
        return true;
      });
      return intro(state.shelf) +
        '<div class="gl-control-row"><div class="gl-segment">' +
        [['all', 'ทั้งหมด'], ['ready', 'มีแล้ว'], ['missing', 'ยังไม่มี'], ['skipped', 'ข้าม']].map(function (v) {
          return '<button class="' + (state.filter === v[0] ? 'active' : '') + '" data-act="filter" data-filter="' +
            v[0] + '">' + v[1] + '</button>';
        }).join('') + '</div></div>' +
        (state.loading ? '<div class="gl-empty">กำลังตรวจสอบรายการหนังสือและ SD...</div>' :
          visible.length ? '<div class="gl-book-list">' + visible.map(function (b, i) {
            const s = bookStatus(b);
            return '<div class="gl-book">' + cover(b, i) +
              '<div class="gl-grow"><div class="gl-name">' + h(b.title || b.fileName || 'Untitled') + '</div>' +
              '<div class="gl-micro">' + h((b.author || '') + (estimate(b) ? ' · ' + fmtSize(estimate(b)) : '')) + '</div></div>' +
              '<span class="gl-pill ' + s[1] + '">' + h(s[0]) + '</span></div>';
          }).join('') + '</div>' : '<div class="gl-empty">ไม่พบรายการหนังสือในหมวดนี้</div>') +
        '<div class="gl-action-panel"><button class="gl-button full" data-act="preview" ' +
        (state.loading ? 'disabled' : '') + '>⌁ &nbsp; Sync Shelf</button>' +
        '<div class="gl-micro gl-center" style="margin-top:7px">ตรวจสอบรายการก่อนดาวน์โหลดเสมอ</div></div>';
    }
    function summaryRow(icon, text, count, tone) {
      return '<div class="gl-summary-row"><span class="gl-s-icon ' + (tone || '') + '">' + icon + '</span>' +
        '<span>' + h(text) + '</span><strong>' + h(count) + '</strong></div>';
    }
    function summary(plan, remove) {
      return '<div class="gl-summary">' +
        summaryRow('✓', 'มีแล้ว (ไม่ต้องทำอะไร)', plan.keep.length, 'good') +
        summaryRow('↓', 'ดาวน์โหลดใหม่', plan.download.length, 'info') +
        summaryRow('▯', 'ข้าม (PDF/อื่น ๆ)', plan.skipped.length, '') +
        summaryRow('⊘', 'ชื่อไฟล์ชน / ต้องตรวจสอบ', plan.conflicts.length, 'bad') +
        summaryRow('⌫', 'อาจลบออก (managed only)', remove ? plan.remove.length : 'ปิด', 'bad') +
        '</div>';
    }
    function previewScreen() {
      const p = state.plan;
      if (!p) return '<div class="gl-empty">ยังไม่มี Sync Preview</div>';
      return intro(state.shelf) +
        summary(p, state.deleteManaged) +
        '<label class="gl-option"><span class="gl-grow"><strong>ลบหนังสือที่ไม่อยู่ใน Shelf</strong>' +
        '<div class="gl-micro">เฉพาะไฟล์ managed ของ Shelf นี้ • ค่าเริ่มต้นปิด</div></span>' +
        '<input type="checkbox" data-role="remove" ' + (state.deleteManaged ? 'checked' : '') +
        (p.unsafeLocal || p.unsafeRemote ? ' disabled' : '') + '></label>' +
        (p.unsafeLocal ? '<div class="gl-alert">พบ sidecar ที่ไม่สามารถยืนยันได้ ' + p.unsafeLocal +
        ' ไฟล์ — ปิดการลบเพื่อความปลอดภัย</div>' : '') +
        (p.unsafeRemote ? '<div class="gl-alert">จำนวนหนังสือที่อ่านได้ไม่ตรงกับ Shelf count — ปิดการลบเพื่อความปลอดภัย</div>' : '') +
        (p.conflicts.length ? '<div class="gl-alert error">พบชื่อไฟล์ชนกับหนังสือที่ไม่ได้จัดการโดย GrimmLink จึงไม่สามารถ Sync จนกว่าจะแก้ชื่อไฟล์</div>' : '') +
        '<div class="gl-micro">' + h(p.download.length) + ' EPUB ต้องดาวน์โหลด' +
        (p.downloadBytes ? ' · ประมาณ ' + fmtSize(p.downloadBytes) : '') + '</div>' +
        (p.download.length ? '<div class="gl-panel" style="margin-top:13px;max-height:220px;overflow:auto">' +
          p.download.slice(0, 20).map(function (b) { return '<div class="gl-micro">↓ ' + h(b.title || safeFile(b)) + '</div>'; }).join('') +
          (p.download.length > 20 ? '<div class="gl-micro">และอีก ' + (p.download.length - 20) + ' เล่ม</div>' : '') +
          '</div>' : '') +
        '<div class="gl-action-panel"><button class="gl-button full" data-act="sync" ' +
        (p.conflicts.length || state.busy ? 'disabled' : '') + '>⌁ &nbsp; เริ่ม Sync</button>' +
        '<p class="gl-micro gl-center">เปิดหน้าเว็บไว้ระหว่าง Sync • ส่ง EPUB ไป SD โดยตรง</p></div>';
    }
    function syncingScreen() {
      const p = state.progress;
      const percent = p.total ? Math.round((p.done / p.total) * 100) : 100;
      return intro(state.shelf) + '<div class="gl-panel"><strong>' +
        (state.cancel ? 'กำลังหยุดหลังจบเล่มปัจจุบัน...' : 'กำลังดาวน์โหลด...') +
        '</strong><div class="gl-micro">' + h(p.done) + ' / ' + h(p.total) + ' เล่ม • ' + percent +
        '%</div><div class="gl-progress"><span style="width:' + percent + '%"></span></div>' +
        '<div class="gl-micro">เล่มปัจจุบัน: ' + h(p.title || 'กำลังเตรียมข้อมูล') +
        '</div></div><div class="gl-panel" style="margin-top:14px;max-height:280px;overflow:auto">' +
        p.results.slice(-20).map(function (e) {
          return '<div class="gl-history-item"><span class="gl-s-icon ' + (e.ok ? 'good' : 'bad') +
            '">' + (e.ok ? '✓' : '×') + '</span> ' + h(e.name) + '</div>';
        }).join('') + (p.results.length ? '' : '<div class="gl-micro">กำลังเชื่อมต่อ Grimmory...</div>') +
        '</div><div class="gl-action-panel"><button class="gl-button secondary full" data-act="cancel" ' +
        (state.cancel ? 'disabled' : '') + '>หยุดหลังดาวน์โหลดเล่มปัจจุบัน</button></div>';
    }
    function completeScreen() {
      const r = state.result || { downloaded: 0, removed: 0, kept: 0, skipped: 0, cancelled: true };
      return '<div class="gl-success" aria-hidden="true">' + (r.cancelled ? '!' : '✓') + '</div>' +
        '<h3 class="gl-center" style="font-size:23px;margin:0 0 8px">' +
        (r.cancelled ? 'Sync หยุดแล้ว' : 'Sync เสร็จสิ้น') + '</h3>' +
        '<p class="gl-center gl-muted" style="margin-bottom:25px">' + h(dateLabel(new Date().toISOString())) + '</p>' +
        '<div class="gl-summary">' +
        summaryRow('✓', 'มีแล้ว / ไม่ต้องทำอะไร', r.kept, 'good') +
        summaryRow('↓', 'ดาวน์โหลดใหม่', r.downloaded, 'info') +
        summaryRow('▯', 'ข้าม PDF/อื่น ๆ', r.skipped, '') +
        summaryRow('⌫', 'ลบออก (managed only)', r.removed, 'bad') +
        '</div><div class="gl-action-panel">' +
        '<button class="gl-button full" data-act="back-to-books">▤ &nbsp; ดูหนังสือใน Shelf นี้</button>' +
        '<button class="gl-button secondary full" data-act="nav" data-view="shelves" style="margin-top:10px">กลับไปยังรายการ Shelf</button></div>';
    }
    function historyScreen() {
      return state.history.length ?
        '<div class="gl-panel">' + state.history.map(function (e) {
          return '<div class="gl-history-item"><div class="gl-name">✓ ' + h(e.name) +
            '</div><div class="gl-micro">' + h(dateLabel(e.at)) + ' · ' + h(e.type) +
            ' · Download ' + h(e.downloaded) + ' · Removed ' + h(e.removed) +
            '</div></div>';
        }).join('') + '</div>' : '<div class="gl-empty">ยังไม่มีประวัติบนเบราว์เซอร์นี้</div>';
    }
    function settingsScreen() {
      return '<div class="gl-panel">' +
        '<div class="gl-summary-row"><span>สถานะ</span><strong>' + h(statusLine()) + '</strong></div>' +
        '<div class="gl-summary-row"><span>ปลายทาง SD</span><strong>' + h(state.cfg ? state.cfg.dest_dir : 'Not configured') + '</strong></div>' +
        '<div class="gl-summary-row"><span>Grimmory</span><strong>' + h(state.cfg ? base(state.cfg.server).replace(/^https?:\/\//, '') : 'Not configured') + '</strong></div>' +
        '<div class="gl-summary-row"><span>ธีม</span><strong>' + (state.theme === 'dark' ? 'Dark' : 'Light') + '</strong></div>' +
        '</div><div class="gl-alert">การตั้งค่า Server/บัญชีอยู่ใน config.json บน SD ของ X4 Pro ไม่แสดงรหัสผ่านในหน้านี้' +
        '<br>ประวัติ Sync เก็บในเบราว์เซอร์เครื่องที่ใช้เปิดเว็บเท่านั้น</div>' +
        '<button class="gl-button secondary full" data-act="reload">เชื่อมต่ออีกครั้ง</button>';
    }
    function render() {
      root.dataset.theme = state.theme;
      const page = {
        home: homeScreen, shelves: shelvesScreen, books: booksScreen,
        preview: previewScreen, sync: syncingScreen, complete: completeScreen,
        history: historyScreen, settings: settingsScreen
      }[state.view];
      root.innerHTML = '<div class="gl-shell"><aside class="gl-sidebar"><div class="gl-logo">' +
        '<span class="gl-symbol">▤</span><span>GrimmLink<small>for X4 Pro</small></span></div>' +
        '<div class="gl-nav">' +
        navButton('home', '⌂', 'Home') +
        navButton('shelves', '▥', 'Shelves') +
        navButton('history', '◷', 'Sync History') +
        navButton('settings', '⚙', 'Settings') +
        '</div><div class="gl-spacer"></div><div class="gl-connection"><span class="' +
        (state.device ? 'gl-green-dot' : 'gl-red-dot') + '"></span>' + h(statusLine()) +
        '<div class="gl-micro">GrimmLink SD Plugin</div></div></aside>' +
        '<main class="gl-main">' + header() + alert() + page() + '</main></div>' +
        '<nav class="gl-bottom-nav" aria-label="Navigation">' +
        bottomButton('home', '⌂', 'Home') +
        bottomButton('shelves', '▥', 'Shelves') +
        bottomButton('history', '◷', 'History') +
        bottomButton('settings', '⚙', 'Settings') + '</nav>';
    }
    async function loadConfig() {
      const r = await fetch(api.pluginFile('config.json'), { cache: 'no-store' });
      if (!r.ok) throw new Error('ไม่พบ config.json — คัดลอก config.example.json เป็น config.json บน SD');
      const cfg = await r.json();
      if (!cfg || !cfg.server || !cfg.username || !cfg.auth_key) {
        throw new Error('config.json ต้องมี server, username และ auth_key');
      }
      if (!/^https?:\/\/[^/]+/.test(cfg.server)) throw new Error('Server URL ต้องขึ้นต้นด้วย https:// หรือ http://');
      const dest = String(cfg.dest_dir || '/GrimmLink').replace(/\/+$/, '');
      if (!/^\/[A-Za-z0-9_\-/]+$/.test(dest) || dest.includes('..') || dest === '/') {
        throw new Error('Invalid SD destination; use /GrimmLink');
      }
      cfg.dest_dir = dest;
      state.cfg = cfg;
    }
    function authHeaders() {
      return { 'x-auth-user': state.cfg.username, 'x-auth-key': state.cfg.auth_key, Accept: 'application/json' };
    }
    async function relayJson(path) {
      if (!state.cfg) throw new Error('Server not configured');
      const response = await api.relay('GET', base(state.cfg.server) + path, authHeaders(), '');
      if (response.status < 200 || response.status >= 300) {
        throw new Error('Grimmory HTTP ' + response.status + ' กรุณาตรวจสอบ Server และบัญชี');
      }
      try { return JSON.parse(response.body); }
      catch (_) { throw new Error('Grimmory ตอบกลับไม่ใช่ JSON ที่สมบูรณ์ (อาจเกิน 32KB)'); }
    }
    async function loadShelves(type) {
      state.loading = true; render();
      try {
        const payload = await relayJson('/api/grimmlink/v1/shelves?type=' + encodeURIComponent(type));
        state.shelves[type] = asList(payload).filter(function (s) {
          return s && /^[0-9]+$/.test(String(selId(s)));
        });
        state.error = '';
      } catch (e) { state.error = String(e.message || e); }
      finally { state.loading = false; render(); }
    }
    async function loadBooks(type, id) {
      const path = '/api/grimmlink/v1/shelves/' + encodeURIComponent(type) +
        '/' + encodeURIComponent(id) + '/books';
      const books = [];
      const seen = new Set();
      for (let page = 0; page < MAX_PAGES; page++) {
        const chunk = asList(await relayJson(path + '?limit=' + PAGE_SIZE + '&offset=' + page * PAGE_SIZE));
        if (chunk.length > PAGE_SIZE) throw new Error('Grimmory ไม่รองรับ pagination ตามที่ร้องขอ: ปิด Sync เพื่อความปลอดภัย');
        for (const b of chunk) {
          const id = String(bookId(b));
          if (!/^[0-9]+$/.test(id) || seen.has(id)) {
            throw new Error('รายการหนังสือซ้ำหรือไม่มี Book ID — หยุด Sync');
          }
          seen.add(id);
          books.push(b);
        }
        if (chunk.length < PAGE_SIZE) return books;
      }
      throw new Error('รายการหนังสือยาวเกินขอบเขตที่ตรวจสอบได้ — หยุด Sync เพื่อความปลอดภัย');
    }
    async function listLocal(dir) {
      const r = await fetch('/api/files?path=' + encodeURIComponent(dir), { cache: 'no-store' });
      if (!r.ok) throw new Error('อ่านรายชื่อไฟล์ใน SD ไม่สำเร็จ (HTTP ' + r.status + ')');
      const files = await r.json();
      if (!Array.isArray(files)) throw new Error('รูปแบบรายการไฟล์ SD ไม่ถูกต้อง');
      return files;
    }
    async function readMeta(path) {
      const r = await fetch('/download?path=' + encodeURIComponent(path), { cache: 'no-store' });
      if (!r.ok) throw new Error('ไม่สามารถอ่าน sidecar: ' + path);
      try { return await r.json(); }
      catch (_) { throw new Error('sidecar ไม่ใช่ JSON: ' + path); }
    }
    async function inspectLocal(type, id) {
      const dir = folder(type, id);
      const files = await listLocal(dir);
      const names = new Set(files.filter(function (f) { return f && !f.isDirectory; }).map(function (f) { return String(f.name); }));
      const byName = new Map(files.map(function (f) { return [String(f.name), f]; }));
      const managed = new Map();
      let unsafe = 0;
      for (const f of files) {
        if (!f || f.isDirectory || !String(f.name).endsWith('.epub.meta.json')) continue;
        let meta;
        try { meta = await readMeta(dir + '/' + f.name); }
        catch (_) { unsafe++; continue; }
        if (!meta || meta.source !== 'grimmlink' || meta.managed !== true ||
          String(meta.shelf_type) !== type || String(meta.shelf_id) !== String(id) ||
          !/^[0-9]+$/.test(String(meta.grimmory_id || ''))) {
          unsafe++;
          continue;
        }
        const bookName = f.name.slice(0, -'.meta.json'.length);
        const match = byName.get(bookName);
        if (!match || !(Number(match.size) > 0) || managed.has(String(meta.grimmory_id))) {
          unsafe++; continue;
        }
        managed.set(String(meta.grimmory_id), {
          bookPath: dir + '/' + bookName,
          sidecarPath: dir + '/' + f.name,
          meta: meta
        });
      }
      return { managed: managed, names: names, unsafe: unsafe, dir: dir };
    }
    async function buildPlan() {
      const type = state.type, id = selId(state.shelf);
      if (!state.shelf || !/^[0-9]+$/.test(String(id))) throw new Error('กรุณาเลือก Shelf ก่อน');
      const remote = await loadBooks(type, id);
      const local = await inspectLocal(type, id);
      const wanted = new Set();
      const download = [], keep = [], skipped = [], conflicts = [], remove = [];
      let downloadBytes = 0;
      for (const b of remote) {
        const bid = String(bookId(b));
        wanted.add(bid); // Never treat a book still in the shelf as removed, even if its format changed.
        if (!supported(b)) { skipped.push(b); continue; }
        if (local.managed.has(bid)) { keep.push(b); continue; }
        const filename = safeFile(b);
        if (local.names.has(filename) || local.names.has(filename + '.meta.json')) {
          conflicts.push({ book: b, filename: filename });
          continue;
        }
        download.push(b);
        downloadBytes += estimate(b);
      }
      if (local.unsafe === 0) {
        for (const pair of local.managed.entries()) {
          if (!wanted.has(pair[0])) remove.push(pair[1]);
        }
      }
      return {
        type: type, id: String(id), remote: remote, local: local.managed,
        dir: local.dir, download: download, keep: keep, skipped: skipped,
        conflicts: conflicts, remove: remove, unsafeLocal: local.unsafe,
        unsafeRemote: state.shelf.bookCount != null && Number.isFinite(Number(state.shelf.bookCount)) && Number(state.shelf.bookCount) !== remote.length,
        downloadBytes: downloadBytes
      };
    }
    async function enterShelves(type) {
      if (state.busy) return;
      state.view = 'shelves'; state.type = type || state.type; state.query = ''; state.error = '';
      render();
      if (state.cfg && !state.shelves[state.type]) await loadShelves(state.type);
    }
    async function enterShelf(id) {
      if (state.busy) return;
      const shelf = (state.shelves[state.type] || []).find(function (s) { return String(selId(s)) === String(id); });
      if (!shelf) return;
      state.shelf = shelf; state.plan = null; state.books = []; state.filter = 'all';
      state.deleteManaged = false; state.view = 'books'; state.loading = true; state.error = '';
      render();
      try {
        state.plan = await buildPlan();
        state.books = state.plan.remote;
        state.error = '';
      } catch (e) {
        state.error = String(e.message || e);
      } finally { state.loading = false; render(); }
    }
    async function enterPreview() {
      if (state.busy) return;
      state.loading = true; state.error = ''; render();
      try {
        state.plan = await buildPlan();
        state.books = state.plan.remote;
        state.view = 'preview';
      } catch (e) { state.error = String(e.message || e); }
      finally { state.loading = false; render(); }
    }
    function encodeUTF8Json(meta) {
      const bytes = new TextEncoder().encode(JSON.stringify(meta));
      let bin = '';
      for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
      return btoa(bin);
    }
    async function deleteOne(path) {
      const body = new URLSearchParams();
      body.set('path', path);
      const r = await fetch('/delete', {
        method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: body.toString()
      });
      if (!r.ok) throw new Error('ลบไฟล์ไม่สำเร็จ (HTTP ' + r.status + '): ' + path);
    }
    async function syncNow() {
      if (state.busy || !state.shelf) return;
      state.busy = true; state.cancel = false; state.error = '';
      state.progress = { done: 0, total: 0, title: '', results: [] };
      const intendedType = state.type, intendedId = String(selId(state.shelf));
      state.view = 'sync'; render();
      let downloaded = 0, removed = 0, p = null;
      try {
        // Always re-read the source of truth before modifying SD, even after Preview.
        p = await buildPlan();
        if (p.type !== intendedType || p.id !== intendedId || p.conflicts.length) {
          throw new Error('Sync plan changed or file names conflict. Review Preview again.');
        }
        state.progress.total = p.download.length;
        render();
        for (let i = 0; i < p.download.length; i++) {
          if (state.cancel) break;
          const b = p.download[i];
          const dest = p.dir + '/' + safeFile(b);
          state.progress.title = b.title || safeFile(b); render();
          const result = await api.fetchToSd(
            base(state.cfg.server) + '/api/grimmlink/v1/books/' + encodeURIComponent(bookId(b)) + '/download',
            dest, { 'x-auth-user': state.cfg.username, 'x-auth-key': state.cfg.auth_key, Accept: 'application/octet-stream' }
          );
          if (!result || result.complete === false || !(Number(result.bytes) > 0) ||
            (result.status != null && Number(result.status) >= 400)) {
            throw new Error('ดาวน์โหลดไม่สำเร็จ: ' + safeFile(b));
          }
          const check = await listLocal(p.dir);
          if (!check.some(function (f) { return f.name === safeFile(b) && !f.isDirectory && Number(f.size) > 0; })) {
            throw new Error('ตรวจสอบ EPUB บน SD ไม่ผ่าน: ' + safeFile(b));
          }
          await api.writeFile(dest + '.meta.json', encodeUTF8Json({
            source: 'grimmlink', managed: true, format: 'epub',
            grimmory_id: Number(bookId(b)), shelf_type: p.type, shelf_id: Number(p.id)
          }));
          downloaded++;
          state.progress.done = downloaded;
          state.progress.results.push({ ok: true, name: b.title || safeFile(b) });
          render();
        }

        if (state.cancel) {
          state.result = { downloaded: downloaded, removed: 0, kept: p.keep.length,
            skipped: p.skipped.length, cancelled: true };
        } else {
          if (state.deleteManaged && p.remove.length && p.unsafeLocal === 0 && !p.unsafeRemote) {
            // Remote content may have changed while downloads were running.
            // Reconcile again; never delete using a stale snapshot.
            const now = await loadBooks(intendedType, intendedId);
            const oldIds = p.remote.filter(supported).map(function (b) { return String(bookId(b)); }).sort();
            const newIds = now.filter(supported).map(function (b) { return String(bookId(b)); }).sort();
            if (JSON.stringify(oldIds) !== JSON.stringify(newIds)) {
              throw new Error('Shelf changed during Sync. Downloads are kept; removal was cancelled.');
            }
            const fresh = await inspectLocal(intendedType, intendedId);
            if (fresh.unsafe) throw new Error('Managed metadata changed during Sync; no removal performed.');
            for (const entry of p.remove) {
              if (state.cancel) break;
              if (!fresh.managed.has(String(entry.meta.grimmory_id))) {
                throw new Error('Managed file changed since Preview; no further removal');
              }
              const existing = fresh.managed.get(String(entry.meta.grimmory_id));
              if (existing.bookPath !== entry.bookPath || existing.sidecarPath !== entry.sidecarPath) {
                throw new Error('Managed identity changed; no further removal');
              }
              await deleteOne(entry.bookPath);
              await deleteOne(entry.sidecarPath);
              removed++;
            }
          }
          state.result = { downloaded: downloaded, removed: removed, kept: p.keep.length,
            skipped: p.skipped.length, cancelled: state.cancel };
        }
        if (!state.result.cancelled) {
          state.history.unshift({ name: state.shelf.name || state.shelf.title || 'Shelf',
            type: intendedType, at: new Date().toISOString(), downloaded: downloaded, removed: removed });
          state.history = state.history.slice(0, 20);
          savePreference(HISTORY_KEY, JSON.stringify(state.history));
        }
        state.view = 'complete';
      } catch (e) {
        state.error = String(e.message || e) + (downloaded ?
          ' · ดาวน์โหลดสำเร็จแล้ว ' + downloaded + ' เล่ม (จะไม่ย้อนลบไฟล์)' : '');
        // Any failure must stop the removal sequence; never claim completion.
        state.view = 'preview';
      } finally { state.busy = false; render(); }
    }

    root.addEventListener('change', function (event) {
      if (event.target && event.target.getAttribute('data-role') === 'remove') {
        state.deleteManaged = !!event.target.checked;
        render();
      }
    });
    root.addEventListener('input', function (event) {
      if (!event.target || event.target.getAttribute('data-role') !== 'search') return;
      state.query = event.target.value;
      const caret = event.target.selectionStart;
      render();
      const search = root.querySelector('[data-role="search"]');
      if (search) { search.focus(); try { search.setSelectionRange(caret, caret); } catch (_) {} }
    });
    root.addEventListener('click', async function (event) {
      const node = event.target.closest('[data-act]');
      if (!node || state.busy && node.dataset.act !== 'cancel' && node.dataset.act !== 'theme') return;
      const act = node.dataset.act;
      if (act === 'theme') {
        state.theme = state.theme === 'light' ? 'dark' : 'light';
        savePreference(THEME_KEY, state.theme);
        render();
      } else if (act === 'nav') {
        if (node.dataset.view === 'shelves') await enterShelves(state.type);
        else { state.view = node.dataset.view; state.error = ''; render(); }
      } else if (act === 'type') {
        await enterShelves(node.dataset.type);
      } else if (act === 'shelf') {
        await enterShelf(node.dataset.id);
      } else if (act === 'filter') {
        state.filter = node.dataset.filter; render();
      } else if (act === 'preview') {
        await enterPreview();
      } else if (act === 'sync') {
        await syncNow();
      } else if (act === 'cancel') {
        state.cancel = true; render();
      } else if (act === 'back-to-books') {
        if (state.shelf) await enterShelf(selId(state.shelf));
      } else if (act === 'back') {
        if (state.view === 'preview') state.view = 'books';
        else if (state.view === 'books' || state.view === 'complete') state.view = 'shelves';
        else state.view = 'home';
        state.error = ''; render();
      } else if (act === 'reload') {
        await init();
      }
    });

    async function init() {
      state.error = ''; render();
      try {
        await loadConfig();
        try {
          const r = await fetch('/api/status', { cache: 'no-store' });
          if (r.ok) state.device = await r.json();
        } catch (_) { state.device = null; }
        await loadShelves('regular');
      } catch (e) { state.error = String(e.message || e); }
      render();
    }
    await init();
  });
})();