val run : (unit -> 'a) -> 'a
(** *)

(** *)
module Task : sig
  type 'a t
  (** *)

  val spawn : (unit -> 'a) -> 'a t
  (** *)

  val await : 'a t -> 'a
  (** *)

  val cancel : ?with_exn:exn -> 'a t -> unit
  (** *)
end
