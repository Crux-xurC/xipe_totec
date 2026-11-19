/// Plain functions: what a calc row calls.
module Sample.Calc

open System.Collections.Generic

let add a b = a + b

let addPair (a, b) = a + b

let add3 a b c = add (add a b) c

let answer () = 42

let half (x: float) = x / 2.0

let range n = [| 0 .. n - 1 |]

let rangeList n = List.ofArray (range n)

let pair n = struct (n, string n)

let counts (s: string) =
    let d = Dictionary<string, int>()
    for c in s do
        let k = string c
        d.[k] <- (match d.TryGetValue k with | true, v -> v + 1 | _ -> 1)
    d

let greet name = $"hello, {name} {{not a brace}}"

let maybe yes = if yes then Some "yes" else None

let unitArea () = Geo.area (Circle 1.0)

let boom (x: int) : int = failwithf "boom: %d" x

let spin () =
    let mutable i = 0L
    while true do
        i <- i + 1L
    i

let adder n = fun x -> x + n

let inline twice x = x + x

let first (xs: 'a list) = List.head xs

let private secret x = x + 1

let internal hidden x = secret x + 1

// values, not functions: not on the map
let limit = 10

let addTen = add 10
