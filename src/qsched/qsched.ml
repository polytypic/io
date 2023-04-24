module Timeout = struct
  type t = { time : Mtime.span; action : unit -> unit }

  let compare l r = Mtime.Span.compare l.time r.time
end

module Pq = Psq.Make (Int) (Timeout)
module Q = Lockfree.Michael_scott_queue

type t = {
  needs_wakeup : bool Atomic.t;
  ready : (unit -> unit) Q.t;
  timeouts : Pq.t Atomic.t;
  alive : int Atomic.t;
  mutable counter : int;
}

let key =
  Domain.DLS.new_key @@ fun () ->
  {
    ready = Q.create ();
    timeouts = Atomic.make Pq.empty;
    counter = 0;
    alive = Atomic.make 0;
    needs_wakeup = Atomic.make false;
  }

type 'a continuation = ('a, unit) Effect.Deep.continuation
type 'a awaiters = [ `Running | `Await of (unit -> unit) * 'a awaiters ]

type 'a task = {
  state : [ 'a awaiters | `Raised of exn | `Returned of 'a ] Atomic.t;
  canceling :
    [ `Not_canceled | `Suspended of unit -> unit | `Canceled of exn ] Atomic.t;
}

type _ Effect.t +=
  | Suspend : ('a continuation -> unit) -> 'a Effect.t
  | Fork : (unit -> 'a) -> 'a task Effect.t

let mark_asleep t = Atomic.set t.needs_wakeup true

let mark_awake t =
  if Atomic.get t.needs_wakeup then Atomic.set t.needs_wakeup false

let rec next t =
  match Q.pop t.ready with
  | Some fn ->
      fn ();
      next t
  | None -> ()

let rec fork t ef =
  let retc () = next t in
  let exnc exn = raise exn in
  let effc (type a) (e : a Effect.t) =
    match e with
    | Suspend fn ->
        let handler k =
          fn k;
          next t
        in
        Some handler
    | Fork ef ->
        let handler k =
          let task =
            {
              state = Atomic.make `Running;
              canceling = Atomic.make `Not_canceled;
            }
          in
          let ef () =
            Atomic.incr t.alive;
            let after =
              match ef () with
              | value -> `Returned value
              | exception exn -> `Raised exn
            in
            Atomic.decr t.alive;
            match Atomic.exchange task.state after with
            | `Running | `Raised _ | `Returned _ -> ()
            | `Await _ as awaiters ->
                let rec loop = function
                  | `Running -> ()
                  | `Await (release, awaiters) ->
                      release ();
                      loop awaiters
                in
                loop awaiters
          in
          Q.push t.ready (fun () -> fork t ef);
          Effect.Deep.continue k task
        in
        Some handler
    | _ -> None
  in
  Effect.Deep.match_with ef () { retc; exnc; effc }

let[@poll error] next_id t =
  let id = t.counter + 1 in
  t.counter <- id;
  id

let[@inline] wakeup { needs_wakeup; _ } =
  if Atomic.get needs_wakeup && Atomic.compare_and_set needs_wakeup true false
  then Io.wakeup ()

module Task = struct
  type 'a t = 'a task

  let spawn ef = Effect.perform (Fork ef)

  let rec await task =
    match Atomic.get task.state with
    | `Returned value -> value
    | `Raised exn -> raise exn
    | #awaiters as awaiters ->
        let t = Domain_local_await.prepare_for_await () in
        if
          Atomic.compare_and_set task.state awaiters
            (`Await (t.release, awaiters))
        then
          match t.await () with
          | () -> await task
          | exception exn ->
              let bt = Printexc.get_raw_backtrace () in
              (* TODO: Remove awaiter *)
              Printexc.raise_with_backtrace exn bt
        else await task

  let rec cancel ?(with_exn = Exit) task =
    match Atomic.get task.canceling with
    | `Canceled _ -> ()
    | `Not_canceled as before ->
        if
          not
          @@ Atomic.compare_and_set task.canceling before
          @@ `Canceled with_exn
        then cancel ~with_exn task
    | `Suspended release as before ->
        if Atomic.compare_and_set task.canceling before @@ `Canceled with_exn
        then release ()
        else cancel ~with_exn task
end

let run main =
  let t = Domain.DLS.get key in
  let rec io_task () =
    let rec release_timeouts () =
      let before = Atomic.get t.timeouts in
      match Pq.pop before with
      | None -> -1.0
      | Some ((_, timeout), after) ->
          let elapsed = Mtime_clock.elapsed () in
          if Mtime.Span.compare timeout.time elapsed <= 0 then begin
            if Atomic.compare_and_set t.timeouts before after then
              timeout.action ();
            release_timeouts ()
          end
          else
            Mtime.Span.to_float_ns (Mtime.Span.abs_diff timeout.time elapsed)
            *. (1. /. 1_000_000_000.)
    in
    let seconds = release_timeouts () in
    if Q.is_empty t.ready then begin
      mark_asleep t;
      if Q.is_empty t.ready then begin
        if 0.0 < seconds || 0 < Atomic.get t.alive then begin
          Q.push t.ready io_task;
          Io.pollf seconds
        end;
        mark_awake t
      end
      else begin
        Q.push t.ready io_task;
        mark_awake t
      end
    end
    else Q.push t.ready io_task
  in
  Q.push t.ready io_task;
  let enqueue k () =
    Q.push t.ready (fun () -> Effect.Deep.continue k ());
    wakeup t
  in
  let prepare_for_await () =
    let state = Atomic.make `Init in
    let release () =
      if Atomic.get state != `Released then
        match Atomic.exchange state `Released with
        | `Awaiting enqueue -> enqueue ()
        | _ -> ()
    and await () =
      if Atomic.get state != `Released then
        let fn k =
          let awaiting = `Awaiting (enqueue k) in
          if Atomic.compare_and_set state `Init awaiting then ()
          else enqueue k ()
        in
        Effect.perform (Suspend fn)
    in
    Domain_local_await.{ release; await }
  in
  let set_timeoutf seconds action =
    match Mtime.Span.of_float_ns (seconds *. 1_000_000_000.) with
    | None ->
        invalid_arg "timeout should be between 0 to pow(2, 53) nanoseconds"
    | Some span ->
        let time = Mtime.Span.add (Mtime_clock.elapsed ()) span in
        let timeout = Timeout.{ time; action } in
        let id = next_id t in
        let rec add_timeout () =
          let before = Atomic.get t.timeouts in
          let after = Pq.add id timeout before in
          if not (Atomic.compare_and_set t.timeouts before after) then
            add_timeout ()
        in
        add_timeout ();
        let rec cancel () =
          let before = Atomic.get t.timeouts in
          let after = Pq.remove id before in
          if not (Atomic.compare_and_set t.timeouts before after) then cancel ()
        in
        cancel
  in
  let result = ref (Error (Failure "deadlock")) in
  let fn () =
    Atomic.incr t.alive;
    result :=
      match main () with
      | value ->
          Atomic.decr t.alive;
          Ok value
      | exception exn ->
          Atomic.decr t.alive;
          Error exn
  in
  Domain_local_await.using ~prepare_for_await ~while_running:(fun () ->
      Domain_local_timeout.using ~set_timeoutf ~while_running:(fun () ->
          fork t fn));
  match !result with Error exn -> raise exn | Ok value -> value
