namespace Sample

type Point =
    { X: float; Y: float }
    static member Of(x: float, y: float) = { X = x; Y = y }

type Shape =
    | Circle of float
    | Rect of float * float
    | Empty

type Color =
    | Red = 0
    | Blue = 1

/// Static members: nodes of their own, overloads apart by their parameters' types.
type Conv =
    static member Show(x: int) = "int " + string x
    static member Show(x: string) = "string " + x
    static member Show(x: float, digits: int) = System.Math.Round(x, digits).ToString(System.Globalization.CultureInfo.InvariantCulture)
    static member Scale (k: float) (p: Point) = { X = k * p.X; Y = k * p.Y }
    static member Origin() = Point.Of(0.0, 0.0)
    static member Sum((a: int, b: int)) = a + b
    static member Twice(xs: int list) = xs |> List.map (fun x -> 2 * x)
    static member Fail(x: int) : int = failwithf "fail: %d" x
    static member private Hidden(x: int) = x
    static member Unit = 1
    member this.Inst(x: int) = x

/// Records and unions: exact values, written back as F# literals.
module Geo =
    let mid (p: Point) (q: Point) = { X = (p.X + q.X) / 2.0; Y = (p.Y + q.Y) / 2.0 }

    let area shape =
        match shape with
        | Circle r -> System.Math.PI * r * r
        | Rect(w, h) -> w * h
        | Empty -> 0.0

    let grow k shape =
        match shape with
        | Circle r -> Circle(r * k)
        | Rect(w, h) -> Rect(w * k, h * k)
        | Empty -> Empty

    let next (c: Color) = if c = Color.Red then Color.Blue else Color.Red

    module Inner =
        let label (s: string) = s.ToUpper()
