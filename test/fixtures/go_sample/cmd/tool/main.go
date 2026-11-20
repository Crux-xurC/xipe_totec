package main

import (
	"fmt"

	c "example.com/calc"
	"example.com/calc/geo"
)

func main() {
	p := geo.Point{X: 1, Y: 2}
	p.Scale(2)
	fmt.Println(c.Add(1, 2), geo.Mid(p, p), run())
}

func run() int { return c.Add3(1, 2, 3) }
