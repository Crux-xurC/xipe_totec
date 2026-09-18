ExUnit.start()

Code.require_file(Path.expand("../lib/repl/eval/scan/direct/iex.exs", __DIR__))

defmodule ReplEvalScanDirectIexTest do
  use ExUnit.Case, async: true

  alias XipeTotec.Repl.Eval.Scan.Direct.Iex, as: ScanDirectIex

  test "a buffer with no heartbeat/exit noise passes through unchanged" do
    buffer = "iex(1)> XT_BEGIN_c1\nrepr=exact\ndisplay=5\nXT_END_c1\n"
    assert ScanDirectIex.clean(buffer) == %{buffer: buffer, heartbeats: 0, exit_status: nil}
  end

  test "strips every XT_HEARTBEAT line and counts them" do
    buffer = "XT_HEARTBEAT\nsome output\nXT_HEARTBEAT\nmore output\n"
    result = ScanDirectIex.clean(buffer)
    assert result.heartbeats == 2
    assert result.buffer == "some output\nmore output\n"
  end

  test "strips the XT_EXIT line and reports the status" do
    buffer = "XT_BEGIN_c1\nrepr=exact\ndisplay=5\nXT_END_c1\nXT_EXIT 0\n"
    result = ScanDirectIex.clean(buffer)
    assert result.exit_status == "0"
    assert result.buffer == "XT_BEGIN_c1\nrepr=exact\ndisplay=5\nXT_END_c1\n"
  end

  test "heartbeats interleaved with an in-progress eval are stripped without touching the eval markers" do
    buffer = "XT_HEARTBEAT\nXT_BEGIN_c1\nrepr=exact\nXT_HEARTBEAT\ndisplay=5\nXT_END_c1\n"
    result = ScanDirectIex.clean(buffer)
    assert result.heartbeats == 2
    assert result.buffer == "XT_BEGIN_c1\nrepr=exact\ndisplay=5\nXT_END_c1\n"
  end
end
