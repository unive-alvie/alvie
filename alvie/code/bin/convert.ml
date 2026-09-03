open Sancus
open Interop

open Core

module IOVOracle = Learninglib.Randomwalkoracle.RandomWalkOracle (Sancus.Input) (Sancus.Output) (Sancus.Fpga)
module IOInterop = Interop (Sancus.Input) (Sancus.Output)

module Obs = struct
  type t = IO of Input.t * Output.t [@@deriving ord,sexp]

  let default = IO (Input.default, Output.default)

  let to_mcrl2_name (s : string) =
    let replacements = [('(', "["); (')', "]")] in
    let cnl = List.map (String.to_list s) ~f:(fun c ->
      match List.find replacements ~f:(fun (s, _) -> Char.equal s c) with
      | None -> String.of_char c | Some (_, e) -> e) in
    (List.fold ~init:"" ~f:(fun str s -> str ^ s) cnl)

  let show_obs_t io = to_mcrl2_name (Sexp.to_string_mach (sexp_of_t io))
end

module LTS (S : sig type t [@@deriving eq,ord,sexp,hash,show] end) = struct
  module LTSMap = Map.Make (struct type t = S.t * Obs.t [@@deriving ord,sexp] end)
  module LTSSSet = Set.Make (struct type t = S.t [@@deriving ord,sexp] end)

  type lts_map_t = LTSSSet.t LTSMap.t [@@deriving sexp]
  type t = {
    initial : S.t;
    states : LTSSSet.t;
    transition : lts_map_t
  }

  (* Ugly hack, sorry *)
  let _ = S.pp

  (* let get_silent_obs (lts : t) = LTSMap.fold lts.transition ~f:(fun ~key:(_, obs) ~data:_ acc -> if Obs.is_silent obs then obs::acc else acc) ~init:[] *)

  module G = Graph.Persistent.Digraph.ConcreteLabeled (S) (Obs)

  module Dot = Graph.Graphviz.Dot(struct
    include G
    let edge_attributes ((_, l, _) : edge) = [`Label (Sexp.to_string (Obs.sexp_of_t l))]
    let default_edge_attributes _ = []
    let get_subgraph _ = None
    let vertex_attributes _ = [`Shape `Circle]
    let vertex_name v = S.show v
    let default_vertex_attributes _ = []
    let graph_attributes _ = []
  end)

  module B = struct
    module G = G

    include G
  end

  (* let to_dot ({ initial; states; transition } : t) : B.t =
    let g = LTSSSet.fold (LTSSSet.add states initial) ~init:G.empty ~f:G.add_vertex in
    let g' =
      LTSMap.fold transition ~init:g ~f:(fun ~key:(s, o) ~data:s'_set g_acc ->
        LTSSSet.fold s'_set ~init:g_acc ~f:(fun g_acc_acc s' ->
              G.add_edge_e g_acc_acc (s, o, s'))) in
      g' *)

  let to_fsm ({ initial; states; transition } : t) : string =
    let state_to_int = List.foldi (initial::(LTSSSet.elements (LTSSSet.remove states initial))) ~init:(fun _ -> failwith "mcrl2.to_aldebaran: Unknown state") ~f:(fun i acc s -> (fun s' -> (if S.equal s' s then i else acc s'))) in
    let last_state = LTSSSet.length states - 1 in
    let states_list = List.range 0 (last_state+1) in
    let fsm_parameters = sprintf "i(%d) Nat %s\n---\n" (last_state + 1) (List.fold states_list ~init:"" ~f:(fun acc i -> sprintf "%s\"%d\" " acc i)) in
    let fsm_states = sprintf "%s---\n" (List.fold states_list ~init:"" ~f:(fun acc i -> sprintf "%s%d\n" acc i)) in
    let fsm_edges = LTSMap.fold transition
      ~init:("")
      ~f:(fun ~key:(s, o) ~data:s'_set acc_s ->
          (LTSSSet.fold s'_set ~init:acc_s
            ~f:(fun acc_s' s' ->
              sprintf "%s%d %d \"%s\"\n" acc_s' (state_to_int s + 1) (state_to_int s' + 1) (Obs.show_obs_t o)
            )
          )
      ) in
    fsm_parameters ^ fsm_states ^ fsm_edges
end

module I = struct type t = Int.t [@@deriving eq,ord,sexp,hash,show] end
module ILTS = LTS (I)
type i_lts_t = ILTS.t

let lts_of_mealy (m : IOVOracle.IIOMealy.t) : i_lts_t =
  let states = ILTS.LTSSSet.of_list (IOVOracle.IIOMealy.SSet.to_list m.states) in
  let transition = IOVOracle.IIOMealy.TransitionMap.fold m.transition
    ~init:ILTS.LTSMap.empty
    ~f:(fun ~key:(s, i) ~data:(o, s') acc_tr ->
        let change_or_add tr ~key ~data =
          if ILTS.LTSMap.mem tr key then
              ILTS.LTSMap.change tr key ~f:(fun old_d -> match old_d with Some old_d -> Some (ILTS.LTSSSet.add old_d data) | _ -> None)
          else ILTS.LTSMap.add_exn tr ~key:key ~data:(ILTS.LTSSSet.singleton data)
        in
          change_or_add acc_tr ~key:(s, IO (i, o)) ~data:s')
  in { initial = m.s0; states; transition }

let command =
  Command.basic
    ~summary:"Given a Sancus model in dot format, converts it to the fsm format."
    (let%map_open.Command
      dotfile =
        flag "--in"
        (required string)
        ~doc:"dotfile The file that needs to be converted"
      and fsmfile =
      flag
          "--out"
          (required string)
          ~doc:"fsmfile The output file"
      in
      fun () ->
        (
        let in_dot = lts_of_mealy (IOInterop.t_of_dot_file IOInterop.IIOMealy.ISet.empty dotfile) in
        Out_channel.write_all fsmfile ~data:(ILTS.to_fsm in_dot);
        Logs.info (fun m -> m "\n=== File converted: %s -> %s" dotfile fsmfile)
        )
    )

let () = Command_unix.run command
