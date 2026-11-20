(* For builds that cannot run programs, e.g. in a browser: mCRL2 is not available *)
let available = false

let unavailable () = failwith "mCRL2 is not available in this build of ALVIE"
let weak_trace_counterexample ~tmpdir:_ ~silent:_ ~m1:_ ~m2:_ = unavailable ()
let formula ~tmpdir:_ ~aut:_ ~spec:_ ~actions:_ ~formula_file:_ =
  Error "formulas need mCRL2, which this build of ALVIE cannot run: use the native ALVIE"
