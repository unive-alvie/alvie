(*
  Tiny, the reference platform of ALVIE/Core (plugins/tiny): the backend, in pure OCaml.

  The processor runs the attacker's code or the enclave's. The attacker arms the timer (timer n) and calls the
  enclave, whose four registers start at 0. Each instruction of the enclave takes one or two cycles, and the timer
  counts them: when it expires during an instruction, the instruction completes and the interrupt is handled, with
  a latency of the cycles the instruction still ran after the timer expired. The enclave's registers are saved, the
  attacker's ISR runs, and reti resumes the enclave (once). ret returns to the attacker, which learns how many
  cycles the enclave ran since it was called or last resumed; the timer stops.

  Two leaks are planted, for the tutorial and Core's tests:
  - bz r takes two cycles if r is 0 and one otherwise: the time the enclave takes tells the secret;
  - pad r takes one cycle if r is 0 and two otherwise: bz r; pad r takes three cycles either way, but an interrupt
    in it has a latency that tells the secret (the attack of Nemesis on Sancus).

  Configuration: mitigation = constant-time makes bz and pad take two cycles whatever the register: both leaks go
  away. Variant: no-interrupts, in which the timer never expires.

  Tiny is a model, not a simulator: a step runs its atom on the backend's own state, and Core's programs of the
  sections are not needed (a simulator such as ALVIE/Sancus compiles them). A dry step (restore) runs the atom too:
  it is cheap, and gives the state the step would have given.
*)

open Core
open Alvie_plugin
module Backend = Alvie_backend.Backend

let plugin =
  lazy (match Plugin.load_embedded ~dir:"plugins/tiny" Tiny_plugin_files.files with
      | Ok p -> p
      | Error es -> failwith ("the embedded Tiny plugin files do not load (a bug):\n" ^ Diag.list_to_string es))

let registers = 4
type mode =
  | Attacker
  | Enclave of int array (* its registers *)
[@@deriving sexp]

type t = {
  mutable mode : mode;
  mutable timer : int option; (* cycles of the enclave until it expires *)
  mutable interrupted : int array option; (* the registers of the enclave that the timer interrupted *)
  mutable cycles : int; (* run by the enclave since it was called or resumed *)
  constant_time : bool;
  interrupts : bool;
}

type bookkeeping = unit [@@deriving sexp]

let none = ()
let capabilities = [ Backend.Restore; Clone ]

let make ~config ~variant =
  let mitigation = Option.value (List.Assoc.find config ~equal:String.equal "mitigation") ~default:"none" in
  let constant_time = match mitigation with
    | "none" -> false
    | "constant-time" -> true
    | m -> failwithf "Tiny: unknown mitigation %S (expected none or constant-time)" m () in
  let interrupts = match variant with
    | None -> true
    | Some "no-interrupts" -> false
    | Some v -> failwithf "Tiny: unknown variant %S (expected no-interrupts)" v () in
  { mode = Attacker; timer = None; interrupted = None; cycles = 0; constant_time; interrupts }

let pre t =
  t.mode <- Attacker;
  t.timer <- None;
  t.interrupted <- None;
  t.cycles <- 0

let post _ = ()
let clone t = { t with mode = (match t.mode with Attacker -> Attacker | Enclave r -> Enclave (Array.copy r)); interrupted = Option.map t.interrupted ~f:Array.copy }

let obs ?(fields = []) kind = Value.Node (kind, fields)

(* The arguments of the atoms (atoms.yaml): a register r{i} and a value, a number (the secret is one by now) *)
let reg (atom : Value.t) = match Value.path atom [ "r"; "i" ] with Some (Int i) when i >= 0 && i < registers -> i | _ -> failwithf "Tiny: no register in %s" (Value.to_string atom) ()
let value (atom : Value.t) = match Value.path atom [ "v"; "num" ] with Some (Int n) -> n | _ -> failwithf "Tiny: no number in %s (an unexpanded secret?)" (Value.to_string atom) ()

let attacker t (atom : Value.t) =
  match Value.tag atom with
  | Some "nop" -> obs "Ok"
  | Some "timer" ->
    (match Value.path atom [ "cycles" ] with
     | Some (Int n) -> if t.interrupts then t.timer <- Some n; obs "Ok"
     | _ -> failwithf "Tiny: a timer without cycles: %s" (Value.to_string atom) ())
  | Some "call" ->
    t.mode <- Enclave (Array.create ~len:registers 0);
    t.interrupted <- None;
    t.cycles <- 0;
    obs "Enter"
  | Some "reti" ->
    (match t.interrupted with
     | Some regs -> t.mode <- Enclave regs; t.interrupted <- None; t.cycles <- 0; obs "Resume"
     | None -> obs "Ok")
  | Some "halt" -> obs "Done"
  | _ -> obs "Illegal"

let enclave t regs (atom : Value.t) =
  let one_or_two zero r = if t.constant_time || Bool.equal (regs.(r) = 0) zero then 2 else 1 in
  let run cycles =
    t.cycles <- t.cycles + cycles;
    match t.timer with
    | Some left when left <= cycles ->
      t.timer <- None;
      t.interrupted <- Some regs;
      t.mode <- Attacker;
      obs "Irq" ~fields:[ ("latency", Int (cycles - left)) ]
    | Some left -> t.timer <- Some (left - cycles); obs "Run"
    | None -> obs "Run" in
  match Value.tag atom with
  | Some "nop" -> run 1
  | Some "mov" -> regs.(reg atom) <- value atom; run 1
  | Some "bz" -> run (one_or_two true (reg atom))
  | Some "pad" -> run (one_or_two false (reg atom))
  | Some "ret" ->
    let time = t.cycles + 1 in
    t.mode <- Attacker;
    t.timer <- None;
    t.cycles <- 0;
    obs "Exit" ~fields:[ ("time", Int time) ]
  | _ -> obs "Illegal"

(* The class of the atom tells whose instruction it is: an instruction that the processor cannot run in its mode
   is Illegal (Core never gives one: its phases follow the mode) *)
let class_of section =
  Option.bind (Sections_file.find (Lazy.force plugin).sections section) ~f:(fun s -> s.atoms)

let step t (s : Backend.step) =
  let o = match t.mode, class_of s.section with
    | Attacker, Some "attacker" -> attacker t s.atom
    | Enclave regs, Some "enclave" -> enclave t regs s.atom
    | _ -> obs "Illegal" in
  ([ o ], ())

let restore t s ~observations:_ () = ignore (step t s)

(* Tiny as a native plugin, for Core's generic commands *)
module Native : Alvie_backend.Native.S = struct
  let plugin = plugin

  module B = struct
    type nonrec t = t
    type nonrec bookkeeping = bookkeeping [@@deriving sexp]

    let capabilities = capabilities
    let pre = pre
    let step = step
    let restore = restore
    let clone = clone
    let post = post
  end

  let none = none
  let make = make
end
