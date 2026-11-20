(* The events of the YAML files known when ALVIE was built (Yaml_table), found by the MD5 of the text *)
type t = { events : (Yaml_event.t * Yaml_event.pos) array; mutable next : int }

let create text =
  match List.assoc_opt (Digest.to_hex (Digest.string text)) Yaml_table.table with
  | Some events -> Ok { events; next = 0 }
  | None -> Error "this build of ALVIE reads only the YAML files of its plugins, and this is not one of them: use the native ALVIE"

let next t =
  if t.next >= Array.length t.events then Error "unexpected end of the YAML events"
  else (let e = t.events.(t.next) in t.next <- t.next + 1; Ok e)
