open Printf
open ForkWork
open Kaputt.Abbreviations
;;

Test.add_simple_test ~title:"fork a subprocess and recover the result" (fun () ->
  let mgr = manager () in
  let iou = fork mgr (fun () -> 42) () in
  let ans = await_result mgr iou in
  Assert.equal (`OK 42) ans)
;;

Test.add_simple_test ~title:"fork a subprocess and recover a specific ChildExn" (fun () ->
  let mgr = manager () in
  let iou = fork mgr (fun () -> raise (ForkWork.ChildExn ["foo"])) () in
  Assert.is_true (match await_result mgr iou with `Exn ["foo"] -> true | _ -> false))
;;

exception MyException of int
;;

Test.add_simple_test ~title:"fork a subprocess and recover some other exception" (fun () ->
  let mgr = manager () in
  let iou = fork mgr (fun () -> raise (MyException 42)) () in
  Assert.is_true (match await_result mgr iou with `Exn ("_" :: _) -> true | _ -> false))
;;

Test.add_simple_test ~title:"raise IPC_Failure upon abnormal exit of a subprocess" (fun () ->
  let mgr = manager () in
  let iou = fork mgr (fun () -> exit 1) () in
  Assert.make_raises
    (function IPC_Failure _ -> true | _ -> false)
    Printexc.to_string
    (fun () ->  ForkWork.await_result mgr iou))
;;

exception Fdcount
;;

let fdcount () =
  let dir = sprintf "/proc/%d/fd" (Unix.getpid ()) in
  if not (Sys.file_exists dir && Sys.is_directory dir) then raise Fdcount;
  Array.length (Sys.readdir dir)
;;

Test.add_simple_test ~title:"don't leak file descriptors" (fun () ->
  try
    let fd0 = fdcount () in
    let mgr = manager () in
    let worker i = match i mod 4 with
      | 0 -> 42
      | 1 -> raise (MyException 42)
      | 2 -> exit 0
      | 3 -> exit 1
      | _ -> assert false
    in begin
      for i = 1 to 64 do
        ignore (fork mgr worker i)
      done;
      await_all mgr;
      Assert.equal fd0 (fdcount ())
    end
  with Fdcount -> printf "(skipping file descriptor leak tests since /proc/%d/fd does not exist)\n" (Unix.getpid ()))
;;

Test.add_simple_test ~title:"use Sys.command in child processes" (fun () ->
  let randsleep () = ignore (Sys.command (sprintf "sleep %.2f" (Random.float 1.0))) in
  let intmgr = manager ~maxprocs:4 () in
  let floatmgr = manager ~maxprocs:4 () in
  let strmgr = manager ~maxprocs:4 () in begin
    for _ = 1 to 4 do
      ignore (fork intmgr (fun () -> randsleep (); Random.int 1234567) ());
      ignore (fork floatmgr (fun () -> randsleep (); Random.float 1.0) ());
      ignore (fork strmgr (fun () -> randsleep (); Bytes.create (Random.int 1000)) ())
    done;
    await_all intmgr; ignore_results intmgr;
    await_all floatmgr; ignore_results floatmgr;
    await_all strmgr; ignore_results strmgr
  end)
;;

Test.add_simple_test ~title:"use Sys.command in master process" (fun () ->
  let randsleep () = ignore (Sys.command (sprintf "sleep %.2f" (Random.float 0.1))) in
  let mgr = manager ~maxprocs:10 () in begin
    for _ = 1 to 50 do
      (try ignore (fork ~nonblocking:true mgr randsleep ()) with Busy -> ());
      randsleep ()
    done;
    await_all mgr;
    ignore_results mgr
  end)
;;

Test.add_assert_test ~title:"kill a child process"
  (fun () -> Filename.temp_file "ForkWorkTests" "")
  (fun fn ->
    let f () = (Unix.sleep 2; ignore (Sys.command ("echo foo > " ^ fn))) in
    let mgr = manager () in
    let job = fork mgr f () in begin
      Unix.sleep 1;
      kill ~wait:true mgr job;
      Unix.sleep 2;
      Assert.equal_int 0 Unix.((stat fn).st_size);
      fn
    end)
  Sys.remove
;;

let abort_map_test _ fn =
  let fd = Unix.(openfile fn [O_RDWR] 0o600) in
  Assert.equal 128 (Unix.write fd (Bytes.make 128 (Char.chr 0)) 0 128);
  let shm = Bigarray.array1_of_genarray (Mmap.V1.map_file fd ~pos:0L Bigarray.nativeint Bigarray.c_layout true [|-1|]) in
  let f i =
    if i = 10 then failwith "";
    Unix.sleep 1;
    shm.{i} <- Nativeint.one (* I sure hope this is atomic! *)
  in begin
    Assert.raises (fun () -> map_array f (Array.init 16 (fun i -> i)));
    let zeroes = ref 0 in begin
      for i = 0 to 15 do
        match shm.{i} with
          | x when x = Nativeint.zero -> incr zeroes
          | x when x = Nativeint.one -> ()
          | _ -> assert false
      done;
      (* Check that at least 1 < N < 16 processes did not complete. Hmm, I suppose
         this is not actually guaranteed to happen, but it seems very likely. *)
      Assert.is_true (!zeroes > 1 && !zeroes < 16);
      Unix.close fd;
      fn
    end
  end
;;

Test.add_assert_test ~title:"ChildExn aborts the map operation"
  (fun () -> Filename.temp_file "ForkWorkTests" "")
  (abort_map_test false)
  Sys.remove
;;

Test.add_assert_test ~title:"ChildExn aborts the map operation (fail_fast)"
  (fun () -> Filename.temp_file "ForkWorkTests" "")
  (abort_map_test true)
  Sys.remove
;;


let timed f x =
  let t0 = Unix.gettimeofday () in
  let y = f x in
  y, (Unix.gettimeofday () -. t0)
;;

Test.add_simple_test ~title:"speed up estimation of pi" (fun () ->
  let f n =
    Random.init n;
    let inside = ref 0 in
    let outside = ref 0 in begin
      for _ = 1 to n do
        let x = Random.float 1.0 in
        let y = Random.float 1.0 in
        incr (if x *. x +. y *. y < 1.0 then inside else outside)
      done;
      (!inside,!outside)
    end
  in
  let inputs = Array.init 32 (fun _ -> int_of_float (1e6 *. (Random.float 10.0))) in
  let par_results, par_time = timed (map_list f) (Array.to_list inputs) in
  let _, ser_time = timed (Array.map f) inputs in
  let speedup = ser_time /. par_time in
  let insides, outsides = List.split par_results in
  let inside = float (List.fold_left (+) 0 insides) in
  let outside = float (List.fold_left (+) 0 outsides) in
  let est_pi = 4.0 *. (inside /. (inside +. outside)) in
  printf "speedup on estimation of pi: %.2fx; estimate = %f\n" speedup est_pi)
;;

open Test
;;
launch_tests ()
;;
