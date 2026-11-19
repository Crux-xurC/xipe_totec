namespace Sample

type Point = { X: float; Y: float }

type Shape =
    | Circle of float
    | Rect of float * float
    | Empty

type Color =
    | Red = 0
    | Blue = 1

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
