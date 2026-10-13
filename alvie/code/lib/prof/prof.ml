(*
  Lightweight wall-clock profiler, enabled by setting ALVIE_PROFILE=1.
  Sections are accumulated by name and reported on stderr at exit.
*)

let enabled =
  match Sys.getenv_opt "ALVIE_PROFILE" with
  | Some ("" | "0") | None -> false
  | Some _ -> true

let table : (string, float ref * int ref) Hashtbl.t = Hashtbl.create 32

let add name dt =
  match Hashtbl.find_opt table name with
  | Some (t, n) -> t := !t +. dt; incr n
  | None -> Hashtbl.add table name (ref dt, ref 1)

let time name f =
  if not enabled then f ()
  else begin
    let t0 = Unix.gettimeofday () in
    match f () with
    | r -> add name (Unix.gettimeofday () -. t0); r
    | exception e -> add name (Unix.gettimeofday () -. t0); raise e
  end

let count name = if enabled then add name 0.0

let report () =
  if enabled then begin
    let rows = Hashtbl.fold (fun k (t, n) acc -> (k, !t, !n) :: acc) table [] in
    let rows = List.sort (fun (_, a, _) (_, b, _) -> compare b a) rows in
    Printf.eprintf "\n=== ALVIE profile (wall-clock, sections may nest) ===\n";
    Printf.eprintf "%-40s %12s %10s %12s\n" "section" "total (s)" "calls" "avg (ms)";
    List.iter (fun (k, t, n) ->
      Printf.eprintf "%-40s %12.3f %10d %12.3f\n" k t n (if n = 0 then 0.0 else 1000.0 *. t /. float n))
      rows;
    flush stderr
  end

let () = at_exit report

(* Make sure the report is produced also when the run is interrupted (e.g., by timeout); SIGUSR1 prints it without stopping *)
let () =
  if enabled then begin
    List.iter (fun s -> Sys.set_signal s (Sys.Signal_handle (fun _ -> exit 130))) [Sys.sigterm; Sys.sigint];
    Sys.set_signal Sys.sigusr1 (Sys.Signal_handle (fun _ -> report ()))
  end
