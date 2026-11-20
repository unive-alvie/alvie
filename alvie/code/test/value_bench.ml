(*
  How fast values compare and hash, against the derived functions of today's Sancus inputs: the learner compares
  and hashes inputs and outputs in its hot paths (the observation tree, apartness, the oracles' caches), which will
  work on values from M3 on.

  For the atoms of spec-lib/enclave-complete.etdl and spec-lib/complete.atdl, it times sorting, Hashtbl lookups and
  equality on: Input.t with its derived functions, Value.t, and interned values (Value.Interned.t).

  Run it from alvie/code: dune exec test/value_bench.exe
*)

open Core
open Alvie_plugin
open Sancus

let time name ~iterations f =
  let start = Time_ns.now () in
  for _ = 1 to iterations do f () done;
  let ns = Time_ns.Span.to_ns (Time_ns.diff (Time_ns.now ()) start) /. Float.of_int iterations in
  printf "  %-28s %10.0f ns\n%!" name ns

let () =
  let code_dir = Sys_unix.getcwd () in
  let plugin = Result.ok_or_failwith (Result.map_error (Plugin.load (Filename.concat code_dir "plugins/sancus")) ~f:Diag.list_to_string) in
  let etdl = "../../spec-lib/enclave-complete.etdl" and atdl = "../../spec-lib/complete.atdl" in
  let spec = Result.ok_or_failwith (Result.map_error (Spec.parse_files plugin [ etdl; atdl ]) ~f:Diag.list_to_string) in
  let spec = Result.ok_or_failwith (Result.map_error (Spec.expand_secret plugin spec ~value:"0") ~f:Diag.to_string) in
  (* The atoms as values and as Sancus inputs, tagged by their section's role as Input.t is *)
  let pairs = List.concat_map spec.sections ~f:(fun s ->
      List.map (Spec.atoms s.body) ~f:(fun v ->
          let input = if String.equal s.name "enclave" then Input.IEnclave (Result.ok_or_failwith (Atom_value.to_enclave v))
            else Input.IAttacker (Result.ok_or_failwith (Atom_value.to_attacker v)) in
          (input, Value.Node ((if String.equal s.name "enclave" then "enclave" else "attacker"), [ ("atom", v) ])))) in
  (* A history-like workload: 10000 inputs drawn from the atoms *)
  let rng = Random.State.make [| 0 |] in
  let n = 10_000 in
  let picks = List.init n ~f:(fun _ -> List.nth_exn pairs (Random.State.int rng (List.length pairs))) in
  let inputs = List.map picks ~f:fst and values = List.map picks ~f:snd in
  (* As the learner would: the alphabet is interned, in order, before learning *)
  Value.Interned.preload (List.map pairs ~f:snd);
  let interned = List.map values ~f:Value.Interned.intern in
  printf "%d distinct atoms, %d inputs\n\n" (List.length pairs) n;
  let iterations = 50 in
  printf "Sorting %d inputs:\n" n;
  time "Input.t (derived)" ~iterations (fun () -> ignore (List.sort inputs ~compare:Input.compare));
  time "Value.t" ~iterations (fun () -> ignore (List.sort values ~compare:Value.compare));
  time "Value.Interned.t" ~iterations (fun () -> ignore (List.sort interned ~compare:Value.Interned.compare));
  printf "Hashing and looking up %d inputs:\n" n;
  let lookups (type a) (module M : Hashtbl.Key with type t = a) (xs : a list) () =
    let tbl = Hashtbl.create (module M) in
    List.iter xs ~f:(fun x -> Hashtbl.update tbl x ~f:(function None -> 1 | Some c -> c + 1)) in
  time "Input.t (derived)" ~iterations (lookups (module Input) inputs);
  time "Value.t" ~iterations (lookups (module Value) values);
  time "Value.Interned.t" ~iterations (lookups (module Value.Interned) interned);
  printf "Equality of consecutive inputs (%d pairs):\n" (n - 1);
  let eq_all equal xs () = ignore (List.fold xs ~init:(List.hd_exn xs, 0) ~f:(fun (prev, c) x -> (x, if equal prev x then c + 1 else c))) in
  time "Input.t (derived)" ~iterations (eq_all Input.equal inputs);
  time "Value.t" ~iterations (eq_all Value.equal values);
  time "Value.Interned.t" ~iterations (eq_all Value.Interned.equal interned);
  printf "Interning %d values: " n;
  time "" ~iterations (fun () -> List.iter values ~f:(fun v -> ignore (Value.Interned.intern v)))
