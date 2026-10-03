(* Learned Mealy machines: construction, DOT output, DOT input, and comparison.

   The DOT dialect is deliberately small, so that a participant can read it
   and edit it by hand:

     digraph model {
       rankdir=LR;
       __start [shape=point]; __start -> 0;
       0 [shape=circle];
       0 -> 1 [label="HELLO / OK"];
     }

   A label is `input / output`. Inputs are upper-case identifiers and contain
   no space, so the first slash with spaces around it separates the two. Quote and
   backslash characters in a label are escaped with a backslash. *)
open! Core

module M = Learninglib.Mealy.Mealy (Learninglib.Showableint.ShowableInt) (Symbol) (Symbol)

type t = M.t

(* Edges as (source, input, output, target), in a stable order. *)
let edges (m : t) =
  Map.to_alist m.transition |> List.map ~f:(fun ((s, i), (o, s')) -> s, i, o, s')

(* Removes the transitions that the `session` expression forbids, and the
   states that no remaining transition mentions. *)
let drop_illegal (m : t) : t =
  let transition = Map.filter m.transition ~f:(fun (o, _) -> not (String.equal o Symbol.illegal)) in
  let mentioned s =
    Int.equal s m.s0 || Map.existsi transition ~f:(fun ~key:(s', _) ~data:(_, s'') -> s' = s || s'' = s)
  in
  { m with transition; states = Set.filter m.states ~f:mentioned }

let escape s =
  String.concat_map s ~f:(function '"' -> "\\\"" | '\\' -> "\\\\" | c -> String.of_char c)

let unescape s =
  let buf = Buffer.create (String.length s) in
  let rec go i =
    if i < String.length s then
      if Char.equal s.[i] '\\' && i + 1 < String.length s then (
        Buffer.add_char buf s.[i + 1];
        go (i + 2))
      else (
        Buffer.add_char buf s.[i];
        go (i + 1))
  in
  go 0;
  Buffer.contents buf

let to_dot (m : t) : string =
  let b = Buffer.create 1024 in
  Buffer.add_string b "digraph model {\n  rankdir=LR;\n";
  bprintf b "  __start [shape=point]; __start -> %d;\n" m.s0;
  Set.iter m.states ~f:(fun s -> bprintf b "  %d [shape=circle];\n" s);
  List.iter (edges m) ~f:(fun (s, i, o, s') ->
    bprintf b "  %d -> %d [label=\"%s\"];\n" s s' (escape (i ^ " / " ^ o)));
  Buffer.add_string b "}\n";
  Buffer.contents b

exception Parse_error of int * string

(* Parses the output of [to_dot]. Lines it does not recognise are errors, so a
   file that is not a model produced by ALVIE is rejected rather than misread. *)
let of_dot (text : string) : t =
  let edge_of_line lineno line =
    let fail msg = raise (Parse_error (lineno, msg)) in
    match String.substr_index line ~pattern:"->" with
    | None -> fail "expected a transition `a -> b [label=\"input / output\"];`"
    | Some k ->
      let src = String.strip (String.sub line ~pos:0 ~len:k) in
      let rest = String.sub line ~pos:(k + 2) ~len:(String.length line - k - 2) in
      (match String.lsplit2 rest ~on:'[' with
       | None -> fail "missing [label=\"...\"]"
       | Some (dst, attrs) ->
         let dst = String.strip dst in
         let label =
           match String.substr_index attrs ~pattern:"label=\"" with
           | None -> fail "missing label"
           | Some p ->
             let start = p + 7 in
             let rec close i =
               if i >= String.length attrs then fail "unterminated label"
               else if Char.equal attrs.[i] '\\' then close (i + 2)
               else if Char.equal attrs.[i] '"' then i
               else close (i + 1)
             in
             unescape (String.sub attrs ~pos:start ~len:(close start - start))
         in
         (match String.substr_index label ~pattern:" / " with
          | None -> fail (sprintf "label %S is not `input / output`" label)
          | Some p ->
            let input = String.sub label ~pos:0 ~len:p in
            let output = String.sub label ~pos:(p + 3) ~len:(String.length label - p - 3) in
            let state s = try Int.of_string s with _ -> fail (sprintf "state %S is not a number" s) in
            state src, input, output, state dst))
  in
  let lines = String.split_lines text in
  let s0 = ref 0 and edges = ref [] and header = ref false in
  List.iteri lines ~f:(fun idx raw ->
    let lineno = idx + 1 in
    let line = String.strip raw in
    let is_state_decl = (not (String.is_empty line)) && Char.is_digit line.[0]
                        && String.is_substring line ~substring:"[" && not (String.is_substring line ~substring:"->") in
    if String.is_empty line || String.equal line "}" || String.is_prefix line ~prefix:"rankdir" || is_state_decl then ()
    else if String.is_prefix line ~prefix:"digraph" then
      if String.is_suffix line ~suffix:"{" then header := true
      else raise (Parse_error (lineno, "put the opening brace at the end of the digraph line and each transition on its own line"))
    else if String.is_prefix line ~prefix:"__start" then (
      match String.substr_index line ~pattern:"-> " with
      | Some k ->
        let target = String.chop_suffix_if_exists (String.strip (String.drop_prefix line (k + 3))) ~suffix:";" in
        (match Int.of_string_opt target with
         | Some n -> s0 := n
         | None -> raise (Parse_error (lineno, sprintf "initial state %S is not a number" target)))
      | None -> ())
    else edges := edge_of_line lineno line :: !edges);
  if not !header then raise (Parse_error (1, "expected a first line like `digraph model {`"));
  let edges = List.rev !edges in
  let states = List.fold edges ~init:(Int.Set.singleton !s0) ~f:(fun acc (s, _, _, s') -> Set.add (Set.add acc s) s') in
  let alphabet = List.map edges ~f:(fun (_, i, _, _) -> i) in
  let transition =
    List.fold edges ~init:M.TransitionMap.empty ~f:(fun acc (s, i, o, s') ->
      match Map.add acc ~key:(s, i) ~data:(o, s') with
      | `Ok acc -> acc
      | `Duplicate -> raise (Parse_error (0, sprintf "state %d has two transitions on %s: not a Mealy machine" s i)))
  in
  M.make
    ~states:(M.SSet.of_list (Set.to_list states))
    ~s0:!s0
    ~input_alphabet:(M.ISet.of_list alphabet)
    ~transition

(* --- Comparison --- *)

type difference = {
  inputs : Symbol.t list;  (* a shortest input sequence on which the models disagree *)
  left : Symbol.t list;  (* outputs of the left model along it *)
  right : Symbol.t list;
}

(* Breadth-first search of the product automaton. Returns the shortest
   distinguishing sequences, at most [limit] of them, one per pair of states
   where the outputs first differ. An input that one model lacks is ignored,
   because the models are partial where `session` forbids an input. *)
let differences ?(limit = 10) (a : t) (b : t) : difference list =
  let inputs = Set.to_list (Set.union (M.input_alphabet a) (M.input_alphabet b)) in
  let seen = Hash_set.Poly.create () in
  let queue = Queue.create () in
  Queue.enqueue queue (a.s0, b.s0, []);
  Hash_set.add seen (a.s0, b.s0);
  let found = ref [] in
  while (not (Queue.is_empty queue)) && List.length !found < limit do
    let sa, sb, path = Queue.dequeue_exn queue in
    List.iter inputs ~f:(fun i ->
      match M.transition a (sa, i), M.transition b (sb, i) with
      | Some (oa, ta), Some (ob, tb) ->
        let path' = (i, oa, ob) :: path in
        if not (String.equal oa ob) then (
          if List.length !found < limit then (
            let p = List.rev path' in
            found := { inputs = List.map p ~f:(fun (i, _, _) -> i);
                       left = List.map p ~f:(fun (_, o, _) -> o);
                       right = List.map p ~f:(fun (_, _, o) -> o) } :: !found))
        else if not (Hash_set.mem seen (ta, tb)) then (
          Hash_set.add seen (ta, tb);
          Queue.enqueue queue (ta, tb, path'))
      | _ -> ())
  done;
  List.rev !found
