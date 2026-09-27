let split s = Str.split (Str.regexp "[ ,]+") s
let count s = List.length (split s)
let () = print_endline "MYLIB SIDE EFFECT"
