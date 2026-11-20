// The terminal of the IDE: a line editor on xterm.js, with built-in commands on the files of the IDE and the commands
// of alvie-web (alvie ..., or sancus/tiny/vaultlink ...), which run in a Web Worker. Ctrl-C stops a running command.
import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import '@xterm/xterm/css/xterm.css';
import { resolvePath } from './files.js';

// Splits a command line as a shell does with quotes ('...' and "...") and backslashes
export function splitArgs(line) {
  const args = []; let cur = '', quote = null, has = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (quote) { if (c === quote) quote = null; else if (c === '\\' && quote === '"' && i + 1 < line.length) cur += line[++i]; else cur += c; }
    else if (c === "'" || c === '"') { quote = c; has = true; }
    else if (c === '\\' && i + 1 < line.length) { cur += line[++i]; has = true; }
    else if (/\s/.test(c)) { if (has || cur) args.push(cur); cur = ''; has = false; }
    else { cur += c; has = true; }
  }
  if (has || cur) args.push(cur);
  return args;
}

const HELP = `The commands of ALVIE run here, in your browser:
  alvie sancus learn --spec spec-lib/example/attacker.atdl --spec spec-lib/example/enclave.etdl --secret 0 --commit bf89c0b --res models/example-0.dot
  alvie sancus compare -help          alvie sancus fixtures          alvie tiny learn -help
  alvie vaultlink learn --spec spec-lib/vaultlink/vault.vtdl --service firmware --res models/firmware.dot
  alvie vaultlink compare models/reference.dot models/firmware.dot
("alvie" may be left out; sancus gets --sancus none --tmpdir /tmp/alvie when they are missing.)

Files:  ls [dir]   cd [dir]   pwd   cat FILE   edit FILE   cp A B   mv A B   rm PATH
        view MODEL [MODEL2] [--inputs I1,I2,...]  (draw one or two models; follow the inputs on them)
        download FILE   reset-files (back to the files of a first visit)   clear   history   help
Keys:   Ctrl-C stops a command, Tab completes a path, Up/Down walk the history.`;

const ALVIE = new Set(['alvie', 'sancus', 'tiny', 'vaultlink']);

export class Shell {
  constructor(element, { files, runner, openEditor, openViewer, download }) {
    Object.assign(this, { files, runner, openEditor, openViewer, download });
    this.cwd = '/';
    this.line = ''; this.cursor = 0;
    this.history = JSON.parse(localStorage.getItem('alvie-ide-history') || '[]'); this.hpos = this.history.length;
    this.term = new Terminal({ fontFamily: 'ui-monospace, Menlo, Consolas, monospace', fontSize: 13, convertEol: true, cursorBlink: true,
      theme: { background: '#1e1e1e' } });
    this.fit = new FitAddon();
    this.term.loadAddon(this.fit);
    this.term.open(element);
    this.fit.fit();
    new ResizeObserver(() => this.fit.fit()).observe(element);
    this.term.onData((d) => this.input(d));
    this.term.writeln('ALVIE in your browser. Type help.');
    this.prompt();
  }

  prompt() { this.term.write(`\x1b[1;34m${this.cwd}\x1b[0m $ `); this.line = ''; this.cursor = 0; }
  redraw() { this.term.write(`\r\x1b[K\x1b[1;34m${this.cwd}\x1b[0m $ ${this.line}`); const back = this.line.length - this.cursor; if (back > 0) this.term.write(`\x1b[${back}D`); }
  print(text, stream = 'stdout') { for (const l of String(text).split('\n')) this.term.writeln(stream === 'stderr' ? `\x1b[31m${l}\x1b[0m` : l); }

  input(data) {
    if (this.runner.running) { if (data === '\x03') { this.runner.cancel(); this.print('^C (stopped)'); } return; }
    for (let i = 0; i < data.length; i++) {
      const c = data[i];
      if (c === '\r') { this.term.write('\r\n'); this.execute(this.line); return; }
      if (c === '\x03') { this.term.write('^C\r\n'); this.prompt(); continue; }
      if (c === '\x7f') { if (this.cursor > 0) { this.line = this.line.slice(0, this.cursor - 1) + this.line.slice(this.cursor); this.cursor--; this.redraw(); } continue; }
      if (c === '\t') { this.complete(); continue; }
      if (c === '\x1b' && data[i + 1] === '[') {
        const k = data[i + 2]; i += 2;
        if (k === 'A' && this.hpos > 0) { this.line = this.history[--this.hpos]; this.cursor = this.line.length; this.redraw(); }
        else if (k === 'B') { this.hpos = Math.min(this.history.length, this.hpos + 1); this.line = this.history[this.hpos] || ''; this.cursor = this.line.length; this.redraw(); }
        else if (k === 'C' && this.cursor < this.line.length) { this.cursor++; this.term.write('\x1b[C'); }
        else if (k === 'D' && this.cursor > 0) { this.cursor--; this.term.write('\x1b[D'); }
        continue;
      }
      if (c >= ' ') { this.line = this.line.slice(0, this.cursor) + c + this.line.slice(this.cursor); this.cursor++; this.redraw(); }
    }
  }

