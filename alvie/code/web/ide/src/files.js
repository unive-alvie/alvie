// The files of the IDE: a map from absolute path to text, kept in IndexedDB so that they survive a reload. On the
// first visit (or after reset), they are the defaults that the build put in public/files (index.json lists them).

const DB = 'alvie-ide', STORE = 'files';

function openDb() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB, 1);
    req.onupgradeneeded = () => req.result.createObjectStore(STORE);
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

export class Files {
  constructor() { this.files = new Map(); this.listeners = []; this.db = null; }

  async load() {
    try {
      this.db = await openDb();
      const entries = await new Promise((resolve, reject) => {
        const tx = this.db.transaction(STORE, 'readonly'), out = [];
        const req = tx.objectStore(STORE).openCursor();
        req.onsuccess = () => { const c = req.result; if (c) { out.push([c.key, c.value]); c.continue(); } else resolve(out); };
        req.onerror = () => reject(req.error);
      });
      for (const [k, v] of entries) this.files.set(k, v);
    } catch (e) {
      console.warn('IndexedDB is not available: the files will not survive a reload', e);
    }
    if (this.files.size === 0) await this.reset();
  }

  async reset() {
    this.files.clear();
    const index = await (await fetch('files/index.json')).json();
    await Promise.all(index.map(async (p) => this.files.set(p, await (await fetch(`files${p}`)).text())));
    await this.persistAll();
    this.changed();
  }

  async persistAll() {
    if (!this.db) return;
    const tx = this.db.transaction(STORE, 'readwrite'), store = tx.objectStore(STORE);
    store.clear();
    for (const [k, v] of this.files) store.put(v, k);
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
