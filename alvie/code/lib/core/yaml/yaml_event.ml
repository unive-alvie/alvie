(* The events of a YAML stream that the plugin files need, as libyaml gives them. Lines and columns start at 0. *)
type pos = { line : int; col : int }

type t =
  | Stream_start
  | Stream_end
  | Document_start
  | Document_end
  | Mapping_start of { anchor : string option; tag : string option }
  | Mapping_end
  | Sequence_start of { anchor : string option; tag : string option }
  | Sequence_end
  | Scalar of { anchor : string option; tag : string option; value : string; quoted : bool }
  | Alias of { anchor : string }
