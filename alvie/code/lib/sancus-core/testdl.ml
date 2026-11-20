(*
This module implements a small DSL (called TestDL) for describing attackers and enclaves capabilities.

Each program has four sections:
  - Enclave section: lists the available instructions and parameters
  - ISR, prepare and cleanup sections: specify the class of "interesting" attackers

In particular, for attackers:
  Given a program in the DSL C, we learn an automaton M_C that describes how the enclave behaves under the attackers the
  program C may generate. We can iterate this approach collecting a set of automata { M_C } for C in some set of DSL
  programs. These automata will be useful afterwords.

  Under a few conditions, these attackers can be combined into sequences of multiple attackes. Also, attackers can be
  added iteratively as they are described, given that the set of new attackers include the set of old ones.
*)

open! Core

open Common
open Angstrom

open Attacker
open Enclave

(*
  TODO: update this

  We borrow some notation from the classic definition of regexps (no extensions).
  The abstract syntax is as follows:
    spec ::= enclave (v, ..., v) { body }; isr { body }; prepare { body }; cleanup { body };
    body ::= empty | ε | atom | body; body | body|body | body*
    atom ::= rst | jin ts | create <ts, te, ds, de> | timer_enable t | inst
    inst ::= nop | mov src dst | jmp next

  where
    ts, te, ds, de in string
    src has the form ?, ri or @ri for min_r <= i < max_r
    dst has the form ?, ri or &ri for min_r <= i < max_r
    t is a word
    v is a word
    next is ri for min_r <= i < max_r

    ? gets expended to the listed values of v and becomes an immediate value (i.e., #v)

  (To simplify parsing and avoid ambiguities, the concrete syntax actually is:
    spec ::= isr { body }; prepare { body }; cleanup { body };
    body ::= action | action|body
    action ::= ε | factor | factor; action
    factor ::=  atom | atom*
    atom ::= rst | jin ts | create <ts, te, ds, de> | timer_enable t | inst | reti | ( body )
    inst ::= jmp next | nop | mov src dst
  )
*)
type test_spec_t = enclave_t * isr_t * prepare_t * cleanup_t [@@deriving eq,ord,sexp,show { with_path = false }]
  and enclave_t = Enclave of Enclave.body_t [@@deriving eq,ord,sexp]
  and isr_t = ISR of Attacker.body_t [@@deriving eq,ord,sexp]
  and prepare_t = Prepare of Attacker.body_t [@@deriving eq,ord,sexp]
  and cleanup_t = Cleanup of Attacker.body_t [@@deriving eq,ord,sexp]

module ParserUtils = struct
  (* Utility stuff *)
  let whitespace = take_while (function | '\x20' | '\x0a' | '\x0d' | '\x09' -> true | _ -> false) <?> "whitespace"
  let ident = take_while (function | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> true | _ -> false) <?> "ident"
  let integer = take_while1 (function '0' .. '9' -> true | _ -> false) <?> "integer"
  let reg = (char 'r' <|> char 'R') *> integer >>=
    (fun idx -> let idx = int_of_string idx in (if idx >= 0 && idx <= 14 then return (R idx) else fail "Register index out of bounds!")) <?> "reg"
  let src_operand = (char '@' *> reg >>| (fun pr -> S_AT pr)) <|> (char '&' *> ident >>| (fun pr -> S_AMP pr)) <|> (char '#' *> (ident <|> integer) >>| (fun pr -> S_IMM pr)) <|> (reg >>| fun pr -> S_R pr) <|> (char '?' *> return S_SECRET) <?> "src_operand"
  let dst_operand = ((char '&' *> reg >>| (fun pr -> D_AMP pr)) <|> (char '&' *> ident >>| (fun pr -> D_AMP_MEM pr))) <|> (reg >>| fun pr -> D_R pr) <?> "dst_operand"

  let parens p = char '(' *> whitespace *> p <* whitespace <* char ')' <?> "parens"

  let instnop = (string "nop" *> return (I_NOP)) <?> "instnop"
  let instdint = (string "dint" *> return (I_DINT)) <?> "instdint"
  let instjmp = (string "jmp" *> whitespace *> src_operand >>| (fun l -> (I_JMP l))) <?> "instjmp"
  let instpush = (string "push" *> whitespace *> src_operand >>| (fun l -> (I_PUSH l))) <?> "instpush"
  let instmov = (string "mov" *> whitespace *> src_operand >>= (fun src -> (whitespace *> char ',' *> whitespace *> dst_operand >>| (fun dst -> (I_MOV (src, dst))))))  <?> "instmov"
  let instadd = (string "add" *> whitespace *> src_operand >>= (fun src -> (whitespace *> char ',' *> whitespace *> dst_operand >>| (fun dst -> (I_ADD (src, dst))))))  <?> "instadd"
  let instcmp = (string "cmp" *> whitespace *> src_operand >>= (fun src -> (whitespace *> char ',' *> whitespace *> dst_operand >>| (fun dst -> (I_CMP (src, dst)))))) <?> "instcmp"
  let inst = (instnop <|> instdint <|> instjmp <|> instpush <|> instmov <|> instadd <|> instcmp)  <?> "inst"
end

module ParserAttacker = struct
  open ParserUtils

  let atrst = (string "rst" *> return (Attacker.Atom CRst)) <?> "atrst"

  let atrst_nz = (string "rst_nz" *> return (Attacker.Atom CRstNZ)) <?> "atrst_nz"

  let atjin = (string "jin" *> whitespace *> ident >>= (fun ts -> return (Attacker.Atom (CJmpIn ts)))) <?> "atjin"

  let atcreate =
    (string "create" *>
      (whitespace *> char '<' *>
        (both
          (count 3 (whitespace *> ident <* whitespace <* char ','))
          (whitespace *> ident <* whitespace))
      <* char '>') >>=
      (function | ([ts; te; ds], de) -> return (Attacker.Atom (CCreateEncl (ts, te, ds, de))) | _ -> fail "Never happens")) <?> "atcreate"

  let attimer_enable =
    (string "timer_enable" *> whitespace *> integer >>= (fun v -> let v = int_of_string v in
      (if v >= 0 && v < 65536 then return (Attacker.Atom (CTimerEnable v))
      else (fail "timer_enable: delay is too long")))) <?> "attimer_enable"

  let atstart_counting =
    (string "start_counting" *> whitespace *> integer >>= (fun v -> let v = int_of_string v in
      (if v >= 0 && v < 65536 then return (Attacker.Atom (CStartCounting v))
      else (fail "start_counting: delay is too long")))) <?> "atstart_counting"

  let atinst = inst >>= (fun i ->
    return (Attacker.Atom (CInst i))
  ) <?> "atinst"

  let atreti = (string "reti" *> return (Attacker.Atom (CReti))) <?> "atreti"

  let single_atom = (atrst_nz <|> atrst <|> atjin <|> atcreate <|> attimer_enable <|> atstart_counting <|> atreti <|> atinst) <?> "single_atom"

  let list_atom = many (whitespace *> single_atom <* whitespace <* char ';') >>= (fun il -> whitespace *> single_atom <* whitespace >>= (fun i -> return (List.map ~f:(function Attacker.Atom a -> a | _ -> failwith "Parsing list_atom, this should never happen!") (il @ [i]) )))

  let atifz = (string "ifz" *> whitespace *> parens list_atom <* whitespace >>= (fun il1 ->
      whitespace *> parens list_atom <* whitespace >>=
        (
          fun il2 -> return (Attacker.Atom (CIfZ (il1, il2)))
        )
      )
    ) <?> "atifz"

  let all_atoms = (atrst_nz <|> atrst <|> atjin <|> atcreate <|> attimer_enable <|> atstart_counting <|> atreti <|> atinst <|> atifz) <?> "all_atoms_attacker"

  (* Components for body *)
  let bdchoice p p' = (both (p <* whitespace <* char '|' <* whitespace) p' >>| (fun (r, r') -> Attacker.Choice (r, r'))) <?> "bdchoice"

  (* Components for action *)
  let acteps = (string "eps" *> return Attacker.Epsilon) <?> "acteps"
  let actseq p p' = (p >>= (fun r -> (whitespace *> char ';' *> whitespace) *> p' >>| (fun r' -> Attacker.Seq (r, r')))) <?> "actseq"

  (* Components for factor *)
  let facatom p = (p >>| (fun a -> Attacker.Atom a)) <?> "facatom"
  let facstar p = ((p <* char '*') >>| (fun a -> Attacker.Star a)) <?> "facstar"

  (* All parsers are parametrized by body, otherwise we would have no way of having mutually recursive definitions *)
  let atom body = (atifz <|> atrst_nz <|> atrst <|> atjin <|> atcreate <|> attimer_enable <|> atstart_counting <|> atreti <|> atinst <|> (parens body)) <?> "atom"

  let factor body = ((facstar (atom body)) <|> (atom body)) <?> "factor"

  let action body = (fix (fun _action -> acteps <|> (actseq (factor body) _action) <|> (factor body))) <?> "action"

  let body = fix (fun _body -> (bdchoice (action _body) _body) <|> (action _body)) <?> "body"

  let section sn = (string sn <?> "header") *> whitespace *> char '{' *> whitespace *> body <* whitespace <* (string "};" <?> "};") <?> (sprintf "section_%s" sn)
