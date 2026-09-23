ExUnit.start()

Code.require_file(Path.expand("../lib/repl/eval/scan/direct/iex.exs", __DIR__))

defmodule ReplEvalScanDirectIexTest do
  use ExUnit.Case, async: true

  alias XipeTotec.Repl.Eval.Scan.Direct.Iex, as: ScanDirectIex

  test "a buffer with no exit noise passes through unchanged" do
    buffer = "iex(1)> XT_BEGIN_c1\nrepr=exact\ndisplay=5\nXT_END_c1\n"
    assert ScanDirectIex.clean(buffer) == %{buffer: buffer, exit_status: nil}
  end

  test "strips the XT_EXIT line and reports the status" do
    buffer = "XT_BEGIN_c1\nrepr=exact\ndisplay=5\nXT_END_c1\nXT_EXIT 0\n"
    result = ScanDirectIex.clean(buffer)
    assert result.exit_status == "0"
    assert result.buffer == "XT_BEGIN_c1\nrepr=exact\ndisplay=5\nXT_END_c1\n"
  end
end
