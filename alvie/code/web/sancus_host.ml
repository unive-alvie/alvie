(* The host of the simulators in WebAssembly (Sancus_core.Wasm_target.host): the JavaScript object
   globalThis.alvieSancus, which has
   - files(commit): the files of the programs of the commit, as an array of [name, text];
   - run(commit, mem, vcd): runs the program of the file mem on the simulator of the commit, writes its trace in the
     file vcd, and gives the status (the files are in the file system of the program: Node's, or the page's).
   The page, or the Node runner (web/node/alvie-web.cjs), makes it before the program starts. *)
open Js_of_ocaml

let install () =
  let obj () : Js.Unsafe.any =
    let o = Js.Unsafe.global##.alvieSancus in
    if Js.Optdef.test o then o else failwith "Sancus: no simulator in WebAssembly (globalThis.alvieSancus is missing)" in
  Sancus_core.Wasm_target.host :=
    Some
      { files = (fun ~commit ->
            let a : Js.Unsafe.any Js.js_array Js.t = Js.Unsafe.meth_call (obj ()) "files" [| Js.Unsafe.inject (Js.string commit) |] in
            Array.to_list (Js.to_array a) |> List.map (fun pair ->
                let p : Js.js_string Js.t Js.js_array Js.t = Js.Unsafe.coerce pair in
                match Js.to_array p with
                | [| name; text |] -> (Js.to_string name, Js.to_string text)
                | _ -> failwith "Sancus: files(commit) must give pairs [name, text]"));
        run = (fun ~commit ~mem ~vcd ->
            Js.Unsafe.meth_call (obj ()) "run"
              [| Js.Unsafe.inject (Js.string commit); Js.Unsafe.inject (Js.string mem); Js.Unsafe.inject (Js.string vcd) |]
            |> Js.float_of_number |> int_of_float) }
