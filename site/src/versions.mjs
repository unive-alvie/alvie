// Version information for the documentation site.
// scripts/build-versions.sh builds one copy of the site per documentation version and passes these
// values through the environment; a plain `npm run build` sets none of them (no version banner).

const env = (name) => (process.env[name] ?? '').trim();

// The version being built: a release tag (e.g. 2026.09) or "dev" (the main branch)
export const docsVersion = env('ALVIE_DOCS_VERSION') || null;
// The most recent release, served at the root of the site
export const latestRelease = env('ALVIE_DOCS_LATEST') || null;
// All releases with documentation, oldest first
export const releases = env('ALVIE_DOCS_RELEASES').split(/\s+/).filter(Boolean);
// Where the site is served, without trailing slash (the latest release lives there)
export const siteRoot = (env('ALVIE_DOCS_ROOT') || '/alvie').replace(/\/$/, '');

// URL of the home page of the given version
export function versionUrl(version) {
  return version === latestRelease ? `${siteRoot}/` : `${siteRoot}/${version}/`;
}

// The other versions a reader may want to switch to, newest first
export function otherVersions() {
  const all = [...releases].reverse();
  if (docsVersion !== 'dev') all.unshift('dev');
  return all.filter((version) => version !== docsVersion);
}
