(* Parser and validator for VaultLink TestDL (`.vtdl`) specifications.

   A specification has four sections, in this order; `values` may be omitted:

     values  { name = "text"; ... };
     inputs  { NAME = "command with {name}"; ... };
     observe { "pattern" -> OUTPUT; ...; _ -> OUTPUT; };
     session { regular expression over input names };

   Comments are written `(* ... *)` and may be nested. The language is
   described for users in `design/vaultlink-language.md`. *)
open! Core

type position = { line : int; column : int } [@@deriving equal, sexp]

exception Error of position * string

let error_message ({ line; column }, msg) = Printf.sprintf "line %d, column %d: %s" line column msg

let fail pos fmt = Printf.ksprintf (fun msg -> raise (Error (pos, msg))) fmt

type t = {
  values : (string * string) list;
  inputs : (string * string) list;  (* input name, concrete command line *)
  observe : Observe.rule list;
  session : Session.t;
}
[@@deriving sexp]

(* Transport meta-commands of the service; they must not appear as inputs. *)
let meta_commands = [ "RESET"; "HELP"; "QUIT" ]

(* --- Lexer --- *)

type token =
  | IDENT of string
  | STRING of string
  | LBRACE
  | RBRACE
  | LPAREN
  | RPAREN
  | SEMI
  | COMMA
  | EQUALS
  | ARROW
  | BAR
  | STAR
  | UNDERSCORE
  | EOF

let describe = function
  | IDENT s -> Printf.sprintf "'%s'" s
  | STRING s -> Printf.sprintf "string \"%s\"" s
  | LBRACE -> "'{'"
  | RBRACE -> "'}'"
  | LPAREN -> "'('"
  | RPAREN -> "')'"
  | SEMI -> "';'"
  | COMMA -> "','"
  | EQUALS -> "'='"
  | ARROW -> "'->'"
  | BAR -> "'|'"
  | STAR -> "'*'"
  | UNDERSCORE -> "'_'"
  | EOF -> "end of file"

let is_ident_start c = Char.is_alpha c
let is_ident_char c = Char.is_alphanum c || Char.equal c '_' || Char.equal c '-'

let tokenize (src : string) : (token * position) array =
  let len = String.length src in
  let line = ref 1 and line_start = ref 0 in
  let pos_at i = { line = !line; column = i - !line_start + 1 } in
  let newline i = incr line; line_start := i + 1 in
  let tokens = Queue.create () in
  let rec skip_comment start i depth =
    if i >= len then fail start "unterminated comment"
    else if i + 1 < len && Char.equal src.[i] '(' && Char.equal src.[i + 1] '*' then skip_comment start (i + 2) (depth + 1)
    else if i + 1 < len && Char.equal src.[i] '*' && Char.equal src.[i + 1] ')' then
      if depth = 1 then i + 2 else skip_comment start (i + 2) (depth - 1)
    else (
      if Char.equal src.[i] '\n' then newline i;
      skip_comment start (i + 1) depth)
  in
  let rec lex_string start buf i =
    if i >= len then fail start "unterminated string"
    else
      match src.[i] with
      | '"' -> i + 1
      | '\n' -> fail start "unterminated string: strings cannot span lines"
      | '\\' when i + 1 < len && (Char.equal src.[i + 1] '"' || Char.equal src.[i + 1] '\\') ->
        Buffer.add_char buf src.[i + 1];
        lex_string start buf (i + 2)
      | c ->
        Buffer.add_char buf c;
        lex_string start buf (i + 1)
  in
  let rec go i =
    if i >= len then Queue.enqueue tokens (EOF, pos_at i)
    else
      let p = pos_at i in
      let single tok = Queue.enqueue tokens (tok, p); go (i + 1) in
      match src.[i] with
      | '\n' -> newline i; go (i + 1)
      | ' ' | '\t' | '\r' -> go (i + 1)
      | '(' when i + 1 < len && Char.equal src.[i + 1] '*' -> go (skip_comment p (i + 2) 1)
      | '{' -> single LBRACE
      | '}' -> single RBRACE
      | '(' -> single LPAREN
      | ')' -> single RPAREN
      | ';' -> single SEMI
      | ',' -> single COMMA
      | '=' -> single EQUALS
      | '|' -> single BAR
      | '*' -> single STAR
      | '-' when i + 1 < len && Char.equal src.[i + 1] '>' ->
        Queue.enqueue tokens (ARROW, p);
        go (i + 2)
      | '"' ->
        let buf = Buffer.create 16 in
        let next = lex_string p buf (i + 1) in
        Queue.enqueue tokens (STRING (Buffer.contents buf), p);
        go next
      | '_' when i + 1 >= len || not (is_ident_char src.[i + 1]) -> single UNDERSCORE
      | c when is_ident_start c ->
        let j = ref i in
        while !j < len && is_ident_char src.[!j] do incr j done;
        Queue.enqueue tokens (IDENT (String.sub src ~pos:i ~len:(!j - i)), p);
        go !j
      | c -> fail p "unexpected character '%c'" c
  in
  go 0;
  Queue.to_array tokens

