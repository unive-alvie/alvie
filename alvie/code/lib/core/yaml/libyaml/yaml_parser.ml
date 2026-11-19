(* The events of libyaml (through the yaml library) *)
type t = Yaml.Stream.parser

let create text = match Yaml.Stream.parser text with Ok p -> Ok p | Error (`Msg m) -> Error m

let event : Yaml.Stream.Event.t -> Yaml_event.t option = function
  | Stream_start _ -> Some Stream_start
  | Stream_end -> Some Stream_end
  | Document_start _ -> Some Document_start
  | Document_end _ -> Some Document_end
  | Mapping_start { anchor; tag; _ } -> Some (Mapping_start { anchor; tag })
  | Mapping_end -> Some Mapping_end
  | Sequence_start { anchor; tag; _ } -> Some (Sequence_start { anchor; tag })
  | Sequence_end -> Some Sequence_end
  | Scalar { anchor; tag; value; style; _ } ->
    let quoted = match style with `Single_quoted | `Double_quoted | `Literal | `Folded -> true | _ -> false in
    Some (Scalar { anchor; tag; value; quoted })
  | Alias { anchor } -> Some (Alias { anchor })
  | Nothing -> None

let next p =
  match Yaml.Stream.do_parse p with
  | Error (`Msg m) -> Error m
  | Ok (e, (pos : Yaml.Stream.Event.pos)) ->
    match event e with
    | Some e -> Ok (e, { Yaml_event.line = pos.start_mark.line; col = pos.start_mark.column })
    | None -> Error "unexpected end of the YAML events"
