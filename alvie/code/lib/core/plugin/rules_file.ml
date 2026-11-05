(*
  phases.yaml and view.yaml: rules over observations, with structured matching.

  A rule matches an observation by its kind (match: a kind or a list of kinds; all kinds if absent), by the current
  section (in: a section or a list; phase rules only) and by the values of fields (when: { field: value, ... }, all
  of them; a field of a record field is written with a dot, e.g. time.mode). The first rule that matches applies.

  phases.yaml says how observations move the system between sections:

    format: 1
    rules:
      - { match: Diverge, do: [{ stop: finished }] }
      - { match: Reset, in: enclave, do: [reset, { enter: cleanup }] }
      - { match: Reti, when: { mode: PM }, do: [resume] }

  Actions: restart (the test starts afresh: the platform rebooted, and the programs of the sections can be new), reset
  (every section starts again, with the same programs), { enter: S } (S starts again and becomes current), { switch: S } (S
  becomes current where it was), { interrupt: S } (the current section is saved and S is entered), resume (the last
  saved section becomes current where it was), { stop: finished } or { stop: invalid }. do: [] changes nothing.

  view.yaml says what the attacker sees of each observation:

    format: 1
    rules:
      - { when: { mode: PM }, show: hidden }
      - { match: [JmpIn, Reti], show: { fields: [gie, mode] } }
      - { match: Reset, show: tag }
      - { match: Diverge, show: distinct }

  show: hidden (the attacker sees nothing: the observation is silent), tag (only its kind), { fields: [...] } (its
  kind and these fields), distinct (never equal to another observation, so always reported), all (everything).
  The match: key is named so because YAML 1.1 reads an unquoted on: as a boolean.
*)

open Core
open Shape

type cond = { path : string list; value : string; kpos : Diag.pos; cpos : Diag.pos }

type stop = Finished | Invalid [@@deriving sexp, equal]

type action =
  | Restart
  | Reset
  | Enter of string
  | Switch of string
  | Interrupt of string
  | Resume
  | Stop of stop
[@@deriving sexp, equal]

type show = Hidden | Tag | Fields of string list list | Distinct | All [@@deriving sexp, equal]

type 'a rule = { kinds : string list option; sections : string list option; when_ : cond list; effect : 'a; pos : Diag.pos }

let when_shape =
  Shape.map_value (Shape.map (Shape.with_pos (Shape.string ())))
    ~f:(List.map ~f:(fun (key, kpos, (value, cpos)) -> { path = String.split key ~on:'.'; value; kpos; cpos }))

let action_shape : action Shape.t =
  let scalar = Shape.enum [ ("restart", Restart); ("reset", Reset); ("resume", Resume) ] in
  let structured =
    let open Obj in
    Shape.map_result
      (obj ~what:"an action"
         (let+ enter = opt "enter" (Shape.string ()) ~doc:"The section starts again and becomes current"
          and+ switch = opt "switch" (Shape.string ()) ~doc:"The section becomes current where it was"
          and+ interrupt = opt "interrupt" (Shape.string ()) ~doc:"The current section is saved, and this one is entered"
          and+ stop = opt "stop" (enum [ ("finished", Finished); ("invalid", Invalid) ]) ~doc:"The test stops" in
          (enter, switch, interrupt, stop)))
      ~f:(fun n -> function
          | Some s, None, None, None -> Ok (Enter s)
          | None, Some s, None, None -> Ok (Switch s)
          | None, None, Some s, None -> Ok (Interrupt s)
          | None, None, None, Some s -> Ok (Stop s)
          | _ -> fail n "an action has exactly one of enter, switch, interrupt and stop") in
  by_kind ~what:"an action" ~scalar ~map:structured () ~doc:"restart, reset, resume, { enter: S }, { switch: S }, { interrupt: S } or { stop: finished | invalid }"

let show_shape : show Shape.t =
  let scalar = Shape.enum [ ("hidden", Hidden); ("tag", Tag); ("distinct", Distinct); ("all", All) ] in
  let fields =
    let open Obj in
    obj ~what:"{ fields: [...] }"
      (let+ fs = req "fields" (Shape.list (Shape.string ())) ~doc:"The fields that the attacker sees" in
       Fields (List.map fs ~f:(String.split ~on:'.'))) in
  by_kind ~what:"what the attacker sees" ~scalar ~map:fields () ~doc:"hidden, tag, distinct, all or { fields: [...] }"

let rule_shape ~with_sections ~effect_name ~effect_doc (effect : 'a Shape.t) : 'a rule Shape.t =
  let open Obj in
  Shape.with_pos
    (obj ~what:"a rule"
       (let+ kinds = opt "match" (one_or_list (Shape.string ())) ~doc:"The kinds of observations the rule applies to (all if absent)"
        and+ sections = (if with_sections then opt "in" (one_or_list (Shape.string ())) ~doc:"The current sections the rule applies in (all if absent)" else pure None)
        and+ when_ = dflt "when" [] when_shape ~doc:"The values of fields the rule requires"
        and+ effect = req effect_name effect ~doc:effect_doc in
        (kinds, sections, when_, effect)))
  |> Shape.map_value ~f:(fun ((kinds, sections, when_, effect), pos) -> { kinds; sections; when_; effect; pos })

let file_shape ~what rule =
  let open Obj in
  obj ~what
    (let+ _ = req "format" (Shape.int ~min:1 ~max:1 ()) ~doc:"The version of the format of this file: 1"
     and+ rules = req "rules" (Shape.list rule) ~doc:"The rules, in order: the first that matches applies" in
     rules)

let phases_shape = file_shape ~what:"a phases file" (rule_shape ~with_sections:true ~effect_name:"do" ~effect_doc:"The actions, in order" (Shape.list action_shape))
let view_shape = file_shape ~what:"a view file" (rule_shape ~with_sections:false ~effect_name:"show" ~effect_doc:"What the attacker sees" show_shape)

type phases = action list rule list
type view = show rule list

let load_phases ~file : (phases, Diag.t list) Result.t = Shape.parse_file phases_shape file
let load_view ~file : (view, Diag.t list) Result.t = Shape.parse_file view_shape file
let load_phases_string ~file text = Shape.parse_string phases_shape ~file text
let load_view_string ~file text = Shape.parse_string view_shape ~file text
