#!/usr/bin/env bash
# External plugins (lib/core/rpc, sdk/python): Tiny in Python (plugins/tiny-py) passes conformance and learns the
# same models as Tiny (up to the bookkeeping, which Core does not compare); Core reports a plugin that crashes,
# hangs, writes on stdout, fails, or does not match its manifest; sessions record and replay. Needs python3.

set -euo pipefail

CODE_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$CODE_DIR"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/alvie-rpc.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT
export ALVIE_RPC_LOG_DIR="$TMP_DIR/logs"
dune build bin/alvie.exe
A=_build/default/bin/alvie.exe
F=plugins/tiny/fixtures

expect() {
  local expected_status="$1" expected_text="$2" status=0
  shift 2
  "$@" >"$TMP_DIR/output" 2>&1 || status=$?
  if [ "$status" -ne "$expected_status" ] || ! grep -q -- "$expected_text" "$TMP_DIR/output"; then
    echo "Unexpected result (exit $status, expected $expected_status, text: $expected_text) from: $*" >&2
    cat "$TMP_DIR/output" >&2
    exit 1
  fi
}

# The other files of tiny-py are those of tiny
for f in sections atoms observations phases view; do
  cmp -s "plugins/tiny/$f.yaml" "plugins/tiny-py/$f.yaml" || { echo "plugins/tiny-py/$f.yaml differs from plugins/tiny/$f.yaml" >&2; exit 1; }
done
# Its generated types are up to date
$A plugin types plugins/tiny-py "$TMP_DIR/tiny_types.py" > /dev/null
cmp -s "$TMP_DIR/tiny_types.py" plugins/tiny-py/tiny_types.py || { echo "plugins/tiny-py/tiny_types.py is not up to date: run alvie plugin types plugins/tiny-py plugins/tiny-py/tiny_types.py" >&2; exit 1; }

# The types of a plugin with records and enums (Sancus) are valid Python, and check their fields
$A plugin types plugins/sancus "$TMP_DIR/sancus_types.py" > /dev/null
PYTHONPATH="$CODE_DIR/sdk/python:$TMP_DIR" python3 -c '
import sancus_types as t
p = t.payload(k=1, gie=True, umem_val=0, reg_val=0, timerA_counter=0, mode="UM")
assert t.Time_Handle(time=p, handle=p) == {"Time_Handle": {"time": p, "handle": p}}
try:
    t.payload(k=1, gie=True, umem_val=0, reg_val=0, timerA_counter=0, mode="XM"); raise SystemExit("an enum accepted XM")
except ValueError as e:
    assert "not one of UM, PM" in str(e), e
'

# The SDK on its own
python3 -I - "$CODE_DIR/sdk/python" <<'PY'
import io, json, sys
sys.path.insert(0, sys.argv[1])
import alvie_plugin as ap
assert ap.get({"mov": {"r": {"reg": {"i": 2}}}}, "r", "i") == 2
assert ap.tag({"nop": {}}) == "nop" and ap.tag({"?": "secret"}) is None and ap.tag(3) is None
try:
    ap.check_int("x", 5, 0, 1); raise SystemExit("check_int accepted 5 in 0..1")
except ValueError as e:
    assert "out of range" in str(e)
class B(ap.Backend):
    def step(self, step): return [ap.node("Ok")]
reqs = [{"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocol": 1, "core": "1", "plugin": "p", "config": {}, "variant": None}},
        {"jsonrpc": "2.0", "id": 1, "method": "step", "params": {"instance": 0, "section": "s", "position": 0, "atom": {"a": {}}, "programs": {}}},
        {"jsonrpc": "2.0", "id": 2, "method": "clone", "params": {"instance": 0}},
        {"jsonrpc": "2.0", "id": 3, "method": "frobnicate", "params": {}},
        {"jsonrpc": "2.0", "id": 4, "method": "pre", "params": {"instance": 9}},
        {"jsonrpc": "2.0", "id": 5, "method": "shutdown", "params": {}}]
out = io.StringIO()
ap.serve("p", "1", B, stdin=io.StringIO("\n".join(json.dumps(r) for r in reqs) + "\n"), stdout=out)
answers = [json.loads(l) for l in out.getvalue().splitlines()]
assert answers[0]["result"]["protocol"] == 1, answers[0]
assert answers[1]["result"]["observations"] == [{"Ok": {}}], answers[1]
assert answers[2]["result"]["instance"] == 1, answers[2]
assert answers[3]["error"]["code"] == -32601, answers[3]
assert "no instance 9" in answers[4]["error"]["message"], answers[4]
assert answers[5]["result"] == {}, answers[5]
PY

# Conformance, and the cost of a call
expect 0 'PASS clone' $A external plugins/tiny-py conformance --spec "$F/leak-interrupt.spec" --secret 0
grep 'Conformance of' "$TMP_DIR/output"
expect 0 'PASS restore' $A external plugins/tiny-py conformance --spec "$F/leak-time.spec" --secret 1 --mitigation constant-time --tests 20

