(* The tools of mCRL2 that ALVIE can use. ALVIE checks trace inclusion itself (Ltscompare.Weak_trace); it needs
   mCRL2 for formulas, and to compare with mCRL2 (ALVIE_MCRL2). The models are in aldebaran format (.aut). *)

(* Whether this build can run mCRL2 *)
val available : bool

(* A trace that m1 has and m2 does not, with the labels in [silent] as tau: ltscompare
   --preorder=weak-trace-ac --strategy=b --counter-example, then tracepp -fplain. The files go in a new directory
   of [tmpdir], removed unless the log level is debug. *)
val weak_trace_counterexample : tmpdir:string -> silent:string list -> m1:string -> m2:string -> string list option

(* Whether the model [aut] satisfies the formula in [formula_file], with lts2pbes and pbes2bool. [spec] declares the
   actions (an mCRL2 specification), and [actions] (the text of actions.txt) says which label each one is. The
   files go in a new directory of [tmpdir], kept with the debug log level (the result says so). *)
val formula :
  tmpdir:string -> aut:string -> spec:string -> actions:string -> formula_file:string -> (bool, string) result