(* --- Parser --- *)

type parser = { tokens : (token * position) array; mutable index : int }

let peek p = fst p.tokens.(p.index)
let peek_pos p = snd p.tokens.(p.index)
let advance p = if p.index < Array.length p.tokens - 1 then p.index <- p.index + 1

let expect p tok what =
  if Poly.equal (peek p) tok then advance p
  else fail (peek_pos p) "expected %s %s, found %s" (describe tok) what (describe (peek p))

let ident p what =
  match peek p with
  | IDENT s ->
    let pos = peek_pos p in
    advance p;
    s, pos
  | t -> fail (peek_pos p) "expected %s, found %s" what (describe t)

let string_lit p what =
  match peek p with
  | STRING s ->
    let pos = peek_pos p in
    advance p;
    s, pos
  | t -> fail (peek_pos p) "expected %s, found %s" what (describe t)

let is_symbol_name s =
  Char.is_uppercase s.[0] && String.for_all s ~f:(fun c -> Char.is_uppercase c || Char.is_digit c || Char.equal c '_')

let section p name body =
  (match peek p with
   | IDENT s when String.equal s name -> advance p
   | t -> fail (peek_pos p) "expected section '%s', found %s" name (describe t));
  expect p LBRACE ("after '" ^ name ^ "'");
  let result = body () in
  expect p RBRACE ("to close section '" ^ name ^ "'");
  expect p SEMI ("after section '" ^ name ^ "'");
  result

(* Splits "ID {me}" into text and value references, and substitutes the values. *)
let substitute values pos template =
  let buf = Buffer.create (String.length template) in
  let len = String.length template in
  let rec go i =
    if i >= len then ()
    else if Char.equal template.[i] '{' then (
      match String.index_from template i '}' with
      | None -> fail pos "unclosed '{' in \"%s\"" template
      | Some j ->
        let name = String.sub template ~pos:(i + 1) ~len:(j - i - 1) in
        (match List.Assoc.find values ~equal:String.equal name with
         | Some v -> Buffer.add_string buf v
         | None ->
           if String.is_empty name then fail pos "empty '{}' in \"%s\"" template
           else fail pos "unknown value '%s' in \"%s\"; declare it in the 'values' section" name template);
        go (j + 1))
    else if Char.equal template.[i] '}' then fail pos "unmatched '}' in \"%s\"" template
    else (
      Buffer.add_char buf template.[i];
      go (i + 1))
  in
  go 0;
  Buffer.contents buf

