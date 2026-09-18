ExUnit.start()

Code.require_file(Path.expand("../lib/repl/eval/field_drip/elixir.exs", __DIR__))
Code.require_file(Path.expand("../lib/repl/eval/result.exs", __DIR__))

defmodule ReplEvalFieldDripElixirTest do
  use ExUnit.Case, async: true

  alias XipeTotec.Repl.Eval.FieldDrip.Elixir, as: FieldDripElixir

  test "parses a plain exact-repr body into a string-keyed map" do
    body = "repr=exact\ntype=integer\ndisplay=5"
    assert FieldDripElixir.parse(body) == %{"repr" => "exact", "type" => "integer", "display" => "5"}
  end

  test "parses a binary-repr body, including bin_base64" do
    body = "repr=binary\ntype=atom\ndisplay=:hello\nbin_base64=g3cFaGVsbG8="

    assert FieldDripElixir.parse(body) == %{
             "repr" => "binary",
             "type" => "atom",
             "display" => ":hello",
             "bin_base64" => "g3cFaGVsbG8="
           }
  end

  test "a display value that itself contains an = sign is not truncated (splits on the first = only)" do
    body = "repr=exact\ntype=map\ndisplay=%{a: 1, b: 2}"
    assert FieldDripElixir.parse(body)["display"] == "%{a: 1, b: 2}"
  end

  test "feeds cleanly into Repl.Eval.Result.success/3" do
    body = "repr=exact\ntype=integer\ndisplay=5"
    fields = FieldDripElixir.parse(body)
    result = XipeTotec.Repl.Eval.Result.success("c1", fields, 0)
    assert result.outcome == {:ok, %{repr: :exact, type: "integer", display: "5", bin: nil}}
  end
end
