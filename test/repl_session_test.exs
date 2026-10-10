ExUnit.start()

Code.require_file(Path.expand("../lib/repl/sender_direct.exs", __DIR__))
Code.require_file(Path.expand("../lib/repl/session.exs", __DIR__))

defmodule ReplSessionTest do
  use ExUnit.Case, async: true

  alias XipeTotec.Repl.Session
  alias XipeTotec.Repl.Sender.Direct

  describe "await_ready/4" do
    test "returns :ok once ready_pattern appears in the output, however many chunks it takes" do
      {:ok, handle} =
        Direct.send(%{
          "kind" => "repl/launch",
          "argv" => ["sh", "-c", "printf 'boo'; sleep 0.05; printf 'ting up\\n'; sleep 30"],
          "env" => %{},
          "cwd" => System.tmp_dir!()
        })

      assert :ok = Session.await_ready(Direct, handle, %{"ready_pattern" => "booting up"}, 2_000)
      Direct.kill(handle)
    end

    test "returns {:error, :timeout} when ready_pattern never shows up" do
      {:ok, handle} =
        Direct.send(%{
          "kind" => "repl/launch",
          "argv" => ["sh", "-c", "sleep 30"],
          "env" => %{},
          "cwd" => System.tmp_dir!()
        })

      assert {:error, :timeout} = Session.await_ready(Direct, handle, %{"ready_pattern" => "never appears"}, 100)
      Direct.kill(handle)
    end

    test "returns {:error, {:exited_before_ready, status, output}} when the process exits before printing the pattern" do
      {:ok, handle} =
        Direct.send(%{
          "kind" => "repl/launch",
          "argv" => ["sh", "-c", "echo not-ready-yet; exit 1"],
          "env" => %{},
          "cwd" => System.tmp_dir!()
        })

      assert {:error, {:exited_before_ready, "1", "not-ready-yet"}} =
               Session.await_ready(Direct, handle, %{"ready_pattern" => "never appears"}, 2_000)
    end

    # what a compile error at boot prints is where it says what and where:
    # handed back (the last lines only), not dropped with the buffer
    test "an exit before ready hands back the last lines it printed" do
      {:ok, handle} =
        Direct.send(%{
          "kind" => "repl/launch",
          "argv" => ["sh", "-c", "for i in $(seq 1 50); do echo line$i; done; echo 'calc.exs:3: syntax error'; echo; exit 1"],
          "env" => %{},
          "cwd" => System.tmp_dir!()
        })

      assert {:error, {:exited_before_ready, "1", output}} =
               Session.await_ready(Direct, handle, %{"ready_pattern" => "never appears"}, 2_000)

      lines = String.split(output, "\n")
      assert length(lines) == 30
      assert List.last(lines) == "calc.exs:3: syntax error"
      assert hd(lines) == "line22"
    end

    # after the banner, the probe is written and
    # XT_READY is what proves the REPL evaluates input
    test "after the banner, writes ready_probe and waits for XT_READY" do
      # a tiny "REPL": banner, then runs each line it reads through sh
      {:ok, handle} =
        Direct.send(%{
          "kind" => "repl/launch",
          "argv" => ["sh", "-c", "echo 'toy repl'; while read -r line; do eval \"$line\"; done"],
          "env" => %{},
          "cwd" => System.tmp_dir!()
        })

      message = %{"ready_pattern" => "toy repl", "ready_probe" => "echo XT_\"\"READY\n"}
      assert :ok = Session.await_ready(Direct, handle, message, 2_000)
      Direct.kill(handle)
    end

    test "a probe that is never answered times out; no banner stage when ready_pattern is nil" do
      {:ok, handle} =
        Direct.send(%{
          "kind" => "repl/launch",
          "argv" => ["sh", "-c", "cat > /dev/null"],
          "env" => %{},
          "cwd" => System.tmp_dir!()
        })

      message = %{"ready_pattern" => nil, "ready_probe" => "anything\n"}
      assert {:error, :timeout} = Session.await_ready(Direct, handle, message, 200)
      Direct.kill(handle)
    end
  end

  describe "close/4" do
    test "graceful path: exit_input alone ends a session that's reading stdin" do
      {:ok, handle} =
        Direct.send(%{
          "kind" => "repl/launch",
          "argv" => ["sh", "-c", "read line && echo \"got: $line\""],
          "env" => %{},
          "cwd" => System.tmp_dir!()
        })

      assert :ok = Session.close(Direct, handle, "quit\n", 2_000)
    end

    test "forceful fallback: a session that isn't reading stdin still ends, via kill/1" do
      {:ok, handle} =
        Direct.send(%{
          "kind" => "repl/launch",
          "argv" => ["sh", "-c", "sleep 30"],
          "env" => %{},
          "cwd" => System.tmp_dir!()
        })

      # short graceful_timeout so the test doesn't wait around -- the
      # session never reads stdin, so this always falls through to kill/1
      assert :ok = Session.close(Direct, handle, "quit\n", 100)
    end
  end
end
