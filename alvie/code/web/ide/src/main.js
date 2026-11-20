// The IDE of ALVIE in the browser: files (left), editor and terminal (centre), viewer (right). Everything runs in the
// page: alvie-web and the simulators of Sancus in WebAssembly, in a Web Worker for each command.
import { Files } from './files.js';
import { Runner } from './runner.js';
import { xtermShell } from './xterm-shell.js';
import { Editor } from './editor.js';
import { Viewer } from './viewer.js';
import { Tree } from './tree.js';
import { linterFor } from './check.js';

const $ = (id) => document.getElementById(id);

const files = new Files();
await files.load();
const runner = new Runner(files);

const editor = new Editor($('editor'), {
  files,
  linterFor,
  onStatus: (path, status) => { $('editor-file').textContent = path; $('editor-status').textContent = status; },
});
const viewer = new Viewer($('viewer'), {
  files,
  onTitle: (paths) => { $('viewer-title').textContent = paths.length ? `Viewer: ${paths.map((p) => p.split('/').pop()).join(' | ')}` : 'Viewer'; },
});
const tree = new Tree($('tree'), { files, onOpen: (p) => editor.open(p), onView: (ps) => viewer.show(ps) });

function download(path) {
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([files.read(path)], { type: 'text/plain' }));
  a.download = path.split('/').pop();
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}

const shell = xtermShell($('terminal'), {
  files, runner,
  openEditor: (p) => { editor.open(p); tree.select(p); },
  openViewer: (ps, inputs) => viewer.show(ps, inputs),
  download,
});

$('new-file').addEventListener('click', () => {
  const name = prompt('New file (a path, e.g. /spec-lib/my.atdl):', '/spec-lib/new.atdl');
  if (name) { files.write(name.startsWith('/') ? name : `/${name}`, ''); editor.open(name.startsWith('/') ? name : `/${name}`); }
});
$('upload').addEventListener('click', () => $('upload-input').click());
$('upload-input').addEventListener('change', async (e) => {
  for (const f of e.target.files) files.write(`/uploads/${f.name}`, await f.text());
  e.target.value = '';
});
$('download').addEventListener('click', () => { const p = tree.selected || editor.path; if (p && files.has(p)) download(p); });
$('viewer-close').addEventListener('click', () => viewer.close(viewer.paths.length - 1));

// The splitter between the editor and the terminal
$('splitter').addEventListener('pointerdown', (e) => {
  const center = $('center'), start = e.clientY, h = $('terminal').getBoundingClientRect().height;
  const move = (ev) => { center.style.setProperty('--terminal-height', `${Math.max(80, h - (ev.clientY - start))}px`); };
  window.addEventListener('pointermove', move);
  window.addEventListener('pointerup', () => window.removeEventListener('pointermove', move), { once: true });
});

tree.render();
const first = '/spec-lib/example/attacker.atdl';
if (files.has(first)) { editor.open(first); tree.select(first); }
viewer.show([]);
// For tests and for the documentation: the IDE drives its own terminal (window.alvieIde.run('alvie ...'))
window.alvieIde = { files, run: (line) => shell.run(line), editor, viewer, shell };
const query = new URLSearchParams(location.search);
if (query.has('selftest')) import('./selftest.js').then((m) => m.selftest(window.alvieIde));
// index.html?demo=1: an example model in the viewer and the help in the terminal (for screenshots)
// index.html?demo=vault: the two services of VaultLink learned, compared, and drawn with their distinguishing sequence
if (query.get('demo') === 'vault') {
  await shell.run('vaultlink learn --spec spec-lib/vaultlink/vault.vtdl --service reference --res models/reference.dot');
  await shell.run('vaultlink learn --spec spec-lib/vaultlink/vault.vtdl --service firmware --res models/firmware.dot');
  await shell.run('vaultlink compare models/reference.dot models/firmware.dot');
  await shell.run('view models/reference.dot models/firmware.dot --inputs HELLO,ID_ME,PASS_OK,AUDIT,AUDIT');
  editor.open('/spec-lib/vaultlink/vault.vtdl');
  setTimeout(() => fetch('ready', { method: 'POST' }), 1000);
} else if (query.has('demo')) {
  await viewer.show(['/results/example/bf89c0b-attacker-enclave-0-0.01-0.01.dot']);
  await shell.run('help');
  setTimeout(() => fetch('ready', { method: 'POST' }), 500);
}
