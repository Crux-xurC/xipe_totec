ExUnit.start()

Code.require_file(Path.expand("../lib/repl/eval/parser.exs", __DIR__))
Code.require_file(Path.expand("../lib/repl/eval/scan/direct/iex.exs", __DIR__))
Code.require_file(Path.expand("../lib/repl/eval/field_drip.exs", __DIR__))

defmodule ReplEvalParserTest.FakeFieldDrip do
  # Stands in for a real FieldDrip.<language> module (none exist yet) --
  # just enough key=value parsing to prove Parser's wiring, not a
  # committed language implementation.
  @behaviour XipeTotec.Repl.Eval.FieldDrip

  @impl true
  def parse(body) do
    body
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [key, value] = String.split(line, "=", parts: 2)
      {key, value}
    end)
  end
end

defmodule ReplEvalParserTest do
  use ExUnit.Case, async: true

  alias XipeTotec.Repl.Eval.Parser
  alias XipeTotec.Repl.Eval.Scan.Direct.Iex, as: ScanDirectIex
  alias ReplEvalParserTest.FakeFieldDrip

  test "pending when the target call_id's result hasn't arrived, still reports interleaved heartbeats" do
    buffer = "XT_HEARTBEAT\niex(1)> "
    assert {:pending, cleaned} = Parser.step(buffer, "c1", ScanDirectIex, FakeFieldDrip, 1)
    assert cleaned.heartbeats == 1
    assert cleaned.exit_status == nil
  end

  test "a success marker pair is parsed all the way to an Evaluator.Result" do
    buffer = "iex(1)> XT_BEGIN_c1\nrepr=exact\ntype=integer\ndisplay=5\nXT_END_c1\n:ok\niex(2)> "
    assert {:ok, result, _cleaned} = Parser.step(buffer, "c1", ScanDirectIex, FakeFieldDrip, 7)

    assert result.call_id == "c1"
    assert result.outcome == {:ok, %{repr: "exact", type: "integer", display: "5", bin: nil}}
    assert result.session_gen == 7
  end

  test "an error marker is parsed to the matching Evaluator.Result outcome" do
    buffer = "XT_ERROR_c1 timeout\n"
    assert {:ok, result, _cleaned} = Parser.step(buffer, "c1", ScanDirectIex, FakeFieldDrip, 0)
    assert result.outcome == :timeout
  end

  test "an unrelated call_id's markers in the buffer don't resolve the one we're waiting for" do
    buffer = "XT_BEGIN_other\nrepr=exact\ntype=integer\ndisplay=1\nXT_END_other\n"
    assert {:pending, _cleaned} = Parser.step(buffer, "c1", ScanDirectIex, FakeFieldDrip, 0)
  end
end
