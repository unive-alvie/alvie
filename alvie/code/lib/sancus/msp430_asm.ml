(*
  An assembler for the MSP430 programs of ALVIE/Sancus: the subset of GNU as (and of the link with pmem.x) that the
  template (src/generic_template.s43), its includes (pmem_defs.asm, sancus_macros.asm) and the atoms use. It gives the
  memory image and the symbols that msp430-as and msp430-ld give, without running them: a program is built in
  microseconds instead of milliseconds. test/asm checks it against the toolchain on a corpus of programs.

  Supported: labels; the directives .include, .set/.equ, .global/.globl, .section, .text, .word, .byte, .macro/.endm
  (with :req and :vararg parameters), .irp/.endr; comments (; and /* */); constant expressions (numbers in decimal,
  hexadecimal, binary and octal, symbols, ., unary - ~ !, and the operators of gas with its precedence); the MSP430
  instructions in their .w and .b forms, with every addressing mode, and the instructions that gas emulates.

  As gas, an immediate uses the constant generator (r2, r3: 0, 1, 2, 4, 8, -1) when its value is an absolute
  constant already known at that point of the source (not a label, and not a symbol defined later).

  The sections are placed as pmem.x places them: .text at ~text_origin, .vectors at ~vectors_origin.
*)

open Core

exception Error of string

let error fmt = Printf.ksprintf (fun m -> raise (Error m)) fmt

(* Sources *)

(* The text without comments: ; to the end of the line, and /* ... */ (which may span lines: they are replaced by
   spaces and newlines, so that line numbers do not change) *)
let strip_comments (s : string) : string =
  let b = Buffer.create (String.length s) in
  let n = String.length s in
  let rec go i in_block in_line in_string =
    if i >= n then ()
    else
      let c = s.[i] in
      if in_block then
        if Char.equal c '*' && i + 1 < n && Char.equal s.[i + 1] '/' then (Buffer.add_string b "  "; go (i + 2) false false false)
        else (Buffer.add_char b (if Char.equal c '\n' then '\n' else ' '); go (i + 1) true false false)
      else if in_line then
        if Char.equal c '\n' then (Buffer.add_char b '\n'; go (i + 1) false false false) else go (i + 1) false true false
      else if in_string then (Buffer.add_char b c; go (i + 1) false false (not (Char.equal c '"')))
      else if Char.equal c '"' then (Buffer.add_char b c; go (i + 1) false false true)
      else if Char.equal c '/' && i + 1 < n && Char.equal s.[i + 1] '*' then (Buffer.add_string b "  "; go (i + 2) true false false)
      else if Char.equal c ';' then go (i + 1) false true false
      else (Buffer.add_char b c; go (i + 1) false false false) in
  go 0 false false false;
  Buffer.contents b

(* Expressions *)

type expr =
  | Num of int
  | Sym of string
  | Here (* . *)
  | Unop of string * expr
  | Binop of string * expr * expr

let is_sym_start c = Char.is_alpha c || Char.equal c '_' || Char.equal c '.' || Char.equal c '$'
let is_sym_char c = Char.is_alphanum c || Char.equal c '_' || Char.equal c '.' || Char.equal c '$'

let parse_number (t : string) : int =
  let t = String.lowercase t in
  try
    if String.is_prefix t ~prefix:"0x" then Int.of_string t
    else if String.is_prefix t ~prefix:"0b" then Int.of_string t
    else if String.length t > 1 && Char.equal t.[0] '0' then Int.of_string ("0o" ^ String.drop_prefix t 1)
    else Int.of_string t
  with _ -> error "bad number %s" t

