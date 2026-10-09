// Deterministic contract smoke tests for the CrossPoint browser SD plugin.
// Run: node --test test/crosspoint_web_ui.test.cjs
const assert = require('node:assert/strict');
const test = require('node:test');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');

const source = fs.readFileSync(path.join(__dirname, '..', 'crosspoint.plugin', 'plugin.js'), 'utf8');

async function setup(options = {}) {
  let init, root;
  const db = new Map();
  const files = new Map();
  const deletions = [], downloads = [];
  const shelf = { id: 7, name: 'Test Shelf', bookCount: options.bookCount ?? 3 };
  const books = options.books || [
    { bookId: 1, title: 'Volume One', extension: 'epub', fileSize: 1024 },
    { bookId: 2, title: 'Volume Two', extension: 'epub', fileSize: 2048 },
    { bookId: 3, title: 'Supplement', extension: 'pdf', fileSize: 3000 }
  ];
  const dir = '/GrimmLink/regular-7';
  const putManaged = (id, name) => {
    files.set(dir + '/' + name, { size: 1200 });
    files.set(dir + '/' + name + '.meta.json', { body: JSON.stringify({
      source: 'grimmlink', managed: true, grimmory_id: id, shelf_type: 'regular', shelf_id: 7
    }) });
  };
  if (options.seed !== false) putManaged(1, 'gl-1-Volume One.epub');
  if (options.orphan) putManaged(99, 'gl-99-Old Book.epub');
  if (options.unmanaged) files.set(dir + '/handmade.epub', { size: 1234 });

  const document = {
    head: { appendChild() {} },
    createElement(tag) {
      const el = { tagName: tag.toUpperCase(), dataset: {}, listeners: {}, innerHTML: '',
        addEventListener(event, handler) { this.listeners[event] = handler; } };
      if (tag === 'div') root = el;
      return el;
    }
  };
  const response = (data, ok = true, status = 200) => ({
    ok, status, async json() { return data; }
  });
  let remoteFailure = false;
  async function fetchMock(uri, options = {}) {
    const url = String(uri), pathname = url.split('?')[0];
    const query = url.slice(pathname.length + 1);
    if (url.includes('config.json')) return response({
      server: 'https://example.invalid', username: 'reader', auth_key: 'key', dest_dir: '/GrimmLink'
    });
    if (pathname === '/api/status') return response({ device: 'X4', ip: '192.168.1.3' });
    if (pathname === '/api/files') {
      const folder = new URLSearchParams(query).get('path');
      const result = [...files].filter(([p]) => p.startsWith(folder + '/') &&
        !p.slice(folder.length + 1).includes('/')).map(([p, f]) => ({
        name: p.slice(folder.length + 1), size: f.size ?? 200, isDirectory: false
      }));
      return response(result);
    }
    if (pathname === '/download') {
      const p = new URLSearchParams(query).get('path');
      const f = files.get(p);
      return response(f ? JSON.parse(f.body) : null, Boolean(f), f ? 200 : 404);
    }
    if (pathname === '/delete') {
      const p = new URLSearchParams(options.body).get('path');
      if (!files.has(p)) return response(null, false, 404);
      files.delete(p);
      deletions.push(p);
      return response({}, true, 200);
    }
    throw Error('Unknown API path: ' + url);
  }
  const api = {
    pluginFile(name) { return '/plugin?name=grimmlink&file=' + name; },
    async relay(method, url) {
      if (remoteFailure) throw Error('Grimmory is down');
      if (url.includes('/shelves?')) return { status: 200, body: JSON.stringify([shelf]) };
      if (url.includes('/shelves/regular/7/books')) {
        const offset = Number(new URL(url).searchParams.get('offset') || 0);
        const limit = Number(new URL(url).searchParams.get('limit') || 12);
        return { status: 200, body: JSON.stringify(books.slice(offset, offset + limit)) };
      }
      throw Error('Unknown Grimmory path: ' + url);
    },
    async fetchToSd(url, dest) {
      downloads.push(dest);
      files.set(dest, { size: 8192 });
      if (options.failDownload) throw Error('Download interrupted');
      return { status: 200, bytes: 8192, complete: true };
    },
    async writeFile(dest, content) {
      files.set(dest, { size: content.length,
        body: Buffer.from(content, 'base64').toString('utf8') });
    }
  };
  const localStorage = {
    getItem(key) { return db.get(key) || null; },
    setItem(key, value) { db.set(key, value); }
  };
  const CrossPoint = { registerPlugin(fn) { init = fn; } };
  vm.runInNewContext(source, {
    CrossPoint, document, fetch: fetchMock, window: { matchMedia: () => ({ matches: false }) },
    localStorage, TextEncoder, btoa: (binary) => Buffer.from(binary, 'binary').toString('base64'),
    URLSearchParams, console
  }, { filename: 'plugin.js' });
  await init({ replaceChildren() {} }, api);
  async function click(act, data = {}) {
    return root.listeners.click({
      target: { closest() { return { dataset: { act, ...data } }; } }
    });
  }
  return {
    click, dir, files, downloads, deletions, getHtml: () => root.innerHTML,
    setRemove(checked) {
      root.listeners.change({
        target: { checked, getAttribute(key) { return key === 'data-role' ? 'remove' : null; } }
      });
    },
    setRemoteFailure(value) { remoteFailure = value; }
  };
}

