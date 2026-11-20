(* Observables: the `observe` section of a `.vtdl` file.

   A rule maps a response line to an abstract output symbol. Rules are tried in
   order and the first match wins; the catch-all rule `_` always matches. *)
open! Core

type part =
  | Lit of string  (* literal text *)
  | Any  (* `*`: any text, possibly empty, discarded *)
  | Capture of string  (* `{x}`: non-empty text, bound to x *)
[@@deriving equal, sexp]

type rule = {
  pattern : part list option;  (* [None] is the catch-all `_` *)
  output : string;
  args : string list;  (* captured variables, in output order *)
}
[@@deriving equal, sexp]

(* Matches the whole [line]. Wildcards are tried shortest first, so a capture
   stops at the first occurrence of the literal text that follows it. *)
let match_parts parts line =
  let len = String.length line in
  let rec go parts i bindings =
    match parts with
    | [] -> if i = len then Some bindings else None
    | Lit l :: rest ->
      if String.is_substring_at line ~pos:i ~substring:l then go rest (i + String.length l) bindings
      else None
    | ((Any | Capture _) as p) :: rest ->
      let min = match p with Capture _ -> 1 | _ -> 0 in
      let rec try_len n =
        if i + n > len then None
        else
          let bindings' =
            match p with
            | Capture x -> (x, String.sub line ~pos:i ~len:n) :: bindings
            | _ -> bindings
          in
          match go rest (i + n) bindings' with
          | Some _ as r -> r
          | None -> try_len (n + 1)
      in
      try_len min
  in
  go parts 0 []

let symbol_of rule bindings =
  match rule.args with
  | [] -> rule.output
  | args ->
    let values = List.map args ~f:(fun x -> List.Assoc.find_exn bindings ~equal:String.equal x) in
    Printf.sprintf "%s(%s)" rule.output (String.concat ~sep:"," values)

(* The output symbol for [line], or [None] if no rule matches. A validated
   specification always ends with a catch-all, so it never returns [None]. *)
let classify rules line =
  List.find_map rules ~f:(fun rule ->
    match rule.pattern with
    | None -> Some rule.output
    | Some parts -> Option.map (match_parts parts line) ~f:(symbol_of rule))

let part_to_string = function
  | Lit l -> l
  | Any -> "*"
  | Capture x -> "{" ^ x ^ "}"

let rule_to_string rule =
  let lhs =
    match rule.pattern with
    | None -> "_"
    | Some parts -> "\"" ^ String.concat (List.map parts ~f:part_to_string) ^ "\""
  in
  let rhs =
    match rule.args with
    | [] -> rule.output
    | args -> Printf.sprintf "%s(%s)" rule.output (String.concat ~sep:", " args)
  in
  lhs ^ " -> " ^ rhs
