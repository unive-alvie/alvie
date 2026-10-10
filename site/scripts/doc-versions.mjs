// Lists the versions of the documentation to publish, as used by build-versions.sh:
//
// - every release, i.e. every git tag YYYY.MM[.N] whose tree contains docs/;
// - every extra version in ../doc-versions.json, e.g. a revision of the documentation of a release
//   ({ "name": "2026.09v2", "ref": "<commit>", "label": "..." });
//
// and their labels (the name, unless overridden by "labels" in ../doc-versions.json). Versions are
// ordered by name, numbers compared numerically (2026.09 < 2026.09v2 < 2026.10): the last one is the
// current documentation, served at the root of the site.
//
// Usage: node doc-versions.mjs          one "name<TAB>ref" line per version, oldest first
//        node doc-versions.mjs --json   [{ "name", "label" }, ...], newest first
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

const git = (...args) => execFileSync('git', args, { encoding: 'utf8' }).trim();
const repo = git('rev-parse', '--show-toplevel');
const config = JSON.parse(readFileSync(new URL('../doc-versions.json', import.meta.url), 'utf8'));

function hasDocs(ref) {
  try {
    execFileSync('git', ['-C', repo, 'cat-file', '-e', `${ref}:docs`], { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}

const versions = new Map();
for (const tag of git('-C', repo, 'tag', '--list').split('\n')) {
  if (/^\d{4}\.\d{2}(\.\d+)?$/.test(tag) && hasDocs(tag)) versions.set(tag, { name: tag, ref: tag });
}
for (const { name, ref } of config.versions ?? []) {
  // Names become directories of the site: keep them simple, and "dev" is the development version
  if (!/^[0-9A-Za-z][0-9A-Za-z._-]*$/.test(name) || name === 'dev') throw new Error(`Invalid version name: ${name}`);
  if (!hasDocs(ref)) throw new Error(`Version ${name}: ${ref} is not a commit with a docs/ directory`);
  versions.set(name, { name, ref });
}

const labels = { ...config.labels };
for (const { name, label } of config.versions ?? []) if (label) labels[name] = label;

const sorted = [...versions.values()].sort((a, b) => a.name.localeCompare(b.name, 'en', { numeric: true }));

if (process.argv.includes('--json')) {
  console.log(JSON.stringify(sorted.reverse().map(({ name }) => ({ name, label: labels[name] ?? name }))));
} else {
  for (const { name, ref } of sorted) console.log(`${name}\t${ref}`);
}
