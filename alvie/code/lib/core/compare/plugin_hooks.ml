(*
  The hooks of the comparison engine (Hooks.S), derived from the files of a plugin: nothing in them is written
  for a platform.

  - Inputs are the atoms of the steps, with their class and whether their section is the attacker's, plus the
    built-in interrupt input of the parts of observations (View.parts). Low inputs are the attacker's atoms and
    interrupts.
  - Outputs are parts of observations. Hidden, public equality and distinct come from view.yaml.
  - A run ends at an observation whose phase rule stops or restarts the test.
  - The victim code of a run is the sequence of atoms of victim sections until the first part that leaves the
    victim (an interrupt, or a phase rule that interrupts it or enters or switches to another section).
    Up to the secret, the expansions of the secret's values in these atoms are replaced by the hole, so that two
    runs with different secrets run "the same code".
  - A witness does not end at a hidden part.
*)

open Core
open Alvie_plugin

module type PARAMS = sig
  val plugin : Plugin.t
  val secret_values : string list (* the values of the secret in the compared models *)
end

module Make (P : PARAMS) = struct
  let view = View.make P.plugin

  module Input = struct
    type t =
      | No_input
      | Interrupt
      | Atom of { cls : string; low : bool; atom : Value.t }
    [@@deriving sexp, equal, compare, hash]

    let default = No_input

    let show = function
      | No_input -> "ε"
      | Interrupt -> "IRQ"
      | Atom { cls; atom; _ } -> Grammar.print_atom P.plugin.grammar ~cls atom

    let pp fmt i = Format.pp_print_string fmt (show i)

    include Comparator.Make (struct type nonrec t = t let compare = compare let sexp_of_t = sexp_of_t end)
  end

  module Output = struct
    type t = Value.t [@@deriving sexp, equal, compare, hash]

    let default = Value.Node ("Illegal", [])
    let show = Value.to_string
    let pp = Value.pp

    include Comparator.Make (struct type nonrec t = t let compare = compare let sexp_of_t = sexp_of_t end)
  end

  let is_low_input = function Input.Interrupt -> true | Atom { low; _ } -> low | No_input -> false
  let is_hidden o = View.is_hidden view o
  let public_equal a b = View.public_equal view a b
  let in_victim o = is_hidden o

  (* The phase rule of an observation (the first that matches it, whatever the current section) *)
  let phase_effect (obs : Value.t) =
    List.find_map P.plugin.phases ~f:(fun (r : Rules_file.action list Rules_file.rule) ->
        let kind_ok = match r.kinds, Value.tag obs with None, _ -> true | Some ks, Some k -> List.mem ks k ~equal:String.equal | Some _, None -> false in
        let when_ok = List.for_all r.when_ ~f:(fun c ->
            match Value.path obs c.path with
            | Some (Value.Sym s) -> String.equal s c.value
            | Some (Value.Int i) -> String.equal (Int.to_string i) c.value
            | Some (Value.Bool b) -> String.equal (Bool.to_string b) c.value
            | _ -> false) in
        if kind_ok && when_ok then Some r.effect else None)

  (* A run ends where the test finishes or restarts (not where it becomes invalid: such outputs stay in the run) *)
  let is_final o =
    match phase_effect o with
    | Some actions -> List.exists actions ~f:(function Rules_file.Stop Finished | Restart -> true | _ -> false)
    | None -> false

  let victim_sections =
    List.filter_map P.plugin.sections.sections ~f:(fun s -> match s.role with Victim -> Some s.name | Attacker -> None)

  (* Whether a part leaves the victim: its phase rule interrupts it or goes to another section. A stop or a restart
     does not: the victim's code is what it ran, whatever ended the test *)
  let leaves_victim (o : Value.t) =
    match phase_effect o with
    | Some actions ->
      List.exists actions ~f:(function
          | Rules_file.Interrupt _ -> true
          | Enter s | Switch s -> not (List.mem victim_sections s ~equal:String.equal)
          | Stop _ | Restart | Reset | Resume -> false)
    | None -> false

  let victim_classes =
    List.filter_map P.plugin.sections.sections ~f:(fun s -> match s.role with Victim -> s.atoms | Attacker -> None)

  let is_victim = function Input.Atom { cls; _ } -> List.mem victim_classes cls ~equal:String.equal | _ -> false

  (* The victim's atoms of a run until it leaves the victim: at a part whose phase rule leaves it, or an interrupt *)
  let victim_code (run : (Input.t * Output.t) list) : Input.t list =
    let rec go acc = function
      | [] -> List.rev acc
      | (Input.Interrupt, _) :: _ -> List.rev acc
      | (_, o) :: _ when leaves_victim o -> List.rev acc
      | (i, _) :: rest when is_victim i -> go (i :: acc) rest
      | _ :: rest -> go acc rest in
    go [] run

  (* The values the secret's values expand to, per type with a secret variant *)
  let expansions =
    List.concat_map P.plugin.grammar.types ~f:(fun t ->
        match List.find_map t.alts ~f:(fun a -> a.secret) with
        | None -> []
        | Some _ ->
          List.filter_map P.secret_values ~f:(fun value ->
              Result.ok (Grammar.expand_secret P.plugin.grammar ~ty:(Grammar.Ref t.name) ~value (Value.Hole Grammar.secret_name))))

  let rec forget_secret (v : Value.t) : Value.t =
    if List.mem expansions v ~equal:Value.equal then Value.Hole Grammar.secret_name
    else match v with
      | Node (tag, fs) -> Node (tag, List.map fs ~f:(fun (n, x) -> (n, forget_secret x)))
      | List vs -> List (List.map vs ~f:forget_secret)
      | v -> v

  (* Only the victim's steps count here: what the attacker does in between does not end the victim's code *)
  let victim_code_up_to_secret run =
    List.map (victim_code (List.filter run ~f:(fun (i, _) -> is_victim i))) ~f:(function
        | Input.Atom a -> Input.Atom { a with atom = forget_secret a.atom }
        | i -> i)

  let comparison_label i o =
    match View.see view o with
    | Hidden -> Input.show i ^ "/τ"
    | Visible v | Distinct v -> Input.show i ^ "/" ^ v

  let human_show i o =
    let shown = match View.see view o with Hidden -> Value.to_string o ^ " (hidden)" | Visible _ | Distinct _ -> Value.to_string o in
    Input.show i ^ "/" ^ shown
end
