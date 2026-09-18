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
    assert message["exit_input"] == "System.halt()\n"
    assert message["heartbeat_input"] =~ "Process.sleep(5000)"
    assert message["heartbeat_input"] =~ "XT_HEARTBEAT"
    assert {:ok, _quoted} = Code.string_to_quoted(message["heartbeat_input"])
  end

  test "argv, env, files, ready_pattern, exit_input, and heartbeat_interval_ms are all overridable" do
    message =
      Launch.build(
        cwd: "/tmp/proj",
        argv: ["iex"],
        env: %{"FOO" => "bar"},
        files: ["a.exs"],
        ready_pattern: "ready>",
        exit_input: ":quit\n",
        heartbeat_interval_ms: 1_000
      )

    assert message["argv"] == ["iex"]
    assert message["env"] == %{"FOO" => "bar"}
    assert message["files"] == ["a.exs"]
    assert message["ready_pattern"] == "ready>"
    assert message["exit_input"] == ":quit\n"
    assert message["heartbeat_input"] =~ "Process.sleep(1000)"
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
