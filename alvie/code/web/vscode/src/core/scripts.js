// The scripts of the guides (learn_example.sh, learn_one.sh, learn_one_nospecial.sh, learn_all.sh, check_example.sh,
// check_one.sh, check_all.sh) as commands of the IDE. Each gives the same jobs as its script: the same commands of
// learn.exe and fa.exe, with the same names, models (results/<subdir>/), counterexamples (counterexamples/<subdir>/)
// and logs (logs/<subdir>/). The files of the IDE are the root of the repository: spec-lib/, results/, ...
//
// A script gives { jobs, errors, exitIfMissing }: jobs = [{ name, argv, log, res }], where res, if set, is the model
// that the job makes (a job whose model is there is "Done before", as in the scripts). The IDE runs the jobs one after
// the other (the scripts run them in parallel).

const EPS = '0.01', DELTA = '0.01';

// The special commit of each attack of learn_all.sh (b8, b9 and a have none)
const ALL = [['b3', '6475709'], ['b4', '3636536'], ['b6', 'd54f031'], ['b7', '264f135'], ['b8', null], ['b9', null],
  ['a', null], ['b1', 'e8cf011'], ['b2', '3170d5d']];

const USAGE = {
  learn_example: '', learn_one: '<special_commit> <att_spec> <subdirectory>', learn_one_nospecial: '<att_spec> <subdirectory>',
  learn_all: '<subdirectory>', check_example: '', check_one: '<spec_basename> <subdirectory>', check_all: '<subdirectory>',
};

// The name of a script in a command: learn_one, learn_one.sh, ./learn_one.sh, bash learn_one.sh, ...
export function scriptOf(args) {
  const a = args[0] === 'bash' || args[0] === 'sh' ? args.slice(1) : args;
  if (a.length === 0) return null;
  const name = a[0].split('/').pop().replace(/\.sh$/, '');
  return Object.hasOwn(USAGE, name) ? { name, params: a.slice(1) } : null;
}

const basename = (p) => p.split('/').pop();
const dirname = (p) => p.slice(0, p.lastIndexOf('/')) || '/';

// The directory of the specs: spec-lib/<subdir> if it is there, else spec-lib
const specDir = (files, subdir) => (files.isDir(`/spec-lib/${subdir}`) ? `/spec-lib/${subdir}` : '/spec-lib');

function learnJobs(experiments, subdir, specs, { interrupts = true } = {}) {
  const jobs = [];
  for (const [att, encl, secret, commit] of experiments) {
    for (const mode of interrupts ? ['int', 'nint'] : [null]) {
      const name = [commit, att, encl, secret, EPS, DELTA, ...(mode ? [mode] : [])].join('-');
      const res = `/results/${subdir}/${name}.dot`;
      const argv = ['learn.exe', '--report', '--att-spec', `${specs}/${att}.atdl`, '--encl-spec', `${specs}/${encl}.etdl`,
        '--res', res, '--commit', commit, '--secret', secret, '--epsilon', EPS, '--delta', DELTA, '--oracle', 'pac',
        ...(mode === 'nint' ? ['--ignore-interrupts'] : [])];
      jobs.push({ name, argv, res, log: `/logs/${subdir}/learn-${name}.log` });
    }
  }
  return jobs;
}

const experiments = (att, commits) => ['0', '1'].flatMap((s) => commits.map((c) => [att, 'enclave-complete', s, c]));

// The files of a directory that match a glob with * (as bash, in the order of their names)
function glob(files, pattern) {
  const dir = dirname(pattern);
  const re = new RegExp(`^${basename(pattern).split('*').map((s) => s.replace(/[.+?^${}()|[\]\\]/g, '\\$&')).join('.*')}$`);
  return files.list(dir).filter(([n, isDir]) => !isDir && re.test(n)).map(([n]) => `${dir}/${n}`).sort();
}

