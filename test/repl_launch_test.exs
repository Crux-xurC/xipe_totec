ExUnit.start()

Code.require_file(Path.expand("../lib/repl/launch.exs", __DIR__))

defmodule ReplLaunchTest do
  use ExUnit.Case, async: true

  alias XipeTotec.Repl.Launch

  test "the default message is mix-mode argv plus the Elixir ready_pattern/exit_input defaults" do
    message = Launch.build(cwd: "/tmp/proj")

    assert message["kind"] == "repl/launch"
    assert message["argv"] == ["iex", "-S", "mix"]
    assert message["cwd"] == "/tmp/proj"
    assert message["files"] == []
    assert message["env"] == %{}
    assert message["ready_pattern"] == "Interactive Elixir"
    # banner, then this echo (Old.md §25.3): the marker split in the source
    assert message["ready_probe"] == ~s|IO.puts("XT_" <> "READY")\n|
    assert message["exit_input"] == "System.halt()\n"
    assert message["interruptible"] == true
  end

  test "argv, env, files, ready_pattern, exit_input, and interruptible are all overridable" do
    message =
      Launch.build(
        cwd: "/tmp/proj",
        argv: ["iex"],
        env: %{"FOO" => "bar"},
        files: ["a.exs"],
        ready_pattern: "ready>",
        exit_input: ":quit\n",
        interruptible: false
      )

    assert message["argv"] == ["iex"]
    assert message["env"] == %{"FOO" => "bar"}
    assert message["files"] == ["a.exs"]
    assert message["ready_pattern"] == "ready>"
    assert message["exit_input"] == ":quit\n"
    assert message["interruptible"] == false
  end

  test "the message is JSON round-trippable" do
    message = Launch.build(cwd: "/tmp/proj", files: ["a.exs", "lib/b.exs"])

    encoded = JSON.encode!(message)
    assert {:ok, decoded} = JSON.decode(encoded)
    assert decoded == message
  end

  test "cwd is required" do
    assert_raise KeyError, fn -> Launch.build([]) end
  end
end
