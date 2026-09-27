(* uses Geometry, which sorts after this file: loading has to retry *)
let of_shape s = Geometry.area s
let total shapes = List.fold_left (fun acc s -> acc +. of_shape s) 0. shapes