async function reachPreview(ctx) {
  await ctx.click('type', { type: 'regular' });
  await ctx.click('shelf', { id: '7' });
  await ctx.click('preview');
}

test('mobile-first pages load and theme switches', async () => {
  const ctx = await setup();
  assert.match(ctx.getHtml(), /GrimmLink/);
  await ctx.click('theme');
  assert.match(ctx.getHtml(), /data-theme="dark"/);
  await reachPreview(ctx);
  assert.match(ctx.getHtml(), /Sync Preview/);
});

test('download-only sync fetches EPUB directly to SD and writes managed sidecar', async () => {
  const ctx = await setup({ unmanaged: true, orphan: true });
  await reachPreview(ctx);
  await ctx.click('sync');
  assert.equal(ctx.downloads.length, 1);
  assert.equal(ctx.deletions.length, 0);
  assert.ok(ctx.files.has(ctx.dir + '/gl-2-Volume Two.epub.meta.json'));
  assert.ok(ctx.files.has(ctx.dir + '/handmade.epub'));
  assert.match(ctx.getHtml(), /Sync เสร็จสิ้น/);
});

test('optional deletion only removes selected shelf managed entries', async () => {
  const ctx = await setup({ unmanaged: true, orphan: true });
  await reachPreview(ctx);
  ctx.setRemove(true);
  await ctx.click('sync');
  assert.deepEqual(ctx.deletions.sort(), [
    ctx.dir + '/gl-99-Old Book.epub',
    ctx.dir + '/gl-99-Old Book.epub.meta.json'
  ].sort());
  assert.ok(ctx.files.has(ctx.dir + '/handmade.epub'));
});

test('remote failure before execution never deletes or downloads', async () => {
  const ctx = await setup({ orphan: true });
  await reachPreview(ctx);
  ctx.setRemove(true);
  ctx.setRemoteFailure(true);
  await ctx.click('sync');
  assert.equal(ctx.downloads.length, 0);
  assert.equal(ctx.deletions.length, 0);
  assert.match(ctx.getHtml(), /Grimmory is down/);
});

test('unknown file collision blocks writes', async () => {
  const ctx = await setup({ seed: false });
  ctx.files.set(ctx.dir + '/gl-1-Volume One.epub', { size: 900 });
  await reachPreview(ctx);
  assert.match(ctx.getHtml(), /ชื่อไฟล์ชน/);
  await ctx.click('sync');
  assert.equal(ctx.downloads.length, 0);
});

test('remote shelf of more than 12 books uses offset paging', async () => {
  const books = Array.from({ length: 25 }, (_, i) => ({
    bookId: i + 100, title: 'Volume ' + i, extension: 'epub'
  }));
  const ctx = await setup({ books, bookCount: 25, seed: false });
  await reachPreview(ctx);
  assert.match(ctx.getHtml(), /25 EPUB ต้องดาวน์โหลด/);
});
