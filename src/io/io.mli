open Unix

(** {2 Interface for IO} *)

exception Timeout
(** *)

val read : ?timeout:float -> file_descr -> bytes -> int -> int -> int
(** *)

val write : ?timeout:float -> file_descr -> bytes -> int -> int -> int
(** *)

val accept :
  ?timeout:float -> ?cloexec:bool -> file_descr -> file_descr * sockaddr
(** *)

(** {2 Interface for schedulers} *)

val pollf : float -> unit
(** *)

val wakeup : unit -> unit
(** *)
