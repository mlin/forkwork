(** Fork child processes to perform work on multiple cores.

ForkWork is intended for workloads that a master process can partition into
independent jobs, each of which will typically take a while to execute
(several seconds, or more). Also, the resulting values should not be too
massive, since they must be marshalled for transmission back to the master
process. *)

(** Get the number of processors believed to be available. The library
attempts to detect this at program startup (currently only works on Linux),
and if that fails it defaults to 4. *)
val ncores : unit -> int

(** Override the number of processors believed to be available.

@param detect if set to true, attempt to detect the number of processors, and
if that fails then use the provided value. *)
val set_ncores : ?detect:bool -> int -> unit

(** {2 High-level interface}

These map functions suffice for many use cases. *)

val map_list : ?maxprocs:int -> ?fail_fast:bool -> ('a -> 'b) -> ('a list) -> ('b list)

val map_array : ?maxprocs:int -> ?fail_fast:bool -> ('a -> 'b) -> ('a array) -> ('b array)
(** Map a list or array, forking one child process per item to map. In
general, the result type ['b] should not include anything that's difficult to
marshal, including functions, exceptions, weak arrays, or custom values from C
bindings.

If a child process ends with an exception, the master process waits for any
other running child processes to exit, and then raises an exception to the
caller. However, the exception raised to the caller may not be the same one
raised in the child process (see below). If multiple child processes end with
exceptions, it is undefined which one the caller learns about. Once any
exception is detected, no new child processes will be forked.

@param maxprocs maximum number of child processes to run at any one time
(default [ncores ()]). ForkWork takes care of keeping [maxprocs] child
processes running at steady-state, even if their individual runtimes vary.

@param fail_fast if set to true, then as soon as any child process ends with
an exception, SIGTERM is sent to all other child processes, and the exception
is raised to the caller once they all exit. *)

exception ChildExn of string list
(** Due to limitations of OCaml's marshalling capabilities, communication of
exceptions from a child process to the master process is tightly restricted:

- If the child process raises [ForkWork.ChildExn lst], the same exception is
  re-raised in the master process. You can put any information you want into
  the string list, including marshalled values.

- If the child process ends with any other exception [exn], the master process
  sees either [ForkWork.ChildExn ["_"; Printexc.to_string exn]] or
  [ForkWork.ChildExn ["_"; Printexc.to_string exn; Printexc.get_backtrace ()]],
  depending on the status of [Printexc.backtrace_status ()].

- It follows that if you're raising [ChildExn] with information to be
  interpreted by the master process, you probably should not put the string
  ["_"] as the first element of the list.

Another, more type-safe option is to encode errors in the result type instead
of raising an exception. The disadvantage of this is that ForkWork would still
proceed with running all the remaining map operations.

@see < http://caml.inria.fr/mantis/view.php?id=1961 > Mantis: 0001961 (exception marshalling)
*)

(** {2 Lower-level interface } 

The lower-level interface provides much more control over child process
scheduling and result retrieval. For example, the master process does not have
to be blocked while child processes are running, and the result of any
individual child process can be retrieved as soon as it finishes.

{b Types} *)

(** The type of a ForkWork manager for a particular result type *)
type 'a mgr

(** A child process can either complete successfully with a result or end with
an exception, as described above. *)
type 'a result = [`OK of 'a | `Exn of string list]

(** An abstract value representing a forked child process *)
type job

(** {b Forking child processes} *)

(** Create a job manager.

@param maxprocs the maximum number of child processes the manager will permit
at any one time (default [ncores ()]) *)
val manager : ?maxprocs:int -> unit -> 'a mgr

(** [ForkWork.fork mgr f x] forks a child process to compute [(f x)]. If the
manager already has [maxprocs] outstanding jobs, then by default [fork] blocks
until one of them exits.

@param prepare actions to be performed immediately before invoking
[Unix.fork]. The default actions are to flush stdout and stderr, and
[Gc.full_major ()].

@param nonblocking if set to [true] and there are already [maxprocs]
outstanding jobs, [fork] raises [Busy] instead of blocking. The low-level
interface doesn't provide a way to "enqueue" an arbitrary number of jobs, but
it's straightforward to layer such logic on top. *)
val fork : ?prepare:(unit->unit) -> ?nonblocking:bool -> 'a mgr -> ('b -> 'a) -> 'b -> job

(** raised by [fork] iff [~nonblocking:true] and the manager already has
    [maxprocs] outstanding child processes *)
exception Busy

(** {b Retrieving results} *)

(** Non-blocking query for the result of a job. By default, if a result is
returned, then it is also removed from the job manager's memory, such that
future calls with the same job would raise [Not_found].

@return [None] if the job is still running. There are no side effects in
this case.

@raise Not_found if the job is not known to the manager

@param keep setting to true keeps the result in the job manager's memory, so
that it can be retrieved again. The result cannot be garbage-collected unless
it is later removed. *)
val result : ?keep:bool -> 'a mgr -> job -> 'a result option

(** Non-blocking query for any available result.

Repeated calls to [any_result] with [~keep:true] may return the same result.
*)
val any_result : ?keep:bool -> 'a mgr -> (job * 'a result) option

(** Get the result of the job, blocking the caller until it's available. *)
val await_result : ?keep:bool -> 'a mgr -> job -> 'a result

(** Get the result of any job, blocking the caller until one is available.

Repeated calls to [await_any_result] with [~keep:true] may return the same
result.

@raise Idle if no results are available and there are no outstanding jobs *)
val await_any_result : ?keep:bool -> 'a mgr -> job * 'a result

(** raised by [await_any_result] iff no results are available and there are no
outstanding jobs *)
exception Idle

(** Block the caller until all outstanding jobs are done. The results of the
jobs are still stored in the manager's memory, and can be retrieved as above.
*)
val await_all : 'a mgr -> unit

(** Convenience function for child processes launched just for side-effects:
for each result {e currently available} in the job manager's memory, remove it
therefrom; and if it's an exception result, raise [ChildExn]. The result
values are lost! This function never blocks; results from any still-running
child processes remain pending.  *)
val ignore_results : 'a mgr -> unit

(** Any of the result retrieval functions might raise [IPC_Failure] if an
exception occurs while trying to receive a result from a child process. This
is a severe internal error, and it's probably reasonable to clean up and abort
the entire program if it occurs. Possible causes include:

- Child process segfaults or is killed
- System out of memory
- System out of disk space
- Corruption of certain temp files *)
exception IPC_Failure of job*exn

(** {b Killing jobs} *)

(** Kill a job. The job is removed from the manager's memory and the child
process is sent SIGTERM if it's still running.

@param wait if set to true, wait for the child process to exit before
returning.
 *)
val kill : ?wait:bool -> 'a mgr -> job -> unit

(** Kill all outstanding jobs, and also remove all results from the job
manager's memory. This effectively resets the job manager. *)
val kill_all : ?wait:bool -> 'a mgr -> unit

(** {2 General restrictions}

The master process {b SHOULD NOT}:
- fork a new child process while multiple threads exist
- call ForkWork functions concurrently from multiple threads. Excepting the
  previous point, calling ForkWork functions from multiple threads is OK if
  protected by a single mutex for all job managers.
- use [Sys.command], [Unix.fork], [Unix.wait], or [Unix.waitpid] from multiple
  threads at any time. Using them in a single-threaded program is possible
  with the following restriction: if you [fork] your own child processes and
  subsequently [wait]/[waitpid] for them, you should not interleave any
  ForkWork functions in between those two steps. ([Sys.command] always
  satisfies this restriction in a single-threaded program.)
- allow a ForkWork manager to be garbage-collected while it still has child
  processes running

Child processes {b SHOULD NOT}:
- use [Unix.fork] or [Unix.exec*] independently of each other (fork-exec and
  [Sys.command] are OK)
- use any ForkWork-related state adopted from the master process
- do anything you typically can't do from a forked child process, e.g. mutate
  global state and expect it to be reflected in the parent process
- neglect to do any of the typical chores that may be required
  of a forked child process, e.g. closing sockets that were open in the master
  at the fork point (if they need to be closed promptly)

Lastly, there's a pedantic chance of ForkWork operations hanging or sending
SIGTERM to the wrong process if/when the kernel recycles process IDs. Do not
use ForkWork for avionics, nuclear equipment, etc. *)
