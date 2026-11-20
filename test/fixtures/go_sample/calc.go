// Package calc: plain functions.
package calc

import "strings"

func Add(a, b int) int { return a + b }

func Add3(a, b, c int) int { return Add(Add(a, b), c) }

func Half(x float64) float64 { return x / 2 }

func Shout(s string) string { return strings.ToUpper(s) + mark() }

func mark() string { return "!" }

func init() { _ = mark() }
