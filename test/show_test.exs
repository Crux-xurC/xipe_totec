ExUnit.start()

Code.require_file(Path.expand("../lib/show.exs", __DIR__))

defmodule ShowTest do
  use ExUnit.Case, async: true

  alias XipeTotec.{Book, Core, Show}

  defp book do
    Book.new()
    |> Core.put_node("n1", %{module: "M", name: "f", anykey: 1, effect: "pure", effect_source: "user"})
    |> Core.add_call("c1", %{node: "n1", args: ["1"]})
  end

  defp row_line(book), do: book |> then(&Show.lines("001", "/p", &1)) |> Enum.find(&String.starts_with?(&1, "row "))

  defp evaluated(book, outcome) do
    Core.apply_results(book, %{}, [%{call_id: "c1", outcome: outcome, compare: "none", evaluated_at: "t", session_gen: "p"}])
  end

  test "an evaluated row shows its value and compare" do
    line = book() |> evaluated({:ok, %{repr: "exact", display: "0", type: "integer", bin: nil}}) |> row_line()
    assert line =~ ~r/args=\["1"\]  0  compare=none$/
  end

  test "an unevaluated row shows -" do
    assert row_line(book()) =~ ~r/args=\["1"\]  -  compare=none$/
  end

  # S-2: the failed row kept its old value; it read as the current one
  test "a row whose last evaluation failed says so and why, and names the old value as the previous one" do
    line =
      book()
      |> evaluated({:ok, %{repr: "exact", display: "0", type: "integer", bin: nil}})
      |> evaluated(:timeout)
      |> row_line()

    assert line =~ ~r/args=\["1"\]  \(error: timeout\)  previous=0  state=eval_error$/
    refute line =~ "compare="
  end

  test "a row that failed on its first evaluation has no previous value" do
    line = book() |> evaluated({:error, "crash boom"}) |> row_line()
    assert line =~ ~r/\(error: crash boom\)  state=eval_error$/
    refute line =~ "previous="
  end
end
