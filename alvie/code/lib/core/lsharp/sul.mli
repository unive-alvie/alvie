module type SUL = sig
    type t
    type input_t
    type output_t

    (* Deep-copies the given SUL*)
    val clone : t -> t

    (* Performs the initialization of the given SUL *)
    val pre : t -> unit

    (* Perform the specified input step on the given SUL and returns the result *)
    val step : ?silent:bool -> ?dry_output:output_t -> t -> input_t -> output_t

    (* Performs the cleanup of the given SUL *)
    val post : t -> unit
end
