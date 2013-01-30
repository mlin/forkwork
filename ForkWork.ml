open Printf
open Helpers
;;

let ncores, set_ncores =
  let attempt_detect ndefault =
    (* TODO: use a binding to sysconf() to do this *)
    try
      let inchan = Unix.open_process_in "sh -c \"cat /proc/cpuinfo | grep -e processor[[:space:]]*: | wc -l\" 2>/dev/null" in
      let stdout = input_line inchan in
      match Unix.close_process_in inchan with
        | Unix.WEXITED 0 -> max 1 (int_of_string stdout)
        | _ -> raise Exit
    with _ -> ndefault
  in
  let n = ref (attempt_detect 4) in
  (fun () -> !n), (fun ?(detect=false) n' -> n := (if detect then attempt_detect n' else n'))
;;

(* types *)
type job = int

type 'a result = [`OK of 'a | `Exn of string list]

type 'a internal_result = [`OK of 'a | `Exn of string list | `IPC_Failure of exn]

type 'a mgr = {
  maxprocs : int;
  pending : (int,(int*Unix.file_descr)) Hashtbl.t; (* job -> pid*result_fd *)
  results: (int,'a internal_result) Hashtbl.t      (* job -> result *)
}

exception ChildExn of string list

(* finalizer: if the manager is being garbage-collected while there are still
outstanding child processes, close the corresponding temporary file
descriptors. We'll stop short of actually killing the child processes, though.
Library users should really be discouraged from putting us in this situation. *)
let finalize_manager {pending} = Hashtbl.iter (fun _ (_,fd) -> Unix.close fd) pending

let manager ?maxprocs () =
  let maxprocs = (match maxprocs with Some n -> n | None -> ncores ()) in
  let mgr = {
    maxprocs;
    pending = Hashtbl.create maxprocs;
    results = Hashtbl.create maxprocs
  } in begin
    Gc.finalise finalize_manager mgr;
    mgr
  end
;;

(* internal: the default prefork actions *)
let default_prefork () =
  flush stdout;
  flush stderr;
  Gc.full_major ()
;;

(* internal: the worker process *)
let worker f x result_fd =
  (* perform the computation *)
  let result =
    try
      let ans = ((f x):'a) in
      `OK ans
    with
      | ChildExn info -> `Exn info
      | exn when Printexc.backtrace_status () -> `Exn ["_"; Printexc.to_string exn; Printexc.get_backtrace ()]
      | exn -> `Exn ["_"; Printexc.to_string exn]
  in
  (* write the results to result_fd *)
  try
    let result_chan = Unix.out_channel_of_descr result_fd in begin
      Marshal.(to_channel result_chan (result:('a result)) [Closures]);
      flush result_chan;
      close_out result_chan;
      exit 0
    end
  with exn -> begin
    eprintf "[PANIC] ForkWork subprocess %d (parent %d) failed to write result: %s\n" (Unix.getpid ()) (Unix.getppid ()) (Printexc.to_string exn);
    if Printexc.backtrace_status() then Printexc.print_backtrace stderr;
    exit 1
  end
;;

(* internal: attempt to read a child process result from the temp file
   descriptor, and (whatever happens) close the file descriptor *)
let receive_result pid result_fd =
  let result_chan = begin
    try
      (* detect if the child process exited abnormally before writing its result
         (it's also possible it crashes while writing the result; in this case we
         have to rely on Marshal to detect the truncation) *)
      let { Unix.st_size } = Unix.fstat result_fd in begin
        if st_size = 0 then failwith (sprintf "ForkWork subprocess %d (parent %d) exited abnormally" pid (Unix.getpid ()));
        ignore Unix.(lseek result_fd 0 SEEK_SET);
        Unix.in_channel_of_descr result_fd
      end
    with exn -> (Unix.close result_fd; raise exn)
  end in
  finally (fun () -> close_in result_chan) (fun () -> Marshal.from_channel result_chan)
;;

(* internal: collect all newly-available results *)
let collect_results (mgr:'a mgr) =
  (* poll the pending child processes to see which ones have exited since the
     last time we checked.
     TODO: is it safe to Hashtbl.remove during Hashtbl.iter? *)
  let pending = Hashtbl.fold (fun k v lst -> (k,v) :: lst) mgr.pending [] in
  List.iter
    (fun (id,(pid,result_fd)) -> if child_process_done pid then begin
      (* remove this child process from the 'pending' table *)
      Hashtbl.remove mgr.pending id;
      (* collect its result and store it in the 'results' table *)
      try
        let result = (((receive_result pid result_fd):'a result) :> 'a internal_result) in
        Hashtbl.add mgr.results id result
      with exn -> Hashtbl.add mgr.results id (`IPC_Failure exn)
    end)
    pending
;;

exception Busy
;;

let fork ?(prepare=default_prefork) ?(nonblocking=false) mgr f x =
  collect_results mgr;
  (* ensure there are fewer than maxprocs outstanding child processes *)
  while Hashtbl.length mgr.pending >= mgr.maxprocs do
    if nonblocking then raise Busy
    else ignore (Unix.wait ());
    collect_results mgr
  done;
  let id = fresh_id () in
  let result_fd = unlinked_temp_fd () in
  prepare ();
  match Unix.fork () with
    | x when x < 0 -> assert false (* supposed to raise an exception, not this *)
    | 0 -> begin
        (* in child process: wipe out my copy of the manager state, since it's unneeded *)
        Hashtbl.iter (fun _ (_,fd) -> Unix.close fd) mgr.pending;
        Hashtbl.clear mgr.pending; Hashtbl.clear mgr.results;

        (* execute worker logic *)
        worker f x result_fd
      end
    | pid -> begin
        (* master process: add the new child process to the 'pending' table *)
        Hashtbl.add mgr.pending id (pid,result_fd);
        id
      end
;;

exception IPC_Failure of job*exn
;;

let result ?(keep=false) mgr job =
  collect_results mgr;
  try
    let ans = Hashtbl.find mgr.results job in begin
      if not keep then Hashtbl.remove mgr.results job;
      match ans with
        | (`OK _) as ans -> Some ans
        | (`Exn _) as ans -> Some ans
        | `IPC_Failure exn -> raise (IPC_Failure (job,exn))
    end
  with Not_found -> begin
    ignore (Hashtbl.find mgr.pending job); (* raise Not_found if this job is unknown to us *)
    None
  end
;;

let any_result ?(keep=false) mgr =
  collect_results mgr;
  let ans = ref None in begin
    (try
      Hashtbl.iter (fun job result -> ans := Some (job,result); raise Exit) mgr.results
     with Exit -> ());
    match !ans with
      | None -> None
      | Some (job,result) -> begin
          if not keep then Hashtbl.remove mgr.results job;
          match result with
            | (`OK _) as x -> Some (job,x)
            | (`Exn _) as x -> Some (job,x)
            | `IPC_Failure exn -> raise (IPC_Failure (job,exn)) (* TODO: communicate job back to caller *)
        end
  end
;;

let rec await_result ?keep mgr job =
  match result ?keep mgr job with
    | Some ans -> ans
    | None -> begin
        ignore (Unix.wait ());
        await_result ?keep mgr job
      end
;;

exception Idle
;;

let rec await_any_result ?keep mgr =
  match any_result ?keep mgr with
    | Some ans -> ans
    | None when Hashtbl.length mgr.pending = 0 -> raise Idle
    | None -> begin
        ignore (Unix.wait ());
        await_any_result ?keep mgr
      end
;;

let rec await_all mgr =
  collect_results mgr;
  if Hashtbl.length mgr.pending > 0 then begin
    ignore (Unix.wait ());
    await_all mgr
  end
;;

exception ChildProcExn of string*(string option)
;;

let ignore_results mgr =
  let results = Hashtbl.fold (fun k r lst -> (k,r) :: lst) mgr.results [] in
  List.iter
    (fun (job,res) ->
      Hashtbl.remove mgr.results job;
      match res with
        | `Exn info -> raise (ChildExn info)
        | `IPC_Failure exn -> raise (IPC_Failure (job,exn))
        | `OK _ -> ())
    results
;;

let kill ?(wait=false) mgr job =
  try
    let (pid,result_fd) = Hashtbl.find mgr.pending job in begin
      Hashtbl.remove mgr.pending job;
      Unix.close result_fd;
      if not (child_process_done pid) then begin
        (try Unix.kill pid Sys.sigterm with _ -> ());
        if wait then
          while not (child_process_done pid) do
            ignore (Unix.wait ())
          done
      end
    end
  with Not_found when Hashtbl.mem mgr.results job -> Hashtbl.remove mgr.results job
;;

let kill_all ?(wait=false) mgr =
  let pending = Hashtbl.fold (fun job (pid,fd) lst -> (job,pid,fd) :: lst) mgr.pending [] in begin
    (* SIGTERM everybody *)
    List.iter
      (fun (_,pid,_) ->
        try
          if not (child_process_done pid) then Unix.kill pid Sys.sigterm
        with _ -> ())
      pending;
    (* wait, if requested *)
    if wait then
      List.iter
        (fun (_,pid,_) ->
          while not (child_process_done pid) do
            ignore (Unix.wait ())
          done)
        pending;
    (* clean up *)
    List.iter (fun (job,_,fd) -> Hashtbl.remove mgr.pending job; Unix.close fd) pending
  end;
  let results = Hashtbl.fold (fun k _ lst -> k :: lst) mgr.results [] in
    List.iter (Hashtbl.remove mgr.results) results
;;

let map_array ?maxprocs ?(fail_fast=false) f ar =
  let f' (i,x) = (i, (f x)) in
  let n = Array.length ar in
  let results = Array.make n None in
  let mgr = manager ?maxprocs () in
  let rec collect () = match any_result mgr with
    | None -> ()
    | Some (job,`Exn info) -> begin
        if fail_fast then
          kill_all ~wait:true mgr
        else
          await_all mgr;
        raise (ChildExn info)
      end
    | Some (job,`OK (i,res)) -> begin
        assert (results.(i) = None);
        results.(i) <- Some res;
        collect ()
      end
  in
    default_prefork ();
    for i = 0 to Array.length ar - 1 do
      collect ();
      ignore (fork ~prepare:Gc.minor mgr f' (i,ar.(i)))
    done;
    await_all mgr;
    collect ();
    Array.map (function Some x -> x | None -> assert false) results
;;

let map_list ?maxprocs ?fail_fast f lst = Array.to_list (map_array ?maxprocs ?fail_fast f (Array.of_list lst))
;;
