defmodule Calc do
  def add(a, b), do: a + b
  def sub(a, b), do: a - b
  def mul(a, b), do: a * b
  def square(x), do: mul(x, x)
  def average(list), do: Enum.sum(list) / length(list)
  def wide_list, do: Enum.to_list(1..100)
end
