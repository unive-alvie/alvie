(*
  What the comparison engine needs to know about the inputs and outputs of a backend.

  The engine (Cexfinder.Make) compares two learned models with mCRL2 and turns the traces that tell them apart
  into witnesses; everything that depends on the meaning of the inputs and outputs (who chose an input, what an
  observer sees of an output, which code is the victim's) comes from these hooks.

  Plugin_hooks derives these hooks from the files of a plugin (the attacker view, the phase rules and the sections),
  so a backend writes none of them; this signature remains the interface of the engine.
*)

open Learninglib.Elttype

module type S = sig
  (* The inputs and outputs of the compared models. They are the labels of the .dot model files. *)
  module Input : sig
    include EltType
  end

  module Output : sig
    include EltType
  end

  (*
    Low (attacker) inputs: the inputs that the attacker chooses. The two runs of a witness have the same low
    inputs; the other inputs (the victim's code) may differ.
  *)
  val is_low_input : Input.t -> bool

  (*
    Hidden outputs: the outputs that the attacker cannot see. They are silent (tau) for mCRL2, so trace inclusion
    is checked on the visible outputs only.
  *)
  val is_hidden : Output.t -> bool

  (* Final outputs: a run ends at them (e.g., a reset). *)
  val is_final : Output.t -> bool

  (*
    Public equality: whether the attacker can tell two visible outputs apart. A witness ends at the first pair of
    outputs that are not publicly equal.
  *)
  val public_equal : Output.t -> Output.t -> bool

  (* Outputs produced while the victim runs: a witness does not end at one of them. *)
  val in_victim : Output.t -> bool

  (*
    The victim-code filter. victim_code run gives the victim's code that a run executes, as a sequence of inputs;
    the two runs of a witness must run the same victim code (one is a prefix of the other) up to the secret, as
    given by victim_code_up_to_secret, and a witness of the models with interrupts is discarded when it runs the
    same victim code as a witness of the models without interrupts.
  *)
  val victim_code : (Input.t * Output.t) list -> Input.t list
  val victim_code_up_to_secret : (Input.t * Output.t) list -> Input.t list

  (* How an observation is printed in witness graphs and in the logs. *)
  val human_show : Input.t -> Output.t -> string

  (*
    The label of a transition for mCRL2: what the attacker sees of it (its input, and the view of its output).
    Transitions with the same label are the same for the comparison.
  *)
  val comparison_label : Input.t -> Output.t -> string
end
