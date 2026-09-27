type shape = Circle of float | Square of float
type point = { x : int; y : int }

let pi = 3.0

let area = function
  | Circle r -> pi *. r *. r
  | Square s -> s *. s

let shapes n = List.init n (fun i -> if i mod 2 = 0 then Circle (float_of_int i) else Square (float_of_int i))
let origin = { x = 0; y = 0 }
let add a b = a + b
let square x = add (x * x) 0
let adder n = fun x -> add x n
let rec spin n = spin (n + 1)
let first l = List.hd l
(* "a string (* not a comment *)" and a let inside a comment:
let hidden = 1 *)
let label = "let not_a_def = 2"

(* top-level effects: never run when xipe loads the file *)
let () = print_endline "GEOMETRY SIDE EFFECT"
;;
print_endline "GEOMETRY SIDE EFFECT 2"
