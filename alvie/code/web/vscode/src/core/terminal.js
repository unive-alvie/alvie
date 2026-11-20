// The shell of ALVIE in the browser: a line editor on a terminal (a Pseudoterminal of VS Code, or the cells of a
// tutorial), with built-in commands on the files, the scripts of the guides, and the commands of alvie-web (alvie ..., or
// sancus/tiny/vaultlink ...), which run in a Web Worker. Ctrl-C stops a running command.
import { resolvePath } from './files.js';
import { programOf, Runner } from './runner.js';
import { scriptOf, scriptJobs } from './scripts.js';

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
("alvie" may be left out; the commands of Sancus get --sancus none --tmpdir /tmp/alvie when they are missing.)
The programs of the guides work too: learn.exe (alvie learn), fa.exe (alvie compare), exec.exe (alvie exec),
alvie.exe, also as _build/default/bin/learn.exe ...
The scripts of the guides: learn_example, learn_one, learn_one_nospecial, learn_all, check_example, check_one,
check_all (also as ./learn_one.sh ...). They run their commands in parallel (up to 4 at once); the logs go to logs/.

Files:  ls [dir]   cd [dir]   pwd   cat FILE   edit FILE   cp A B   mv A B   rm PATH
        view MODEL [MODEL2] [--inputs I1,I2,...]  (draw one or two models; follow the inputs on them)
        cmp A B (are two files identical?)
        download FILE   reset-files (back to the files of a first visit)   clear   history   help
