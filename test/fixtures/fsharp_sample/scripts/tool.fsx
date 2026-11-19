// A script whose top level must never run when Xipe Totec loads it.
System.IO.File.WriteAllText("TOP_LEVEL_RAN", "tool.fsx")
printfn "tool.fsx: top level"

let factor = 3

let sq x = x * x

let scale x = x * factor

let computed = sq 4

do printfn "tool.fsx: do"

module Text =
    let shout (s: string) = s.ToUpper() + "!"
