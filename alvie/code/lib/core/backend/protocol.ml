(*
  The protocol between ALVIE/Core and an external plugin, version 1: JSON-RPC 2.0, one message per line, on the
  plugin's standard input (requests of Core) and standard output (its answers). The plugin's standard error is its
  log: Core keeps it in a file and shows its last lines when the plugin fails.

  Core sends requests one at a time and waits for each answer; the plugin never sends requests. The methods:

    initialize  {protocol, core, plugin, config, variant}   -> {protocol, name, version, capabilities}
    pre         {instance}                                   -> {}
    step        {instance, section, position, atom, programs} -> {observations, bookkeeping}
    restore     {instance, section, position, atom, programs, observations, bookkeeping} -> {}
    clone       {instance}                                   -> {instance}
    post        {instance}                                   -> {}
    shutdown    {}                                           -> {}   (then the plugin exits)

  initialize makes instance 0; clone makes a new one, an independent copy (Backend.clone). Values (atoms, programs,
  observations) are in the JSON form of Value.to_json; programs is an object from each section to its program, a
  list of atoms. bookkeeping is any JSON value: Core keeps it and gives it back to restore, but never looks at it.

  An error is a JSON-RPC error object {code, message, data}: the plugin's message is shown to the user, and data
  (e.g. a traceback) is logged.

  This module defines the messages once: the encoders and decoders of Core, and the JSON Schema of the protocol
  (alvie plugin schemas writes it), which the Python SDK follows.
*)

open Core

let version = 1

type step = {
  instance : int;
  section : string;
  position : int;
  atom : Alvie_plugin.Value.t;
  programs : (string * Alvie_plugin.Value.t list) list;
}

let request ~id ~meth (params : Yojson.Safe.t) : Yojson.Safe.t =
  `Assoc [ ("jsonrpc", `String "2.0"); ("id", `Int id); ("method", `String meth); ("params", params) ]

let initialize_params ~core ~plugin ~config ~variant : Yojson.Safe.t =
  `Assoc [ ("protocol", `Int version); ("core", `String core); ("plugin", `String plugin);
           ("config", `Assoc (List.map config ~f:(fun (k, v) -> (k, `String v))));
           ("variant", match variant with Some v -> `String v | None -> `Null) ]

let instance_params i : Yojson.Safe.t = `Assoc [ ("instance", `Int i) ]

let step_fields (s : step) : (string * Yojson.Safe.t) list =
  let open Alvie_plugin in
  [ ("instance", `Int s.instance); ("section", `String s.section); ("position", `Int s.position);
    ("atom", Value.to_json s.atom);
    ("programs", `Assoc (List.map s.programs ~f:(fun (sec, p) -> (sec, `List (List.map p ~f:Value.to_json))))) ]

let step_params s : Yojson.Safe.t = `Assoc (step_fields s)

let restore_params s ~observations ~(bookkeeping : Yojson.Safe.t) : Yojson.Safe.t =
  `Assoc (step_fields s @ [ ("observations", `List (List.map observations ~f:Alvie_plugin.Value.to_json)); ("bookkeeping", bookkeeping) ])

(* Answers *)

type answer = Result of Yojson.Safe.t | Error of { code : int; message : string; data : Yojson.Safe.t option }

let answer_of_json ~id (j : Yojson.Safe.t) : (answer, string) Result.t =
  match j with
  | `Assoc fields ->
    let find k = List.Assoc.find fields ~equal:String.equal k in
    (match find "jsonrpc", find "id" with
     | Some (`String "2.0"), Some (`Int id') when id' = id ->
       (match find "result", find "error" with
        | Some r, None -> Ok (Result r)
        | None, Some (`Assoc e) ->
          let ef k = List.Assoc.find e ~equal:String.equal k in
          (match ef "code", ef "message" with
           | Some (`Int code), Some (`String message) -> Ok (Error { code; message; data = ef "data" })
           | _ -> Error "its error has no code and message")
        | _ -> Error "it has neither a result nor an error (or both)")
     | Some (`String "2.0"), Some id' -> Error (sprintf "it answers request %s, not %d" (Yojson.Safe.to_string id') id)
     | _ -> Error "it is not a JSON-RPC 2.0 answer (jsonrpc: \"2.0\" and the id of the request)")
  | _ -> Error "it is not a JSON object"

let field (j : Yojson.Safe.t) k = match j with `Assoc fs -> List.Assoc.find fs ~equal:String.equal k | _ -> None

type hello = { name : string; plugin_version : string; capabilities : string list }

let hello_of_result (r : Yojson.Safe.t) : (hello, string) Result.t =
  match field r "protocol", field r "name", field r "version", field r "capabilities" with
  | Some (`Int p), _, _, _ when p <> version -> Error (sprintf "the plugin speaks version %d of the protocol, but this ALVIE speaks version %d" p version)
  | Some (`Int _), Some (`String name), Some (`String plugin_version), Some (`List cs) ->
    (match Result.all (List.map cs ~f:(function `String c -> Ok c | j -> Error (Yojson.Safe.to_string j))) with
     | Ok capabilities -> Ok { name; plugin_version; capabilities }
     | Error j -> Error (sprintf "capabilities has %s, which is not a string" j))
  | _ -> Error "the answer to initialize needs protocol (an integer), name, version and capabilities (a list)"

