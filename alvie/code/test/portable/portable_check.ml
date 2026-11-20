(* The fixtures of Tiny, learned and compared with the portable part of ALVIE only (see dune) *)
open Core
module R = Alvie_cli.Runner.Make (Alvie_tiny.Tiny.Native)

let () =
  let module D = Learninglib.Defaults in
  let dir = "../../plugins/tiny/fixtures" in
  let out = Filename.concat (Filename.temp_dir_name) (sprintf "alvie-portable-%d" (Random.State.int (Random.State.make_self_init ()) 1_000_000)) in
  Alvie_cli.Fs.mkdir_p out;
  let oracle = R.Pac { epsilon = D.pac_epsilon; delta = D.pac_delta; round_limit = None } in
  let fixtures = List.filter (Alvie_cli.Fs.ls_dir dir) ~f:(String.is_suffix ~suffix:".yaml") in
  let failed = List.count fixtures ~f:(fun f ->
      let v = R.run_fixture ~base:[] ~out ~tmpdir:out ~oracle (Filename.concat dir f) in
      printf "%s %-24s %s\n" (if v.passed then "PASS" else "FAIL") v.fixture v.summary;
      not v.passed) in
  printf "%d fixtures, %d failed\n" (List.length fixtures) failed;
  if failed > 0 || List.is_empty fixtures then exit 1
