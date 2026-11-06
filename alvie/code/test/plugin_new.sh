#!/usr/bin/env bash
# alvie plugin new: the template makes a plugin that builds, whose files check, and that passes conformance (and,
# where mCRL2 is installed, its fixtures). The plugin is made in the tree under a name of its own, and removed.

set -euo pipefail

CODE_DIR=$(cd "$(dirname "$0")/.." && pwd)
NAME="template-check-$$"
cd "$CODE_DIR"
cleanup() { rm -rf "plugins/$NAME" "lib/plugins/$NAME"; rmdir lib/plugins 2>/dev/null || true; rm -rf "$OUT"; }
OUT=$(mktemp -d "${TMPDIR:-/tmp}/alvie-plugin-new.XXXXXX")
trap cleanup EXIT

dune build bin/alvie.exe
_build/default/bin/alvie.exe plugin new "$NAME" > "$OUT/new.log"
grep -q "wrote ./lib/plugins/$NAME/main.ml" "$OUT/new.log"
dune build "lib/plugins/$NAME/main.exe"
_build/default/bin/alvie.exe plugin check "plugins/$NAME" > /dev/null
ALVIE_NEW="_build/default/lib/plugins/$NAME/main.exe"
"$ALVIE_NEW" conformance --spec "plugins/$NAME/fixtures/leak.spec" --secret 0 > "$OUT/conformance.log" || { cat "$OUT/conformance.log" >&2; exit 1; }
if command -v lts2pbes > /dev/null; then
  "$ALVIE_NEW" fixtures --out "$OUT/fixtures" > "$OUT/fixtures.log" || { cat "$OUT/fixtures.log" >&2; exit 1; }
  grep -q "2 fixtures, 0 failed" "$OUT/fixtures.log"
else
  echo "(mCRL2 is not installed: the fixtures of the template are not run)"
fi
# The name is checked, and an existing plugin is not overwritten
if _build/default/bin/alvie.exe plugin new "$NAME" > "$OUT/again.log" 2>&1; then echo "plugin new overwrote a plugin" >&2; exit 1; fi
grep -q "exists already" "$OUT/again.log"
if _build/default/bin/alvie.exe plugin new Bad_Name > "$OUT/bad.log" 2>&1; then echo "plugin new took a bad name" >&2; exit 1; fi
grep -q "is not a name for a plugin" "$OUT/bad.log"
echo "alvie plugin new checks passed."
