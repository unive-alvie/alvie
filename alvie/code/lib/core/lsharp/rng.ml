(*
  The random numbers of ALVIE: the generator of the standard library of OCaml 4.13 (Random.State, a lagged
  Fibonacci generator seeded through MD5) and the functions of Base v0.15 on top of it, copied here so that a seed
  gives the same numbers, hence the same models, on every compiler and target. OCaml 5 replaced the generator of
  Random (LXM), so Random gave other numbers, and other models, for the same seed; results/ and the attack
  catalogue were learned with OCaml 4.13.

  Every value is masked to 30 bits, as in the original: the numbers are the same with 63-bit integers (native) and
  with 31-bit integers (wasm_of_ocaml). ALVIE draws its random choices only from here; seed them with [init].
*)

type t = { st : int array; mutable idx : int }

(* OCaml 4.13, Random.State.full_init *)
let full_init s seed =
  let combine accu x = Stdlib.Digest.string (accu ^ Stdlib.Int.to_string x) in
  let extract d =
    Char.code d.[0] + (Char.code d.[1] lsl 8) + (Char.code d.[2] lsl 16) + (Char.code d.[3] lsl 24) in
  let seed = if Array.length seed = 0 then [| 0 |] else seed in
  let l = Array.length seed in
  for i = 0 to 54 do s.st.(i) <- i done;
  let accu = ref "x" in
  for i = 0 to 54 + Stdlib.max 55 l do
    let j = i mod 55 and k = i mod l in
    accu := combine !accu seed.(k);
    s.st.(j) <- (s.st.(j) lxor extract !accu) land 0x3FFFFFFF
  done;
  s.idx <- 0

let make seed = let s = { st = Array.make 55 0; idx = 0 } in full_init s seed; s

(* 30 random bits, 0 <= x < 2^30 (OCaml 4.13, Random.State.bits) *)
let bits s =
  s.idx <- (s.idx + 1) mod 55;
  let curval = s.st.(s.idx) in
  let newval = s.st.((s.idx + 24) mod 55) + (curval lxor ((curval lsr 25) land 0x1F)) in
  let newval30 = newval land 0x3FFFFFFF in
  s.st.(s.idx) <- newval30;
  newval30

(* 0 <= x < bound, for 0 < bound <= 2^30 - 1 (OCaml 4.13, Random.State.int) *)
let rec intaux s n = let r = bits s in let v = r mod n in if r - v > 0x3FFFFFFF - n + 1 then intaux s n else v
let int_of s bound = if bound > 0x3FFFFFFF || bound <= 0 then invalid_arg "Rng.int" else intaux s bound

(* A float in [0, 1) (Base v0.15, Random.State.rawfloat) *)
let rec rawfloat s =
  let scale = 0x1p-30 in
  let r1 = Stdlib.float_of_int (bits s) in
  let r2 = Stdlib.float_of_int (bits s) in
  let result = ((r1 *. scale) +. r2) *. scale in
  if Stdlib.( < ) result 1.0 then result else rawfloat s

(* The state of the draws of ALVIE. Before [init], as Base's default state: seeded with 137 *)
let default = make [| 137 |]

let init seed = full_init default [| seed |]
let int ?(state = default) bound = int_of state bound

(* lo <= x < hi (Base v0.15, Random.float_range) *)
let float_range ?(state = default) lo hi =
  if Stdlib.( > ) lo hi then invalid_arg "Rng.float_range" else lo +. (rawfloat state *. (hi -. lo))

(* An element of a non-empty list, each with the same probability (Base v0.15, List.random_element_exn) *)
let random_element_exn ?(state = default) = function
  | [] -> failwith "Rng.random_element_exn: empty list"
  | l -> List.nth l (int ~state (List.length l))

let random_element ?state l = match l with [] -> None | _ -> Some (random_element_exn ?state l)
