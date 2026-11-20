// The files of the IDE as a file system of VS Code (alvie:/path). Directories exist only through their files, as in
// the IDE: an empty directory is kept with a hidden file .keep. Every change, by VS Code or by a command of ALVIE, is
// an event of the file system, so that the Explorer and the editors follow the files.
import * as vscode from 'vscode';

export const SCHEME = 'alvie';
const KEEP = '.keep';

export class FilesProvider {
  constructor(files) {
    this.files = files;
    this.emitter = new vscode.EventEmitter();
    this.onDidChangeFile = this.emitter.event;
    this.mtime = new Map();
    this.known = new Map(files.files);
    files.onChange(() => this.changed());
  }

  // The events of a change: the files created, changed and deleted since the last one
  changed() {
    const now = Date.now(), events = [], uri = (path) => vscode.Uri.from({ scheme: SCHEME, path });
    for (const [p, text] of this.files.files) {
      if (!this.known.has(p)) events.push({ type: vscode.FileChangeType.Created, uri: uri(p) });
      else if (this.known.get(p) !== text) events.push({ type: vscode.FileChangeType.Changed, uri: uri(p) });
      else continue;
      this.mtime.set(p, now);
    }
    for (const p of this.known.keys()) if (!this.files.has(p)) events.push({ type: vscode.FileChangeType.Deleted, uri: uri(p) });
    this.known = new Map(this.files.files);
    if (events.length) this.emitter.fire(events);
  }

  stat(uri) {
    const p = uri.path;
    if (this.files.has(p)) {
      return { type: vscode.FileType.File, ctime: 0, mtime: this.mtime.get(p) ?? 0, size: new TextEncoder().encode(this.files.read(p)).length };
    }
    if (p === '/' || this.files.isDir(p)) return { type: vscode.FileType.Directory, ctime: 0, mtime: 0, size: 0 };
    throw vscode.FileSystemError.FileNotFound(uri);
  }

  readDirectory(uri) {
    if (uri.path !== '/' && !this.files.isDir(uri.path)) throw vscode.FileSystemError.FileNotFound(uri);
    return this.files.list(uri.path).filter(([n]) => n !== KEEP)
      .map(([n, dir]) => [n, dir ? vscode.FileType.Directory : vscode.FileType.File]);
  }

  readFile(uri) {
    if (!this.files.has(uri.path)) throw vscode.FileSystemError.FileNotFound(uri);
    return new TextEncoder().encode(this.files.read(uri.path));
  }

  writeFile(uri, content, { create, overwrite }) {
    const p = uri.path, exists = this.files.has(p);
    if (!exists && !create) throw vscode.FileSystemError.FileNotFound(uri);
    if (exists && create && !overwrite) throw vscode.FileSystemError.FileExists(uri);
    if (this.files.isDir(p)) throw vscode.FileSystemError.FileIsADirectory(uri);
    this.files.write(p, new TextDecoder().decode(content));
  }

  createDirectory(uri) { this.files.write(`${uri.path}/${KEEP}`, ''); }

  delete(uri) {
    if (!this.files.has(uri.path) && !this.files.isDir(uri.path)) throw vscode.FileSystemError.FileNotFound(uri);
    this.files.remove(uri.path);
  }

  rename(from, to, { overwrite }) {
    if (!overwrite && (this.files.has(to.path) || this.files.isDir(to.path))) throw vscode.FileSystemError.FileExists(to);
    this.files.rename(from.path, to.path);
  }

  watch() { return new vscode.Disposable(() => {}); }
}
