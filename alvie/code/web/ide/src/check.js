// Live errors in the editor: the specs (.atdl, .etdl, .spec, .vtdl) are checked by ALVIE's own parsers, alvie-web
// check FILE (web/alvie_web.ml), in a Web Worker, 600 ms after the last change. Its problems become diagnostics of
// CodeMirror.
import { linter } from '@codemirror/lint';

const CHECKED = /\.(atdl|etdl|spec|vtdl)$/;

function check(path, text) {
  return new Promise((resolve) => {
    const worker = new Worker('alvie/runner.js');
    const lines = [];
    const done = () => { worker.terminate(); resolve(lines.flatMap((l) => { try { return [JSON.parse(l)]; } catch { return []; } })); };
    const timer = setTimeout(done, 10000);
    worker.onmessage = (e) => {
      if (e.data.type === 'output' && e.data.stream === 'stdout') lines.push(e.data.line);
      else if (e.data.type === 'done') { clearTimeout(timer); done(); }
    };
    worker.onerror = () => { clearTimeout(timer); done(); };
    worker.postMessage({ argv: ['check', path], env: {}, cwd: '/', files: { [path]: text }, commits: [] });
  });
}

export function linterFor(path) {
  if (!CHECKED.test(path)) return [];
  return linter(async (view) => {
    const doc = view.state.doc;
    const problems = await check(path, doc.toString());
    return problems.map((p) => {
      const line = doc.line(Math.min(Math.max(1, p.line), doc.lines));
      const from = Math.min(line.from + Math.max(0, p.col - 1), line.to);
      // The word at the position, or the rest of the line
      const word = /^[\w?#&-]+/.exec(doc.sliceString(from, line.to));
      return { from, to: word ? from + word[0].length : line.to, severity: p.severity === 'warning' ? 'warning' : 'error', message: p.message };
    });
  }, { delay: 600 });
}