let parse_values p =
  let rec go acc =
    match peek p with
    | RBRACE -> List.rev acc
    | _ ->
      let name, pos = ident p "a value name" in
      if List.Assoc.mem acc ~equal:String.equal name then fail pos "value '%s' is declared twice" name;
      expect p EQUALS ("after value name '" ^ name ^ "'");
      let v, _ = string_lit p ("the text of value '" ^ name ^ "'") in
      expect p SEMI ("after value '" ^ name ^ "'");
      go ((name, v) :: acc)
  in
  go []

let parse_inputs values p =
  let rec go acc =
    match peek p with
    | RBRACE ->
      if List.is_empty acc then fail (peek_pos p) "the 'inputs' section must declare at least one input";
      List.rev acc
    | _ ->
      let name, pos = ident p "an input name" in
      if not (is_symbol_name name) then
        fail pos "input name '%s' must be upper case, for example '%s'" name (String.uppercase name);
      if List.Assoc.mem acc ~equal:String.equal name then fail pos "input '%s' is declared twice" name;
      if List.mem meta_commands name ~equal:String.equal then
        fail pos "'%s' is a transport meta-command and cannot be an input" name;
      expect p EQUALS ("after input name '" ^ name ^ "'");
      let template, tpos = string_lit p ("the command of input '" ^ name ^ "'") in
      let command = substitute values tpos template in
      (match String.split command ~on:' ' |> List.filter ~f:(Fn.non String.is_empty) with
       | [] -> fail tpos "the command of input '%s' is empty" name
       | verb :: _ when List.mem meta_commands (String.uppercase verb) ~equal:String.equal ->
         fail tpos "'%s' is a transport meta-command; ALVIE sends RESET itself between queries" verb
       | _ -> ());
      expect p SEMI ("after input '" ^ name ^ "'");
      go ((name, command) :: acc)
  in
  go []

let parse_pattern pos s =
  let len = String.length s in
  let parts = Queue.create () in
  let lit = Buffer.create 16 in
  let flush () =
    if Buffer.length lit > 0 then (
      Queue.enqueue parts (Observe.Lit (Buffer.contents lit));
      Buffer.clear lit)
  in
  let wildcard part =
    flush ();
    (match Queue.last parts with
     | Some (Observe.Any | Observe.Capture _) ->
       fail pos "in \"%s\": two wildcards in a row must be separated by literal text" s
     | _ -> ());
    Queue.enqueue parts part
  in
  let rec go i =
    if i >= len then flush ()
    else
      match s.[i] with
      | '*' -> wildcard Observe.Any; go (i + 1)
      | '{' ->
        (match String.index_from s i '}' with
         | None -> fail pos "unclosed '{' in pattern \"%s\"" s
         | Some j ->
           let x = String.sub s ~pos:(i + 1) ~len:(j - i - 1) in
           if String.is_empty x || not (is_ident_start x.[0] && String.for_all x ~f:is_ident_char) then
             fail pos "'{%s}' in pattern \"%s\" is not a valid capture name" x s;
           if Queue.exists parts ~f:(function Observe.Capture y -> String.equal x y | _ -> false) then
             fail pos "capture '{%s}' appears twice in pattern \"%s\"" x s;
           wildcard (Observe.Capture x);
           go (j + 1))
      | '}' -> fail pos "unmatched '}' in pattern \"%s\"" s
      | c -> Buffer.add_char lit c; go (i + 1)
  in
  go 0;
  Queue.to_list parts

