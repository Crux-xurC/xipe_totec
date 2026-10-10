Code.require_file("sender.exs", __DIR__)
Code.require_file("../project_env.exs", __DIR__)

defmodule XipeTotec.Repl.Sender.Direct do
  @moduledoc """
  Default `Repl.Sender`: spawns the process locally via `erlexec`
  (`:exec.run/2`), in its own process group (`{:group, 0}`). `kill/1`'s
  group-wide SIGKILL and `interrupt/1`'s group-wide SIGINT need that group:
  without one, a Ctrl-C on xipe_totec's own CLI process would hit the REPL
  too, and a REPL that forks children (`iex -S mix`'s build step) would
  leave them orphaned by a single-pid kill.

  The returned `handle` is a `GenServer` pid, not the erlexec ospid:
  `Repl.Sender`'s contract requires exit to show up as an `"XT_EXIT
  <status>"` marker inside the ordinary `:data` stream, and
  `write/2`/`kill/1`/`interrupt/1` to work against the same handle -- so
  this module owns the ospid privately and exposes only the generic
  contract.

  Not supervised: if the caller dies without calling `kill/1`, this
  GenServer (and the OS process group under it) is orphaned.
  """

  use GenServer

  @behaviour XipeTotec.Repl.Sender

  @sigint 2
  @sigkill 9

  @impl XipeTotec.Repl.Sender
  def send(%{"kind" => "repl/launch", "argv" => [exe | args], "env" => env, "cwd" => cwd} = message)
      when is_binary(exe) and is_list(args) and is_map(env) and is_binary(cwd) do
    # a PATH in env (the project's environment, ProjectEnv) is where the
    # project's own REPL is found
    case XipeTotec.ProjectEnv.find_executable(exe, env) do
      nil ->
        {:error, {:executable_not_found, exe}}

      path ->
        files = Map.get(message, "files", [])
        spawn_args = with_files(args, files)
        argv = Enum.map([path | spawn_args], &String.to_charlist/1)
        # binaries, not charlists: erlexec refuses a flake's environment
        # (empty values, UTF-8 text) passed as charlists, and accepts the
        # same values as binaries
        exec_env = Map.to_list(env)
        start_linked({argv, cwd, exec_env, self()})
    end
  end

  def send(other), do: {:error, {:unsupported_message, other}}

  # GenServer.start_link/2, except that a spawn failure comes back only as
  # `{:error, {:spawn_failed, reason}}`. init/1 stopping makes the new
  # process exit, and that exit signal would otherwise take the caller (the
  # CLI, a server's pass process) down with it -- it is caught here, for
  # the duration of the start only, and discarded.
  defp start_linked(arg) do
    trapping = Process.flag(:trap_exit, true)

    try do
      case GenServer.start_link(__MODULE__, arg) do
        {:ok, pid} ->
          {:ok, pid}

        {:error, reason} ->
          receive do
            {:EXIT, _pid, _} -> :ok
          after
            0 -> :ok
          end

          {:error, reason}
      end
    after
      Process.flag(:trap_exit, trapping)
    end
  end

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
  # -- this callback itself stays a single unconditional SIGKILL.
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

  # stderr forwarded the same way stdout is: erlexec keeps them as separate
  # message tags, so this module merges them into one stream here, for every
  # downstream consumer (Scan/Parser do not distinguish the two).
  def handle_info({:stderr, ospid, bin}, %{ospid: ospid, caller: caller} = state) do
    Kernel.send(caller, {self(), {:data, bin}})
    {:noreply, state}
  end

  def handle_info({:DOWN, ospid, :process, _pid, reason}, %{ospid: ospid, caller: caller} = state) do
    Kernel.send(caller, {self(), {:data, "XT_EXIT #{exit_status_of(reason)}\n"}})
    {:stop, :normal, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # erlexec's raw :DOWN reason: a clean exit 0 is the bare atom `:normal`;
  # any other exit_status packs a nonzero exit code as `code << 8` and a
  # signal death as the bare signal number (:exec.status/1 decodes that).
  # A signal death is printed as "128 + signal number" (SIGKILL is 137), a
  # normal exit as the plain code (`"XT_EXIT 0"`, `"XT_EXIT 3"`).
  defp exit_status_of(:normal), do: 0

  defp exit_status_of({:exit_status, raw}) do
    case :exec.status(raw) do
      {:status, code} -> code
      {:signal, sig, _core_dumped} -> 128 + :exec.signal_to_int(sig)
    end
  end

  defp exit_status_of(other), do: inspect(other)
end
