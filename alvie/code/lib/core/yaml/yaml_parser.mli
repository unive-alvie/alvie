(* A parser of a YAML text, one event at a time *)
type t

(* A parser of [text], or why the text cannot be read *)
val create : string -> (t, string) result

(* The next event and where it starts, or why the text is invalid *)
val next : t -> (Yaml_event.t * Yaml_event.pos, string) result
