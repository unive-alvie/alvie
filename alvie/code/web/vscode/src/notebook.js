// The tutorials of ALVIE as notebooks of VS Code. A tutorial (.alvienb) is Markdown: its ```alvie blocks are cells of
// commands, the rest is text. A cell runs its lines one after the other in the shell of the notebook (one for each
// notebook, so that cd stays), as in an ALVIE terminal; its output streams into the cell, and `view A [B] --inputs ...`
// draws the models in the cell (the renderer of renderer.js).
import * as vscode from 'vscode';
import { Shell } from './core/terminal.js';
import { Runner } from './core/runner.js';

export const NOTEBOOK = 'alvie-tutorial';
export const MODELS_MIME = 'application/vnd.alvie.models+json';
const LANGUAGE = 'alvie';
const FENCE = /^```alvie\s*$/;

// Markdown with ```alvie blocks <-> cells
export function parseNotebook(text) {
  const cells = [], md = [];
  const flush = () => {
    const t = md.join('\n').trim();
    if (t) cells.push({ kind: 'markup', text: t });
    md.length = 0;
  };
  const lines = text.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    if (FENCE.test(lines[i])) {
      flush();
      const code = [];
      for (i++; i < lines.length && !/^```\s*$/.test(lines[i]); i++) code.push(lines[i]);
      cells.push({ kind: 'code', text: code.join('\n') });
    } else md.push(lines[i]);
  }
  flush();
  return cells;
}

export function printNotebook(cells) {
  return `${cells.map((c) => (c.kind === 'code' ? `\`\`\`${LANGUAGE}\n${c.text}\n\`\`\`` : c.text.trim())).join('\n\n')}\n`;
}

export class Serializer {
  deserializeNotebook(content) {
    const cells = parseNotebook(new TextDecoder().decode(content)).map((c) => (c.kind === 'code'
      ? new vscode.NotebookCellData(vscode.NotebookCellKind.Code, c.text, LANGUAGE)
      : new vscode.NotebookCellData(vscode.NotebookCellKind.Markup, c.text, 'markdown')));
    return new vscode.NotebookData(cells);
  }

  serializeNotebook(data) {
    return new TextEncoder().encode(printNotebook(data.cells.map((c) => ({
      kind: c.kind === vscode.NotebookCellKind.Code ? 'code' : 'markup', text: c.value }))));
  }
}

// The controller: runs cells of commands of ALVIE
export function controller({ files, base, newWorker, openEditor }) {
  const shells = new Map(); // notebook URI -> its shell
  const c = vscode.notebooks.createNotebookController('alvie-tutorial-shell', NOTEBOOK, 'ALVIE');
  c.supportedLanguages = [LANGUAGE];
  c.supportsExecutionOrder = true;
  let order = 0;

  const shellOf = (notebook) => {
    const key = notebook.uri.toString();
    if (!shells.has(key)) {
      const term = { out: null, write: (t) => term.out?.(String(t)), writeln: (t) => term.out?.(`${t}\n`), clear: () => {} };
      const shell = new Shell(term, { files, runner: new Runner(files, { base, newWorker }), openEditor, download: () => {},
        openViewer: (paths, inputs) => term.view?.(paths, inputs) });
      shell.prompt = () => {};
      shells.set(key, { shell, term });
    }
    return shells.get(key);
  };

  c.executeHandler = async (cells, notebook) => {
    for (const cell of cells) {
      const run = c.createNotebookCellExecution(cell);
      run.executionOrder = ++order;
      run.start(Date.now());
      await run.clearOutput();
      const { shell, term } = shellOf(notebook);
      let text = '', pending = null, ok = true;
      const outputs = [];
      // The text of the cell, updated at most 10 times a second
      const stream = new vscode.NotebookCellOutput([vscode.NotebookCellOutputItem.stdout('')]);
      const show = () => run.replaceOutput([stream, ...outputs].filter((o) => o !== stream || text));
      const flush = () => { pending = null; stream.items[0] = vscode.NotebookCellOutputItem.stdout(text); return show(); };
      term.out = (t) => { text += t.replace(/\r/g, ''); pending ??= setTimeout(flush, 100); };
      term.view = (paths, inputs) => {
        const models = paths.map((p) => ({ path: p, text: files.has(p) ? files.read(p) : null }));
        outputs.push(new vscode.NotebookCellOutput([vscode.NotebookCellOutputItem.json({ models, inputs }, MODELS_MIME)]));
      };
      const cancel = run.token.onCancellationRequested(() => { ok = false; shell.runner.cancel(); });
      for (const line of cell.document.getText().split('\n')) {
        if (run.token.isCancellationRequested) break;
        const l = line.trim();
        if (!l || l.startsWith('#')) continue;
        term.out(`\x1b[2m$ ${l}\x1b[0m\n`);
        // A command that fails stops the cell
        if ((await shell.execute(l)) !== 0) { ok = false; break; }
      }
      cancel.dispose();
      clearTimeout(pending); await flush();
      run.end(ok, Date.now());
    }
  };
  c.interruptHandler = (notebook) => shells.get(notebook.uri.toString())?.shell.runner.cancel();
  // The controller of every tutorial, so that ▷ runs a cell without asking for a kernel
  const prefer = (nb) => { if (nb.notebookType === NOTEBOOK) c.updateNotebookAffinity(nb, vscode.NotebookControllerAffinity.Preferred); };
  vscode.workspace.notebookDocuments.forEach(prefer);
  const opened = vscode.workspace.onDidOpenNotebookDocument(prefer);
  const dispose = c.dispose.bind(c);
  c.dispose = () => { opened.dispose(); dispose(); };
  return c;
}
