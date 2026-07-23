import { readdir, readFile, stat } from 'node:fs/promises';
import path from 'node:path';

const dist = path.resolve('dist');
const siteBase = '/alvie/';
const attributePattern = /\b(?:href|src)=["']([^"']+)["']/g;

async function findHtmlFiles(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = await Promise.all(entries.map(async (entry) => {
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory()) return findHtmlFiles(entryPath);
    return entry.name.endsWith('.html') ? [entryPath] : [];
  }));
  return files.flat();
}

function localTarget(source, link) {
  const target = link.split(/[?#]/, 1)[0];
  if (!target || target.startsWith('#') || target.startsWith('data:') ||
      /^[a-z][a-z0-9+.-]*:/i.test(target) || target.startsWith('//')) return null;

  if (target.startsWith('/')) {
    if (!target.startsWith(siteBase) || target.startsWith('/alvie/_astro/')) return null;
    return path.join(dist, target.slice(siteBase.length));
  }
  return path.resolve(path.dirname(source), target);
}

async function exists(target) {
  const candidates = [target, `${target}.html`, path.join(target, 'index.html')];
  for (const candidate of candidates) {
    try {
      if ((await stat(candidate)).isFile()) return true;
    } catch {
      // Try the next representation of the page URL.
    }
  }
  return false;
}

const broken = [];
for (const source of await findHtmlFiles(dist)) {
  const html = await readFile(source, 'utf8');
  for (const match of html.matchAll(attributePattern)) {
    const target = localTarget(source, match[1]);
    if (target && !(await exists(target))) {
      broken.push(`${path.relative(dist, source)} -> ${match[1]}`);
    }
  }
}

if (broken.length) {
  console.error('Broken internal links:\n' + broken.join('\n'));
  process.exit(1);
}

console.log('Verified internal links in generated documentation.');