(* gas: unary; then * / % << >>; then | & ^ !; then + - (and comparisons, unused here) *)
let parse_expr (s : string) : expr =
  let n = String.length s in
  let pos = ref 0 in
  let skip () = while !pos < n && Char.is_whitespace s.[!pos] do incr pos done in
  let peek () = skip (); if !pos < n then Some s.[!pos] else None in
  let starts p = skip (); String.is_substring_at s ~pos:!pos ~substring:p in
  let rec primary () =
    match peek () with
    | Some '(' -> incr pos; let e = level3 () in (match peek () with Some ')' -> incr pos; e | _ -> error "missing ) in %S" s)
    | Some '-' -> incr pos; Unop ("-", primary ())
    | Some '~' -> incr pos; Unop ("~", primary ())
    | Some '!' -> incr pos; Unop ("!", primary ())
    | Some '+' -> incr pos; primary ()
    | Some c when Char.is_digit c ->
      let st = !pos in
      while !pos < n && Char.is_alphanum s.[!pos] do incr pos done;
      Num (parse_number (String.sub s ~pos:st ~len:(!pos - st)))
    | Some '.' when !pos + 1 >= n || not (is_sym_char s.[!pos + 1]) -> incr pos; Here
    | Some c when is_sym_start c ->
      let st = !pos in
      while !pos < n && is_sym_char s.[!pos] do incr pos done;
      (match String.sub s ~pos:st ~len:(!pos - st) with
       | "$" -> Here (* as ., in gas for the MSP430 *)
       | name -> Sym name)
    | _ -> error "bad expression %S" s
  and level1 () =
    let rec loop l =
      if starts "<<" then (pos := !pos + 2; loop (Binop ("<<", l, primary ())))
      else if starts ">>" then (pos := !pos + 2; loop (Binop (">>", l, primary ())))
      else match peek () with
        | Some ('*' | '/' | '%' as c) -> incr pos; loop (Binop (String.of_char c, l, primary ()))
        | _ -> l in
    loop (primary ())
  and level2 () =
    let rec loop l =
      match peek () with
      | Some ('|' | '&' | '^' as c) when not (starts "||" || starts "&&") -> incr pos; loop (Binop (String.of_char c, l, level1 ()))
      | Some '!' -> incr pos; loop (Binop ("!", l, level1 ()))
      | _ -> l in
    loop (level1 ())
  and level3 () =
    let rec loop l =
      match peek () with
      | Some ('+' | '-' as c) -> incr pos; loop (Binop (String.of_char c, l, level2 ()))
      | _ -> l in
    loop (level2 ()) in
  let e = level3 () in
  skip ();
  if !pos <> n then error "bad expression %S" s;
  e

(* A value: absolute, or an address in a section (a label) *)
type value = Abs of int | Rel of string * int

type symbol = { value : value }

type env = {
  symbols : (string, symbol) Hashtbl.t;
  aliases : (string, expr) Hashtbl.t; (* a .set whose value was not known yet (a symbol defined later): as gas *)
  mutable section : string;
  mutable here : int; (* the offset in the current section *)
}

