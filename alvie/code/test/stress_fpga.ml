(*
  tt_stress_fpga: checks that the image on an FPGA board of ALVIE/Sancus-FPGA always gives the same answer to the
  same query. An image is accepted only if it passes (see docs/sancus/fpga.md).

  A Sancus core can have combinational loops (e.g., in its crypto, which sancus_enable uses) that timing analysis does
  not cover: on the board, their result depends on the placement of each build, and a bad build answers some queries
  at random only (e.g., 20% of the queries after sancus_enable). Each program of fixtures/fpga/stress.programs
  creates an enclave; the test runs it with each breakpoint from Fpga.first_instruction (the first after the code
  that clears the memory: before it, a trace shows what the previous query left in the memory) to the end of the
  program, rounds times each, and requires that the rounds of a query give the same trace, or all no trace (after the
  end of the program).

  It needs the board, so it is not part of CI. Run it from alvie/code:

    dune exec test/stress_fpga.exe -- [ROUNDS]     (default 20; the port is ALVIE_FPGA_PORT, default /dev/ttyUSB1)
*)
open Core
module Fpga = Sancus_fpga.Fpga

let programs_file = "test/fixtures/fpga/stress.programs"

(* After this many breakpoints in a row without a trace, the program ended *)
let ended_after = 3

(* The last breakpoint: well after sancus_enable (instruction 37 of the programs), and after the end of most programs
   (some loop until the reset of the end of a test, after thousands of instructions) *)
let max_breakpoint = 150

let of_hex h = String.init (String.length h / 2) ~f:(fun i -> Char.of_int_exn (Int.of_string ("0x" ^ String.sub h ~pos:(2 * i) ~len:2)))

let programs () =
  In_channel.read_lines programs_file
  |> List.filter ~f:(fun l -> not (String.is_empty l || String.is_prefix l ~prefix:"#"))
  |> List.map ~f:(fun l ->
    match String.split l ~on:' ' with
    | [ pmem; vectors ] -> of_hex pmem, of_hex vectors
    | _ -> failwithf "%s: a line is not <pmem hex> <vectors hex>: %s" programs_file l ())

let () =
  let rounds = match Sys.get_argv () with [| _; r |] -> Int.of_string r | _ -> 20 in
  let port = Option.value (Sys.getenv "ALVIE_FPGA_PORT") ~default:"/dev/ttyUSB1" in
  let fd = Fpga.connect ~port in
  (match Fpga.identify fd with
   | Some id ->
     printf "Image on %s: Sancus %s, built from %s%s\n%!" port id.sancus_commit id.build (if id.build_dirty then " with uncommitted changes" else "")
   | None -> printf "Image on %s: an image that does not identify itself\n%!" port);
  let size = Fpga.window * Fpga.entry_size in
  let queries = ref 0 and unstable = ref [] in
  List.iteri (programs ()) ~f:(fun n (pmem, vectors) ->
    let rec sweep breakpoint without_trace answered =
      if without_trace >= ended_after || breakpoint > max_breakpoint then answered
      else begin
        let data = Fpga.payload ~pmem ~vectors ~breakpoint () in
        let answers = List.init rounds ~f:(fun _ -> Fpga.exchange fd ~data ~size) in
        queries := !queries + rounds;
        let traces = List.dedup_and_sort answers ~compare:String.compare in
        let complete = List.filter answers ~f:(fun a -> String.length a = size) in
        (match traces with
         | [ _ ] -> ()
         | _ ->
           unstable := (n, breakpoint) :: !unstable;
           if List.count !unstable ~f:(fun (n', _) -> n' = n) <= 5 then printf "  program %d, breakpoint %d: %d/%d traces, %d different answers\n%!" n breakpoint (List.length complete) rounds
             (List.length traces));
        if List.is_empty complete then sweep (breakpoint + 1) (without_trace + 1) answered
        else sweep (breakpoint + 1) 0 (answered + 1)
      end in
    let answered = sweep Fpga.first_instruction 0 0 in
    printf "Program %d: %d breakpoints with a trace\n%!" n answered);
  match !unstable with
  | [] -> printf "PASS: %d queries, each always gave the same answer (%d rounds)\n" !queries rounds
  | u ->
    printf "FAIL: %d of the queries gave different answers (of %d queries, %d rounds): the image is not reliable, build it again (see docs/sancus/fpga.md)\n"
      (List.length u) !queries rounds;
    exit 1
