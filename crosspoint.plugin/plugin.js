(function () {
  'use strict';

  CrossPoint.registerPlugin(async function (container, api) {
    const state = { cfg: null, type: 'regular', shelves: [], busy: false };

    container.innerHTML =
      '<h2>GrimmLink Shelf Sync</h2>' +
      '<p>Sync EPUB books from a Grimmory shelf directly to this reader.</p>' +
      '<label>Shelf type <select data-role="type"><option value="regular">Regular</option><option value="magic">Magic</option></select></label> ' +
      '<button data-role="load">Load shelves</button>' +
      '<div style="margin-top:10px"><label>Shelf <select data-role="shelf"><option>Load shelves first</option></select></label></div>' +
      '<div style="margin-top:10px"><label><input type="checkbox" data-role="delete"> Remove GrimmLink-managed books no longer in this shelf</label></div>' +
      '<div style="margin-top:12px"><button data-role="preview">Preview</button> <button data-role="sync">Sync Shelf</button></div>' +
      '<pre data-role="status" style="white-space:pre-wrap;margin-top:12px"></pre>';

    const $ = (role) => container.querySelector('[data-role="' + role + '"]');
    const status = $('status');

    function setStatus(s) { status.textContent = s; }
    function baseUrl(s) { return String(s || '').replace(/\/+$/, ''); }
    function headers() {
      return {
        'x-auth-user': state.cfg.username,
        'x-auth-key': state.cfg.auth_key,
        'Accept': 'application/json'
      };
    }
    function listPayload(v) {
      if (Array.isArray(v)) return v;
      if (v && Array.isArray(v.content)) return v.content;
      if (v && Array.isArray(v.items)) return v.items;
      return [];
    }
    function shelfId(s) { return s && (s.id != null ? s.id : (s.shelfId != null ? s.shelfId : s.shelf_id)); }
    function bookId(b) { return b && (b.bookId != null ? b.bookId : (b.id != null ? b.id : b.book_id)); }
    function ext(b) {
      const raw = String((b && (b.extension || b.fileFormat || b.file_format || b.fileName || b.originalFileName)) || '');
      const m = raw.toLowerCase().match(/\.?([a-z0-9]+)$/);
      return m ? m[1] : '';
    }
    function isEpub(b) { return ext(b) === 'epub' || String(b.fileFormat || b.file_format || '').toLowerCase() === 'epub'; }
    function safeName(s) {
      let name = String(s || 'book').replace(/[\\/:*?"<>|\x00-\x1f]/g, '_').trim();
      name = name.replace(/^\.+/, '').replace(/[. ]+$/, '');
      if (!name) name = 'book';
      return name.slice(0, 180);
    }
    function fileName(b) {
      let n = safeName(b.fileName || b.originalFileName || b.original_file_name || b.title || ('book-' + bookId(b)));
      if (!/\.epub$/i.test(n)) n += '.epub';
      return n;
    }
    function encPath(p) { return encodeURIComponent(p); }

    async function loadConfig() {
      const r = await fetch(api.pluginFile('config.json'), { cache: 'no-store' });
      if (!r.ok) throw new Error('config.json not found. Copy config.example.json to config.json first.');
      const cfg = await r.json();
      if (!cfg.server || !cfg.username || !cfg.auth_key) throw new Error('config.json is missing server, username, or auth_key.');
      cfg.dest_dir = String(cfg.dest_dir || '/GrimmLink');
      if (!cfg.dest_dir.startsWith('/') || cfg.dest_dir.includes('..')) throw new Error('Unsafe dest_dir in config.json');
      state.cfg = cfg;
      return cfg;
    }

    async function relayJson(path) {
      const cfg = state.cfg || await loadConfig();
      const res = await api.relay('GET', baseUrl(cfg.server) + path, headers(), '');
      if (res.status < 200 || res.status >= 300) throw new Error('Grimmory HTTP ' + res.status + ' for ' + path);
      try { return JSON.parse(res.body); } catch (_) { throw new Error('Invalid JSON from Grimmory for ' + path); }
    }

    async function loadShelves() {
      state.type = $('type').value;
      const raw = await relayJson('/api/grimmlink/v1/shelves?type=' + encodeURIComponent(state.type));
      state.shelves = listPayload(raw);
      const sel = $('shelf');
      sel.innerHTML = '';
      for (const s of state.shelves) {
        const id = shelfId(s);
        if (id == null) continue;
        const o = document.createElement('option');
        o.value = String(id);
        o.textContent = String(s.name || s.title || ('Shelf ' + id));
        sel.appendChild(o);
      }
      if (!sel.options.length) sel.innerHTML = '<option value="">No shelves found</option>';
      setStatus('Loaded ' + sel.options.length + ' ' + state.type + ' shelf(s).');
    }

    async function remoteBooks() {
      const id = $('shelf').value;
      if (!id) throw new Error('Choose a shelf first.');
      const raw = await relayJson('/api/grimmlink/v1/shelves/' + encodeURIComponent(state.type) + '/' + encodeURIComponent(id) + '/books');
      const all = listPayload(raw);
      const books = all.filter(isEpub).filter((b) => bookId(b) != null);
      if (!Array.isArray(all)) throw new Error('Shelf response is not a list.');
      return { all, books, shelfId: id };
    }

    async function listLocal() {
      const cfg = state.cfg || await loadConfig();
      const r = await fetch('/api/files?path=' + encPath(cfg.dest_dir), { cache: 'no-store' });
      if (r.status === 404) return [];
      if (!r.ok) throw new Error('Cannot list ' + cfg.dest_dir + ' (HTTP ' + r.status + ')');
      const v = await r.json();
      return Array.isArray(v) ? v : [];
    }

    async function readJsonFile(path) {
      const r = await fetch('/download?path=' + encPath(path), { cache: 'no-store' });
      if (!r.ok) return null;
      try { return await r.json(); } catch (_) { return null; }
    }

    async function managedLocal() {
      const cfg = state.cfg || await loadConfig();
      const files = await listLocal();
      const map = new Map();
      for (const f of files) {
        if (!f || f.isDirectory || !/\.meta\.json$/i.test(String(f.name || ''))) continue;
        const sidecarPath = cfg.dest_dir.replace(/\/$/, '') + '/' + f.name;
        const meta = await readJsonFile(sidecarPath);
        if (!meta || meta.source !== 'grimmlink' || meta.grimmory_id == null) continue;
        const bookPath = sidecarPath.replace(/\.meta\.json$/i, '');
        map.set(String(meta.grimmory_id), { bookPath, sidecarPath, meta });
      }
      return map;
    }

    async function buildPlan() {
      await loadConfig();
      const remote = await remoteBooks();
      if (!Array.isArray(remote.books)) throw new Error('Remote shelf could not be verified.');
      const local = await managedLocal();
      const remoteIds = new Set(remote.books.map((b) => String(bookId(b))));
      const download = remote.books.filter((b) => !local.has(String(bookId(b))));
      const remove = [];
      for (const [id, entry] of local.entries()) if (!remoteIds.has(id)) remove.push(entry);
      return { remote, local, download, remove };
    }

    function describe(plan) {
      return [
        'EPUB in shelf: ' + plan.remote.books.length,
        'Managed on X4 Pro: ' + plan.local.size,
        'Download: ' + plan.download.length,
        'Remove candidates: ' + plan.remove.length,
        '',
        plan.download.length ? 'Download:\n' + plan.download.map((b) => ' + ' + (b.title || fileName(b))).join('\n') : 'Nothing to download.',
        '',
        plan.remove.length ? 'Managed removal candidates:\n' + plan.remove.map((e) => ' - ' + e.bookPath).join('\n') : 'Nothing to remove.'
      ].join('\n');
    }

    async function writeSidecar(path, meta) {
      const bytes = new TextEncoder().encode(JSON.stringify(meta));
      let bin = '';
      for (const b of bytes) bin += String.fromCharCode(b);
      await api.writeFile(path, btoa(bin));
    }

    async function deletePaths(paths) {
      if (!paths.length) return;
      const body = new URLSearchParams();
      body.set('paths', JSON.stringify(paths));
      const r = await fetch('/delete', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: body.toString() });
      if (!r.ok) throw new Error('Delete failed (HTTP ' + r.status + ')');
    }

    async function syncShelf() {
      if (state.busy) return;
      state.busy = true;
      $('sync').disabled = true;
      $('preview').disabled = true;
      try {
        const plan = await buildPlan();
        setStatus(describe(plan) + '\n\nStarting sync...');

        let done = 0;
        for (const b of plan.download) {
          const id = bookId(b);
          const name = fileName(b);
          const dest = state.cfg.dest_dir.replace(/\/$/, '') + '/' + name;
          setStatus(describe(plan) + '\n\nDownloading ' + (done + 1) + '/' + plan.download.length + ': ' + name);
          await api.fetchToSd(
            baseUrl(state.cfg.server) + '/api/grimmlink/v1/books/' + encodeURIComponent(id) + '/download',
            dest,
            { 'x-auth-user': state.cfg.username, 'x-auth-key': state.cfg.auth_key, 'Accept': 'application/octet-stream' }
          );
          await writeSidecar(dest + '.meta.json', {
            grimmory_id: id,
            source: 'grimmlink',
            format: 'epub',
            managed: true,
            shelf_type: state.type,
            shelf_id: plan.remote.shelfId
          });
          done++;
        }

        let removed = 0;
        if ($('delete').checked && plan.remove.length) {
          const paths = [];
          for (const e of plan.remove) paths.push(e.bookPath, e.sidecarPath);
          await deletePaths(paths);
          removed = plan.remove.length;
        }

        setStatus('Sync complete.\nDownloaded: ' + done + '\nRemoved: ' + removed + '\nUnchanged: ' + (plan.remote.books.length - done) + '\nPDF/unsupported skipped: ' + (plan.remote.all.length - plan.remote.books.length));
      } catch (e) {
        setStatus('Sync stopped safely.\n' + String((e && e.message) || e) + '\nNo removal is attempted unless the remote shelf and local managed metadata were read successfully.');
      } finally {
        state.busy = false;
        $('sync').disabled = false;
        $('preview').disabled = false;
      }
    }

    $('load').onclick = async () => {
      try { await loadConfig(); await loadShelves(); } catch (e) { setStatus(String((e && e.message) || e)); }
    };
    $('type').onchange = () => { state.type = $('type').value; $('shelf').innerHTML = '<option>Load shelves first</option>'; };
    $('preview').onclick = async () => {
      try { const p = await buildPlan(); setStatus(describe(p)); } catch (e) { setStatus('Preview failed: ' + String((e && e.message) || e)); }
    };
    $('sync').onclick = syncShelf;

    try { await loadConfig(); await loadShelves(); } catch (e) { setStatus(String((e && e.message) || e)); }
  });
})();