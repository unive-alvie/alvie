(*
  The files and directories that the commands of Core use, with the Sys of OCaml's standard library only: it works
  wherever OCaml does, also in a browser (on the file system of js_of_ocaml or wasm_of_ocaml), unlike core_unix.
*)

let exists path = Stdlib.Sys.file_exists path
let is_directory path = exists path && Stdlib.Sys.is_directory path
let is_file path = exists path && not (Stdlib.Sys.is_directory path)

(* Makes the directory and its missing parents, as mkdir -p *)
let rec mkdir_p path =
  if not (exists path) then begin
    let parent = Filename.dirname path in
    if not (String.equal parent path) then mkdir_p parent;
    try Stdlib.Sys.mkdir path 0o755 with Sys_error _ when is_directory path -> ()
  end

(* The names in a directory, sorted *)
let ls_dir path = List.sort String.compare (Array.to_list (Stdlib.Sys.readdir path))
