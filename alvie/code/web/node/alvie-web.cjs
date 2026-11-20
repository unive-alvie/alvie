// alvie-web in Node: node alvie-web-node.cjs ARGS... runs alvie-web (alvie-web.js, next to this file) with ARGS,
// for example: sancus learn --spec A.atdl --spec E.etdl --secret 0 --commit bf89c0b --res out.dot
//
// It is the host of the simulators in WebAssembly (see web/sancus_host.ml): ALVIE_WEB_SIM names the directory where
// web/sim/build-sim.sh wrote them (one directory per commit, with sim.js, sim.wasm and files/). The simulator of the
// commit given with --commit is loaded before ALVIE starts (all of them without --commit), since ALVIE calls it
// synchronously.
'use strict';
const fs = require('fs');
const path = require('path');

const simDir = process.env.ALVIE_WEB_SIM || path.join(__dirname, 'sim');
const sims = {};

globalThis.alvieSancus = {
  files(commit) {
    const dir = path.join(simDir, commit, 'files');
    if (!fs.existsSync(dir)) throw new Error(`no simulator in WebAssembly for the commit ${commit} in ${simDir}`);
    return fs.readdirSync(dir).sort().map((name) => [name, fs.readFileSync(path.join(dir, name), 'utf8')]);
  },
  run(commit, mem) {
    const sim = sims[commit];
    if (!sim) throw new Error(`the simulator of the commit ${commit} is not loaded`);
    return sim.run(mem);
  },
};

(async () => {
  const i = process.argv.indexOf('--commit');
  const commits = i > 0 ? [process.argv[i + 1]] : (fs.existsSync(simDir) ? fs.readdirSync(simDir) : []);
  for (const commit of commits) {
    const js = path.join(simDir, commit, 'sim.js');
    if (fs.existsSync(js)) sims[commit] = await require(js)();
  }
  require(path.join(__dirname, 'alvie-web.js'));
})();
