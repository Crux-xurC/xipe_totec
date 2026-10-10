ExUnit.start()

Code.require_file(Path.expand("../lib/repl/sender_direct.exs", __DIR__))

defmodule ReplSenderDirectTest do
  use ExUnit.Case, async: true

  alias XipeTotec.Repl.Sender.Direct

  # A Port's :data messages arrive as an unpredictably-chunked byte
  # stream, not one message per line -- "pwd && echo ..." can legitimately
  # split across two separate {:data, ...} deliveries depending on
  # scheduling. Accumulates every chunk up through the "XT_EXIT <status>"
  # marker (same buffering style as Repl.Session's await_ready/await_exit)
  # instead of asserting against a single assert_receive.
  defp collect_until_exit(handle, timeout \\ 2_000), do: collect_until_exit(handle, "", timeout)

  defp collect_until_exit(handle, buffer, timeout) do
    receive do
      {^handle, {:data, chunk}} ->
        buffer = buffer <> chunk

        case Regex.run(~r/XT_EXIT (\S+)\n\z/, buffer) do
          [marker, status] -> {String.trim_trailing(buffer, marker), status}
          nil -> collect_until_exit(handle, buffer, timeout)
        end
    after
      timeout -> flunk("no XT_EXIT within #{timeout}ms, buffer so far: #{inspect(buffer)}")
    end
  end

  # A trivial, always-available command stands in for a real REPL launch
  # here -- this test is about the Port plumbing (argv/env/cwd/exit,
  # message shape), not about iex or distributed Erlang, which stays a
  # live 2-node concern out of this fast suite.
  test "spawns argv[0] with the given args, cwd, and env, and the caller receives its stdout" do
    {:ok, handle} =
      Direct.send(%{
        "kind" => "repl/launch",
        "argv" => ["sh", "-c", "pwd && echo \"$XIPE_TEST_VAR\""],
        "env" => %{"XIPE_TEST_VAR" => "hello-from-env"},
        "cwd" => System.tmp_dir!()
      })

    {output, status} = collect_until_exit(handle)
    assert output =~ System.tmp_dir!() |> Path.expand()
    assert output =~ "hello-from-env"
    assert status == "0"
  end

  test "a nonzero exit status is forwarded as the same XT_EXIT marker" do
    {:ok, handle} =
      Direct.send(%{
        "kind" => "repl/launch",
        "argv" => ["sh", "-c", "exit 3"],
        "env" => %{},
        "cwd" => System.tmp_dir!()
      })

    assert_receive {^handle, {:data, "XT_EXIT 3\n"}}, 2_000
  end

  test "an unknown executable is a clean error, not a crash" do
    assert {:error, {:executable_not_found, "definitely-not-a-real-command-xt"}} =
             Direct.send(%{
               "kind" => "repl/launch",
               "argv" => ["definitely-not-a-real-command-xt"],
               "env" => %{},
               "cwd" => System.tmp_dir!()
             })
  end

  # a spawn that erlexec refuses used to take the caller down
  # with it (the failing GenServer's exit signal over the link), so a bad
  # launch crashed `xipe eval` instead of reporting launch_failed
  test "a spawn failure is a clean error and leaves the caller alive, not trapping exits" do
    trapping = Process.flag(:trap_exit, false)

    for _ <- 1..3 do
      assert {:error, {:spawn_failed, _reason}} =
               Direct.send(%{
                 "kind" => "repl/launch",
                 "argv" => ["sh", "-c", "true"],
                 # a non-string value: erlexec refuses the spawn itself
                 "env" => %{"XT_BAD" => 1},
                 "cwd" => System.tmp_dir!()
               })
    end

    assert Process.info(self(), :trap_exit) == {:trap_exit, false}
    refute_received {:EXIT, _, _}
    Process.flag(:trap_exit, trapping)
  end

  test "with_files/2 inserts one -r pair per file, ahead of the rest of argv" do
    assert Direct.with_files(["--sname", "x", "--cookie", "y"], ["a.exs", "lib/b.exs"]) ==
             ["-r", "a.exs", "-r", "lib/b.exs", "--sname", "x", "--cookie", "y"]

    assert Direct.with_files(["--sname", "x"], []) == ["--sname", "x"]
  end

  test "message[\"files\"], when present, is spliced into the actual spawn args (proved via with_files/2 above; here just checking send/1 reads it and doesn't error)" do
    {:ok, handle} =
      Direct.send(%{
        "kind" => "repl/launch",
        "argv" => ["true"],
        "env" => %{},
        "cwd" => System.tmp_dir!(),
        "files" => ["a.exs", "lib/b.exs"]
      })

    assert_receive {^handle, {:data, "XT_EXIT 0\n"}}, 2_000
  end

  test "write/2 writes to the running process's stdin, and the reaction shows up as ordinary :data" do
    {:ok, handle} =
      Direct.send(%{
        "kind" => "repl/launch",
        "argv" => ["cat"],
        "env" => %{},
        "cwd" => System.tmp_dir!()
      })

    assert :ok = Direct.write(handle, "hello from write/2\n")
    assert_receive {^handle, {:data, "hello from write/2\n"}}, 2_000

    assert :ok = Direct.kill(handle)
    assert_receive {^handle, {:data, "XT_EXIT " <> _}}, 2_000
  end

  test "kill/1 forcefully ends a process that isn't reading stdin (the hang case), still producing XT_EXIT" do
    {:ok, handle} =
      Direct.send(%{
        "kind" => "repl/launch",
        "argv" => ["sh", "-c", "sleep 30"],
        "env" => %{},
        "cwd" => System.tmp_dir!()
      })

    assert :ok = Direct.kill(handle)
    # SIGKILL -> Erlang reports 128 + signal number (9) = 137, per the
    # port's own exit-status convention -- asserted loosely here since
    # that convention is a documented but not code-verified assumption
    assert_receive {^handle, {:data, "XT_EXIT " <> status}}, 2_000
    assert String.trim(status) in ["137", "9"]
  end

  test "write/2 and kill/1 against an already-dead handle report cleanly instead of crashing with :noproc" do
    {:ok, handle} =
      Direct.send(%{
        "kind" => "repl/launch",
        "argv" => ["sh", "-c", "exit 0"],
        "env" => %{},
        "cwd" => System.tmp_dir!()
      })

    # let the GenServer actually run its course (forward XT_EXIT, then
    # {:stop, :normal, state}) rather than racing it -- this reproduces the
    # real-world timing (a boot failure, or the tail end of a graceful
    # close) that originally crashed a caller with a raw GenServer.call
    # {:noproc} exit, not a deliberately-still-racing handle. Monitor +
    # assert_receive :DOWN (not just the XT_EXIT data message, which is
    # sent slightly before the GenServer's own {:stop,...}) for a
    # deterministic "now it's actually gone".
    ref = Process.monitor(handle)
    assert_receive {^handle, {:data, "XT_EXIT 0\n"}}, 2_000
    assert_receive {:DOWN, ^ref, :process, ^handle, :normal}, 2_000

    assert {:error, :noproc} = Direct.write(handle, "too late\n")
    assert :ok = Direct.kill(handle)
  end

  test "a message of an unrecognized shape is a clean error" do
    assert {:error, {:unsupported_message, %{"kind" => "repl/eval"}}} =
             Direct.send(%{"kind" => "repl/eval"})
  end
end