// The comparisons of check_one.sh (spec given) and check_all.sh (spec from the name of each model)
function checkJobs(files, subdir, spec) {
  const res = `/results/${subdir}`, jobs = [], errors = [];
  const zero = glob(files, spec ? `${res}/*-${spec}-*-0-*-int.dot` : `${res}/*-0-*-int.dot`);
  if (zero.length === 0) return { jobs, errors: [`Comparison incomplete: no secret-0 interrupt-enabled models found in ${res}.`], exitIfMissing: 2 };
  for (const m1 of zero) {
    const m1Name = basename(m1).replace(/\.dot$/, ''), commit = m1Name.slice(0, 7);
    const att = spec ?? m1Name.slice(8, 10).replaceAll('-', '');
    const ones = glob(files, `${res}/${commit}-${att}-*-1-*-int.dot`);
    const what = spec ? commit : `${commit}/${att}`;
    if (ones.length === 0) { errors.push(`Comparison incomplete: missing secret-1 interrupt-enabled model for ${what} in ${res}.`); continue; }
    for (const m2 of ones) {
      const m1n = m1.replaceAll('int', 'nint'), m2n = m2.replaceAll('int', 'nint');
      if (!files.has(m1n) || !files.has(m2n)) { errors.push(`Comparison incomplete: missing no-interrupt model for ${what} in ${res}.`); continue; }
      if (m1Name === basename(m2).replace(/\.dot$/, '')) continue;
      const name = `${commit}-${att}`;
      jobs.push({ name, log: `/logs/${subdir}/compare-${name}.log`,
        argv: ['fa.exe', '--m1-int', m1, '--m2-int', m2, '--m1-nint', m1n, '--m2-nint', m2n,
          '--witness-file-basename', `/counterexamples/${subdir}/${att}/${name}`, '--debug'] });
    }
  }
  return { jobs, errors };
}

function checkExample(files) {
  const res = '/results/example', jobs = [], errors = [];
  const zero = glob(files, `${res}/*-attacker-*-0-*.dot`);
  if (zero.length === 0) return { jobs, errors: [`Comparison incomplete: no secret-0 example models found in ${res}.`], exitIfMissing: 2 };
  for (const m1 of zero) {
    const m1Name = basename(m1).replace(/\.dot$/, ''), commit = m1Name.slice(0, 7);
    const ones = glob(files, `${res}/${commit}-attacker-*-1-*.dot`);
    if (ones.length === 0) { errors.push(`Comparison incomplete: missing secret-1 model for ${commit} in ${res}.`); continue; }
    for (const m2 of ones) {
      if (m1Name === basename(m2).replace(/\.dot$/, '')) continue;
      const name = `${commit}-attacker`;
      jobs.push({ name, log: `/logs/example/compare-${name}.log`,
        argv: ['fa.exe', '--m1-int', m1, '--m2-int', m2, '--witness-file-basename', `/counterexamples/example/${name}`] });
    }
  }
  return { jobs, errors };
}

// The jobs of a script, or { usage } when its parameters are wrong
export function scriptJobs(files, { name, params }) {
  const wanted = USAGE[name] ? USAGE[name].split(' ').length : 0;
  if (params.length !== wanted) return { usage: `Usage: ${name}.sh ${USAGE[name]}`.trimEnd() };
  const missing = (specs, ...need) => need.some((f) => !files.has(`${specs}/${f}`)) ? [`Missing specifications in ${specs}`] : [];
  switch (name) {
    case 'learn_example':
      return { jobs: learnJobs([['attacker', 'enclave', '0', 'bf89c0b'], ['attacker', 'enclave', '1', 'bf89c0b']], 'example', '/spec-lib/example', { interrupts: false }), errors: [] };
    case 'learn_one': case 'learn_one_nospecial': {
      const [special, att, subdir] = name === 'learn_one' ? params : [null, ...params];
      const specs = specDir(files, subdir);
      const errors = missing(specs, `${att}.atdl`, 'enclave-complete.etdl');
      if (errors.length) return { jobs: [], errors, exitIfMissing: 2 };
      return { jobs: learnJobs(experiments(att, ['ef753b6', ...(special ? [special] : []), 'bf89c0b']), subdir, specs), errors };
    }
    case 'learn_all': {
      const [subdir] = params, specs = specDir(files, subdir);
      const errors = missing(specs, 'enclave-complete.etdl');
      if (errors.length) return { jobs: [], errors: ['Missing enclave specification in ' + specs], exitIfMissing: 2 };
      return { jobs: ALL.flatMap(([att, c]) => learnJobs(experiments(att, ['ef753b6', ...(c ? [c] : []), 'bf89c0b']), subdir, specs)), errors };
    }
    case 'check_example': return checkExample(files);
    case 'check_one': return checkJobs(files, params[1], params[0]);
    case 'check_all': return checkJobs(files, params[0], null);
  }
}
