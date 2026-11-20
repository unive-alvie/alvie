// Runs one command of alvie-web for the IDE, in a Web Worker (a new one for each command: alvie-web runs its main
// once). The page posts { argv, env, cwd, files, commits }: files is an object from absolute path to text, commits the
// commits of sancus-core-gap whose simulators the command needs. The worker posts { type: 'output', stream, line } as
// alvie-web prints, then { type: 'done', exit, files }: the exit code (null if it did not call exit) and every file of
// the file system except /tmp, as an object from path to text.
'use strict';
const SIM_FILES = ['generic_template.s43', 'pmem_defs.asm', 'pmem.sh', 'pmem.x', 'sancus_macros.asm'];

self.onmessage = async (event) => {
  const { argv, env, cwd, files, commits } = event.data;
  const output = (stream) => (line) => postMessage({ type: 'output', stream, line });
  let vfs = null, finished = false;
  const finish = () => {
    if (finished) return;
    finished = true;
    vfs?.flush();
    const out = {};
    if (vfs) for (const p of vfs.walk('/')) if (!p.startsWith('/tmp/')) out[p] = vfs.readFile(p);
    postMessage({ type: 'done', exit: vfs?.exitCode ?? null, files: out });
  };
  try {
    // The simulators first: Emscripten chooses its environment when it makes a module, and must not see the shim
    const sims = {}, simFiles = {};
    for (const commit of commits || []) {
      importScripts(`sim/${commit}/sim.js`);
      sims[commit] = await createSancusSim({ locateFile: (p) => `sim/${commit}/${p}` });
      simFiles[commit] = await Promise.all(SIM_FILES.map(async (n) => [n, await (await fetch(`sim/${commit}/files/${n}`)).text()]));
    }
    importScripts('node-shim.js');
    vfs = AlvieNodeShim.install({ argv, env, base: './', stdout: (l) => { if (!finished) output('stdout')(l); },
      stderr: (l) => { if (!finished) output('stderr')(l); }, onExit: () => finish() });
    for (const [path, text] of Object.entries(files || {})) vfs.writeFile(path, text);
    if (cwd) { vfs.fs.mkdirSync(cwd, { recursive: true }); process.chdir(cwd); }
    self.alvieSancus = {
      files: (commit) => {
        if (!simFiles[commit]) throw new Error(`no simulator for the commit ${commit} (simulators: ${commits.join(', ') || 'none'})`);
        return simFiles[commit];
      },
      run: (commit, mem, vcd) => { const r = sims[commit].run(vfs.readBytes(mem)); vfs.writeBytes(vcd, r.vcd); return r.status; },
    };
    self.alvieDone = () => setTimeout(finish, 0);
    self.addEventListener('error', (e) => {
      if (e.error?.alvieExit === undefined) output('stderr')(`error: ${e.message}`);
      e.preventDefault(); finish();
    });
    self.addEventListener('unhandledrejection', (e) => {
      if (e.reason?.alvieExit === undefined) output('stderr')(`error: ${e.reason}`);
      e.preventDefault(); finish();
    });
    importScripts('alvie-web.js');
  } catch (e) {
    if (e?.alvieExit === undefined) output('stderr')(`error: ${e} ${e?.stack || ''}`);
    finish();
  }
};