# The same models as Tiny, up to the bookkeeping
strip() { tail -n +2 "$1" | sed -E 's/\(bookkeeping( null|\(\))\)//'; }
pairs=0
for spec in leak-time leak-interrupt safe-no-branch; do
  for secret in 0 1; do
    for opt in "" "--variant no-interrupts" "--mitigation constant-time"; do
      # shellcheck disable=SC2086
      $A tiny learn --spec "$F/$spec.spec" --secret $secret $opt --res "$TMP_DIR/native.dot" > /dev/null
      # shellcheck disable=SC2086
      $A external plugins/tiny-py learn --spec "$F/$spec.spec" --secret $secret $opt --res "$TMP_DIR/python.dot" > /dev/null
      if ! diff <(strip "$TMP_DIR/native.dot") <(strip "$TMP_DIR/python.dot") > /dev/null; then
        echo "Tiny and Tiny in Python learn different models of $spec.spec (secret $secret $opt)" >&2; exit 1
      fi
      pairs=$((pairs + 1))
    done
  done
done
echo "Tiny and Tiny in Python learned the same $pairs models"

# Record a session, and replay it without the plugin
ALVIE_RPC_RECORD="$TMP_DIR/session.jsonl" $A external plugins/tiny-py learn --spec "$F/leak-time.spec" --secret 0 --res "$TMP_DIR/recorded.dot" > /dev/null
ALVIE_RPC_REPLAY="$TMP_DIR/session.jsonl" $A external plugins/tiny-py learn --spec "$F/leak-time.spec" --secret 0 --res "$TMP_DIR/replayed.dot" > /dev/null
cmp -s "$TMP_DIR/recorded.dot" "$TMP_DIR/replayed.dot" || { echo "a replayed session learned another model" >&2; exit 1; }
ALVIE_RPC_REPLAY="$TMP_DIR/session.jsonl" expect 1 'the run differs from the recording' \
  $A external plugins/tiny-py learn --spec "$F/leak-time.spec" --secret 1 --res "$TMP_DIR/replayed.dot"

# Plugins that misbehave: a copy of tiny-py whose command is test/rpc/misbehave.py MODE
bad() {
  local mode="$1" dir="$TMP_DIR/bad-$1"
  mkdir -p "$dir"
  cp plugins/tiny-py/*.yaml plugins/tiny-py/tiny.py plugins/tiny-py/tiny_types.py test/rpc/misbehave.py "$dir/"
  sed -i "s|^command: .*|command: [python3, misbehave.py, $mode]|; s|^fixtures: .*||" "$dir/alvie-plugin.yaml"
  echo "$dir"
}
export PYTHONPATH="$CODE_DIR/sdk/python"
run() { $A external "$(bad "$1")" exec --spec "$F/leak-time.spec" --secret 0 --inputs "$TMP_DIR/inputs.txt"; }
printf 'timer 1\ncall\nmov r0, 0\nreti\nret\nhalt\n' > "$TMP_DIR/inputs.txt"
expect 1 'plugin tiny-py stopped during step (it exited with status 3)' run crash
grep -q 'about to crash' "$TMP_DIR/output" || { echo "the end of the log of a crashed plugin is not shown" >&2; exit 1; }
ALVIE_RPC_TIMEOUT=2 expect 1 'plugin tiny-py did not answer step within 2s (ALVIE_RPC_TIMEOUT), and was stopped' run hang
expect 1 'answered step with a line that is not JSON: "debugging output on stdout"' run noise
expect 1 'plugin tiny-py failed in step: the simulator rejected the program' run error
expect 1 'plugin tiny-py failed in step: IndexError: list index out of range' run bug
expect 1 'the program of plugin tiny-py is version 1999.01, but its manifest is version 2026.10' run version
expect 1 'the manifest of plugin tiny-py declares clone, which its program does not have' run nocap
ALVIE_RPC_TIMEOUT=0 expect 1 'ALVIE_RPC_TIMEOUT must be a number of seconds greater than zero' run crash
dir=$(bad missing); sed -i 's|^command: .*|command: [./no-such-program]|' "$dir/alvie-plugin.yaml"
expect 1 'cannot start plugin tiny-py with .*no-such-program.*No such file or directory' $A external "$dir" exec --spec "$F/leak-time.spec" --secret 0 --inputs "$TMP_DIR/inputs.txt"
expect 2 'is native: it is built into a program of its own' $A external plugins/tiny learn --spec "$F/leak-time.spec"
expect 2 'alvie external DIR names a directory that does not exist' $A external plugins/nope learn
# No plugin process is left behind
sleep 1
if pgrep -f 'misbehave.py' > /dev/null; then echo "a plugin process was left running" >&2; pgrep -af misbehave.py >&2; exit 1; fi

echo "External plugin checks passed."