end

module ParserEnclave = struct
  open ParserUtils

  (* (Aggregate) actions for enclaves *)
  let atinst = inst >>= (fun i ->
    return (Enclave.Atom (CInst i))
    (* return (Enclave.inst_of_pa (Enclave.PAInst i)) *)
  ) <?> "atinst"

  let atubr = (string "ubr" *>
    return (Enclave.Atom (Enclave.CUbr))
    (* return (Enclave.inst_of_pa (Enclave.PAUbr)) *)
  ) <?> "atubr"

  let atrst = (string "rst" *> return (Enclave.Atom CRst)) <?> "atrst"

  let list_inst = many (whitespace *> inst <* whitespace <* char ';') >>= (fun il -> whitespace *> inst <* whitespace >>= (fun i -> return (il @ [i])))

  let atbalanced_ifz =
    (* Define a parse for sequence; We do not use here actseq because we want a list as output! *)
    (string "balanced_ifz" *> whitespace *> (parens list_inst) <* whitespace >>=
      (
        fun i ->
          return (Enclave.Atom (CBalancedIfZ i))
          (* return (Enclave.inst_of_pa (Enclave.PAZeroOrNop (i, int_of_string n))) *)
      )
    ) <?> "atbalanced_ifz"

  let single_atom = (atrst <|> atinst <|> atubr <|> atbalanced_ifz) <?> "single_atom"

  let list_atom = many (whitespace *> single_atom <* whitespace <* char ';') >>= (fun il -> whitespace *> single_atom <* whitespace >>= (fun i -> return (List.map ~f:(function Enclave.Atom a -> a | _ -> failwith "Parsing list_atom, this should never happen!") (il @ [i]) )))

  let atifz = (string "ifz" *> whitespace *> parens list_atom <* whitespace >>= (fun il1 ->
      whitespace *> parens list_atom <* whitespace >>=
        (
          fun il2 -> return (Enclave.Atom (CIfZ (il1, il2)))
        )
      )
    ) <?> "atifz"

  let all_atoms = (atrst <|> atinst <|> atubr <|> atbalanced_ifz <|> atifz) <?> "all_atoms_enclave"


  (* Components for body *)
  let bdchoice p p' = (both (p <* whitespace <* char '|' <* whitespace) p' >>| (fun (r, r') -> Enclave.Choice (r, r'))) <?> "bdchoice"

  (* Components for action *)
  let acteps = (string "eps" *> return Enclave.Epsilon) <?> "acteps"

  let actseq p p' = (p >>= (fun r -> (whitespace *> char ';' *> whitespace) *> p' >>| (fun r' -> Enclave.Seq (r, r')))) <?> "actseq"

  (* Components for factor *)
  let facatom p = (p >>| (fun a -> Enclave.Atom a)) <?> "facatom"
  let facstar p = ((p <* char '*') >>| (fun a -> Enclave.Star a)) <?> "facstar"

  (* All parsers are parametrized by body, otherwise we would have no way of having mutually recursive definitions *)
  let atom body = (atubr <|> atrst <|> atinst <|> atbalanced_ifz <|> atifz <|> (parens body)) <?> "atom"

  let factor body = ((facstar (atom body)) <|> (atom body)) <?> "factor"

  let action body = (fix (fun _action -> acteps <|> (actseq (factor body) _action) <|> (factor body))) <?> "action"

  let body = fix (fun _body -> (bdchoice (action _body) _body) <|> (action _body)) <?> "body"

  let section sn = (string sn <?> "header") *> whitespace *> char '{' *> whitespace *> body <* whitespace <* (string "};" <?> "};") <?> (sprintf "section_%s" sn)

