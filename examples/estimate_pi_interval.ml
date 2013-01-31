(*
Compute an interval estimate of pi, using a ForkWork-powered Monte Carlo
simulation that runs until the estimate reaches a certain theoretical accuracy
threshold. This is a demonstration of using ForkWork's lower-level interface
so that the master process can do other things while child processes are
working, including launch more child processes.

$ ocamlfind ocamlopt -o estimate_pi_interval -package forkwork -linkpkg estimate_pi_interval.ml && time ./estimate_pi_interval
Based on 1.8e+08 samples, π ∊ [3.141173,3.141663]

real  0m16.962s
user  1m3.540s
sys   0m0.168s
*)

(* Worker: sample k points uniformly at random from the unit square; return
   how many fall inside and outside of the unit circle *)
let worker k =
  Random.self_init ();
  let inside = ref 0 in
  let outside = ref 0 in begin
    for i = 1 to k do
      let x = Random.float 1.0 in
      let y = Random.float 1.0 in
      incr (if x *. x +. y *. y <= 1.0 then inside else outside)
    done;
    (!inside,!outside)
  end
;;

(* Based on the samples taken so far, return a lower & upper bound on pi *)
let pi_interval inside outside =
  (* Bayesian posterior mean & variance of the binomial proportion, with a
     uniform prior (Beta[1,1]) *)
  let a = float (inside+1) and b = float (outside+1) in
  let n = a +. b in
  let p = a /. n in
  let p_var = (a *. b) /. (n ** 3.0 +. n ** 2.0) in
  (* Perfect so far -- now do a lousy 2*sigma interval *)
  let pi = 4.0 *. p in
  let pi_sd = 4.0 *. sqrt p_var in
  (pi -. 2.0 *. pi_sd, pi +. 2.0 *. pi_sd)
;;

(* Run the simulation until the credible interval is less than 'acc' wide *)
let rec iter mgr acc k inside outside =
  let pi_lo, pi_hi = pi_interval inside outside in begin
    if pi_hi -. pi_lo <= acc then begin
      (* The estimate has reached the desired accuracy, so kill workers and
         report results *)
      ForkWork.kill_all mgr;
      Printf.printf "Based on %.1e samples, π ∊ [%f,%f]\n" (float (inside+outside)) pi_lo pi_hi
    end else
      (* Collect more data from whichever worker process finishes next. This
         blocks until it's available, but there's also a nonblocking version. *)
      match ForkWork.await_any_result mgr with
        | _, `OK (more_inside, more_outside) -> begin
            (* Launch a new worker process to replace the one whose result we
               just got; continue to the next iteration *)
            ignore (ForkWork.fork mgr worker k);
            iter mgr acc k (inside+more_inside) (outside+more_outside)
          end
        (* worker crashed or ended with an exception *)
        | _ -> assert false
  end
;;

(* Instantiate the "ForkWork manager", launch the initial fleet of worker
   processes, and enter the main loop. *)
let acc = 5e-4 and k = 10_000_000 in
let mgr = ForkWork.manager () in begin
  for i = 1 to 4 do
    ignore (ForkWork.fork mgr worker k)
  done;
  iter mgr acc k 0 0
end
;;
