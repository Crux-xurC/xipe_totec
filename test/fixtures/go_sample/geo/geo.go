package geo

import (
	"math"

	"example.com/calc"
)

type Point struct{ X, Y float64 }

func (p Point) Dist(q Point) float64 { return math.Hypot(p.X-q.X, p.Y-q.Y) }

func (p *Point) Scale(k float64) { p.X, p.Y = p.X*k, p.Y*k; p.norm() }

func (p *Point) norm() {}

func Mid(a, b Point) Point { return Point{calc.Half(a.X + b.X), calc.Half(a.Y + b.Y)} }

func Map[T any](xs []T, f func(T) T) []T {
	out := make([]T, len(xs))
	for i, x := range xs {
		out[i] = f(x)
	}
	return out
}
