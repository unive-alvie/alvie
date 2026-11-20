// ALVIE in VS Code for the Web. Everything runs in the browser:
//   - the files (spec-lib/, results/, models/, tutorials/, ...) are the folder alvie:/, kept in IndexedDB;
//   - an ALVIE terminal runs a shell (core/terminal.js): the commands of ALVIE (in a Web Worker each), the programs and
//     the scripts of the guides, and commands on the files;
//   - the tutorials (.alvienb) are notebooks whose cells run commands of ALVIE (notebook.js);
//   - the specs (.atdl, .etdl, .spec, .vtdl) are checked by alvie-web check as they change: their mistakes are in the
//     Problems panel;
//   - a model (.dot) is drawn in a preview, alone or next to another, and `view A [B] --inputs ...` follows inputs on it.
// alvie-web, the simulators and the files of a first visit are in bundle/ of this extension (see prepare.sh).
import * as vscode from 'vscode';
import { Files } from './core/files.js';
import { Runner } from './core/runner.js';
import { Shell } from './core/terminal.js';
import { NOTEBOOK, Serializer, controller } from './notebook.js';
import { FilesProvider, SCHEME } from './files-provider.js';
import { Preview } from './preview.js';

const CHECKED = new Set(['testdl', 'vtdl']);

export async function activate(context) {
  const base = `${vscode.Uri.joinPath(context.extensionUri, 'bundle').toString(true)}/`;
  const files = new Files({ base });
  await files.load();
  const provider = new FilesProvider(files);
  context.subscriptions.push(vscode.workspace.registerFileSystemProvider(SCHEME, provider, { isCaseSensitive: true }));

  // The extension host has another origin than bundle/: its workers are made from a blob of runner.js
  let runnerUrl = null;
  const newWorker = async () => {
    runnerUrl ??= URL.createObjectURL(new Blob([await (await fetch(`${base}alvie/runner.js`)).text()], { type: 'text/javascript' }));
    return new Worker(runnerUrl);
  };

  const preview = new Preview(context, files);
  // The tutorials: notebooks of commands of ALVIE
  const tutorials = controller({ files, base, newWorker, openEditor: (p) => vscode.window.showTextDocument(vscode.Uri.from({ scheme: SCHEME, path: p }), { viewColumn: vscode.ViewColumn.Beside }) });
  context.subscriptions.push(
    // Outputs are not part of a tutorial: running its cells does not change it
    vscode.workspace.registerNotebookSerializer(NOTEBOOK, new Serializer(), { transientOutputs: true }),
    tutorials,
  );
  const uriOf = (path) => vscode.Uri.from({ scheme: SCHEME, path });
  const pathOf = (uri) => (uri.scheme === SCHEME ? uri.path : null);

  // An ALVIE terminal: the shell on a pseudoterminal, with its own runner (terminals run in parallel)
  const storage = { getItem: (k) => context.globalState.get(k) ?? null, setItem: (k, v) => context.globalState.update(k, v) };
  const pty = () => {
    const write = new vscode.EventEmitter();
    const crlf = (s) => String(s).replace(/\r?\n/g, '\r\n');
    const term = { write: (s) => write.fire(crlf(s)), writeln: (s) => write.fire(`${crlf(s)}\r\n`), clear: () => write.fire('\x1b[2J\x1b[3J\x1b[H') };
    let shell = null;
    return {
      onDidWrite: write.event,
      open: () => {
        shell = new Shell(term, {
          files, runner: new Runner(files, { base, newWorker }), storage,
          openEditor: (p) => vscode.window.showTextDocument(uriOf(p), { preview: false }),
          openViewer: (ps, inputs) => preview.show(ps, inputs),
          download: (p) => vscode.commands.executeCommand('revealInExplorer', uriOf(p))
            .then(() => term.writeln('Right-click the file in the Explorer and choose Download...')),
        });
      },
      close: () => shell?.cancel(),
      handleInput: (data) => shell?.input(data),
    };
  };
  const newTerminal = () => {
    const t = vscode.window.createTerminal({ name: 'ALVIE', pty: pty() });
    t.show();
    return t;
  };
  context.subscriptions.push(
    vscode.window.registerTerminalProfileProvider('alvie.terminal-profile', {
      provideTerminalProfile: () => new vscode.TerminalProfile({ name: 'ALVIE', pty: pty() }),
    }),
    vscode.commands.registerCommand('alvie.terminal', newTerminal),
    vscode.commands.registerCommand('alvie.preview', (uri) => {
      const p = pathOf(uri ?? vscode.window.activeTextEditor?.document.uri);
      if (p) preview.show([p]);
    }),
    vscode.commands.registerCommand('alvie.previewWith', async (uri) => {
      const p = pathOf(uri ?? vscode.window.activeTextEditor?.document.uri);
      if (!p) return;
      const models = [...files.files.keys()].filter((f) => f.endsWith('.dot') && f !== p);
      const other = await vscode.window.showQuickPick(models, { placeHolder: `The model to draw next to ${p}` });
      if (other) preview.show([p, other]);
    }),
    vscode.commands.registerCommand('alvie.resetFiles', async () => {
      const ok = await vscode.window.showWarningMessage('Bring back the files of a first visit? Your files and models are removed.', { modal: true }, 'Reset');
      if (ok) await files.reset();
    }),
  );

  // Problems: the mistakes that alvie-web check finds in a spec, 600 ms after its last change
  const diagnostics = vscode.languages.createDiagnosticCollection('alvie');
  context.subscriptions.push(diagnostics);
  const timers = new Map();
  const check = (doc) => {
    const path = pathOf(doc.uri);
    if (!path || !CHECKED.has(doc.languageId)) return;
    clearTimeout(timers.get(path));
    timers.set(path, setTimeout(async () => {
      const problems = await checkSpec(newWorker, base, path, doc.getText());
      diagnostics.set(doc.uri, problems.map((p) => {
        const line = Math.min(Math.max(0, p.line - 1), doc.lineCount - 1);
        const start = new vscode.Position(line, Math.max(0, p.col - 1));
        const range = doc.getWordRangeAtPosition(start, /[\w?#&-]+/) ?? doc.lineAt(line).range.with(start);
        const d = new vscode.Diagnostic(range, p.message, p.severity === 'warning' ? vscode.DiagnosticSeverity.Warning : vscode.DiagnosticSeverity.Error);
        d.source = 'alvie';
        return d;
      }));
    }, 600));
  };
  context.subscriptions.push(
    vscode.workspace.onDidOpenTextDocument(check),
    vscode.workspace.onDidChangeTextDocument((e) => check(e.document)),
    vscode.workspace.onDidCloseTextDocument((doc) => diagnostics.delete(doc.uri)),
  );
  vscode.workspace.textDocuments.forEach(check);

  // The first view of the folder alvie:/ in an empty session: an example spec and an ALVIE terminal. A tutorial (the page
  // opens it, see site/main.js) is the view of its own session.
  if (vscode.workspace.workspaceFolders?.some((f) => f.uri.scheme === SCHEME)) {
    setTimeout(async () => {
      const tabs = vscode.window.tabGroups.all.flatMap((g) => g.tabs);
      if (tabs.some((t) => t.input instanceof vscode.TabInputNotebook)) return;
      const first = '/spec-lib/example/attacker.atdl';
      if (tabs.length === 0 && files.has(first)) await vscode.window.showTextDocument(uriOf(first), { preview: false, preserveFocus: true });
      if (vscode.window.terminals.length === 0) newTerminal();
    }, 1000);
  }
  // For tests: the API of the extension. run(line) runs a command line in a shell of its own and gives its output
  const run = async (line) => {
    const out = [];
    const term = { write: (t) => out.push(String(t)), writeln: (t) => out.push(`${t}\n`), clear: () => {} };
    const shell = new Shell(term, { files, runner: new Runner(files, { base, newWorker }), openEditor: () => {},
      openViewer: (ps, inputs) => preview.show(ps, inputs), download: () => {} });
    await shell.run(line);
    return out.join('').replace(/\x1b\[[0-9;]*[A-Za-z]/g, '');
  };
  return { files, preview, newTerminal, run, diagnostics, tutorials };
}

// alvie-web check PATH on a spec: its problems ({ line, col, severity, message }, one JSON per line)
function checkSpec(newWorker, base, path, text) {
  return new Promise((resolve) => {
    const lines = [];
    newWorker().then((worker) => {
      const done = () => { worker.terminate(); resolve(lines.flatMap((l) => { try { return [JSON.parse(l)]; } catch { return []; } })); };
      const timer = setTimeout(done, 10000);
      worker.onmessage = (e) => {
        if (e.data.type === 'output' && e.data.stream === 'stdout') lines.push(e.data.line);
        else if (e.data.type === 'done') { clearTimeout(timer); done(); }
      };
      worker.onerror = () => { clearTimeout(timer); done(); };
      worker.postMessage({ argv: ['check', path], env: {}, cwd: '/', files: { [path]: text }, commits: [], base: `${base}alvie/` });
    }, () => resolve([]));
  });
}

export function deactivate() {}