(* The value of an expression, if every symbol in it is defined; ~resolve gives the address of a section *)
let rec eval ?(resolve : (string -> int) option) (env : env) (e : expr) : value option =
  let abs v = match v, resolve with
    | Abs n, _ -> Some n
    | Rel (sec, off), Some r -> Some (r sec + off)
    | Rel _, None -> None in
  match e with
  | Num n -> Some (Abs n)
  | Here -> Some (Rel (env.section, env.here))
  | Sym s ->
    (match Hashtbl.find env.symbols s with
     | Some sy -> Some sy.value
     | None ->
       (* an alias is evaluated without itself, so that a cycle is an undefined symbol *)
       Option.bind (Hashtbl.find env.aliases s) ~f:(fun e ->
           Hashtbl.remove env.aliases s;
           let v = eval ?resolve env e in
           Hashtbl.set env.aliases ~key:s ~data:e;
           v))
  | Unop (op, a) ->
    Option.bind (Option.bind (eval ?resolve env a) ~f:abs) ~f:(fun x ->
        Some (Abs (match op with "-" -> -x | "~" -> lnot x | _ -> if x = 0 then 1 else 0)))
  | Binop (op, a, b) ->
    (match eval ?resolve env a, eval ?resolve env b with
     | Some va, Some vb ->
       (match op, va, vb with
        (* a label plus or minus a constant stays a label; two labels of a section subtract to a constant *)
        | "+", Rel (s, x), Abs y | "+", Abs y, Rel (s, x) when Option.is_none resolve -> Some (Rel (s, x + y))
        | "-", Rel (s, x), Abs y when Option.is_none resolve -> Some (Rel (s, x - y))
        | "-", Rel (s, x), Rel (s', y) when String.equal s s' -> Some (Abs (x - y))
        | _ ->
          (match abs va, abs vb with
           | Some x, Some y ->
             Some (Abs (match op with
                 | "+" -> x + y | "-" -> x - y | "*" -> x * y
                 | "/" -> if y = 0 then error "division by zero" else x / y
                 | "%" -> if y = 0 then error "division by zero" else x mod y
                 | "<<" -> x lsl y | ">>" -> x asr y
                 | "|" -> x lor y | "&" -> x land y | "^" -> x lxor y | "!" -> x lor (lnot y)
                 | _ -> error "operator %s" op))
           | _ -> None))
     | _ -> None)

(* Instructions *)

let registers =
  [ ("pc", 0); ("sp", 1); ("sr", 2); ("cg", 3) ] @ List.init 16 ~f:(fun i -> (sprintf "r%d" i, i))

let register s = List.Assoc.find registers ~equal:String.equal (String.lowercase (String.strip s))

type operand =
  | Reg of int
  | Indexed of expr * int (* x(Rn) *)
  | Absolute of expr (* &x *)
  | Symbolic of expr (* x, relative to the PC *)
  | Indirect of int (* @Rn *)
  | Autoinc of int (* @Rn+ *)
  | Immediate of expr (* #x *)

let parse_operand (s : string) : operand =
  let s = String.strip s in
  if String.is_empty s then error "missing operand";
  match register s with
  | Some r -> Reg r
  | None ->
    if Char.equal s.[0] '#' then Immediate (parse_expr (String.drop_prefix s 1))
    else if Char.equal s.[0] '&' then Absolute (parse_expr (String.drop_prefix s 1))
    else if Char.equal s.[0] '@' then
      let r = String.drop_prefix s 1 in
      if String.is_suffix r ~suffix:"+" then
        (match register (String.drop_suffix r 1) with Some r -> Autoinc r | None -> error "bad operand %s" s)
      else (match register r with Some r -> Indirect r | None -> error "bad operand %s" s)
    else if String.is_suffix s ~suffix:")" then
      match String.rindex s '(' with
      | Some i ->
        (match register (String.sub s ~pos:(i + 1) ~len:(String.length s - i - 2)) with
         | Some r -> Indexed (parse_expr (String.prefix s i), r)
         | None -> Symbolic (parse_expr s))
      | None -> error "bad operand %s" s
    else Symbolic (parse_expr s)

let double_ops =
  [ ("mov", 0x4); ("add", 0x5); ("addc", 0x6); ("subc", 0x7); ("sub", 0x8); ("cmp", 0x9); ("dadd", 0xA); ("bit", 0xB);
    ("bic", 0xC); ("bis", 0xD); ("xor", 0xE); ("and", 0xF) ]

let single_ops = [ ("rrc", 0); ("swpb", 1); ("rra", 2); ("sxt", 3); ("push", 4); ("call", 5) ]

let jumps =
  [ ("jne", 0); ("jnz", 0); ("jeq", 1); ("jz", 1); ("jnc", 2); ("jlo", 2); ("jc", 3); ("jhs", 3); ("jn", 4);
    ("jge", 5); ("jl", 6); ("jmp", 7) ]

(* The instructions that gas emulates, as the instruction and its operands (with $d the destination) *)
let emulated =
  [ ("nop", ("mov", Some "#0", Some "r3")); ("ret", ("mov", Some "@sp+", Some "pc")); ("dint", ("bic", Some "#8", Some "sr"));
    ("eint", ("bis", Some "#8", Some "sr")); ("setc", ("bis", Some "#1", Some "sr")); ("clrc", ("bic", Some "#1", Some "sr"));
    ("setz", ("bis", Some "#2", Some "sr")); ("clrz", ("bic", Some "#2", Some "sr")); ("setn", ("bis", Some "#4", Some "sr"));
    ("clrn", ("bic", Some "#4", Some "sr"));
    ("br", ("mov", None, Some "pc")); ("clr", ("mov", Some "#0", None)); ("inc", ("add", Some "#1", None));
    ("incd", ("add", Some "#2", None)); ("dec", ("sub", Some "#1", None)); ("decd", ("sub", Some "#2", None));
    ("tst", ("cmp", Some "#0", None)); ("inv", ("xor", Some "#-1", None)); ("pop", ("mov", Some "@sp+", None));
    ("adc", ("addc", Some "#0", None)); ("sbc", ("subc", Some "#0", None)); ("dadc", ("dadd", Some "#0", None)) ]

(* rla and rlc are add and addc of the operand to itself *)
let doubling = [ ("rla", "add"); ("rlc", "addc") ]

(* The source mode of an immediate: the constant generator if it is a known absolute constant *)
let constant_generator ~byte (v : int) : (int * int) option =
  let v = if byte then v land 0xff else v land 0xffff in
  let minus1 = if byte then 0xff else 0xffff in
  if v = 0 then Some (3, 0) else if v = 1 then Some (3, 1) else if v = 2 then Some (3, 2)
  else if v = minus1 then Some (3, 3) else if v = 4 then Some (2, 2) else if v = 8 then Some (2, 3) else None

(* The source of an instruction: (register, As, extension word) *)
type src_enc = { sreg : int; as_ : int; sext : expr option; spc_rel : bool; scg : bool }

let encode_src ~byte ~(known : expr -> int option) (o : operand) : src_enc =
  match o with
  | Reg r -> { sreg = r; as_ = 0; sext = None; spc_rel = false; scg = false }
  | Indexed (x, r) -> { sreg = r; as_ = 1; sext = Some x; spc_rel = false; scg = false }
  | Symbolic x -> { sreg = 0; as_ = 1; sext = Some x; spc_rel = true; scg = false }
  | Absolute x -> { sreg = 2; as_ = 1; sext = Some x; spc_rel = false; scg = false }
  | Indirect r -> { sreg = r; as_ = 2; sext = None; spc_rel = false; scg = false }
  | Autoinc r -> { sreg = r; as_ = 3; sext = None; spc_rel = false; scg = false }
  | Immediate x ->
    (match Option.bind (known x) ~f:(constant_generator ~byte) with
     | Some (r, a) -> { sreg = r; as_ = a; sext = None; spc_rel = false; scg = true }
     | None -> { sreg = 0; as_ = 3; sext = Some x; spc_rel = false; scg = false })

type dst_enc = { dreg : int; ad : int; dext : expr option; dpc_rel : bool }

let encode_dst (o : operand) : dst_enc =
  match o with
  | Reg r -> { dreg = r; ad = 0; dext = None; dpc_rel = false }
  | Indexed (x, r) -> { dreg = r; ad = 1; dext = Some x; dpc_rel = false }
  | Symbolic x -> { dreg = 0; ad = 1; dext = Some x; dpc_rel = true }
  | Absolute x -> { dreg = 2; ad = 1; dext = Some x; dpc_rel = false }
  | Indirect r -> { dreg = r; ad = 1; dext = Some (Num 0); dpc_rel = false } (* @Rn as destination is 0(Rn) *)
  | Autoinc _ | Immediate _ -> error "this addressing mode is not allowed for a destination"

(* An item of a section: a word computed in the second pass *)
type item =
  | Word of int (* known *)
  | Ext of expr * bool (* an extension word: the expression, and whether it is relative to its own address *)
  | Expr_word of expr (* .word *)
  | Jump of int * expr (* the opcode with the condition, and the target *)
  | Byte of expr

type section = { name : string; mutable items : (int * item) list (* offset, item; last first *); mutable size : int }

type image = {
  words : (int * int) list; (* address, 16-bit word, ascending *)
  symbols : (string * int) list; (* every symbol with its value (labels: their address) *)
  sections : (string * int * int) list; (* name, address, size in bytes *)
}

(* Splits the arguments of a directive or instruction at the commas that are not in parentheses or strings *)
let split_args (s : string) : string list =
  let s = String.strip s in
  if String.is_empty s then []
  else
    let parts = ref [] and depth = ref 0 and cur = Buffer.create 16 and in_str = ref false in
    String.iter s ~f:(fun c ->
        if !in_str then (Buffer.add_char cur c; if Char.equal c '"' then in_str := false)
        else match c with
          | '"' -> in_str := true; Buffer.add_char cur c
          | '(' -> incr depth; Buffer.add_char cur c
          | ')' -> decr depth; Buffer.add_char cur c
          | ',' when !depth = 0 -> parts := Buffer.contents cur :: !parts; Buffer.clear cur
          | c -> Buffer.add_char cur c);
    parts := Buffer.contents cur :: !parts;
    List.rev_map !parts ~f:String.strip

type macro = { params : (string * [ `Req | `Opt | `Vararg ]) list; body : string list }

let assemble ~(read_include : string -> string) ~text_origin ~vectors_origin ?(defsyms = []) (source : string) : image =
  let env = { symbols = Hashtbl.create (module String); aliases = Hashtbl.create (module String); section = ".text"; here = 0 } in
  List.iter defsyms ~f:(fun (k, v) -> Hashtbl.set env.symbols ~key:k ~data:{ value = Abs v });
  let sections = Hashtbl.create (module String) in
  let section name =
    Hashtbl.find_or_add sections name ~default:(fun () -> { name; items = []; size = 0 }) in
  let macros = Hashtbl.create (module String) in
  let emit item size =
    let sec = section env.section in
    sec.items <- (env.here, item) :: sec.items;
    env.here <- env.here + size;
    sec.size <- env.here in
  let switch name = (section env.section).size <- env.here; env.section <- name; env.here <- (section name).size in
  (* an absolute constant already defined at this point, for the constant generator *)
  let known e = match eval env e with Some (Abs n) -> Some n | _ -> None in
  let define name v =
    Hashtbl.set env.symbols ~key:name ~data:{ value = v } in
  let instruction mnemonic (args : string list) =
    let m = String.lowercase mnemonic in
    let byte, base =
      if String.is_suffix m ~suffix:".b" then (true, String.drop_suffix m 2)
      else if String.is_suffix m ~suffix:".w" then (false, String.drop_suffix m 2)
      else (false, m) in
    let double op src dst =
      let s = encode_src ~byte ~known (parse_operand src) and d = encode_dst (parse_operand dst) in
      let w = (op lsl 12) lor (s.sreg lsl 8) lor (d.ad lsl 7) lor ((if byte then 1 else 0) lsl 6) lor (s.as_ lsl 4) lor d.dreg in
      emit (Word w) 2;
      Option.iter s.sext ~f:(fun x -> emit (Ext (x, s.spc_rel)) 2);
      Option.iter d.dext ~f:(fun x -> emit (Ext (x, d.dpc_rel)) 2) in
    match List.Assoc.find double_ops ~equal:String.equal base, args with
    | Some op, [ src; dst ] -> double op src dst
    | Some _, _ -> error "%s needs two operands" m
    | None, _ ->
      match List.Assoc.find single_ops ~equal:String.equal base, args with
      | Some op, [ a ] ->
        let s = encode_src ~byte ~known (parse_operand a) in
        (* as gas: push takes #4 and #8 as a word, not from r2 (the MSP430 erratum of push with the constant
           generator) *)
        let s = if String.equal base "push" && s.scg && s.sreg = 2 then
            (match parse_operand a with Immediate x -> { sreg = 0; as_ = 3; sext = Some x; spc_rel = false; scg = false } | _ -> s)
          else s in
        (* as gas: an immediate in a word of the instructions that take an address (all but push) must be even *)
        (match parse_operand a with
         | Immediate x when not s.scg && not byte && not (String.equal base "push") ->
           Option.iter (known x) ~f:(fun v -> if v land 1 <> 0 then error "odd operand: %d" v)
         | _ -> ());
        let w = 0x1000 lor (op lsl 7) lor ((if byte then 1 else 0) lsl 6) lor (s.as_ lsl 4) lor s.sreg in
        emit (Word w) 2;
        Option.iter s.sext ~f:(fun x -> emit (Ext (x, s.spc_rel)) 2)
      | Some _, _ -> error "%s needs one operand" m
      | None, _ ->
        if String.equal base "reti" then emit (Word 0x1300) 2
        else match List.Assoc.find jumps ~equal:String.equal base, args with
          | Some c, [ t ] -> emit (Jump (0x2000 lor (c lsl 10), parse_expr t)) 2
          | Some _, _ -> error "%s needs one operand" m
          | None, _ ->
            match List.Assoc.find doubling ~equal:String.equal base, args with
            | Some op, [ a ] -> double (List.Assoc.find_exn double_ops ~equal:String.equal op) a a
            | _ ->
              match List.Assoc.find emulated ~equal:String.equal base with
              | Some (op, src, dst) ->
                let opcode = List.Assoc.find_exn double_ops ~equal:String.equal op in
                (match src, dst, args with
                 | Some s, Some d, [] -> double opcode s d
                 | None, Some d, [ s ] -> double opcode s d
                 | Some s, None, [ d ] -> double opcode s d
                 | _ -> error "bad operands for %s" m)
              | None -> error "unknown instruction %s" m in
  (* Statements: one per line *)
  let rec statements (lines : string list) =
    match lines with
    | [] -> ()
    | line :: rest ->
      let line = String.strip line in
      if String.is_empty line then statements rest
      else
        (* labels at the start *)
        let rec labels line =
          match String.lfindi line ~f:(fun _ c -> not (is_sym_char c)) with
          | Some i when i > 0 && Char.equal line.[i] ':' ->
            define (String.prefix line i) (Rel (env.section, env.here));
            labels (String.strip (String.drop_prefix line (i + 1)))
          | _ -> line in
        let line = labels line in
        if String.is_empty line then statements rest
        else
          let word, args =
            match String.lfindi line ~f:(fun _ c -> Char.is_whitespace c) with
            | Some i -> (String.prefix line i, String.strip (String.drop_prefix line i))
            | None -> (line, "") in
          let lw = String.lowercase word in
          match lw with
          | ".macro" ->
            let name, params = match String.lsplit2 args ~on:' ' with
              | Some (n, p) -> (n, p) | None -> (args, "") in
            let params =
              String.split_on_chars params ~on:[ ','; ' '; '\t' ]
              |> List.filter ~f:(fun p -> not (String.is_empty p))
              |> List.map ~f:(fun p -> match String.lsplit2 p ~on:':' with
                  | Some (n, "req") -> (n, `Req) | Some (n, "vararg") -> (n, `Vararg) | Some (n, _) -> (n, `Opt)
                  | None -> (p, `Opt)) in
            let rec body acc = function
              | [] -> error "missing .endm of %s" name
              | l :: ls ->
                if String.equal (String.lowercase (String.strip l)) ".endm" then (List.rev acc, ls) else body (l :: acc) ls in
            let b, rest = body [] rest in
            Hashtbl.set macros ~key:name ~data:{ params; body = b };
            statements rest
          | ".irp" ->
            let var, values = match split_args args with
              | v :: vs -> (String.strip v, List.concat_map vs ~f:(fun x -> String.split x ~on:' ' |> List.filter ~f:(fun s -> not (String.is_empty s))))
              | [] -> error ".irp needs a variable" in
            let rec body acc = function
              | [] -> error "missing .endr"
              | l :: ls -> if String.equal (String.lowercase (String.strip l)) ".endr" then (List.rev acc, ls) else body (l :: acc) ls in
            let b, rest = body [] rest in
            List.iter values ~f:(fun v ->
                statements (List.map b ~f:(fun l -> String.substr_replace_all l ~pattern:("\\" ^ var) ~with_:v)));
            statements rest
          | _ ->
            directive_or_instruction lw word args;
            statements rest
  and directive_or_instruction lw word args =
    match lw with
    | ".include" ->
      let file = String.strip args |> String.strip ~drop:(Char.equal '"') in
      statements (String.split_lines (strip_comments (read_include file)))
    | ".set" | ".equ" ->
      (match split_args args with
       | [ name; e ] ->
         let e' = parse_expr e in
         (match eval env e' with
          | Some v -> Hashtbl.remove env.aliases name; define name v
          | None -> Hashtbl.remove env.symbols name; Hashtbl.set env.aliases ~key:name ~data:e')
       | _ -> error "bad %s %s" word args)
    | ".global" | ".globl" -> ()
    | ".text" -> switch ".text"
    | ".section" ->
      (match split_args args with
       | name :: _ -> switch name
       | [] -> error ".section needs a name")
    | ".word" -> List.iter (split_args args) ~f:(fun e -> emit (Expr_word (parse_expr e)) 2)
    | ".byte" -> List.iter (split_args args) ~f:(fun e -> emit (Byte (parse_expr e)) 1)
    | _ when Char.equal (String.get lw 0) '.' -> error "unsupported directive %s" word
    | _ ->
      match Hashtbl.find macros word with
      | Some m ->
        let actual = split_args args in
        let rec bind params actual acc =
          match params, actual with
          | [], [] -> acc
          | [], _ -> error "too many arguments for %s" word
          | (p, `Vararg) :: _, rest -> (p, String.concat ~sep:", " rest) :: acc
          | (p, `Req) :: _, [] -> error "missing argument %s of %s" p word
          | (p, `Opt) :: ps, [] -> bind ps [] ((p, "") :: acc)
          | (p, _) :: ps, a :: rest -> bind ps rest ((p, a) :: acc) in
        let bindings = bind m.params actual [] |> List.sort ~compare:(fun (a, _) (b, _) -> Int.compare (String.length b) (String.length a)) in
        statements (List.map m.body ~f:(fun l ->
            List.fold bindings ~init:l ~f:(fun l (p, v) -> String.substr_replace_all l ~pattern:("\\" ^ p) ~with_:v)))
      | None -> instruction word (split_args args) in
  statements (String.split_lines (strip_comments source));
  (section env.section).size <- env.here;
  (* Placement, as pmem.x *)
  let origin name =
    if String.equal name ".text" then text_origin
    else if String.equal name ".vectors" then vectors_origin
    else error "section %s is not placed by pmem.x (only .text and .vectors are)" name in
  let resolve = origin in
  let value_of e =
    match eval ~resolve env e with
    | Some (Abs n) -> n
    | Some (Rel (s, o)) -> resolve s + o
    | None ->
      let rec syms = function
        | Sym s -> [ s ] | Num _ | Here -> [] | Unop (_, a) -> syms a | Binop (_, a, b) -> syms a @ syms b in
      let undefined = List.filter (syms e) ~f:(fun s -> not (Hashtbl.mem env.symbols s || Hashtbl.mem env.aliases s)) in
      error "undefined symbol: %s" (String.concat ~sep:", " (if List.is_empty undefined then syms e else undefined)) in
  let bytes = Hashtbl.create (module Int) in
  Hashtbl.iter sections ~f:(fun sec ->
      let base = origin sec.name in
      List.iter (List.rev sec.items) ~f:(fun (off, item) ->
          let addr = base + off in
          let put16 w = Hashtbl.set bytes ~key:addr ~data:(w land 0xff); Hashtbl.set bytes ~key:(addr + 1) ~data:((w lsr 8) land 0xff) in
          env.section <- sec.name; env.here <- off;
          match item with
          | Word w -> put16 w
          | Expr_word e -> put16 (value_of e)
          | Byte e -> Hashtbl.set bytes ~key:addr ~data:(value_of e land 0xff)
          | Ext (e, pc_rel) ->
            let v = if pc_rel then value_of e - addr else value_of e in
            (* as gas: a word operand relative to the PC must be even *)
            if pc_rel && v land 1 <> 0 then error "odd operand: %d" (value_of e);
            put16 v
          | Jump (op, t) ->
            let off = value_of t - (addr + 2) in
            if off land 1 <> 0 || off < -1024 || off > 1022 then error "jump target out of range or odd at 0x%04x" addr;
            put16 (op lor ((off / 2) land 0x3ff))));
  let addrs = Hashtbl.keys bytes |> List.map ~f:(fun a -> a land lnot 1) |> List.dedup_and_sort ~compare:Int.compare in
  let words = List.map addrs ~f:(fun a ->
      (a, Option.value (Hashtbl.find bytes a) ~default:0 lor (Option.value (Hashtbl.find bytes (a + 1)) ~default:0 lsl 8))) in
  let symbols = (Hashtbl.to_alist env.symbols |> List.map ~f:(fun (k, s) -> (k, s.value)))
                @ List.map (Hashtbl.keys env.aliases) ~f:(fun k -> (k, Abs (value_of (Sym k))))
                |> List.map ~f:(fun (k, v) -> (k, match v with Abs n -> n land 0xffff | Rel (sec, o) -> origin sec + o))
                |> List.sort ~compare:(fun (a, _) (b, _) -> String.compare a b) in
  let sections = Hashtbl.data sections |> List.map ~f:(fun sec -> (sec.name, origin sec.name, sec.size))
                 |> List.sort ~compare:(fun (_, a, _) (_, b, _) -> Int.compare a b) in
  { words; symbols; sections }

(* The bytes of a section, little-endian, as the ELF file of the toolchain has them *)
let section_bytes (img : image) name : string =
  match List.find img.sections ~f:(fun (n, _, _) -> String.equal n name) with
  | None -> ""
  | Some (_, addr, size) ->
    let words = Int.Map.of_alist_reduce img.words ~f:(fun a _ -> a) in
    String.init size ~f:(fun i ->
        let a = addr + i in
        let w = Option.value (Map.find words (a land lnot 1)) ~default:0 in
        Char.of_int_exn (if a land 1 = 0 then w land 0xff else (w lsr 8) land 0xff))

(* The memory file that the simulator loads, as Simulator.ihex2mem writes it from the IHEX file of the toolchain: the
   words of the program memory of mem_size bytes that ends at 0xffff, 16 a line after their index (@xxxx), in upper
   case hexadecimal, 0000 where the program has nothing *)
let mem_file ~mem_size (img : image) : string =
  let num_word = mem_size / 2 in
  let offset = 65536 - mem_size in
  let arr = Array.create ~len:num_word "0000" in
  List.iter img.words ~f:(fun (a, w) ->
      let i = (a - offset) / 2 in
      if i >= 0 && i < num_word then arr.(i) <- sprintf "%04X" w);
  let buf = Buffer.create ((num_word + 1) * 6) in
  Array.iteri arr ~f:(fun i v ->
      if i % 16 = 0 then Buffer.add_string buf (sprintf "\n@%04x " i);
      Buffer.add_char buf ' ';
      Buffer.add_string buf v);
  Buffer.add_string buf "\n\n";
  Buffer.contents buf
