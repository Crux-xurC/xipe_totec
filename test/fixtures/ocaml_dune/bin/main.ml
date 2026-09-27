let greet name = "hello " ^ name ^ " (" ^ string_of_int (Mylib.Words.count name) ^ ")"
let () = print_endline (greet "main")
