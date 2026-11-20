(* Rng gives the draws that Base v0.15 Random gave on OCaml 4.13 (recorded below with Random.init, Random.int,
   Random.float_range 0.0 1.0 and List.random_element_exn), whatever the compiler and the target. *)
let golden = [
  (0, [0; 0; 2; 5; 2; 3; 68; 322; 17802; 397056657; 3; 7], [0x1.5b5cef71c7c24p-2; 0x1.35e9d9ecff7f5p-2; 0x1.95c4063af64b3p-2; 0x1.0d8061dcb7736p-3; 0x1.1e49e99a5538fp-3; 0x1.cd0a824a3dd3bp-1], ["d"; "d"; "d"; "b"; "b"; "a"]);
  (1, [0; 0; 0; 2; 1; 41; 78; 102; 45403; 877432848; 2; 5], [0x1.df99f5802eb21p-1; 0x1.3d3e470a9b844p-2; 0x1.15032652996e1p-3; 0x1.4c1dc8826379ap-7; 0x1.859a4f3f80457p-1; 0x1.ea9cf962e0fddp-3], ["d"; "e"; "a"; "c"; "a"; "c"]);
  (42, [0; 1; 0; 3; 7; 5; 34; 1; 42971; 326811298; 1; 7], [0x1.ee7eb2043f085p-1; 0x1.c83c6a13b0311p-1; 0x1.8aabe9cb86d85p-1; 0x1.93cc625b7fb45p-1; 0x1.7a4362ffc638fp-2; 0x1.8d6fd9b6c95f1p-1], ["a"; "d"; "b"; "d"; "d"; "e"]);
  (137, [0; 0; 1; 3; 6; 8; 55; 669; 22451; 9744291; 1; 1], [0x1.3fe594b8353bdp-1; 0x1.be793fa0a9f03p-1; 0x1.ad179b11f1339p-1; 0x1.cfd8e9239a0cep-3; 0x1.8a89d6bca979fp-1; 0x1.c86fcd2f351d7p-1], ["c"; "e"; "e"; "a"; "e"; "e"]);
  (123456789, [0; 1; 0; 6; 9; 54; 78; 846; 12682; 765958084; 4; 2], [0x1.297374f5f5505p-2; 0x1.0c76e3f0703e1p-1; 0x1.205d392c278eap-3; 0x1.b567d3171271ep-2; 0x1.5099f778aa515p-3; 0x1.c87c8381d9b8ep-2], ["d"; "d"; "a"; "b"; "b"; "c"]);
]

let bounds = [ 1; 2; 3; 7; 10; 55; 100; 1000; 65536; 1073741823; 5; 9 ]

let () =
  let failures = ref 0 in
  List.iter (fun (seed, ints, floats, elems) ->
      Learninglib.Rng.init seed;
      let ints' = List.map (fun b -> Learninglib.Rng.int b) bounds in
      let floats' = List.map (fun _ -> Learninglib.Rng.float_range 0.0 1.0) [ 1; 2; 3; 4; 5; 6 ] in
      let elems' = List.map (fun _ -> Learninglib.Rng.random_element_exn [ "a"; "b"; "c"; "d"; "e" ]) [ 1; 2; 3; 4; 5; 6 ] in
      if ints <> ints' || floats <> floats' || elems <> elems' then begin
        incr failures; Printf.printf "seed %d: the draws differ from those of OCaml 4.13\n" seed
      end)
    golden;
  if !failures > 0 then exit 1 else print_endline "Rng: the draws of OCaml 4.13 for every seed"
