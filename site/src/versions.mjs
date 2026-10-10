// Version information for the documentation site.
// scripts/build-versions.sh builds one copy of the site per documentation version and passes these
// values through the environment; a plain `npm run build` sets none of them (no version banner).

const env = (name) => (process.env[name] ?? '').trim();

// The version being built: a version of scripts/doc-versions.mjs (e.g. 2026.09) or "dev" (main)
export const docsVersion = env('ALVIE_DOCS_VERSION') || null;
// The current version, served at the root of the site
export const latestRelease = env('ALVIE_DOCS_LATEST') || null;
// All the versions with their labels, newest first
const versions = JSON.parse(env('ALVIE_DOCS_VERSIONS') || '[]');
// Where the site is served, without trailing slash
export const siteRoot = (env('ALVIE_DOCS_ROOT') || '/alvie').replace(/\/$/, '');

// Human-readable name of a version
export function versionLabel(version) {
  if (version === 'dev') return 'development version';
  return versions.find(({ name }) => name === version)?.label ?? version;
}

// URL of the home page of the given version
export function versionUrl(version) {
  return version === latestRelease ? `${siteRoot}/` : `${siteRoot}/${version}/`;
}

// The other versions a reader may want to switch to: the development version, then newest first
export function otherVersions() {
  return ['dev', ...versions.map(({ name }) => name)].filter((version) => version !== docsVersion);
}
