ExUnit.start()

Code.require_file(Path.expand("../lib/repl_sender_direct.exs", __DIR__))
Code.require_file(Path.expand("../lib/repl_session.exs", __DIR__))

defmodule ReplSessionTest do
  use ExUnit.Case, async: true

  alias XipeTotec.Repl.Session
  alias XipeTotec.Repl.Sender.Direct

  describe "await_ready/3" do
    test "returns :ok once ready_pattern appears in the output, however many chunks it takes" do
      {:ok, handle} =
        Direct.send(%{
          "kind" => "repl/launch",
          "argv" => ["sh", "-c", "printf 'boo'; sleep 0.05; printf 'ting up\\n'; sleep 30"],
          "env" => %{},
          "cwd" => System.tmp_dir!()
        })

      assert :ok = Session.await_ready(handle, "booting up", 2_000)
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

      assert {:error, :timeout} = Session.await_ready(handle, "never appears", 100)
      Direct.kill(handle)
    end

    test "returns {:error, {:exited_before_ready, status}} when the process exits before printing the pattern" do
      {:ok, handle} =
        Direct.send(%{
          "kind" => "repl/launch",
          "argv" => ["sh", "-c", "echo not-ready-yet; exit 1"],
          "env" => %{},
          "cwd" => System.tmp_dir!()
        })

      assert {:error, {:exited_before_ready, "1"}} = Session.await_ready(handle, "never appears", 2_000)
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
