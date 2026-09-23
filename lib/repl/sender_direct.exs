Code.require_file("sender.exs", __DIR__)

defmodule XipeTotec.Repl.Sender.Direct do
  @moduledoc """
  Default `Repl.Sender`: spawns the process locally via `erlexec`
  (`:exec.run/2`), in its own process group (2026-09-22, Old.md §23
  -- replaces the earlier bare-`Port` implementation). A bare `Port`
  cannot create or signal a POSIX process group, which `kill/1`'s
  group-wide SIGKILL and `interrupt/1`'s group-wide SIGINT both need:
  without a group of its own, the REPL child shares xipe_totec's own
  process group, so (a) a Ctrl-C on xipe_totec's own CLI process would
  hit the REPL child too as collateral damage, and (b) a REPL that forks
  its own children (`iex -S mix`'s build step, say) would leave those
  orphaned by a single-pid kill. `{:group, 0}` (`:exec.run/2`'s own spawn
  option) fixes both -- the child gets a session/group of its own, and
  erlexec's own C helper delivers `kill/2`'s signal to that whole group.
  Confirmed live 2026-09-22 against a plain-pipe `iex`: `:exec.kill(ospid,
  2)` reaches BEAM's own SIGINT handler and drops it into the
  interactive "BREAK: (a)bort..." menu, exactly as a real terminal's
  Ctrl-C would -- no PTY required.

  xipe_totec earlier decided against `erlexec` for a *different* need
  (the §16 WS server, which is the side being connected *to*, never
  spawning anything) -- that reasoning never applied to this module's own
  need (spawning the target REPL), and no longer holds now that group
  isolation is required.

  The returned `handle` is a `GenServer` pid, not the raw erlexec ospid:
  `Repl.Sender`'s contract requires exit to show up as an `"XT_EXIT
  <status>"` marker inside the ordinary `:data` stream rather than as
  erlexec's own `:DOWN` monitor message, and requires
  `write/2`/`kill/1`/`interrupt/1` to work against the same handle -- so
  this module owns the ospid privately and exposes only the generic
  contract.

  Not supervised -- if the caller dies without calling `kill/1`, this
  GenServer (and the OS process group under it) is orphaned.
  Session/process lifecycle beyond that is `Repl.Session`'s and,
  eventually, `Evaluator`'s concern (プロセスアーキテクチャ, E in
  Old.md §28), not this module's.
  """

  use GenServer

  @behaviour XipeTotec.Repl.Sender

  @sigint 2
  @sigkill 9

  @impl XipeTotec.Repl.Sender
  def send(%{"kind" => "repl/launch", "argv" => [exe | args], "env" => env, "cwd" => cwd} = message)
      when is_binary(exe) and is_list(args) and is_map(env) and is_binary(cwd) do
    case System.find_executable(exe) do
      nil ->
        {:error, {:executable_not_found, exe}}

      path ->
        files = Map.get(message, "files", [])
        spawn_args = with_files(args, files)
        argv = Enum.map([path | spawn_args], &String.to_charlist/1)
        exec_env = Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
        GenServer.start_link(__MODULE__, {argv, cwd, exec_env, self()})
    end
  end

  def send(other), do: {:error, {:unsupported_message, other}}

  # See ../sender_direct.exs (Port version)'s own note, still true here:
  # a handle can legitimately already be gone by the time write/2,
  # kill/1, or interrupt/1 is called -- a raw GenServer.call/2 to a dead
  # pid exits with {:noproc, _} rather than returning an error value.
  # write/2 on a dead handle reports it as an ordinary {:error, :noproc}
  # (nothing to write to); kill/1 and interrupt/1 on one instead return
  # plain :ok -- the session is already gone either way.
  @impl XipeTotec.Repl.Sender
  def write(handle, text) when is_binary(text) do
    GenServer.call(handle, {:write, text})
  catch
    :exit, {:noproc, _} -> {:error, :noproc}
  end

  @impl XipeTotec.Repl.Sender
  def kill(handle) do
    GenServer.call(handle, :kill)
  catch
    :exit, {:noproc, _} -> :ok
  end

  @impl XipeTotec.Repl.Sender
  def interrupt(handle) do
    GenServer.call(handle, :interrupt)
  catch
    :exit, {:noproc, _} -> :ok
  end

  # `message["files"]` is plain data, opaque to `Repl.Launch` -- this
  # sender decides the only thing it means for *this* delivery mechanism:
  # one `-r <file>` pair per file, inserted before the rest of argv (so it
  # works whether `args` came from the mix-mode default or a scripts-mode
  # override). Exposed (not `defp`) so this decision is unit-testable
  # without spawning a real process.
  @spec with_files([String.t()], [String.t()]) :: [String.t()]
  def with_files(args, files), do: Enum.flat_map(files, &["-r", &1]) ++ args

  # ---------------------------------------------------------------------
  # GenServer: privately owns the real erlexec ospid, translates its
  # native message shapes into Repl.Sender's single `{handle, {:data,
  # ...}}` contract (sender.exs has the full rationale).
  # ---------------------------------------------------------------------

  @impl GenServer
  def init({argv, cwd, env, caller}) do
    case Application.ensure_all_started(:erlexec) do
      {:ok, _} -> :ok
      {:error, r} -> raise "erlexec failed to start: #{inspect(r)}"
    end

    opts = [:stdin, :stdout, :stderr, :monitor, {:group, 0}, {:cd, String.to_charlist(cwd)}, {:env, env}]

    case :exec.run(argv, opts) do
      {:ok, _pid, ospid} -> {:ok, %{ospid: ospid, caller: caller}}
      {:error, reason} -> {:stop, {:spawn_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call({:write, text}, _from, %{ospid: ospid} = state) do
    case :exec.send(ospid, text) do
      :ok -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # Group-wide SIGKILL: `{:group, 0}` at spawn (init/1) is what makes this
  # reach children the direct ospid alone wouldn't (see moduledoc).
  # `:exec.stop/1` exists as a higher-level "try graceful, escalate"
  # helper built into erlexec itself, but `Evaluator` already owns that
  # escalation (`interrupt/1` first, `kill/1` as the guaranteed fallback)
  # -- this callback itself stays a single unconditional SIGKILL, same
  # contract the old Port-based implementation had.
  def handle_call(:kill, _from, %{ospid: ospid} = state) do
    _ = :exec.kill(ospid, @sigkill)
    {:reply, :ok, state}
  end

  def handle_call(:interrupt, _from, %{ospid: ospid} = state) do
    case :exec.kill(ospid, @sigint) do
      :ok -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_info({:stdout, ospid, bin}, %{ospid: ospid, caller: caller} = state) do
    Kernel.send(caller, {self(), {:data, bin}})
    {:noreply, state}
  end

  # stderr forwarded the same way stdout is -- the old Port implementation
  # merged both into one stream via :stderr_to_stdout; erlexec keeps them
  # as separate message tags, so this module does the merge itself here
  # instead, same net effect for every downstream consumer (Scan/Parser
  # never distinguished the two either).
  def handle_info({:stderr, ospid, bin}, %{ospid: ospid, caller: caller} = state) do
    Kernel.send(caller, {self(), {:data, bin}})
    {:noreply, state}
  end

  def handle_info({:DOWN, ospid, :process, _pid, reason}, %{ospid: ospid, caller: caller} = state) do
    Kernel.send(caller, {self(), {:data, "XT_EXIT #{exit_status_of(reason)}\n"}})
    {:stop, :normal, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # erlexec's raw :DOWN reason (confirmed live, 2026-09-22): a clean exit
  # 0 is reported as the bare atom `:normal`, not a tuple at all; any
  # other exit_status packs a normal (nonzero) exit code as `code << 8`
  # and a signal death as the bare signal number -- :exec.status/1 is
  # erlexec's own decoder for that packed form. Signal deaths keep the
  # pre-existing "128 + signal number" convention (matching what the old
  # Port-based `kill -9` path produced, so a SIGKILL still shows up as
  # status 137) for anyone already expecting that shape; normal exits
  # print the plain code, matching every existing test (`"XT_EXIT 0"`,
  # `"XT_EXIT 3"`, ...).
  defp exit_status_of(:normal), do: 0

  defp exit_status_of({:exit_status, raw}) do
    case :exec.status(raw) do
      {:status, code} -> code
      {:signal, sig, _core_dumped} -> 128 + :exec.signal_to_int(sig)
    end
  end

  defp exit_status_of(other), do: inspect(other)
end
