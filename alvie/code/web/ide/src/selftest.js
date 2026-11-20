// The self-test of the IDE (index.html?selftest=1, see test.py): runs commands in its terminal, checks the files they
// leave, and posts the result to /result
export async function selftest(ide) {
  const lines = [], checks = [];
  const term = ide.shell;
  const origPrint = term.print.bind(term);
  term.print = (text, stream) => { lines.push(String(text)); origPrint(text, stream); };
  const check = (name, ok) => checks.push({ name, ok: !!ok });
  const t0 = performance.now();
  await ide.run('ls spec-lib');
  check('ls lists spec-lib', lines.some((l) => l.includes('a.atdl')));
  await ide.run('alvie sancus learn --spec spec-lib/example/attacker.atdl --spec spec-lib/example/enclave.etdl --secret 0 --commit bf89c0b --res models/example-0.dot');
  check('sancus learn writes the model', ide.files.has('/models/example-0.dot'));
  await ide.run('alvie tiny fixtures --out models/tiny-fixtures');
  check('tiny fixtures pass', lines.some((l) => l.includes('5 fixtures, 0 failed')));
  await ide.run('alvie sancus fixtures --out models/sancus-fixtures');
  check('sancus fixtures pass', lines.some((l) => l.includes('4 fixtures, 0 failed')));
  await ide.run('vaultlink learn --spec spec-lib/vaultlink/vault.vtdl --service reference --res models/reference.dot');
  await ide.run('vaultlink learn --spec spec-lib/vaultlink/vault.vtdl --service firmware --res models/firmware.dot');
  check('vaultlink learn writes both models', ide.files.has('/models/reference.dot') && ide.files.has('/models/firmware.dot'));
  await ide.run('vaultlink compare models/reference.dot models/firmware.dot');
  check('vaultlink compare finds the difference', lines.some((l) => l.includes('1 distinguishing sequence')));
  // The programs and the scripts of the guides
  const example1 = '/results/example/bf89c0b-attacker-enclave-1-0.01-0.01.dot', before = ide.files.read(example1);
  ide.files.remove(example1);
  await ide.run('./learn_example.sh');
  check('learn_example learns the missing model, as in results/example', lines.some((l) => l.includes('bf89c0b-attacker-enclave-0-0.01-0.01 ... [OK - Done before]'))
    && ide.files.read(example1) === before && ide.files.has('/logs/example/learn-bf89c0b-attacker-enclave-1-0.01-0.01.log'));
  await ide.run('check_example');
  check('check_example writes its log', lines.some((l) => l.includes('bf89c0b-attacker ... [OK - logs/example/compare-bf89c0b-attacker.log]')));
  await ide.run('_build/default/bin/fa.exe --witness-file-basename models/fa --m1-int results/example/bf89c0b-attacker-enclave-0-0.01-0.01.dot --m2-int results/example/bf89c0b-attacker-enclave-1-0.01-0.01.dot');
  check('fa.exe runs as alvie compare', !lines[lines.length - 1].includes('exit'));
  // Live errors: a mistake in a spec opened in the editor is underlined
  ide.files.write('/models/bad.atdl', 'isr {\n  timer_enable 1;\n  retx\n};\n');
  ide.editor.open('/models/bad.atdl');
  await new Promise((r) => setTimeout(r, 3000));
  check('the editor underlines a mistake', document.querySelectorAll('.cm-lintRange-error').length > 0);
  await ide.run('view models/reference.dot models/firmware.dot --inputs HELLO,ID_ME,PASS_OK,AUDIT,AUDIT');
  await new Promise((r) => setTimeout(r, 1500));
  check('the viewer draws two models', document.querySelectorAll('#viewer svg').length === 2);
  const heads = [...document.querySelectorAll('.viewer-pane-head')].map((h) => h.textContent);
  check('the inputs are followed on both models', heads.length === 2 && heads.every((h) => h.includes('followed 5 inputs')));
  const result = { checks, lines, ms: Math.round(performance.now() - t0), userAgent: navigator.userAgent,
    model: ide.files.read('/models/example-0.dot'),
    logs: Object.fromEntries(Object.entries(ide.files.all()).filter(([k]) => k.startsWith('/logs/'))) };
  await fetch('/result', { method: 'POST', body: JSON.stringify(result) });
}
