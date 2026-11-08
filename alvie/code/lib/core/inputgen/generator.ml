(*
  The input generator of ALVIE/Core: given a spec and the history of a test (inputs and the observations they
  caused), the inputs that the spec allows next. Learning asks it at every step.

  A test is in one section at a time. Its observations move it between sections by the plugin's phase rules
  (phases.yaml), and its inputs are the atoms of the current section, as the section's body (a regular expression)
  allows them: each input derives the body (Deriv).

  The prefix rule. A section of kind code is code: running it again runs the same code from its start. All the
  runs of a section in a test must therefore be prefixes of its longest run, its program: when a run is at a
  position that the program already has, the only option is the program's atom there, and new atoms are chosen only
  beyond the end of the program. A run starts when the section is entered (enter, or interrupt into it); switch and
  resume continue the run of the section they make current. Sections of kind stimulus choose afresh every time, and
  opaque sections have the single input run, whose program the backend knows.

  Interrupts. interrupt saves where the current section is (its run and the position in its body) and enters
  another section; resume makes the last section interrupted current again, at the position where it was
  interrupted. The saved position stays: resuming again returns to it again, as when a Sancus attacker executes reti
  twice and re-enters the enclave where the timer last interrupted it. Resuming at a position that the section's
  program already has replays the program from there. A reset keeps the saved positions: whether the platform can
  resume after it is for its observations to say.

  The state of a test is a value: Core computes it once per prefix of a history (see Cache) and the learner shares
  it between the queries that extend the same prefix.

  Constraints (constraint { ... }; in a spec) hold over a whole test: Core keeps the values of the attributes that
  they use, for each section (the monitor), and offers a new atom only if, with it, every constraint still holds and
  the section can still reach the end of its body with atoms that keep them (an exact search over the simplified
  derivatives and the monitor). Atoms that the prefix rule replays are offered as they are: they ran before, so
  their values are already in the monitor.

  Threads: a test has one thread of control for now. The state keeps the thread's current section and stack
  apart, so that several threads can be added without changing the interface.
*)

open Core
open Alvie_plugin

type input = { section : string; atom : Value.t } [@@deriving sexp, equal, compare, hash]

(* The built-in input of opaque sections *)
let run_atom = Value.Node ("run", [])

type status = Running | Finished | Invalid [@@deriving sexp, equal, compare]

type section_state = {
  deriv : Spec.body; (* what the section accepts from its current position *)
  run : Value.t list; (* the atoms of the current run, the last first *)
  run_length : int;
  program : Value.t list; (* the longest run so far *)
  program_length : int;
}

(* Where an interrupted section was *)
type saved = { sname : string; at : section_state }

type thread = { current : string; saved : saved list (* the last interrupted section, if any (nested interrupts are not supported yet) *) }

type state = {
  sections : section_state String.Map.t;
  monitor : Value.t list String.Map.t; (* attr(section) -> the values so far, sorted *)
  threads : thread list; (* one, for now *)
  status : status;
}

(* A compiled rule: kinds (none for all), sections (none for all), and the field values it requires *)
type 'a rule = { kinds : String.Set.t option; in_ : String.Set.t option; when_ : (string list * Value.t) list; effect : 'a }

type t = {
  plugin : Plugin.t;
  spec : Spec.t;
  phases : Rules_file.action list rule list;
  kinds_of : Sections_file.kind String.Map.t;
  classes : string String.Map.t; (* the atom class of each section *)
  bodies : Spec.body String.Map.t;
  constraints : Spec.constraint_ list;
  watched : (string * string) list; (* the (attribute, section) that the constraints use *)
  initial : state;
}

let key attr section = attr ^ "(" ^ section ^ ")"