Keys:   Ctrl-C stops a command, Tab completes a path, Up/Down walk the history.`;

// How many commands of a script run at once: half of the cores of the computer, at most 4 (each command is a Web Worker
// with its own WebAssembly)
const scriptJobsAtOnce = () => Math.max(1, Math.min(4, Math.floor((globalThis.navigator?.hardwareConcurrency || 2) / 2)));

const ALVIE = new Set(['alvie', 'sancus', 'tiny', 'vaultlink', 'learn', 'compare', 'exec', 'check']);

export class Shell {
  // term: { write(text), writeln(text), clear() }; the terminal gives its input to input(data)
  constructor(term, { files, runner, openEditor, openViewer, download, storage = globalThis.localStorage }) {
    Object.assign(this, { term, files, runner, openEditor, openViewer, download, storage });
    this.cwd = '/';
    this.line = ''; this.cursor = 0;
    try { this.history = JSON.parse(storage?.getItem('alvie-ide-history') || '[]'); } catch { this.history = []; }
    this.hpos = this.history.length;
    this.term.writeln('ALVIE in your browser. Type help.');
    this.prompt();
  }

  prompt() { this.term.write(`\x1b[1;34m${this.cwd}\x1b[0m $ `); this.line = ''; this.cursor = 0; }
  redraw() { this.term.write(`\r\x1b[K\x1b[1;34m${this.cwd}\x1b[0m $ ${this.line}`); const back = this.line.length - this.cursor; if (back > 0) this.term.write(`\x1b[${back}D`); }
  print(text, stream = 'stdout') { for (const l of String(text).split('\n')) this.term.writeln(stream === 'stderr' ? `\x1b[31m${l}\x1b[0m` : l); }

  input(data) {
    if (this.busy) { if (data === '\x03') { this.cancel(); this.print('^C (stopped)'); } return; }
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
      try { this.storage?.setItem('alvie-ide-history', JSON.stringify(this.history)); } catch {}
    }
    const args = splitArgs(trimmed);
    // The exit status of the command: 0, or a failure (130 when it was stopped)
    let status = 0;
    this.busy = true; this.stopped = false;
    try {
      if (args.length === 0) {}
      else if (scriptOf(args)) status = await this.script(scriptOf(args));
      else if (ALVIE.has(args[0]) || programOf(args[0])) status = await this.alvie(args);
      else this.builtin(args);
    } catch (e) { this.print(String(e.message || e), 'stderr'); status = 1; }
    this.busy = false;
    this.prompt();
    return status;
  }

  async alvie(args) {
    const { exit, ms, cancelled } = await this.runner.run(args, { cwd: this.cwd, onOutput: (stream, l) => this.print(l, stream) });
    if (!cancelled) this.print(`\x1b[2m(${(ms / 1000).toFixed(1)} s${exit !== null && exit !== 0 ? `, exit ${exit}` : ''})\x1b[0m`);
    return cancelled ? 130 : exit ?? 0;
  }

  // A script of the guides: its jobs, in parallel, each with its output in its log, and the messages of the
  // script. Returns the exit status of the script
  async script(sc) {
    const { usage, jobs = [], errors = [], exitIfMissing } = scriptJobs(this.files, sc);
    if (usage) { this.print(usage, 'stderr'); return 2; }
    if (exitIfMissing) { errors.forEach((e) => this.print(e, 'stderr')); return exitIfMissing; }
    const learning = sc.name.startsWith('learn');
    const logs = jobs.length ? jobs[0].log.slice(0, jobs[0].log.lastIndexOf('/')) : '';
    this.print(`\n${learning ? 'Learning' : 'Comparison'} started: refer to files in ${logs.slice(1)} for details`);
    let failed = false, next = 0, stopped = false;
    const t0 = performance.now();
    // The commands run in parallel, as the scripts run them (ALVIE_JOBS), each in its own Web Worker
    this.pool = Array.from({ length: Math.min(jobs.length, scriptJobsAtOnce()) }, () => new Runner(this.files, { base: this.runner.base, newWorker: this.runner.newWorker }));
    const work = async (runner) => {
      while (!stopped && !this.stopped && next < jobs.length) {
        const k = next++, job = jobs[k];
        if (job.res && this.files.has(job.res)) { this.print(`${job.name} ... [OK - Done before]`); continue; }
        this.print(`\x1b[2m[${k + 1}/${jobs.length}]\x1b[0m ${job.argv.map((a) => (a.startsWith('/') ? a.slice(1) : a)).join(' ')}`);
        // The directories of the model and of the counterexamples, as the scripts have them (mkdir -p)
        for (const flag of ['--res', '--witness-file-basename']) {
          const i = job.argv.indexOf(flag), dir = i >= 0 ? job.argv[i + 1].slice(0, job.argv[i + 1].lastIndexOf('/')) : '';
          if (dir && !this.files.isDir(dir)) this.files.write(`${dir}/.keep`, '');
        }
        const out = [];
        const { exit, cancelled } = await runner.run(job.argv, { cwd: '/', onOutput: (_, l) => out.push(l) });
        this.files.write(job.log, out.join('\n') + '\n');
        if (cancelled) { stopped = true; return; }
        if (exit === 0 || exit === null) this.print(`${job.name} ... [OK - ${job.log.slice(1)}]`);
        else { failed = true; this.print(`${job.name} ... [KO - ${job.log.slice(1)}]`, 'stderr'); }
      }
    };
    await Promise.all(this.pool.map(work));
    this.pool = [];
    if (stopped || this.stopped) { this.print(`Stopped: ${jobs.length - next} commands not started.`, 'stderr'); return 130; }
    errors.forEach((e) => this.print(e, 'stderr'));
    this.print(`\x1b[2m(${((performance.now() - t0) / 1000).toFixed(1)} s)\x1b[0m`);
    if (errors.length) { this.print(`Comparison incomplete: required models are missing. See results/${{ check_one: sc.params[1], check_all: sc.params[0] }[sc.name] ?? 'example'}.`, 'stderr'); return 2; }
    if (failed) { this.print(`${learning ? 'Learning' : 'Comparison'} incomplete: one or more ${learning ? 'models' : 'comparisons'} failed. See ${logs.slice(1)}.`, 'stderr'); return 1; }
    return 0;
  }

  // Stops the running command: a command of ALVIE, or every command of a script
  cancel() {
    this.stopped = true;
    this.runner.cancel();
    for (const r of this.pool || []) r.cancel();
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
      case 'cmp': {
        need(2);
        for (const f of rest.slice(0, 2)) if (!this.files.has(p(f))) throw new Error(`cmp: no such file: ${f}`);
        if (this.files.read(p(rest[0])) !== this.files.read(p(rest[1]))) throw new Error(`cmp: ${rest[0]} and ${rest[1]} differ`);
        this.print(`${rest[0]} and ${rest[1]} are identical`);
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

