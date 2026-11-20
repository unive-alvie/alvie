(*
  The host of alvie-web, in JavaScript (this file when js_of_ocaml is installed, see dune; host.none.ml otherwise).

  The host gives, as JavaScript globals:
  - alvieSancus, the simulators of ALVIE/Sancus in WebAssembly (Sancus_core.Wasm_target.host), with
    files(commit): the files of the programs of the commit, as an array of [name, text], and run(commit, mem, vcd):
    runs the program of the file mem on the simulator of the commit, writes its trace in the file vcd, and gives the
    status (the files are in the file system of the program: Node's, or the page's);
  - alvieArgv: the arguments of the command (an array of strings; default: the argv of the program, as in Node);
  - alvieFiles: files to write before the command runs, an object from path to text;
  - alvieCollect: paths of files to read when the command ends (e.g. the model it learned);
  - alvieDone(files): called when the command ends (its output says how), with the files of alvieCollect that
    exist, as an object from path to text.
  The page (browser/worker.js), or the Node runner (node/alvie-web.cjs), makes them before the program starts.
*)
open Js_of_ocaml

let global name : Js.Unsafe.any Js.Optdef.t = Js.Unsafe.get Js.Unsafe.global (Js.string name)

let install_sancus () =
  let obj () : Js.Unsafe.any =
    match Js.Optdef.to_option (global "alvieSancus") with
    | Some o -> o
    | None -> failwith "Sancus: no simulator in WebAssembly (globalThis.alvieSancus is missing)" in
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

let argv () =
  match Js.Optdef.to_option (global "alvieArgv") with
  | Some a -> "alvie" :: List.map Js.to_string (Array.to_list (Js.to_array (Js.Unsafe.coerce a)))
  | None -> "alvie" :: List.tl (Array.to_list Sys.argv)

let write_files () =
  Js.Optdef.iter (global "alvieFiles") (fun files ->
      let keys : Js.js_string Js.t Js.js_array Js.t = Js.object_keys (Js.Unsafe.coerce files) in
      Array.iter (fun key ->
          let path = Js.to_string key and text : Js.js_string Js.t = Js.Unsafe.get files key in
          Sancus_core.Step.mkdir_p (Filename.dirname path);
          Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc (Js.to_string text)))
        (Js.to_array keys))

let on_exit () =
  Js.Optdef.iter (global "alvieDone") (fun f ->
      let collected = Js.Unsafe.obj [||] in
      Js.Optdef.iter (global "alvieCollect") (fun paths ->
          Array.iter (fun p ->
              let path = Js.to_string p in
              if Sys.file_exists path then
                Js.Unsafe.set collected p (Js.string (In_channel.with_open_bin path In_channel.input_all)))
            (Js.to_array (Js.Unsafe.coerce paths)));
      ignore (Js.Unsafe.fun_call f [| Js.Unsafe.inject collected |]))
