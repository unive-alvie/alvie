// Runs a command of alvie-web in a new Web Worker (public/alvie/runner.js) with the files of the IDE, and merges the
// files it gives back. One command at a time; cancel() terminates the worker.

// The commits of sancus-core-gap that have a simulator (public/alvie/sim/index.json)
let commitsPromise = null;
export function knownCommits(base = '') {
  commitsPromise ??= fetch(`${base}alvie/sim/index.json`).then((r) => (r.ok ? r.json() : [])).catch(() => []);
  return commitsPromise;
}

// The programs of the guides, as commands of alvie-web: learn.exe is alvie learn, fa.exe alvie compare, exec.exe alvie
// exec, alvie.exe alvie (also as _build/default/bin/..., or ./...)
const PROGRAMS = { 'learn.exe': ['learn'], 'fa.exe': ['compare'], 'exec.exe': ['exec'], 'alvie.exe': [], alvie: [] };
export const programOf = (word) => PROGRAMS[word.split('/').pop()];

// The argv as alvie-web takes it: without a leading "alvie" (or learn.exe ...), and, for the commands of Sancus, with
// the parameters that a browser does not use (the checkout of sancus-core-gap, the temporary directory) when they are
// missing
export function prepareArgv(args) {
  const program = programOf(args[0]);
  const argv = program ? [...program, ...args.slice(1)] : [...args];
  const sancus = ['sancus', 'learn', 'compare', 'exec'].includes(argv[0]);
  if (sancus && argv.length > 1 && !argv.includes('-help') && !argv.includes('help')) {
    if (!argv.includes('--sancus') && argv[0] !== 'compare') argv.push('--sancus', 'none');
    if (!argv.includes('--tmpdir')) argv.push('--tmpdir', '/tmp/alvie');
  }
  return argv;
}

export class Runner {
  // base: the URL of the directory that has alvie/; newWorker makes the worker of alvie/runner.js (VS Code makes it
  // from a blob, since its extension host has another origin)
  constructor(files, { base = '', newWorker = () => new Worker(`${base}alvie/runner.js`) } = {}) {
    Object.assign(this, { files, base, newWorker }); this.worker = null; this.finish = null;
  }

  get running() { return this.worker !== null; }

  async run(args, { cwd = '/', env = {}, onOutput }) {
    if (this.worker) throw new Error('a command is running');
    const argv = prepareArgv(args);
    const known = await knownCommits(this.base);
    // The simulators: the commit of --commit, or all (e.g. for the fixtures, whose commits are in their files)
    const i = argv.indexOf('--commit');
    const usesSimulator = ['sancus', 'learn', 'exec'].includes(argv[0]);
    const commits = !usesSimulator ? [] : i >= 0 ? [argv[i + 1]].filter((c) => known.includes(c)) : ['learn', 'exec'].includes(argv[0]) ? ['ef753b6'] : known;
    const worker = await this.newWorker();
    const sent = this.files.all();
    return new Promise((resolve) => {
      this.worker = worker;
      const t0 = performance.now();
      this.finish = (result) => {
        worker.terminate();
        this.worker = null; this.finish = null;
        resolve({ ...result, ms: performance.now() - t0 });
      };
      let ended = false;
      worker.onmessage = (event) => {
        const m = event.data;
        if (ended) return;
        if (m.type === 'done') ended = true;
        if (m.type === 'output') onOutput(m.stream, m.line);
        else if (m.type === 'done') {
          // Only the files that the command wrote: another command (in another terminal) may have changed the others
          this.files.merge(Object.fromEntries(Object.entries(m.files).filter(([p, t]) => sent[p] !== t)));
          this.finish({ exit: m.exit });
        }
      };
      worker.onerror = (e) => { onOutput('stderr', `error: ${e.message}`); this.finish?.({ exit: null }); };
      worker.postMessage({ argv, env, cwd, files: sent, commits, base: this.base ? `${this.base}alvie/` : undefined });
    });
  }

  cancel() { if (this.finish) this.finish({ exit: null, cancelled: true }); }
}
