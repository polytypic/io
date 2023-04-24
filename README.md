> TL;DR It is not necessary to agree on a single concurrent programming library,
> or scheduler, that provides IO, because asynchronous IO can be expressed as a
> library, independent of any particular scheduler, such that IO can then easily
> be used by libraries and applications and executed on any number of
> schedulers. Other concurrent runtime facilities such as blocking, timeouts,
> and cancellation can also be given scheduler independent interfaces. By
> providing such key concurrent runtime facilities in scheduler independent form
> we can have an ecosystem of interoperable libraries, multiple schedulers, and
> avoid unnecessary community split.

**_NOTE_**: _This is still WIP. The basic idea should be clear, but I want to
expand upon it a bit. The code in this repository is not meant to provide a full
implementation of anything (IO or a scheduler). The code is just a proof of
concept of the feasibility of the ideas here._

# IO should be just a library

For concurrent programming in OCaml one has traditionally had to make a choice
between two incompatible ecosystems:
[Lwt](https://ocsigen.org/lwt/latest/manual/manual) or
[Async](https://opensource.janestreet.com/async/). This split is typically
considered to be unfortunate as, due to lack of interoperability, it has lead to
duplication of effort, as argued in
[Abandoning Async](http://rgrinberg.com/posts/abandoning-async/).

While entering the multicore era OCaml 5 also got another new major feature,
called [effect handlers](https://v2.ocaml.org/manual/effects.html), which allows
one to express lightweight threads among other things. Somewhat to my surprise
this has not &mdash; at least not yet &mdash; lead to an explosion of effects
based concurrent programming libraries. Perhaps this might be partly due to the
fear of another community split, which has, in part, motivated the design and
development of the [Eio](https://github.com/ocaml-multicore/eio#readme) library
&mdash; destined to become **_the one_** library for concurrent programming and
asynchronous IO for OCaml.

I believe it is fair to say that Eio has an opinionated design in a number of
ways. Eio provides a programming model based on
[capabilities](https://github.com/ocaml-multicore/eio#design-note-capabilities)
and [structured concurrency](https://github.com/ocaml-multicore/eio#switches)
with [cancellation](https://github.com/ocaml-multicore/eio#switches) used as a
key coordination mechanism. IO is provided through a
[flow](https://ocaml-multicore.github.io/eio/eio/Eio/Flow/index.html)
abstraction.

However, those opinionated designs are not what I'd like to draw attention to.
The key issue I'd like to discuss is the architecture of Eio. As described in
Eio's documentation, Eio has optimized backends for different platforms. See the
below diagram and note the direction of dependencies:

```
              Application
                   |
             +-----+----+
             |          |
             v          v
           Eio_main    Eio <--+
             |                |
-  - ---+----+----+--- - -    |
        |    |    |           |
        |    |    v           |
        |    |  Eio_windows +-+
        |    |                |
        |    v                |
        | Eio_posix +---------+
        |                     |
        v                     |
     Eio_linux +--------------+
```

The `Eio` library has some common components, but the core loop of Eio is
actually not a single loop. The `Eio_main` library abstracts that loop and each
of the backends implements it separately (see
[linux sched](https://github.com/ocaml-multicore/eio/blob/75c27bf50e986cc80bdcd1932a48286b56ab620f/lib_eio_linux/sched.ml#L387),
[posix sched](https://github.com/ocaml-multicore/eio/blob/75c27bf50e986cc80bdcd1932a48286b56ab620f/lib_eio_posix/sched.ml#L314),
[windows sched](https://github.com/ocaml-multicore/eio/blob/75c27bf50e986cc80bdcd1932a48286b56ab620f/lib_eio_windows/sched.ml#L318)).

Imagine you would like to implement a different concurrent programming model.

Why would you want to do that?

Well, perhaps you'd like to use work stealing, like provided by
[Domainslib](https://github.com/ocaml-multicore/domainslib#readme), motived by
the idea put forth in the thesis
[Using effect handlers for efficient parallel scheduling &mdash; Bartosz Modelski](https://k-lifo.com/mphil.pdf):

> Modern hardware is so parallel and workloads are so concurrent that there is
> no single, perfect scheduling strategy across a complex application software
> stack. Therefore, significant performance advantages can be gained from
> customizing and composing schedulers.

Or perhaps you'd rather not have capabilities, because you feel that they are
unnecessary or you'd rather wait for typed effects to provide much of the same
ability with convenient type inference.

Or perhaps you'd like to
[introduce an actor framework](https://discuss.ocaml.org/t/rfc-for-a-distributed-process-actor-model-library/12004/5):

> The “ideal” scheduler would allow automatic distribution of processes across
> domains with effects etc, which would be the part concretely within OCaml 5
> territory. It is doable but it would mean needing to reimplementing Eio just
> to have a scheduler-aware IO layer. It seems easier to just wait for upstream
> Eio to maybe introduce that.

Those are just particular examples. <!-- selective IO primitives, better
support for parallelism, ... -->

It would be nice to be able to reuse basic IO facilities for a number of
reasons. It takes considerable effort to implement efficient IO primitives for
multiple platforms. But the bigger problem is that if you would implement your
own asynchronous IO system like Eio, you'd fork the community.

What I'm proposing is that instead of associating IO intimately with a
scheduler, we introduce a scheduler independent IO layer for OCaml. This layer
would provide an interface much like e.g. the `Unix` module of OCaml does. The
key difference being that basic IO operations like `read` and `write` would be
able to block in a scheduler independent manner. Code, whether in libraries or
applications, using that IO layer would then not necessarily be tied to any
particular scheduler:

```
                                +-- Eio
Applications                    |
    and    -----> IO <----------+-- Domainslib
 Libraries         |            |
             +-----+----+       +-- Actor lib
             |     |    |       |
             v     |    v       +-- Oslo
           Linux   |  Windows   |
                   |            +-- Helsinki
                   v            |
                 Posix          .
                                .
                                .
```

How could that be done?

It is simpler that you might think. If you look at how IO is integrated into the
Eio backends, you can see a pattern. First of all each IO backend ultimately has
a blocking operation, much like `Unix.select`, that waits for an IO event or
returns after a given timeout has expired (see
[linux](https://github.com/ocaml-multicore/eio/blob/75c27bf50e986cc80bdcd1932a48286b56ab620f/lib_eio_linux/sched.ml#L246),
[posix](https://github.com/ocaml-multicore/eio/blob/75c27bf50e986cc80bdcd1932a48286b56ab620f/lib_eio_posix/sched.ml#L206),
[windows](https://github.com/ocaml-multicore/eio/blob/75c27bf50e986cc80bdcd1932a48286b56ab620f/lib_eio_windows/sched.ml#L211)).
Additionally, it is sometimes necessary to break the wait before the timeout
expires, such as when a fiber is resumed by a non-IO action, so some wakeup
mechanism is needed (see
[linux](https://github.com/ocaml-multicore/eio/blob/75c27bf50e986cc80bdcd1932a48286b56ab620f/lib_eio_linux/sched.ml#L86),
[posix](https://github.com/ocaml-multicore/eio/blob/75c27bf50e986cc80bdcd1932a48286b56ab620f/lib_eio_posix/sched.ml#L71),
[windows](https://github.com/ocaml-multicore/eio/blob/75c27bf50e986cc80bdcd1932a48286b56ab620f/lib_eio_windows/sched.ml#L82)).

What this means is that we can abstract IO from the point-of-view of a
scheduler:

```ocaml
module type Io = sig
  type t
  (** IO context for a specific domain. *)

  val get_context : unit -> t
  (** Get IO context for current domain. *)

  val pollf : float -> unit
  (** Wait for and trigger IO actions on current domain. *)

  val wakeup : t -> unit
  (** Force [pollf] on specified context to return. *)
end
```

The exact signatures above are subject to minor variations, but the above is
implementable.

A scheduler, then, to provide IO, needs to arrange for `Io.pollf` to be called
periodically and use `Io.wakeup`, when necessary, to force `Io.pollf` to return.
For Eio this would mean that instead of having three slightly different loops,
there would be only one. For other schedulers, like Domainslib, this means that
they actually become usable.

But, we are not actually done yet? How would fibers waiting for IO events be
suspended and resumed? In Eio, the mapping of suspended fibers to e.g. file
descriptors is managed by the scheduler loop and fibers are resumed after the
blocking wait by the scheduler loop. We can avoid that simply by using a
scheduler independent blocking mechanism such as
[domain local await](https://github.com/ocaml-multicore/domain-local-await/#readme).
Using domain local await the IO layer can suspend and resume fibers waiting for
IO events without having to directly depend on the scheduler. In other words,
after `pollf` returns, it has already resumed all the fibers corresponding to
the IO events and the scheduler loop should then have fibers to run.

## Concurrent runtime services

More generally there is a vision for composing schedulers in OCaml as described
in
[Composing Schedulers using Effect Handlers](https://kcsrk.info/papers/compose_ocaml22.pdf).
I'd like to expand on that vision and consider what are the key services that
libraries need from a concurrent runtime and could we provide abstract
minimalistic interfaces for those such that we could have an ecosystem of
interoperable scheduler independent libraries.

### Blocking

- Communication and synchronization abstractions
  - STM
  - Promise
  - Mutex
  - Semaphore
  - Async IO
  - ...

```ocaml
module type Blocking = sig
  type t = { release : unit -> unit; await : unit -> unit }
  val prepare_for_await : unit -> t
end
```

### Cancellation

- Anything that needs to call scheduler when it must not be canceled
  - Condition variable that reacquires the Mutex after `wait`
  - Protected sections:
    `Fun.protect ( ... ) ~finally:(fun () -> (* protected *))`

```ocaml
module type Cancelation = sig
  val forbid : (unit -> 'a) -> 'a
  val permit : (unit -> 'a) -> 'a
end
```

### Timeouts

```ocaml
module type Timeout = sig
  val set_timeoutf : float -> (unit -> unit) -> unit -> unit
end
```

### IO

```ocaml
module type Io = sig
  val pollf : float -> unit
  val wakeup : unit -> unit
end
```

### Fibers

```ocaml
module type Fiber = sig
  type 'a t
  val spawn : (unit -> 'a) -> 'a t
  val join : 'a t -> 'a
end
```

### Nested parallelism

```ocaml
module type NestedParallelism = sig
  val par : (unit -> 'a) -> (unit -> 'b) -> 'a * 'b
end
```
