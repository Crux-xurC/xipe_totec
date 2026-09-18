ExUnit.start()

Code.require_file(Path.expand("../lib/repl/eval/scan.exs", __DIR__))

defmodule ReplEvalScanTest do
  use ExUnit.Case, async: true

  alias XipeTotec.Repl.Eval.Scan

  test ":pending when neither marker has arrived yet" do
    assert Scan.scan("iex(1)> ", "c1") == :pending
    assert Scan.scan("XT_BEGIN_c1\nrepr=exact\n", "c1") == :pending
  end

  test "extracts the body once both XT_BEGIN_<id> and XT_END_<id> are present" do
    buffer = "iex(1)> XT_BEGIN_c1\nrepr=exact\ntype=integer\ndisplay=5\nXT_END_c1\n:ok\niex(2)> "
    assert Scan.scan(buffer, "c1") == {:ok, {:success, "repr=exact\ntype=integer\ndisplay=5"}}
  end

  test "extracts the detail text after XT_ERROR_<id>" do
    assert Scan.scan("noise\nXT_ERROR_c1 timeout\nmore\n", "c1") == {:ok, {:error, "timeout"}}

    assert Scan.scan("XT_ERROR_c1 crash {:badarith, []}\n", "c1") ==
             {:ok, {:error, "crash {:badarith, []}"}}
  end

  test "an XT_ERROR line without its trailing newline yet is still :pending" do
    assert Scan.scan("XT_ERROR_c1 timeo", "c1") == :pending
  end

  test "ignores another call_id's markers entirely" do
    buffer = "XT_BEGIN_other\nrepr=exact\ndisplay=1\nXT_END_other\n"
    assert Scan.scan(buffer, "c1") == :pending
  end

  test "prefers a complete success pair even if an error line for the same id somehow also appears" do
    # shouldn't happen in practice (eval_template only ever emits one or
    # the other) but success should win if both patterns are present
    buffer = "XT_BEGIN_c1\nrepr=exact\ndisplay=5\nXT_END_c1\nXT_ERROR_c1 timeout\n"
    assert Scan.scan(buffer, "c1") == {:ok, {:success, "repr=exact\ndisplay=5"}}
  end
end
