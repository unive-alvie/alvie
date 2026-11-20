#!/usr/bin/env bash
# validate.sh results|bench WEB_DIR SIM_DIR OUT_DIR [JOBS]: checks that alvie-web (WebAssembly, in Node) learns the
# models that the native ALVIE learns.
#   results  learns every checked-in model of results/ with alvie-web and compares it with the file (byte for byte)
#   bench    the 320 learnings of the benchmark (8 commits x example, a, b1-b4, b6-b9 x secrets 0, 1 x with and
#            without interrupts), learned by learn.exe and by alvie-web, compared byte for byte
# WEB_DIR: the output of web/build.sh; SIM_DIR: the simulators (web/sim/build-sim.sh). Writes OUT_DIR/results.csv
# (job, native seconds, web seconds, verdict) and the models. Runs from anywhere; needs the native build
# (dune build in alvie/code) and the sancus-core-gap checkout given by SANCUS (default: the submodule).
set -uo pipefail
mode=$1 web=$(readlink -f "$2") sim=$(readlink -f "$3") out=$(mkdir -p "$4" && readlink -f "$4") jobs=${5:-6}
root=$(readlink -f "$(dirname "$(readlink -f "$0")")/../../../..")
code=$root/alvie/code; lib=$root/spec-lib; sancus=${SANCUS:-$root/sancus-core-gap}
export web sim out code lib sancus root

one() {  # name commit att encl secret variant reference
  local name=$1 commit=$2 att=$3 encl=$4 secret=$5 variant=$6 ref=$7
  local v_native=() v_web=()
  [ "$variant" = nint ] && v_native=(--ignore-interrupts) && v_web=(--variant no-interrupts)
  local tn=-
  if [ "$ref" = native ]; then
    local s=$(date +%s.%N)
    (cd "$code" && ./_build/default/bin/learn.exe --att-spec "$att" --encl-spec "$encl" --secret "$secret" --commit "$commit" \
       --sancus "$sancus" --tmpdir "$out/tmp/$name-native" --res "$out/$name-native.dot" "${v_native[@]}" > "$out/$name-native.log" 2>&1)
    tn=$(echo "$(date +%s.%N) - $s" | bc); rm -rf "$out/tmp/$name-native"; ref=$out/$name-native.dot
  fi
  local s=$(date +%s.%N)
  ALVIE_WEB_SIM=$sim node "$web/alvie-web-node.cjs" sancus learn --spec "$att" --spec "$encl" --secret "$secret" --commit "$commit" \
    --sancus none --tmpdir "$out/tmp/$name-web" --res "$out/$name-web.dot" "${v_web[@]}" > "$out/$name-web.log" 2>&1
  local tw=$(echo "$(date +%s.%N) - $s" | bc); rm -rf "$out/tmp/$name-web"
  local verdict=identical
  if [ ! -s "$out/$name-web.dot" ]; then verdict=web-failed
  elif [ ! -s "$ref" ]; then verdict=native-failed
  elif ! cmp -s "$ref" "$out/$name-web.dot"; then verdict=different; fi
  echo "$name,$tn,$tw,$verdict" | tee -a "$out/results.csv"
}
export -f one

case "$mode" in
  results)
    for f in "$root"/results/*-enclave-complete-*.dot; do
      b=$(basename "$f" .dot); IFS=- read -r commit spec _ _ secret _ _ variant <<< "$b"
      echo "$b $commit $lib/$spec.atdl $lib/enclave-complete.etdl $secret $variant $f"
    done
    for f in "$root"/results/example/*-attacker-enclave-*.dot; do
      b=$(basename "$f" .dot); IFS=- read -r commit _ _ secret _ <<< "$b"
      echo "example-$b $commit $lib/example/attacker.atdl $lib/example/enclave.etdl $secret int $f"
    done ;;
  bench)
    for commit in ef753b6 e8cf011 3170d5d 6475709 3636536 d54f031 264f135 bf89c0b; do
      for spec in example a b1 b2 b3 b4 b6 b7 b8 b9; do for secret in 0 1; do for variant in int nint; do
        if [ "$spec" = example ]; then att=$lib/example/attacker.atdl encl=$lib/example/enclave.etdl
        else att=$lib/$spec.atdl encl=$lib/enclave-complete.etdl; fi
        echo "$commit-$spec-$secret-$variant $commit $att $encl $secret $variant native"
      done; done; done
    done ;;
  *) echo "Usage: $0 results|bench WEB_DIR SIM_DIR OUT_DIR [JOBS]" >&2; exit 2 ;;
esac > "$out/jobs.txt"
: > "$out/results.csv"
xargs -P "$jobs" -L 1 bash -c 'one "$@"' _ < "$out/jobs.txt" > /dev/null
echo "$mode: $(wc -l < "$out/results.csv") jobs: $(cut -d, -f4 "$out/results.csv" | sort | uniq -c | tr '\n' ' ')"
