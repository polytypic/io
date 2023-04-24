let byte = Bytes.create 1

module Awaiter = struct
  type t = { file_descr : Unix.file_descr; release : unit -> unit }

  let file_descr_of t = t.file_descr

  let[@tail_mod_cons] rec signal aws file_descr =
    match aws with
    | [] -> []
    | aw :: aws ->
        if aw.file_descr == file_descr then (
          aw.release ();
          aws)
        else aw :: signal aws file_descr

  let signal_or_wakeup wakeup aws file_descr =
    if file_descr == wakeup then (
      let n = Unix.read file_descr byte 0 1 in
      assert (n = 1);
      aws)
    else signal aws file_descr
end

type state = {
  pipe_inn : Unix.file_descr;
  pipe_out : Unix.file_descr;
  mutable reading : Awaiter.t list;
  mutable writing : Awaiter.t list;
}

let key =
  Domain.DLS.new_key @@ fun () ->
  let pipe_inn, pipe_out = Unix.pipe () in
  { pipe_inn; pipe_out; reading = []; writing = [] }

let pollf seconds =
  let s = Domain.DLS.get key in
  let rs, ws, _ =
    Unix.select
      (s.pipe_inn :: List.map Awaiter.file_descr_of s.reading)
      (List.map Awaiter.file_descr_of s.writing)
      [] seconds
  in
  s.reading <- List.fold_left (Awaiter.signal_or_wakeup s.pipe_inn) s.reading rs;
  s.writing <- List.fold_left Awaiter.signal s.writing ws

let wakeup () =
  let s = Domain.DLS.get key in
  let n = Unix.write s.pipe_out byte 0 1 in
  assert (n = 1)

exception Timeout

let await ?timeout mode file_descr =
  let s = Domain.DLS.get key in
  let Domain_local_await.{ await; release } =
    Domain_local_await.prepare_for_await ()
  in
  let timeout =
    match timeout with
    | None -> None
    | Some seconds ->
        let timeout = ref false in
        let cancel =
          Domain_local_timeout.set_timeoutf seconds (fun () ->
              timeout := true;
              release ())
        in
        Some (timeout, cancel)
  in
  begin
    match mode with
    | `R -> s.reading <- Awaiter.{ file_descr; release } :: s.reading
    | `W -> s.writing <- Awaiter.{ file_descr; release } :: s.writing
  end;
  let finally () =
    match mode with
    | `R -> s.reading <- Awaiter.signal s.reading file_descr
    | `W -> s.writing <- Awaiter.signal s.writing file_descr
  in
  Fun.protect await ~finally;
  match timeout with
  | None -> ()
  | Some (timeout, cancel) -> if !timeout then raise Timeout else cancel ()

let read ?timeout file_descr bytes pos len =
  await ?timeout `R file_descr;
  Unix.read file_descr bytes pos len

let write ?timeout file_descr bytes pos len =
  await ?timeout `W file_descr;
  Unix.write file_descr bytes pos len

let accept ?timeout ?cloexec file_descr =
  await ?timeout `R file_descr;
  Unix.accept ?cloexec file_descr
