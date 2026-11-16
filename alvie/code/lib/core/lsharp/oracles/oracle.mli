open Elttype
open Mealy
open Observationtree
open Sul
open Showableint

module type Oracle =
    functor
        (I : EltType)
        (O : EltType)
        (S : SUL with type input_t = I.t and type output_t = O.t) ->
    sig
    type t

    module IIOObservationTree : module type of ObservationTree (ShowableInt) (I) (O)
    module IIOMealy : module type of Mealy (ShowableInt) (I) (O)

    val get_stats : t -> int*int*int*int*int*float*float
    (* The oracle numbers the nodes it adds to the tree after this one (for a tree that L# starts from) *)
    val set_last_state : t -> int -> unit
    val output_query : t -> IIOObservationTree.t -> S.t -> I.t list -> IIOObservationTree.t * (I.t * O.t) list
    val equiv_query : t -> IIOObservationTree.t -> S.t -> IIOMealy.t -> [`Cex of IIOObservationTree.t * I.t list | `Equivalent ]
end
