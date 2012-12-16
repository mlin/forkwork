(*
Estimate pi using a ForkWork-powered Monte Carlo simulation.

$ ocamlfind ocamlopt -o estimate_pi -package forkwork -linkpkg estimate_pi.ml && time ./estimate_pi
Based on 1.0e+08 samples, π ≈ 3.141717

real  0m6.843s
user  0m26.428s
sys   0m0.052s
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

let estimate_pi n k =
  (* Fork n parallel worker processes to collect samples *)
  let results = ForkWork.map_array worker (Array.make n k) in
  (* Combine the results and derive the estimate *)
  let insides, outsides = List.split (Array.to_list results) in
  let inside = float (List.fold_left (+) 0 insides) in
  let outside = float (List.fold_left (+) 0 outsides) in
  4.0 *. (inside /. (inside +. outside))
;;

let n = 30 and k = 25_000_000 in
Printf.printf "Based on %.1e samples, π ≈ %f\n" (float (n*k)) (estimate_pi n k)
;;