(* The value of a scalar of a rule for the type of the field it tests, in each kind that has the field *)
let compile_rules (p : Plugin.t) (rules : 'a Rules_file.rule list) : 'a rule list =
  List.map rules ~f:(fun (r : 'a Rules_file.rule) ->
      let kinds = match r.kinds with
        | Some ks -> List.filter_map ks ~f:(Observations_file.find_kind p.observations)
        | None -> p.observations.kinds in
      let when_ = List.map r.when_ ~f:(fun (c : Rules_file.cond) ->
          (* the field has the same type in every kind (Plugin checks the values against each); take the first *)
          let v = List.find_map kinds ~f:(fun k ->
              Option.bind (Observations_file.path_type p.observations k.fields c.path) ~f:(fun ty ->
                  Result.ok (Observations_file.scalar_value p.observations ty c.value))) in
          (c.path, Option.value v ~default:(Value.Sym c.value))) in
      { kinds = Option.map r.kinds ~f:String.Set.of_list; in_ = Option.map r.sections ~f:String.Set.of_list; when_; effect = r.effect })

let fresh_section body = { deriv = body; run = []; run_length = 0; program = []; program_length = 0 }

let make (p : Plugin.t) (spec : Spec.t) : t =
  let bodies = String.Map.of_alist_exn (List.map spec.sections ~f:(fun s -> (s.name, s.body))) in
  let watched = List.dedup_and_sort ~compare:[%compare: string * string]
      (List.concat_map spec.constraints ~f:(fun c ->
           List.filter_map [ c.left; c.right ] ~f:(function Spec.Attr { attr; section } -> Some (attr, section) | Values _ -> None))) in
  let sections = String.Map.of_alist_exn (List.map p.sections.sections ~f:(fun s ->
      (s.name, fresh_section (Option.value (Map.find bodies s.name) ~default:Spec.Epsilon)))) in
  let initial = { sections; monitor = String.Map.empty; threads = [ { current = (Sections_file.initial p.sections).name; saved = [] } ]; status = Running } in
  { plugin = p; spec; phases = compile_rules p p.phases;
    kinds_of = String.Map.of_alist_exn (List.map p.sections.sections ~f:(fun s -> (s.name, s.kind)));
    classes = String.Map.of_alist_exn (List.filter_map p.sections.sections ~f:(fun s -> Option.map s.atoms ~f:(fun a -> (s.name, a))));
    bodies; constraints = spec.constraints; watched; initial }

let initial t = t.initial

let thread st = List.hd_exn st.threads
let set_thread st th = { st with threads = [ th ] }
let current st = (thread st).current

let section st name = Map.find_exn st.sections name
let set_section st name s = { st with sections = Map.set st.sections ~key:name ~data:s }

(* The section starts a new run, from the start of its body; its program stays *)
let restart t st name =
  let s = section st name in
  (* opaque sections have no body *)
  set_section st name { s with deriv = Option.value (Map.find t.bodies name) ~default:Spec.Epsilon; run = []; run_length = 0 }

let matches (r : _ rule) ~current (obs : Value.t) =
  (match r.kinds, Value.tag obs with
   | None, _ -> true
   | Some ks, Some k -> Set.mem ks k
   | Some _, None -> false)
  && (match r.in_ with None -> true | Some ss -> Set.mem ss current)
  && List.for_all r.when_ ~f:(fun (path, v) -> match Value.path obs path with Some v' -> Value.equal v v' | None -> false)

let apply t st (a : Rules_file.action) =
  match a with
  | Restart -> t.initial
  | Reset -> List.fold (Map.keys st.sections) ~init:st ~f:(restart t)
  | Enter s -> set_thread (restart t st s) { (thread st) with current = s }
  | Switch s -> set_thread st { (thread st) with current = s }
  | Interrupt s ->
    let th = thread st in
    (* Resume returns to the last interrupted position, and does not forget it: only that one matters *)
    let saved = { sname = th.current; at = section st th.current } in
    set_thread (restart t st s) { current = s; saved = [ saved ] }
  | Resume ->
    (match (thread st).saved with
     | { sname; at } :: _ ->
       (* back to the position it was interrupted at; its program is the one it has now *)
       let now = section st sname in
       let st = set_section st sname { at with program = now.program; program_length = now.program_length } in
       set_thread st { (thread st) with current = sname }
     | [] -> { st with status = Invalid })
  | Stop Finished -> { st with status = Finished }
  | Stop Invalid -> { st with status = Invalid }

(* The observations of one step, in order: the first phase rule that matches each applies *)
let observe t st (observations : Value.t list) : state =
  List.fold observations ~init:st ~f:(fun st obs ->
      match st.status with
      | Finished | Invalid -> st
      | Running ->
        (match List.find t.phases ~f:(fun r -> matches r ~current:(current st) obs) with
         | None -> st
         | Some r -> List.fold r.effect ~init:st ~f:(apply t)))

(* The constraints *)

let add_atom t monitor ~section (a : Value.t) =
  List.fold t.watched ~init:monitor ~f:(fun monitor (attr, s) ->
      if not (String.equal s section) then monitor
      else
        let cls = Map.find_exn t.classes section in
        let values = Grammar.attribute_of_atom t.plugin.grammar ~cls ~name:attr a in
        if List.is_empty values then monitor
        else Map.update monitor (key attr s) ~f:(fun old ->
            List.dedup_and_sort (values @ Option.value old ~default:[]) ~compare:Value.compare))

let holds t monitor =
  let set = function
    | Spec.Attr { attr; section } -> Option.value (Map.find monitor (key attr section)) ~default:[]
    | Values vs -> vs in
  List.for_all t.constraints ~f:(fun (c : Spec.constraint_) ->
      let l = set c.left and r = set c.right in
      match c.relation with
      | Disjoint -> not (List.exists l ~f:(fun v -> List.mem r v ~equal:Value.equal))
      | Subset -> List.for_all l ~f:(fun v -> List.mem r v ~equal:Value.equal))

(* Derivatives up to the associativity, commutativity and idempotence of choice, and the units: a body has
   finitely many of them, so the search below ends *)
let rec simplify (b : Spec.body) : Spec.body =
  match b with
  | Empty | Epsilon | Atom _ -> b
  | Seq (r, s) ->
    (match simplify r, simplify s with
     | Empty, _ | _, Empty -> Empty
     | Epsilon, s' -> s'
     | r', Epsilon -> r'
     | r', s' -> Seq (r', s'))
  | Star r -> (match simplify r with Empty | Epsilon -> Epsilon | r' -> Star r')
  | Choice _ ->
    let rec alts (b : Spec.body) = match b with Choice (l, r) -> alts l @ alts r | Empty -> [] | b -> [ b ] in
    let items = List.dedup_and_sort (List.concat_map (alts b) ~f:(fun x -> alts (simplify x))) ~compare:Spec.compare_body in
    (match List.rev items with
     | [] -> Empty
     | last :: rest -> List.fold rest ~init:last ~f:(fun acc x -> Choice (x, acc)))

let search_budget = 100_000

(* Whether the section can reach the end of b with atoms that keep the constraints *)
let completable t ~section b monitor =
  let visited = Hash_set.Poly.create () in
  let budget = ref search_budget in
  let rec go = function
    | [] -> false
    | (b, monitor) :: rest ->
      if Deriv.nu b then true
      else if !budget <= 0 then true (* too large to decide: offer the atom, a dead end only ends the test *)
      else if Hash_set.mem visited (b, monitor) then go rest
      else (
        Hash_set.add visited (b, monitor);
        decr budget;
        let next = List.filter_map (Deriv.atoms b) ~f:(fun a ->
            let monitor' = add_atom t monitor ~section a in
            let b' = simplify (Deriv.derive b a) in
            if Deriv.is_empty b' || not (holds t monitor') then None else Some (b', monitor')) in
        go (next @ rest)) in
  go [ (simplify b, monitor) ]

(* One input, in the current section *)
let input t st (i : input) : state =
  match st.status with
  | Finished | Invalid -> st
  | Running ->
    let name = current st in
    if not (String.equal i.section name) then { st with status = Invalid }
    else
      let s = section st name in
      let s = match Map.find_exn t.kinds_of name with
        | Opaque -> s
        | Code | Stimulus ->
          let run = i.atom :: s.run and run_length = s.run_length + 1 in
          let program, program_length =
            if run_length > s.program_length then (List.rev run, run_length) else (s.program, s.program_length) in
          (* Simplified, so that a star does not make it grow with every repetition (it would double) *)
          { deriv = simplify (Deriv.derive s.deriv i.atom); run; run_length; program; program_length } in
      let st = set_section st name s in
      if List.is_empty t.watched then st else { st with monitor = add_atom t st.monitor ~section:name i.atom }

type option_ = [ `Next of input | `Stop ]

(* What may come next: the inputs, in the declaration order of the section's atoms; [`Stop] when the test cannot go
   on (it is invalid); [] when it has finished *)
let options t st : option_ list =
  match st.status with
  | Finished -> []
  | Invalid -> [ `Stop ]
  | Running ->
    let name = current st in
    let s = section st name in
    let next () =
      let cls = Map.find_exn t.classes name in
      let atoms = Deriv.next t.plugin.grammar ~cls s.deriv in
      let atoms =
        if List.is_empty t.constraints then atoms
        else List.filter atoms ~f:(fun a ->
            let monitor = add_atom t st.monitor ~section:name a in
            holds t monitor && completable t ~section:name (Deriv.derive s.deriv a) monitor) in
      List.map atoms ~f:(fun atom -> `Next { section = name; atom }) in
    (match Map.find_exn t.kinds_of name with
     | Opaque -> [ `Next { section = name; atom = run_atom } ]
     | Stimulus -> next ()
     | Code ->
       if s.run_length < s.program_length then [ `Next { section = name; atom = List.nth_exn s.program s.run_length } ]
       else next ())

(* Whether the spec allows i next *)
let legal t st i = List.mem (options t st) (`Next i) ~equal:Poly.equal

(*
  States of the prefixes of histories, computed once: the learner asks for the options of a history, then of the
  same history with one more step, and many queries share their prefixes. The key of a prefix is the id of its
  state, given in the order states are created, and the item that extends it.
*)
module Cache (Item : sig type t [@@deriving hash, compare, sexp_of] end) = struct
  type key = int * Item.t [@@deriving hash, compare, sexp_of]

  type entry = { id : int; st : state }

  type cache = {
    gen : t;
    step : t -> state -> Item.t -> state;
    table : (key, entry) Hashtbl.t;
    options_memo : (int, option_ list) Hashtbl.t;
    root : entry;
    mutable next_id : int;
  }

  let create gen ~step =
    { gen; step; table = Hashtbl.create (module struct type t = key [@@deriving hash, compare, sexp_of] end);
      options_memo = Hashtbl.create (module Int); root = { id = 0; st = initial gen }; next_id = 1 }

  let extend c (e : entry) (item : Item.t) : entry =
    match Hashtbl.find c.table (e.id, item) with
    | Some e' -> e'
    | None ->
      let e' = { id = c.next_id; st = c.step c.gen e.st item } in
      c.next_id <- c.next_id + 1;
      Hashtbl.set c.table ~key:(e.id, item) ~data:e';
      e'

  let state_of c (items : Item.t list) : entry = List.fold items ~init:c.root ~f:(extend c)

  let options c (e : entry) =
    match Hashtbl.find c.options_memo e.id with
    | Some o -> o
    | None -> let o = options c.gen e.st in Hashtbl.set c.options_memo ~key:e.id ~data:o; o
end

(* What backends see of a state *)

(* The program of each section, in the order of the plugin's sections: the longest run of a code section, and the
   current run of a stimulus section (opaque sections have none) *)
let programs t st : (string * Value.t list) list =
  List.filter_map t.plugin.sections.sections ~f:(fun s ->
      let ss = section st s.name in
      match s.kind with
      | Code -> Some (s.name, ss.program)
      | Stimulus -> Some (s.name, List.rev ss.run)
      | Opaque -> None)

(* The position of the current run of a section: the number of atoms it has run *)
let position st name = (section st name).run_length

(*
  A key of where the test is in the spec: the current section, the saved positions and what each section accepts
  next. Two states with the same key offer the same inputs from now on, for the same observations; programs and
  runs are not in it. Backends may use it to recognise a repeated state (Sancus does, to collapse re-entries).
*)
let key st =
  let th = thread st in
  Sexp.to_string_mach
    [%sexp
      (th.current : string),
      (List.map th.saved ~f:(fun s -> (s.sname, s.at.deriv)) : (string * Spec.body) list),
      (Map.to_alist (Map.map st.sections ~f:(fun s -> s.deriv)) : (string * Spec.body) list),
      (st.status : status)]
