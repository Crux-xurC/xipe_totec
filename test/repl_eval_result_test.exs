ExUnit.start()

Code.require_file(Path.expand("../lib/repl/eval/result.exs", __DIR__))

defmodule ReplEvalResultTest do
  use ExUnit.Case, async: true

  alias XipeTotec.Repl.Eval.Result

  describe "success/3" do
    test "maps repr/type/display/compare straight through as the plain strings eval_template prints" do
      result =
        Result.success("c1", %{"repr" => "exact", "type" => "integer", "display" => "5", "compare" => "same"}, 3)

      assert result.call_id == "c1"
      assert result.outcome == {:ok, %{repr: "exact", display: "5", type: "integer", bin: nil}}
      assert result.compare == "same"
      assert result.session_gen == 3
      assert {:ok, _, _} = DateTime.from_iso8601(result.evaluated_at)
    end

    test "a missing compare field (shouldn't happen once wired, but stay safe) defaults to \"none\"" do
      result = Result.success("c1", %{"repr" => "exact", "type" => "integer", "display" => "5"}, 0)
      assert result.compare == "none"
    end

    test "unsupported and binary repr pass through as strings; binary keeps bin_base64 as base64 text, not decoded" do
      unsupported = Result.success("c1", %{"repr" => "unsupported", "type" => "pid", "display" => "#PID<0.1.0>"}, 0)
      assert {:ok, %{repr: "unsupported"}} = unsupported.outcome

      encoded = Base.encode64(:erlang.term_to_binary(:hello))

      binary =
        Result.success(
          "c1",
          %{"repr" => "binary", "type" => "atom", "display" => ":hello", "bin_base64" => encoded},
          0
        )

      # bin stays the base64 string as-is -- Store persists every column via
      # JSON.encode!/1, and arbitrary :erlang.term_to_binary/1 bytes are not
      # valid JSON text, so base64 is the only JSON-safe form this can cross
      # the Core boundary in .
      assert {:ok, %{repr: "binary", bin: ^encoded}} = binary.outcome
      assert :erlang.binary_to_term(Base.decode64!(encoded)) == :hello
    end
  end

  describe "error/3" do
    test "\"timeout\" maps to the bare :timeout outcome, compare skipped" do
      result = Result.error("c1", "timeout", 1)
      assert result.outcome == :timeout
      assert result.compare == "skipped"
      assert result.call_id == "c1"
      assert result.session_gen == 1
    end

    test "\"max_heap\" maps to the bare :max_heap outcome (distinct from a generic crash)" do
      result = Result.error("c1", "max_heap", 1)
      assert result.outcome == :max_heap
      assert result.compare == "skipped"
    end

    test "\"crash <reason>\" maps to {:error, reason}, compare skipped" do
      result = Result.error("c1", "crash {:badarith, []}", 1)
      assert result.outcome == {:error, "{:badarith, []}"}
      assert result.compare == "skipped"
    end
  end
end