let step_of_result (r : Yojson.Safe.t) : (Alvie_plugin.Value.t list * Yojson.Safe.t, string) Result.t =
  match field r "observations" with
  | Some (`List os) ->
    Result.map (Result.all (List.map os ~f:Alvie_plugin.Value.of_json)) ~f:(fun os -> (os, Option.value (field r "bookkeeping") ~default:`Null))
  | _ -> Error "the answer to step needs observations, a list of values"

let instance_of_result (r : Yojson.Safe.t) : (int, string) Result.t =
  match field r "instance" with Some (`Int i) -> Ok i | _ -> Error "the answer to clone needs instance, an integer"

(* The JSON Schema of the protocol: the params and the result of each method *)
let json_schema () : Yojson.Safe.t =
  let obj ?(required = []) props : Yojson.Safe.t =
    `Assoc [ ("type", `String "object"); ("properties", `Assoc props); ("required", `List (List.map required ~f:(fun r -> `String r))) ] in
  let int = `Assoc [ ("type", `String "integer") ] and str = `Assoc [ ("type", `String "string") ] in
  let value = `Assoc [ ("description", `String "A value, in the JSON form of the plugin's values (see the values schemas of alvie plugin schemas)") ] in
  let any = `Assoc [ ("description", `String "Any JSON value") ] in
  let step_props = [ ("instance", int); ("section", str); ("position", int); ("atom", value);
                     ("programs", `Assoc [ ("type", `String "object"); ("additionalProperties", `Assoc [ ("type", `String "array"); ("items", value) ]) ]) ] in
  let step_req = [ "instance"; "section"; "position"; "atom"; "programs" ] in
  let meth name doc params result =
    (name, `Assoc [ ("description", `String doc); ("params", params); ("result", result) ]) in
  `Assoc [
    ("$schema", `String "https://json-schema.org/draft/2020-12/schema");
    ("$id", `String "https://unive-alvie.github.io/alvie/schemas/1/protocol.schema.json");
    ("title", `String "The protocol of ALVIE/Core with external plugins");
    ("description", `String (sprintf "Version %d. JSON-RPC 2.0, one message per line, on the plugin's standard input and output. Each member of methods gives the params and the result of a method." version));
    ("methods", `Assoc [
        meth "initialize" "The handshake: makes instance 0 for the configuration and the variant"
          (obj ~required:[ "protocol"; "core"; "plugin"; "config"; "variant" ]
             [ ("protocol", int); ("core", str); ("plugin", str);
               ("config", `Assoc [ ("type", `String "object"); ("additionalProperties", str) ]);
               ("variant", `Assoc [ ("type", `List [ `String "string"; `String "null" ]) ]) ])
          (obj ~required:[ "protocol"; "name"; "version"; "capabilities" ]
             [ ("protocol", int); ("name", str); ("version", str);
               ("capabilities", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("enum", `List [ `String "restore"; `String "clone" ]) ]) ]) ]);
        meth "pre" "Starts a test" (obj ~required:[ "instance" ] [ ("instance", int) ]) (obj []);
        meth "step" "Runs one input" (obj ~required:step_req step_props)
          (obj ~required:[ "observations" ] [ ("observations", `Assoc [ ("type", `String "array"); ("items", value) ]); ("bookkeeping", any) ]);
        meth "restore" "A dry step: update the state as if the step ran, with these observations"
          (obj ~required:(step_req @ [ "observations"; "bookkeeping" ]) (step_props @ [ ("observations", `Assoc [ ("type", `String "array"); ("items", value) ]); ("bookkeeping", any) ]))
          (obj []);
        meth "clone" "Makes an independent copy of the instance" (obj ~required:[ "instance" ] [ ("instance", int) ]) (obj ~required:[ "instance" ] [ ("instance", int) ]);
        meth "post" "Ends a test" (obj ~required:[ "instance" ] [ ("instance", int) ]) (obj []);
        meth "shutdown" "The last request: the plugin answers, then exits" (obj []) (obj []) ]) ]
