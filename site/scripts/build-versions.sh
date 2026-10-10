#!/usr/bin/env bash
# Builds the documentation site for every version and for the current tree, into dist/:
#
#   /alvie/            the current documentation, i.e. the last version
#   /alvie/<version>/  each version: every release (git tag YYYY.MM[.N] containing docs/) and the
#                      extra versions of doc-versions.json (see scripts/doc-versions.mjs)
#   /alvie/dev/        the docs/ of the current tree (the main branch, once published)
#
# Each copy is built with the current site tooling and the docs/ of its version, so releases keep
# the documentation they shipped with. Run from anywhere after `npm ci` in site/; the release tags
# and the commits of the extra versions must be available (actions/checkout needs fetch-depth: 0).
set -euo pipefail

SITE_DIR=$(cd "$(dirname "$0")/.." && pwd)
REPO_DIR=$(git -C "$SITE_DIR" rev-parse --show-toplevel)
ROOT=/alvie
WORK="$SITE_DIR/build-versions"

cd "$SITE_DIR"

# The versions to publish, oldest first, and the git revision holding the docs/ of each
# (two parallel arrays rather than an associative one, which bash 3 on macOS lacks)
versions=()
refs=()
while IFS=$'\t' read -r name ref; do
  versions+=("$name")
  refs+=("$ref")
done < <(node scripts/doc-versions.mjs)
count=${#versions[@]}
latest=${versions[count-1]:-}
latest_ref=${refs[count-1]:-}

export ALVIE_DOCS_ROOT=$ROOT
export ALVIE_DOCS_LATEST=$latest
export ALVIE_DOCS_VERSIONS=$(node scripts/doc-versions.mjs --json)
echo "Documentation versions: ${versions[*]:-none}; current: ${latest:-none}"

# build <version> <base> <docs source: a git revision, or "worktree"> <output directory>
build() {
  local version=$1 base=$2 source=$3 out=$4
  echo "=== Building the documentation of $version at $base/"
  rm -rf src/content/docs
  mkdir -p src/content/docs
  if [ "$source" = worktree ]; then
    cp -R "$REPO_DIR/docs/." src/content/docs/
  else
    git -C "$REPO_DIR" archive "$source" docs | tar -x --strip-components=1 -C src/content/docs
  fi
  # Pages may link each other with absolute paths (/alvie/...): keep such links within this version
  if [ "$base" != "$ROOT" ]; then
    find src/content/docs -type f \( -name '*.md' -o -name '*.mdx' \) -print0 \
      | xargs -0 perl -pi -e "s#\\]\\(\\Q$ROOT\\E/#]($base/#g"
  fi
  ALVIE_DOCS_VERSION=$version ALVIE_DOCS_BASE=$base ALVIE_DOCS_OUTDIR=$out npm run build
}

rm -rf "$WORK" dist
for ((i = 0; i < count; i++)); do
  build "${versions[i]}" "$ROOT/${versions[i]}" "${refs[i]}" "$WORK/${versions[i]}"
done
build dev "$ROOT/dev" worktree "$WORK/dev"
if [ -n "$latest" ]; then
  build "$latest" "$ROOT" "$latest_ref" "$WORK/root"
else
  # No version yet: serve the development version at the root as well
  build dev "$ROOT" worktree "$WORK/root"
fi

# Assemble: the root copy, then each version in its own directory
mkdir -p dist
cp -R "$WORK/root/." dist/
for version in ${versions[@]+"${versions[@]}"} dev; do
  cp -R "$WORK/$version" "dist/$version"
done
rm -rf "$WORK"

# Leave the current documentation in place for `npm run dev`
rm -rf src/content/docs
mkdir -p src/content/docs
cp -R "$REPO_DIR/docs/." src/content/docs/

echo "Documentation site assembled in $SITE_DIR/dist"
