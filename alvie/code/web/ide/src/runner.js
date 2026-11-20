// Runs a command of alvie-web in a new Web Worker (public/alvie/runner.js) with the files of the IDE, and merges the
// files it gives back. One command at a time; cancel() terminates the worker.

// The commits of sancus-core-gap that have a simulator (public/alvie/sim/index.json)
let commitsPromise = null;
export function knownCommits() {
  commitsPromise ??= fetch('alvie/sim/index.json').then((r) => (r.ok ? r.json() : [])).catch(() => []);
  return commitsPromise;
}

// The argv as alvie-web takes it: without a leading "alvie", and, for sancus, with the parameters that a browser does
// not use (the checkout of sancus-core-gap, the temporary directory) when they are missing
export function prepareArgv(args) {
  const argv = args[0] === 'alvie' ? args.slice(1) : [...args];
  if (argv[0] === 'sancus' && argv.length > 1 && !argv.includes('-help') && !argv.includes('help')) {
    if (!argv.includes('--sancus')) argv.push('--sancus', 'none');
    if (!argv.includes('--tmpdir')) argv.push('--tmpdir', '/tmp/alvie');
  }
  return argv;
}

export class Runner {
  constructor(files) { this.files = files; this.worker = null; this.finish = null; }

  get running() { return this.worker !== null; }

  async run(args, { cwd = '/', env = {}, onOutput }) {
    if (this.worker) throw new Error('a command is running');
    const argv = prepareArgv(args);
    const known = await knownCommits();
    // The simulators: the commit of --commit, or all (e.g. for the fixtures, whose commits are in their files)
    const i = argv.indexOf('--commit');
    const commits = argv[0] !== 'sancus' ? [] : i >= 0 ? [argv[i + 1]].filter((c) => known.includes(c)) : known;
    return new Promise((resolve) => {
      const worker = new Worker('alvie/runner.js');
      this.worker = worker;
      const t0 = performance.now();
      this.finish = (result) => {
        worker.terminate();
        this.worker = null; this.finish = null;
        resolve({ ...result, ms: performance.now() - t0 });
      };
      worker.onmessage = (event) => {
        const m = event.data;
        if (m.type === 'output') onOutput(m.stream, m.line);
        else if (m.type === 'done') { this.files.merge(m.files); this.finish({ exit: m.exit }); }
      };
      worker.onerror = (e) => { onOutput('stderr', `error: ${e.message}`); this.finish?.({ exit: null }); };
      worker.postMessage({ argv, env, cwd, files: this.files.all(), commits });
    });
  }

  cancel() { if (this.finish) this.finish({ exit: null, cancelled: true }); }
}