let parse_observe p =
  let rec args acc =
    let x, pos = ident p "a capture name" in
    let acc = (x, pos) :: acc in
    match peek p with
    | COMMA -> advance p; args acc
    | _ -> List.rev acc
  in
  let rec go acc catch_all =
    match peek p with
    | RBRACE ->
      if Option.is_none catch_all then
        fail (peek_pos p) "the 'observe' section must end with a catch-all rule, such as: _ -> OTHER;";
      List.rev acc
    | _ ->
      (match catch_all with
       | Some cpos ->
         fail (peek_pos p) "this rule is never used: the catch-all rule at line %d already matches every response"
           cpos.line
       | None -> ());
      let rule_pos = peek_pos p in
      let pattern =
        match peek p with
        | UNDERSCORE -> advance p; None
        | STRING s -> advance p; Some (parse_pattern rule_pos s)
        | t -> fail rule_pos "expected a pattern string or '_', found %s" (describe t)
      in
      expect p ARROW "after the pattern";
      let output, opos = ident p "an output name" in
      if not (is_symbol_name output) then
        fail opos "output name '%s' must be upper case, for example '%s'" output (String.uppercase output);
      if List.mem Symbol.reserved_outputs output ~equal:String.equal then
        fail opos "'%s' is reserved for ALVIE's own outputs" output;
      let args =
        match peek p with
        | LPAREN ->
          advance p;
          let a = args [] in
          expect p RPAREN ("to close the arguments of '" ^ output ^ "'");
          a
        | _ -> []
      in
      let captured = match pattern with
        | None -> []
        | Some parts -> List.filter_map parts ~f:(function Observe.Capture x -> Some x | _ -> None) in
      List.iter args ~f:(fun (x, pos) ->
        if not (List.mem captured x ~equal:String.equal) then
          fail pos "'%s' is not captured by this rule's pattern; write {%s} in the pattern" x x);
      expect p SEMI "after the rule";
      let rule = { Observe.pattern; output; args = List.map args ~f:fst } in
      go (rule :: acc) (if Option.is_none pattern then Some rule_pos else None)
  in
  go [] None

let parse_session inputs p =
  let rec alternation () =
    let left = sequence () in
    match peek p with
    | BAR -> advance p; Session.alt left (alternation ())
    | _ -> left
  and sequence () =
    let left = postfix () in
    match peek p with
    | SEMI ->
      advance p;
      (* A trailing ';' before the closing brace or parenthesis is accepted. *)
      (match peek p with
       | RBRACE | RPAREN -> left
       | _ -> Session.seq left (sequence ()))
    | _ -> left
  and postfix () =
    let rec stars r = match peek p with STAR -> advance p; stars (Session.star r) | _ -> r in
    stars (atom ())
  and atom () =
    match peek p with
    | IDENT "eps" -> advance p; Session.eps
    | IDENT name ->
      let pos = peek_pos p in
      if not (List.Assoc.mem inputs ~equal:String.equal name) then
        fail pos "'%s' is not declared in the 'inputs' section" name;
      advance p;
      Session.sym name
    | LPAREN ->
      advance p;
      let r = alternation () in
      expect p RPAREN "to close the group";
      r
    | t -> fail (peek_pos p) "expected an input name, 'eps', or '(', found %s" (describe t)
  in
  alternation ()

let parse (src : string) : t =
  let p = { tokens = tokenize src; index = 0 } in
  let values =
    match peek p with
    | IDENT "values" -> section p "values" (fun () -> parse_values p)
    | _ -> []
  in
  let inputs = section p "inputs" (fun () -> parse_inputs values p) in
  let observe = section p "observe" (fun () -> parse_observe p) in
  let session = section p "session" (fun () -> parse_session inputs p) in
  (match peek p with
   | EOF -> ()
   | t -> fail (peek_pos p) "unexpected %s after the 'session' section" (describe t));
  { values; inputs; observe; session }

let parse_result src = try Ok (parse src) with Error (pos, msg) -> Error (pos, msg)

(* Problems that do not prevent learning but probably indicate a mistake. *)
let warnings (spec : t) =
  let used = Session.symbols spec.session in
  let unused =
    List.filter_map spec.inputs ~f:(fun (name, _) ->
      if Set.mem used name then None
      else Some (Printf.sprintf "input '%s' never appears in 'session', so it is never sent" name))
  in
  let session_empty =
    if Session.is_empty spec.session then [ "the 'session' expression accepts no input sequence" ] else []
  in
  unused @ session_empty
