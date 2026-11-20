// alvie-web in a Web Worker. The page posts { argv, files, collect, commit }; the worker gives alvie-web a small Node
// (node-shim.js: an in-memory file system), writes the files there, loads the simulator of the commit
// (sim/COMMIT/sim.js and its files), runs the command, and posts { done: true, lines, files, exit }: what alvie-web
// printed, the files of collect, and its exit code (null if it did not call exit).
self.onmessage = async (event) => {
  const { argv, files, collect, commit } = event.data;
  const lines = [];
  const log = (...args) => lines.push(args.join(' '));
  console.log = log; console.error = log; console.warn = log; console.info = log;
  let vfs = null, posted = false;
  const finish = () => {
    if (posted) return; posted = true;
    vfs?.flush();
    const out = {};
    for (const p of collect || []) if (vfs?.exists(p)) out[p] = vfs.readFile(p);
    postMessage({ done: true, lines, files: out, exit: vfs?.exitCode ?? null });
  };
  try {
    // The simulator first: Emscripten chooses its environment when the module is made, and must not see the shim
    importScripts(`sim/${commit}/sim.js`);
    const sim = await createSancusSim({ locateFile: (p) => `sim/${commit}/${p}` });
    const names = ['generic_template.s43', 'pmem_defs.asm', 'pmem.sh', 'pmem.x', 'sancus_macros.asm'];
    const simFiles = await Promise.all(names.map(async (n) => [n, await (await fetch(`sim/${commit}/files/${n}`)).text()]));
    importScripts('node-shim.js');
    vfs = AlvieNodeShim.install({ argv, base: './', stdout: log, stderr: log });
    for (const [path, text] of Object.entries(files || {})) vfs.writeFile(path, text);
    self.alvieSancus = { files: () => simFiles, run: (_commit, mem) => sim.run(mem) };
    self.alvieDone = () => setTimeout(finish, 0);
    self.addEventListener('error', (e) => { if (e.error?.alvieExit !== undefined) { e.preventDefault(); finish(); } });
    self.addEventListener('unhandledrejection', (e) => {
      if (e.reason?.alvieExit !== undefined) { e.preventDefault(); finish(); }
      else { lines.push(`error: ${e.reason} ${e.reason?.stack || ''}`); finish(); }
    });
    importScripts('alvie-web.js');
  } catch (e) {
    lines.push(`worker error: ${e} ${e.stack || ''}`);
    finish();
  }
};