(*
  (* v0 .. vn *)
  let paramlist = Angstrom.many (integer <* whitespace) >>= (fun vl -> return vl)

   let param_section sn =
    let src_expand_secret v src =
      match src with
      | S_SECRET -> S_IMM v
      | _ -> src in
    let rec inst_expand_secret (v : string) (i : Common.instruction_t) =
      match i with
      | I_NOP | I_DINT | I_JZ _ | I_JNZ _  -> i
      | I_NAMED (s, i') -> I_NAMED (s, inst_expand_secret v i')
      | I_MOV (src, dst) -> I_MOV (src_expand_secret v src, dst)
      | I_ADD (src, dst) -> I_ADD (src_expand_secret v src, dst)
      | I_CMP (src, dst) -> I_CMP (src_expand_secret v src, dst)
      | I_PUSH src -> I_PUSH (src_expand_secret v src)
      | I_JMP src -> I_JMP (src_expand_secret v src) in
    let rec body_expand_secret (v : string) (b : Enclave.body_t) =
      match b with
      | Empty | Epsilon -> b
      | Choice (l, r) -> Choice (body_expand_secret v l, body_expand_secret v r)
      | Seq (l, r) -> Seq (body_expand_secret v l, body_expand_secret v r)
      | Star b' -> Star (body_expand_secret v b')
      | Atom (CUbr) -> b
      | Atom (CInst i) -> Atom (CInst (inst_expand_secret v i))
      | Atom (CZeroOrNop (i, k)) -> Atom (CZeroOrNop (inst_expand_secret v i, k)) in
    let rec inst_no_secret (i : Common.instruction_t) =
      match i with
      | I_NAMED (_, i') -> inst_no_secret i'
      | I_MOV (S_SECRET, _) | I_ADD (S_SECRET, _) | I_CMP (S_SECRET, _) | I_PUSH S_SECRET | I_JMP S_SECRET -> false
      | _ -> true in
    let rec body_no_secret b =
      match (b : Enclave.body_t) with
      | Empty | Epsilon | Atom (CUbr) -> true
      | Choice (l, r) | Seq (l, r) -> body_no_secret l && body_no_secret r
      | Star b' -> body_no_secret b'
      | Atom (CInst i) | Atom (CZeroOrNop (i, _)) -> inst_no_secret i in
    (string sn <?> "param header") *> whitespace *> char '(' *> whitespace *> paramlist <* whitespace <* char ')' >>=
    (fun vl -> char '{' *> whitespace *> body <* whitespace <* (string "};" <?> "};")
      >>= (fun b ->
            match vl with
            | [] -> assert (body_no_secret b); return [b]
            | vl -> return (List.map vl ~f:(fun v -> body_expand_secret v b))
          )
    ) <?> (sprintf "section_%s" sn) *)
