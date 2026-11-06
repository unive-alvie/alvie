(*
  YAML documents as trees whose nodes know where they are in the file, for precise error messages.

  The plugin files use a small subset of YAML: one document of mappings, sequences and scalars. Anchors, aliases and
  tags are rejected: they are not needed, and aliases can make a small file expand into a huge one.

  Scalars keep whether they were quoted. libyaml implements YAML 1.1, where unquoted yes, no, on, off, y and n are
  booleans; in YAML 1.2 (and in most editors) they are strings. Core rejects them unquoted (see Shape), so that a
  file means the same thing everywhere.
*)

open Core

type node = { desc : desc; pos : Diag.pos }
and desc =
  | Scalar of { value : string; quoted : bool }
  | Seq of node list
  | Map of (node * node) list

let describe n =
  match n.desc with
  | Scalar { value = ""; quoted = false } -> "an empty value"
  | Scalar { value; _ } -> sprintf "the scalar %S" value
  | Seq _ -> "a list"
  | Map _ -> "a mapping"

let parse ~file (text : string) : (node, Diag.t) result =
  let pos_of (p : Yaml.Stream.Event.pos) = { Diag.file; line = p.start_mark.line + 1; col = p.start_mark.column + 1 } in
  let start = { Diag.file; line = 1; col = 1 } in
  let fail ?(pos = start) fmt = Printf.ksprintf (fun m -> Error (Diag.error ~pos m)) fmt in
  match Yaml.Stream.parser text with
  | Error (`Msg m) -> fail "cannot read the YAML: %s" m
  | Ok parser ->
    let next () =
      match Yaml.Stream.do_parse parser with
      | Ok (e, p) -> Ok (e, pos_of p)
      | Error (`Msg m) -> fail "invalid YAML: %s" m in
    let open Result.Let_syntax in
    (* Reads one node whose first event is e *)
    let rec node (e : Yaml.Stream.Event.t) pos : (node, Diag.t) result =
      match e with
      | Scalar { anchor = Some a; _ } | Mapping_start { anchor = Some a; _ } | Sequence_start { anchor = Some a; _ } ->
        fail ~pos "YAML anchors (&%s) are not supported in plugin files" a
      | Alias { anchor } -> fail ~pos "YAML aliases (*%s) are not supported in plugin files" anchor
      | Scalar { tag = Some t; _ } | Mapping_start { tag = Some t; _ } | Sequence_start { tag = Some t; _ } ->
        fail ~pos "YAML tags (%s) are not supported in plugin files" t
      | Scalar s ->
        let quoted = match s.style with `Single_quoted | `Double_quoted | `Literal | `Folded -> true | _ -> false in
        Ok { desc = Scalar { value = s.value; quoted }; pos }
      | Sequence_start _ ->
        let rec items acc =
          let%bind e, p = next () in
          match e with
          | Sequence_end -> Ok (List.rev acc)
          | _ -> let%bind n = node e p in items (n :: acc) in
        let%map items = items [] in
        { desc = Seq items; pos }
      | Mapping_start _ ->
        let rec members acc =
          let%bind e, p = next () in
          match e with
          | Mapping_end -> Ok (List.rev acc)
          | _ ->
            let%bind k = node e p in
            let%bind e', p' = next () in
            let%bind v = node e' p' in
            members ((k, v) :: acc) in
        let%bind members = members [] in
        (* Duplicate keys are an error in YAML, but libyaml accepts them *)
        let rec check seen = function
          | [] -> Ok ()
          | ({ desc = Scalar { value; _ }; pos }, _) :: rest ->
            if List.mem seen value ~equal:String.equal then fail ~pos "the key %S appears twice in this mapping" value
            else check (value :: seen) rest
          | _ :: rest -> check seen rest in
        let%map () = check [] members in
        { desc = Map members; pos }
      | _ -> fail ~pos "invalid YAML: unexpected structure" in
    let%bind e, _ = next () in
    let%bind () = match e with Stream_start _ -> Ok () | _ -> fail "invalid YAML stream" in
    let%bind e, p = next () in
    (match e with
     | Stream_end -> Ok { desc = Map []; pos = start } (* an empty file is an empty mapping *)
     | Document_start _ ->
       let%bind e, p = next () in
       let%bind root = node e p in
       let%bind e, _ = next () in
       let%bind () = match e with Document_end _ -> Ok () | _ -> fail ~pos:p "invalid YAML document" in
       let%bind e, p = next () in
       (match e with
        | Stream_end -> Ok root
        | _ -> fail ~pos:p "a plugin file holds a single YAML document (remove the second ---)")
     | _ -> fail ~pos:p "invalid YAML stream")

let parse_file file =
  match In_channel.read_all file with
  | text -> parse ~file text
  | exception Sys_error m -> Error (Diag.errorf "cannot read %s: %s" file m)

(* The members of a mapping whose keys are plain scalars *)
let keys members = List.filter_map members ~f:(fun (k, _) -> match k.desc with Scalar { value; _ } -> Some value | _ -> None)
