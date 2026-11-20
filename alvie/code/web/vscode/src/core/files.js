// The files of ALVIE in the browser: a map from absolute path to text, kept in IndexedDB so that they survive a reload.
// The defaults are what the build put in files/ (prepare.sh): files/index.json maps each path to the SHA-256 of its
// text. A first visit (or a reset) gets all of them. A later visit gets the defaults that are new since the last one,
// and the new version of a default that the user did not change (e.g. a tutorial); a default that the user changed or
// removed stays as the user left it.

const DB = 'alvie-ide', STORE = 'files';
const GIVEN = '\u0000defaults'; // the key of { path: SHA-256 } of the defaults given so far (paths start with /)

function openDb() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB, 1);
    req.onupgradeneeded = () => req.result.createObjectStore(STORE);
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

export async function sha256(text) {
  const d = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

export class Files {
  // base: the URL of the directory that has files/ (the defaults)
  constructor({ base = '' } = {}) { this.base = base; this.files = new Map(); this.listeners = []; this.db = null; this.given = {}; }

  async load() {
    try {
      this.db = await openDb();
      const entries = await new Promise((resolve, reject) => {
        const tx = this.db.transaction(STORE, 'readonly'), out = [];
        const req = tx.objectStore(STORE).openCursor();
        req.onsuccess = () => { const c = req.result; if (c) { out.push([c.key, c.value]); c.continue(); } else resolve(out); };
        req.onerror = () => reject(req.error);
      });
      for (const [k, v] of entries) { if (k === GIVEN) this.given = JSON.parse(v); else this.files.set(k, v); }
    } catch (e) {
      console.warn('IndexedDB is not available: the files will not survive a reload', e);
    }
    if (this.files.size === 0) await this.reset();
    else await this.update();
  }

  async defaults() { return (await fetch(`${this.base}files/index.json`)).json(); }
  async fetchDefault(p) { return (await fetch(`${this.base}files${p}`)).text(); }

  async reset() {
    this.files.clear();
    const index = await this.defaults();
    await Promise.all(Object.keys(index).map(async (p) => this.files.set(p, await this.fetchDefault(p))));
    this.given = index;
    await this.persistAll();
    this.changed();
  }

  // The new defaults, and the new versions of the defaults that the user did not change
  async update() {
    const index = await this.defaults(), changed = [];
    for (const [p, hash] of Object.entries(index)) {
      const before = this.given[p];
      if (before === hash) continue;
      if (before === undefined ? !this.files.has(p) : this.files.has(p) && (await sha256(this.files.get(p))) === before) changed.push(p);
    }
    await Promise.all(changed.map(async (p) => { this.files.set(p, await this.fetchDefault(p)); this.persist(p); }));
    this.given = index;
    this.persistGiven();
    if (changed.length) this.changed();
  }

  persistGiven() {
    if (!this.db) return;
    this.db.transaction(STORE, 'readwrite').objectStore(STORE).put(JSON.stringify(this.given), GIVEN);
  }

  async persistAll() {
    if (!this.db) return;
    const tx = this.db.transaction(STORE, 'readwrite'), store = tx.objectStore(STORE);
    store.clear();
    for (const [k, v] of this.files) store.put(v, k);
    store.put(JSON.stringify(this.given), GIVEN);
  }

  persist(path) {
    if (!this.db) return;
    const tx = this.db.transaction(STORE, 'readwrite');
    if (this.files.has(path)) tx.objectStore(STORE).put(this.files.get(path), path);
    else tx.objectStore(STORE).delete(path);
  }

  onChange(f) { this.listeners.push(f); }
  changed(path) { for (const f of this.listeners) f(path); }

  has(path) { return this.files.has(path); }
  read(path) { return this.files.get(path); }
  write(path, text) { this.files.set(path, text); this.persist(path); this.changed(path); }
  remove(path) {
    const prefix = path.endsWith('/') ? path : `${path}/`;
    for (const p of [...this.files.keys()]) if (p === path || p.startsWith(prefix)) { this.files.delete(p); this.persist(p); }
    this.changed(path);
  }
  rename(from, to) {
    const prefix = `${from}/`;
    for (const p of [...this.files.keys()]) {
      if (p === from || p.startsWith(prefix)) {
        const q = to + p.slice(from.length);
        this.files.set(q, this.files.get(p)); this.files.delete(p); this.persist(p); this.persist(q);
      }
    }
    this.changed(to);
  }
  // Whether a directory has files (directories exist only through their files)
  isDir(path) { const prefix = path === '/' ? '/' : `${path}/`; for (const p of this.files.keys()) if (p.startsWith(prefix)) return true; return false; }
  // The names directly in a directory: [name, isDir]
  list(dir) {
    const prefix = dir === '/' ? '/' : `${dir}/`, out = new Map();
    for (const p of this.files.keys()) {
      if (!p.startsWith(prefix)) continue;
      const rest = p.slice(prefix.length), i = rest.indexOf('/');
      if (i < 0) out.set(rest, false); else out.set(rest.slice(0, i), true);
    }
    return [...out.entries()].sort((a, b) => (a[1] === b[1] ? a[0].localeCompare(b[0]) : a[1] ? -1 : 1));
  }
  all() { return Object.fromEntries(this.files); }
  // Merge the files that a command gave back: new and changed files
  merge(files) {
    for (const [p, t] of Object.entries(files)) if (this.files.get(p) !== t) { this.files.set(p, t); this.persist(p); }
    this.changed();
  }
}

export function resolvePath(cwd, p) {
  const parts = [];
  for (const part of (p.startsWith('/') ? p : `${cwd}/${p}`).split('/')) {
    if (part === '' || part === '.') continue;
    if (part === '..') parts.pop(); else parts.push(part);
  }
  return `/${parts.join('/')}`;
}
