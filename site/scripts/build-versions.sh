#!/usr/bin/env bash
# Builds the documentation site for every release and for the current tree, into dist/:
#
#   /alvie/            the latest release
#   /alvie/<release>/  each release, i.e. each git tag YYYY.MM[.N] containing docs/
#   /alvie/dev/        the docs/ of the current tree (the main branch, once published)
#
# Each copy is built with the current site tooling and the docs/ of its version, so releases keep
# the documentation they shipped with. Run from anywhere after `npm ci` in site/; the release tags
# must be available (actions/checkout needs fetch-depth: 0).
set -euo pipefail

SITE_DIR=$(cd "$(dirname "$0")/.." && pwd)
REPO_DIR=$(git -C "$SITE_DIR" rev-parse --show-toplevel)
ROOT=/alvie
WORK="$SITE_DIR/build-versions"

cd "$SITE_DIR"

releases=()
while read -r tag; do
  if git -C "$REPO_DIR" cat-file -e "$tag:docs" 2>/dev/null; then
    releases+=("$tag")
  fi
done < <(git -C "$REPO_DIR" tag --list | grep -E '^[0-9]{4}\.[0-9]{2}(\.[0-9]+)?$' | sort -V)
latest=${releases[${#releases[@]}-1]:-}

export ALVIE_DOCS_ROOT=$ROOT
export ALVIE_DOCS_LATEST=$latest
export ALVIE_DOCS_RELEASES="${releases[*]}"
echo "Releases with documentation: ${releases[*]:-none}; latest: ${latest:-none}"

# build <version> <base> <docs source: a tag, or "worktree"> <output directory>
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
for release in "${releases[@]}"; do
  build "$release" "$ROOT/$release" "$release" "$WORK/$release"
done
build dev "$ROOT/dev" worktree "$WORK/dev"
if [ -n "$latest" ]; then
  build "$latest" "$ROOT" "$latest" "$WORK/root"
else
  # No release yet: serve the development version at the root as well
  build dev "$ROOT" worktree "$WORK/root"
fi

# Assemble: the root copy, then each version in its own directory
mkdir -p dist
cp -R "$WORK/root/." dist/
for version in "${releases[@]}" dev; do
  cp -R "$WORK/$version" "dist/$version"
done
rm -rf "$WORK"

# Leave the current documentation in place for `npm run dev`
rm -rf src/content/docs
mkdir -p src/content/docs
cp -R "$REPO_DIR/docs/." src/content/docs/

echo "Documentation site assembled in $SITE_DIR/dist"
