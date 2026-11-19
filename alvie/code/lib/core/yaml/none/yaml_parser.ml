(* For builds without C code, e.g. in a browser, until they embed the events of their plugin files *)
type t = unit
let create _ = Error "this build of ALVIE cannot read YAML: use the native ALVIE"
let next () = Error "this build of ALVIE cannot read YAML"
