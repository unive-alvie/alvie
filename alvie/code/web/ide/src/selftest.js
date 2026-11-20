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
  await ide.run('vaultlink learn --spec spec-lib/vaultlink/vault.vtdl --service reference --res models/reference.dot');
  await ide.run('vaultlink learn --spec spec-lib/vaultlink/vault.vtdl --service firmware --res models/firmware.dot');
  check('vaultlink learn writes both models', ide.files.has('/models/reference.dot') && ide.files.has('/models/firmware.dot'));
  await ide.run('vaultlink compare models/reference.dot models/firmware.dot');
  check('vaultlink compare finds the difference', lines.some((l) => l.includes('1 distinguishing sequence')));
  await ide.run('view models/reference.dot models/firmware.dot');
  await new Promise((r) => setTimeout(r, 1500));
  check('the viewer draws two models', document.querySelectorAll('#viewer svg').length === 2);
  const result = { checks, lines, ms: Math.round(performance.now() - t0), userAgent: navigator.userAgent,
    model: ide.files.read('/models/example-0.dot') };
  await fetch('/result', { method: 'POST', body: JSON.stringify(result) });
}
