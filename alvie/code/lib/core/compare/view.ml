(*
  The attacker view of a plugin (view.yaml), evaluated on observations: what the attacker sees of each one.

  An observation of a step may stand for several events (parts rules): it is first split into its parts, each with
  the input of the step or the built-in interrupt input. Each part is then seen by the first show rule that matches
  it: hidden (silent for the comparison), its kind only, its kind and some fields, all of it, or distinct (never
  equal to anything, so always reported).
*)

open Core
open Alvie_plugin

type seen = Hidden | Visible of string | Distinct of string [@@deriving sexp, equal, compare]

type compiled = {
  kinds : String.Set.t option;
  when_ : (string list * Value.t) list;
  effect : Rules_file.effect;
}

type t = { plugin : Plugin.t; rules : compiled list }

let make (p : Plugin.t) : t =
  let rules = List.map p.view ~f:(fun (r : Rules_file.effect Rules_file.rule) ->
      let kinds = match r.kinds with
        | Some ks -> List.filter_map ks ~f:(Observations_file.find_kind p.observations)
        | None -> p.observations.kinds in
      let when_ = List.map r.when_ ~f:(fun (c : Rules_file.cond) ->
          let v = List.find_map kinds ~f:(fun k ->
              Option.bind (Observations_file.path_type p.observations k.fields c.path) ~f:(fun ty ->
                  Result.ok (Observations_file.scalar_value p.observations ty c.value))) in
          (c.path, Option.value v ~default:(Value.Sym c.value))) in
      { kinds = Option.map r.kinds ~f:String.Set.of_list; when_; effect = r.effect }) in
  { plugin = p; rules }

let matches (r : compiled) (obs : Value.t) =
  (match r.kinds, Value.tag obs with None, _ -> true | Some ks, Some k -> Set.mem ks k | Some _, None -> false)
  && List.for_all r.when_ ~f:(fun (path, v) -> match Value.path obs path with Some v' -> Value.equal v v' | None -> false)

(* The parts of an observation: (part, whether its input is the interrupt), or the observation itself *)
let parts t (obs : Value.t) : (Value.t * bool) list =
  match List.find t.rules ~f:(fun r -> match r.effect with Parts _ -> matches r obs | Show _ -> false) with
  | Some { effect = Parts ps; _ } ->
    List.map ps ~f:(fun (p : Rules_file.part) ->
        let fields = match p.field, obs with
          | None, _ -> []
          | Some "self", Value.Node (_, fs) -> fs
          | Some f, _ -> (match Value.field obs f with Some (Value.Node (_, fs)) -> fs | _ -> []) in
        (Value.Node (p.as_kind, fields), p.interrupt))
  | _ -> [ (obs, false) ]

(* What the attacker sees of a part *)
let see t (part : Value.t) : seen =
  match List.find t.rules ~f:(fun r -> match r.effect with Show _ -> matches r part | Parts _ -> false) with
  | None | Some { effect = Show All; _ } -> Visible (Value.to_string part)
  | Some { effect = Show Hidden; _ } -> Hidden
  | Some { effect = Show Tag; _ } -> Visible (Option.value (Value.tag part) ~default:(Value.to_string part))
  | Some { effect = Show (Fields paths); _ } ->
    let tag = Option.value (Value.tag part) ~default:"" in
    Visible (tag ^ "(" ^ String.concat ~sep:", " (List.map paths ~f:(fun p ->
        String.concat ~sep:"." p ^ " = " ^ Option.value_map (Value.path part p) ~default:"?" ~f:Value.to_string)) ^ ")")
  | Some { effect = Show Distinct; _ } -> Distinct (Value.to_string part)
  | Some { effect = Parts _; _ } -> Visible (Value.to_string part)

let is_hidden t part = match see t part with Hidden -> true | Visible _ | Distinct _ -> false

let public_equal t a b =
  match see t a, see t b with
  | Visible x, Visible y -> String.equal x y
  | Hidden, Hidden -> true
  | Distinct _, _ | _, Distinct _ | Hidden, Visible _ | Visible _, Hidden -> false
