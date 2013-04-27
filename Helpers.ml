(* we don't use pid's to represent jobs because they can be recycled *)
let fresh_id =
  let nxt = ref 0 in
  (fun () -> incr nxt; !nxt)
;;

exception Inner of exn 
exception Finally of exn*exn
let finally finalize f =
  try
    let ans = f () in begin
      (try finalize () with exn -> raise (Inner exn));
      ans
    end
  with
    | Inner exn -> raise exn
    | exn -> begin
        (try finalize () with exn2 -> raise (Finally(exn,exn2)));
        raise exn
      end
;;

(* Premature optimization: if available, use /dev/shm for temporary storage of
   subprocess results *)
let temp_dir =
  try
    if Sys.is_directory "/run/shm" then Some "/run/shm" else None
  with Sys_error _ -> None
;;

(* Create a temp file, unlink it, and return an open file descriptor. Child
processes use these unlinked temp files to communicate their results back to
the master. *)
let unlinked_temp_fd () = 
  let fn = Filename.temp_file ?temp_dir "ForkWork" "mar" in
  let fd = Unix.(openfile fn [O_RDWR] 0600) in begin
    Unix.unlink fn;
    fd
  end
;;

(* Check if the child process pid has exited. Due to various complications
with waitpid state management, we do not check the exit status -- instead, we
will check for a result written to the temp file *)
let child_process_done pid =
  try
    match Unix.(waitpid [WNOHANG] pid) with
      | (0,_) -> false
      | (pid',_) when pid=pid' -> true
      | _ -> assert false
  with Unix.Unix_error (Unix.ECHILD,_,_) -> true
;;