  complete() {
    const m = this.line.slice(0, this.cursor).match(/(\S*)$/);
    const word = m[1], dir = word.includes('/') ? word.slice(0, word.lastIndexOf('/') + 1) : '', base = word.slice(dir.length);
    const entries = this.files.list(resolvePath(this.cwd, dir || '.')).filter(([n]) => n.startsWith(base));
    if (entries.length === 0) return;
    let common = entries[0][0] + (entries[0][1] ? '/' : '');
    if (entries.length > 1) {
      common = entries.map(([n]) => n).reduce((a, b) => { let k = 0; while (k < a.length && a[k] === b[k]) k++; return a.slice(0, k); });
      this.term.write('\r\n' + entries.map(([n, d]) => n + (d ? '/' : '')).join('  ') + '\r\n');
    }
    const add = common.slice(base.length);
    this.line = this.line.slice(0, this.cursor) + add + this.line.slice(this.cursor); this.cursor += add.length; this.redraw();
  }

  // Runs a command line given by the terminal or by the IDE (e.g. a button)
  async run(line) { this.term.write(line + '\r\n'); await this.execute(line); }

  async execute(line) {
    const trimmed = line.trim();
    if (trimmed) {
      if (this.history[this.history.length - 1] !== trimmed) this.history.push(trimmed);
      this.history = this.history.slice(-200); this.hpos = this.history.length;
      try { localStorage.setItem('alvie-ide-history', JSON.stringify(this.history)); } catch {}
    }
    const args = splitArgs(trimmed);
    try {
      if (args.length === 0) {}
      else if (ALVIE.has(args[0])) await this.alvie(args);
      else this.builtin(args);
    } catch (e) { this.print(String(e.message || e), 'stderr'); }
    this.prompt();
  }

  async alvie(args) {
    const { exit, ms, cancelled } = await this.runner.run(args, { cwd: this.cwd, onOutput: (stream, l) => this.print(l, stream) });
    if (!cancelled) this.print(`\x1b[2m(${(ms / 1000).toFixed(1)} s${exit !== null && exit !== 0 ? `, exit ${exit}` : ''})\x1b[0m`);
  }

  builtin([cmd, ...rest]) {
    const p = (x) => resolvePath(this.cwd, x);
    const need = (n) => { if (rest.length < n) throw new Error(`${cmd}: missing argument (see help)`); };
    switch (cmd) {
      case 'help': this.print(HELP); break;
      case 'clear': this.term.clear(); break;
      case 'pwd': this.print(this.cwd); break;
      case 'history': this.history.forEach((h, i) => this.print(`${String(i + 1).padStart(4)}  ${h}`)); break;
      case 'ls': {
        const d = p(rest[0] || '.');
        if (this.files.has(d)) { this.print(rest[0]); break; }
        if (!this.files.isDir(d) && d !== '/') throw new Error(`ls: no such directory: ${rest[0]}`);
        this.print(this.files.list(d).map(([n, dir]) => (dir ? `\x1b[1;34m${n}/\x1b[0m` : n)).join('  '));
        break;
      }
      case 'cd': { const d = p(rest[0] || '/'); if (d !== '/' && !this.files.isDir(d)) throw new Error(`cd: no such directory: ${rest[0]}`); this.cwd = d; break; }
      case 'cat': need(1); for (const f of rest) { if (!this.files.has(p(f))) throw new Error(`cat: no such file: ${f}`); this.print(this.files.read(p(f))); } break;
      case 'edit': need(1); this.openEditor(p(rest[0])); break;
      case 'view': {
        need(1);
        const i = rest.indexOf('--inputs');
        const inputs = i >= 0 ? (rest[i + 1] || '').split(/[,\s]+/).filter(Boolean) : [];
        const models = i >= 0 ? rest.filter((_, k) => k !== i && k !== i + 1) : rest;
        for (const f of models) if (!this.files.has(p(f))) throw new Error(`view: no such file: ${f}`);
        this.openViewer(models.map(p), inputs);
        break;
      }
      case 'cp': need(2); if (!this.files.has(p(rest[0]))) throw new Error(`cp: no such file: ${rest[0]}`); this.files.write(p(rest[1]), this.files.read(p(rest[0]))); break;
      case 'mv': need(2); this.files.rename(p(rest[0]), p(rest[1])); break;
      case 'rm': need(1); for (const f of rest) this.files.remove(p(f)); break;
      case 'mkdir': need(1); this.files.write(`${p(rest[0])}/.keep`, ''); break;
      case 'download': need(1); if (!this.files.has(p(rest[0]))) throw new Error(`download: no such file: ${rest[0]}`); this.download(p(rest[0])); break;
      case 'reset-files': this.files.reset().then(() => this.print('The files are those of a first visit again.')); break;
      default: throw new Error(`${cmd}: unknown command (type help)`);
    }
  }
}
