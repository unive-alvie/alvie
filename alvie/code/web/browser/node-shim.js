// The Node of alvie-web in a browser. wasm_of_ocaml reaches files, the environment and the standard output through
// Node (require("node:fs"), process); in a browser it has none, and OCaml programs cannot open a file. This shim gives
// it a small Node: an in-memory file system with the synchronous calls of node:fs that the runtime uses, process,
// path, os, tty, and a child_process that runs nothing. The page reads and writes the same files (vfs).
//
//   const vfs = AlvieNodeShim.install({ argv, base, stdout, stderr });
//   vfs.writeFile('/w/a.atdl', text); ... importScripts('alvie-web.js') ... vfs.readFile('/w/model.dot')
//
// base is the URL of the directory of alvie-web.js: the runtime loads alvie-web.assets/*.wasm from there.
'use strict';
(function () {
  const constants = {
    O_RDONLY: 0, O_WRONLY: 1, O_RDWR: 2, O_CREAT: 64, O_EXCL: 128, O_NOCTTY: 256, O_TRUNC: 512, O_APPEND: 1024,
    O_NONBLOCK: 2048, O_DSYNC: 4096, O_SYNC: 1052672, F_OK: 0, X_OK: 1, W_OK: 2, R_OK: 4,
  };
  const errnos = { ENOENT: -2, EBADF: -9, EEXIST: -17, ENOTDIR: -20, EISDIR: -21, EINVAL: -22, ENOTEMPTY: -39, ENOSYS: -38 };
  const messages = { ENOENT: 'no such file or directory', EBADF: 'bad file descriptor', EEXIST: 'file already exists',
    ENOTDIR: 'not a directory', EISDIR: 'illegal operation on a directory', EINVAL: 'invalid argument',
    ENOTEMPTY: 'directory not empty', ENOSYS: 'function not implemented' };
  function fail(code, syscall, path) {
    const e = new Error(`${code}: ${messages[code]}, ${syscall}${path !== undefined ? ` '${path}'` : ''}`);
    return Object.assign(e, { code, errno: errnos[code], syscall, path });
  }

  function normalize(cwd, p) {
    const parts = [];
    for (const part of (p.startsWith('/') ? p : `${cwd}/${p}`).split('/')) {
      if (part === '' || part === '.') continue;
      if (part === '..') parts.pop(); else parts.push(part);
    }
    return `/${parts.join('/')}`;
  }
  const dirname = (p) => { const i = p.replace(/\/+$/, '').lastIndexOf('/'); return i <= 0 ? (p.startsWith('/') ? '/' : '.') : p.slice(0, i); };
  const basename = (p) => p.replace(/\/+$/, '').split('/').pop();

  function install({ argv = [], base = '.', stdout = (s) => console.log(s), stderr = (s) => console.error(s) } = {}) {
    // A node is { dir: Map(name -> node) } or { data: Uint8Array }; inode numbers for stat
    const root = { dir: new Map(), ino: 1, mtime: Date.now() };
    let ino = 2;
    const state = { cwd: '/', exitCode: null };
    const enc = new TextEncoder(), dec = new TextDecoder();

    function lookup(path, syscall) {
      let node = root;
      for (const part of path.split('/').filter((x) => x)) {
        if (!node.dir) throw fail('ENOTDIR', syscall, path);
        node = node.dir.get(part);
        if (!node) throw fail('ENOENT', syscall, path);
      }
      return node;
    }
    function parentOf(path, syscall) {
      const parent = lookup(dirname(path), syscall);
      if (!parent.dir) throw fail('ENOTDIR', syscall, path);
      return parent;
    }
    const resolve = (p) => normalize(state.cwd, String(p));

    function stats(node, bigint) {
      const size = node.dir ? 4096 : node.data.length;
      const t = node.mtime;
      const s = {
        dev: 1, ino: node.ino, mode: node.dir ? 0o40755 : 0o100644, nlink: 1, uid: 0, gid: 0, rdev: 0,
        size: bigint ? BigInt(size) : size, atimeMs: t, mtimeMs: t, ctimeMs: t,
        isFile: () => !node.dir, isDirectory: () => !!node.dir, isSymbolicLink: () => false,
        isCharacterDevice: () => false, isBlockDevice: () => false, isFIFO: () => false, isSocket: () => false,
      };
      return s;
    }

    // Open files: fd -> { node, pos, flags }; 0, 1, 2 are the standard streams
    const fds = new Map();
    let nextFd = 3;
    const lineBuffers = { 1: '', 2: '' };
    function emit(fd, bytes) {
      lineBuffers[fd] += dec.decode(bytes, { stream: true });
      const lines = lineBuffers[fd].split('\n');
      lineBuffers[fd] = lines.pop();
      for (const l of lines) (fd === 1 ? stdout : stderr)(l);
    }
    function flushStd() {
      for (const fd of [1, 2]) if (lineBuffers[fd]) { (fd === 1 ? stdout : stderr)(lineBuffers[fd]); lineBuffers[fd] = ''; }
    }
    function grow(node, size) {
      if (node.data.length >= size) return;
      const d = new Uint8Array(size);
      d.set(node.data); node.data = d;
    }

    const fs = {
      constants,
      existsSync(p) { try { lookup(resolve(p), 'exists'); return true; } catch { return false; } },
      accessSync(p) { lookup(resolve(p), 'access'); },
      statSync(p, opts) {
        try { return stats(lookup(resolve(p), 'stat'), opts?.bigint); }
        catch (e) { if (opts?.throwIfNoEntry === false && e.code === 'ENOENT') return undefined; throw e; }
      },
      lstatSync(p, opts) { return fs.statSync(p, opts); },
      fstatSync(fd, opts) { const f = fds.get(fd); if (!f) throw fail('EBADF', 'fstat'); return stats(f.node, opts?.bigint); },
      openSync(p, flags = 0) {
        const path = resolve(p);
        let node;
        try {
          node = lookup(path, 'open');
          if ((flags & constants.O_CREAT) && (flags & constants.O_EXCL)) throw fail('EEXIST', 'open', path);
        } catch (e) {
          if (e.code !== 'ENOENT' || !(flags & constants.O_CREAT)) throw e;
          node = { data: new Uint8Array(0), ino: ino++, mtime: Date.now() };
          parentOf(path, 'open').dir.set(basename(path), node);
        }
        if (node.dir && (flags & 3) !== constants.O_RDONLY) throw fail('EISDIR', 'open', path);
        if (node.data && (flags & constants.O_TRUNC)) { node.data = new Uint8Array(0); node.mtime = Date.now(); }
        const fd = nextFd++;
        fds.set(fd, { node, pos: 0, flags });
        return fd;
      },
      closeSync(fd) { if (fd > 2) fds.delete(fd); else flushStd(); },
      writeSync(fd, buffer, offset = 0, length, position) {
        if (typeof buffer === 'string') buffer = enc.encode(buffer);
        if (length === undefined) length = buffer.length - offset;
        const bytes = buffer.subarray(offset, offset + length);
        if (fd === 1 || fd === 2) { emit(fd, bytes); return length; }
        const f = fds.get(fd); if (!f) throw fail('EBADF', 'write');
        const at = (f.flags & constants.O_APPEND) ? f.node.data.length : (position ?? f.pos);
        grow(f.node, at + length);
        f.node.data.set(bytes, at); f.node.mtime = Date.now();
        if (position === null || position === undefined) f.pos = at + length;
        return length;
      },
      readSync(fd, buffer, offset = 0, length, position) {
        if (fd === 0) return 0;
        const f = fds.get(fd); if (!f) throw fail('EBADF', 'read');
        if (f.node.dir) throw fail('EISDIR', 'read');
        const at = position ?? f.pos;
        const n = Math.max(0, Math.min(length, f.node.data.length - at));
        buffer.set(f.node.data.subarray(at, at + n), offset);
        if (position === null || position === undefined) f.pos = at + n;
        return n;
      },
      fsyncSync() {},
      ftruncateSync(fd, len = 0) { const f = fds.get(fd); if (!f) throw fail('EBADF', 'ftruncate'); const d = new Uint8Array(len); d.set(f.node.data.subarray(0, len)); f.node.data = d; },
      truncateSync(p, len = 0) { const n = lookup(resolve(p), 'truncate'); const d = new Uint8Array(len); d.set(n.data.subarray(0, len)); n.data = d; },
      mkdirSync(p, opts) {
        const path = resolve(p);
        if (opts?.recursive) {
          let cur = '';
          for (const part of path.split('/').filter((x) => x)) { cur += `/${part}`; if (!fs.existsSync(cur)) fs.mkdirSync(cur); }
          return;
        }
        if (fs.existsSync(path)) throw fail('EEXIST', 'mkdir', path);
        parentOf(path, 'mkdir').dir.set(basename(path), { dir: new Map(), ino: ino++, mtime: Date.now() });
      },
      rmdirSync(p) {
        const path = resolve(p); const n = lookup(path, 'rmdir');
        if (!n.dir) throw fail('ENOTDIR', 'rmdir', path);
        if (n.dir.size) throw fail('ENOTEMPTY', 'rmdir', path);
        parentOf(path, 'rmdir').dir.delete(basename(path));
      },
      unlinkSync(p) {
        const path = resolve(p); const n = lookup(path, 'unlink');
        if (n.dir) throw fail('EISDIR', 'unlink', path);
        parentOf(path, 'unlink').dir.delete(basename(path));
      },
      renameSync(a, b) {
        const from = resolve(a), to = resolve(b); const n = lookup(from, 'rename');
        parentOf(to, 'rename').dir.set(basename(to), n);
        parentOf(from, 'rename').dir.delete(basename(from));
      },
      readdirSync(p) { const n = lookup(resolve(p), 'scandir'); if (!n.dir) throw fail('ENOTDIR', 'scandir', p); return [...n.dir.keys()].sort(); },
      opendirSync(p) {
        const names = fs.readdirSync(p); let i = 0;
        return { readSync: () => (i < names.length ? { name: names[i++] } : null), closeSync() {} };
      },
      chmodSync() {}, fchmodSync() {}, utimesSync() {},
      linkSync(a) { throw fail('ENOSYS', 'link', a); }, symlinkSync(a) { throw fail('ENOSYS', 'symlink', a); },
      readlinkSync(a) { throw fail('EINVAL', 'readlink', a); },
    };

    // What the runtime loads from next to require.main.filename: its WebAssembly, fetched from base
    const fsPromises = { readFile: async (p) => new Uint8Array(await (await fetch(new URL(p.replace(/^\/+/, ''), new URL(base, self.location.href)))).arrayBuffer()) };
    const path = { join: (...ps) => ps.join('/').replace(/\/+/g, '/'), dirname, basename, sep: '/' };
    const modules = {
      'node:fs': fs, 'node:fs/promises': fsPromises, 'node:path': path,
      'node:os': { tmpdir: () => '/tmp', platform: () => 'browser' },
      'node:tty': { isatty: () => false },
      'node:child_process': { spawnSync: () => ({ error: new Error('alvie-web runs no program in a browser') }) },
    };
    const require = (m) => { if (!(m in modules)) throw new Error(`alvie-web: no module ${m} in the browser`); return modules[m]; };
    require.main = { filename: '/alvie-web.js' };
    globalThis.require = require;
    globalThis.process = {
      versions: { node: 'alvie-web-shim' }, platform: 'linux', env: {}, argv: ['node', '/alvie-web.js', ...argv],
      cwd: () => state.cwd, chdir: (p) => { const d = resolve(p); lookup(d, 'chdir'); state.cwd = d; },
      exit: (code) => { flushStd(); state.exitCode = code; throw Object.assign(new Error(`exit ${code}`), { alvieExit: code }); },
      on: (event, f) => { if (event === 'uncaughtException') self.addEventListener('error', (e) => { if (e.error && e.error.alvieExit === undefined) f(e.error); }); },
      cpuUsage: () => ({ user: Math.round(performance.now() * 1000), system: 0 }),
    };
    fs.mkdirSync('/tmp');

    // The page's view of the same files
    return {
      fs,
      writeFile(p, text) { const path = resolve(p); fs.mkdirSync(dirname(path), { recursive: true }); const fd = fs.openSync(path, constants.O_WRONLY | constants.O_CREAT | constants.O_TRUNC); fs.writeSync(fd, enc.encode(text)); fs.closeSync(fd); },
      readFile(p) { const n = lookup(resolve(p), 'open'); return dec.decode(n.data); },
      exists: (p) => fs.existsSync(p),
      list(p = '/') { return fs.readdirSync(p); },
      flush: flushStd,
      get exitCode() { return state.exitCode; },
    };
  }

  globalThis.AlvieNodeShim = { install };
})();
