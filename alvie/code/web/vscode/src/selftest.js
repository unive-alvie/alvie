// The self-test of the extension, in VS Code for the Web (vscode-test-web --extensionTestsPath, see test.sh): the
// folder alvie:/, the commands of ALVIE in a shell, the Problems of a spec, and the preview of models. It fails (and
// test.sh with it) when a check fails.
import * as vscode from 'vscode';

export async function run() {
  const results = [];
  const check = (name, ok, detail = '') => { results.push({ name, ok: !!ok }); console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${ok ? '' : ` ${detail}`}`); };
  const api = await vscode.extensions.getExtension('unive-alvie.alvie').activate();
  const uri = (path) => vscode.Uri.from({ scheme: 'alvie', path });
  const t0 = Date.now();

  check('the folder is alvie:/', vscode.workspace.workspaceFolders?.[0]?.uri.toString() === 'alvie:/');
  const root = await vscode.workspace.fs.readDirectory(uri('/'));
  check('the folder has spec-lib', root.some(([n, t]) => n === 'spec-lib' && t === vscode.FileType.Directory));
  const spec = new TextDecoder().decode(await vscode.workspace.fs.readFile(uri('/spec-lib/example/attacker.atdl')));
  check('a spec can be read', spec.length > 0);

  let out = await api.run('alvie sancus learn --spec spec-lib/example/attacker.atdl --spec spec-lib/example/enclave.etdl --secret 0 --commit bf89c0b --res models/example-0.dot');
  const model = new TextDecoder().decode(await vscode.workspace.fs.readFile(uri('/models/example-0.dot')));
  const native = JSON.parse(NATIVE_EXAMPLE); // the models of results/example, learned by the native ALVIE (build.mjs)
  check('sancus learn writes the model of the native ALVIE', model === native[0], out.slice(-500));
  out = await api.run('learn_example');
  check('learn_example learns the models of the native ALVIE', [0, 1].every((s) => api.files.read(`/results/example/bf89c0b-attacker-enclave-${s}-0.01-0.01.dot`) === native[s]), out.slice(-500));
  out = await api.run('check_example');
  check('check_example', out.includes('bf89c0b-attacker ... [OK'), out.slice(-500));
  // Two commands at once (as in two terminals): each keeps what the other wrote
  await Promise.all([
    api.run('vaultlink learn --spec spec-lib/vaultlink/vault.vtdl --service reference --res models/reference.dot'),
    api.run('vaultlink learn --spec spec-lib/vaultlink/vault.vtdl --service firmware --res models/firmware.dot'),
  ]);
  // A file changed while a command runs keeps the change
  api.files.write('/models/note.txt', 'v1');
  const running = api.run('vaultlink learn --spec spec-lib/vaultlink/vault.vtdl --service reference --res models/reference-2.dot');
  await new Promise((r) => setTimeout(r, 50));
  api.files.write('/models/note.txt', 'v2');
  await running;
  check('a file changed while a command runs keeps the change', api.files.read('/models/note.txt') === 'v2' && api.files.has('/models/reference-2.dot'));
  check('two commands at once keep both models', api.files.has('/models/reference.dot') && api.files.has('/models/firmware.dot'));
  out = await api.run('vaultlink compare models/reference.dot models/firmware.dot');
  check('vaultlink compare finds the difference', out.includes('1 distinguishing sequence'), out.slice(-500));

  // A file written in VS Code is a file of ALVIE, and a mistake in it is a problem
  const bad = uri('/models/bad.atdl');
  await vscode.workspace.fs.writeFile(bad, new TextEncoder().encode('isr {\n  timer_enable 1;\n  retx\n};\n'));
  check('a file written in VS Code is in the files of ALVIE', api.files.has('/models/bad.atdl'));
  const doc = await vscode.workspace.openTextDocument(bad);
  await vscode.window.showTextDocument(doc);
  check('a .atdl is TestDL', doc.languageId === 'testdl');
  let problems = [];
  for (let i = 0; i < 40 && problems.length === 0; i++) { await new Promise((r) => setTimeout(r, 250)); problems = vscode.languages.getDiagnostics(bad); }
  check('a mistake in a spec is a problem', problems.length > 0 && problems[0].range.start.line === 2, JSON.stringify(problems));

  await api.run('view models/reference.dot models/firmware.dot --inputs HELLO,ID_ME,PASS_OK,AUDIT,AUDIT');
  check('view opens the preview of two models', api.preview.panel && api.preview.paths.length === 2);
  const terminal = api.newTerminal();
  terminal.sendText('ls spec-lib');
  check('an ALVIE terminal opens', vscode.window.terminals.includes(terminal));

  // The tutorials: each opens as a notebook, and every cell of commands runs to its end. alvie tiny compare ends with the
  // status 4 when it finds a leak, and vaultlink compare 1 when the models differ, as the tutorials say: those cells
  // must fail.
  const leak = (text) => (/tiny compare/.test(text) && !/ct-0\.dot/.test(text)) || /vaultlink compare/.test(text);
  const only = (globalThis.process?.env?.ALVIE_TUTORIALS || '').split(',').filter(Boolean);
  for (const [name, type] of await vscode.workspace.fs.readDirectory(uri('/tutorials'))) {
    if (type !== vscode.FileType.File || !name.endsWith('.alvienb') || (only.length && !only.some((o) => name.startsWith(o)))) continue;
    const t1 = Date.now();
    const nb = await vscode.workspace.openNotebookDocument(uri(`/tutorials/${name}`));
    const editor = await vscode.window.showNotebookDocument(nb);
    await vscode.commands.executeCommand('notebook.selectKernel', { notebookEditor: editor, id: api.tutorials.id, extension: 'unive-alvie.alvie' });
    const cells = nb.getCells().filter((c) => c.kind === vscode.NotebookCellKind.Code);
    await api.tutorials.executeHandler(cells, nb, api.tutorials);
    await new Promise((r) => setTimeout(r, 1000)); // the result of the last cell reaches the document
    const bad = cells.filter((c) => c.executionSummary?.success !== !leak(c.document.getText()));
    const text = (c) => c.outputs.flatMap((o) => o.items).map((i) => new TextDecoder().decode(i.data)).join('').slice(-600);
    check(`the tutorial ${name} runs (${cells.length} cells, ${Math.round((Date.now() - t1) / 1000)} s)`, bad.length === 0 && cells.length > 0,
      bad.map((c) => `cell ${c.index}: ${c.document.getText().split('\n')[0]}\n${text(c)}`).join('\n---\n'));
    const models = cells.flatMap((c) => c.outputs.flatMap((o) => o.items)).filter((i) => i.mime === 'application/vnd.alvie.models+json');
    check(`the tutorial ${name} draws models`, models.length > 0 && models.every((i) => JSON.parse(new TextDecoder().decode(i.data)).models.every((m) => m.text)));
    await vscode.commands.executeCommand('workbench.action.closeActiveEditor');
  }

  console.log(`${results.filter((r) => r.ok).length}/${results.length} checks passed in ${Date.now() - t0} ms`);
  if (results.some((r) => !r.ok)) throw new Error('the self-test failed');
}
