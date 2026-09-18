ExUnit.start()

Code.require_file(Path.expand("../lib/repl/eval/result.exs", __DIR__))

defmodule ReplEvalResultTest do
  use ExUnit.Case, async: true

  alias XipeTotec.Repl.Eval.Result

  describe "success/3" do
    test "maps repr/type/display straight through, repr as an atom" do
      result = Result.success("c1", %{"repr" => "exact", "type" => "integer", "display" => "5"}, 3)

      assert result.call_id == "c1"
      assert result.outcome == {:ok, %{repr: :exact, display: "5", type: "integer", bin: nil}}
      assert result.compare == :none
      assert result.session_gen == 3
      assert {:ok, _, _} = DateTime.from_iso8601(result.evaluated_at)
    end

    test "unsupported and binary repr map correctly, binary decodes bin_base64" do
      unsupported = Result.success("c1", %{"repr" => "unsupported", "type" => "pid", "display" => "#PID<0.1.0>"}, 0)
      assert {:ok, %{repr: :unsupported}} = unsupported.outcome

      encoded = Base.encode64(:erlang.term_to_binary(:hello))

      binary =
        Result.success(
          "c1",
          %{"repr" => "binary", "type" => "atom", "display" => ":hello", "bin_base64" => encoded},
          0
        )

      assert {:ok, %{repr: :binary, bin: bin}} = binary.outcome
      assert :erlang.binary_to_term(bin) == :hello
    end
  end

  describe "error/3" do
    test "\"timeout\" maps to the bare :timeout outcome" do
      result = Result.error("c1", "timeout", 1)
      assert result.outcome == :timeout
      assert result.call_id == "c1"
      assert result.session_gen == 1
    end

    test "\"crash <reason>\" maps to {:error, reason}" do
      result = Result.error("c1", "crash {:badarith, []}", 1)
      assert result.outcome == {:error, "{:badarith, []}"}
    end
  end
end
