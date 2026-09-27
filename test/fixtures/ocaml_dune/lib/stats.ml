let longest s = List.fold_left (fun a w -> if String.length w > String.length a then w else a) "" (Words.split s)