end

module Parser = struct
  open ParserUtils

  (*
    Quick and dirty parse to make the life easier.
    We expect traces to be ;-separated inputs.
    Each input starts with att: or enc: to specify who performs the action and is followed by an atom of such category
  *)
  let attack_trace =
    let att_parser = Angstrom.string "att:" *> whitespace *> ParserAttacker.all_atoms >>= (function (Atom at) -> return (Input.IAttacker at) | _ -> failwith "Attack trace, attacker action is not an atom") in
    let encl_parser = Angstrom.string "enc:" *> whitespace *> ParserEnclave.all_atoms >>= (function (Atom at) -> return (Input.IEnclave at) | _ -> failwith "Attack trace, enclave action is not an atom") in
    let comb_parser = att_parser <|> encl_parser in
    many (whitespace *> comb_parser <* whitespace <* char ';') >>= (fun il -> whitespace *> comb_parser <* whitespace >>= (fun i -> return (il @ [i])))

  let spec =
    (whitespace *> ParserEnclave.section "enclave") >>=
      (fun enclave ->
        (whitespace *> ParserAttacker.section "isr") >>=
          (fun isr ->
            ((whitespace *> ParserAttacker.section "prepare") >>=
              (fun prep ->
                ((whitespace *> ParserAttacker.section "cleanup" <* whitespace) >>|
                  (fun cleanup ->
                      (Enclave enclave, ISR isr, Prepare prep, Cleanup cleanup)
                ))
            ))
          )
      )

  let parse_spec = parse_string ~consume:All spec
  let parse_attack_trace = parse_string ~consume:All attack_trace
end
