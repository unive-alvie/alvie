(* Regular expressions over input names, with Brzozowski derivatives.

   This is the `session` section of a `.vtdl` file. As in TestDL, an input is
   allowed after a prefix when the derivative of the expression by that input
   still has a non-empty language.

   Every expression is built through the smart constructors below. They keep
   [Empty] out of every [Seq], [Alt], and [Star], so an expression denotes the
   empty language exactly when it is [Empty]. *)
open! Core

type t =
  | Empty
  | Eps
  | Sym of string
  | Seq of t * t
  | Alt of t * t
  | Star of t
[@@deriving equal, compare, sexp]

let empty = Empty
let eps = Eps
let sym s = Sym s

let seq a b =
  match a, b with
  | Empty, _ | _, Empty -> Empty
  | Eps, r | r, Eps -> r
  | _ -> Seq (a, b)

let alt a b =
  match a, b with
  | Empty, r | r, Empty -> r
  | _ when equal a b -> a
  | _ -> Alt (a, b)

let star = function
  | Empty | Eps -> Eps
  | Star _ as r -> r
  | r -> Star r

let rec nullable = function
  | Empty | Sym _ -> false
  | Eps | Star _ -> true
  | Seq (a, b) -> nullable a && nullable b
  | Alt (a, b) -> nullable a || nullable b

let rec derive (x : string) = function
  | Empty | Eps -> Empty
  | Sym s -> if String.equal s x then Eps else Empty
  | Seq (a, b) ->
    let d = seq (derive x a) b in
    if nullable a then alt d (derive x b) else d
  | Alt (a, b) -> alt (derive x a) (derive x b)
  | Star a as r -> seq (derive x a) r

let is_empty r = equal r Empty

let allows r x = not (is_empty (derive x r))

let rec symbols = function
  | Empty | Eps -> String.Set.empty
  | Sym s -> String.Set.singleton s
  | Seq (a, b) | Alt (a, b) -> Set.union (symbols a) (symbols b)
  | Star a -> symbols a

let rec to_string = function
  | Empty -> "<empty>"
  | Eps -> "eps"
  | Sym s -> s
  | Seq (a, b) -> Printf.sprintf "(%s; %s)" (to_string a) (to_string b)
  | Alt (a, b) -> Printf.sprintf "(%s | %s)" (to_string a) (to_string b)
  | Star a -> Printf.sprintf "%s*" (to_string a)
