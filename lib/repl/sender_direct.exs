Code.require_file("sender.exs", __DIR__)

defmodule XipeTotec.Repl.Sender.Direct do
  @moduledoc """
  Default `Repl.Sender`: spawns the process locally via a bare `Port`, no
  extra dependency. xipe_totec earlier decided against pulling in
  `erlexec` for the §16 WS server, reasoning that xipe_totec is the side
  being connected TO there, not the side connecting out (see
  xipe-totec-design memory, Tier 0 note). A REPL launch is a genuine
  "connecting out" need, but a plain argv+env+cwd spawn is exactly what
  Erlang's own `Port` already does, so that reasoning still holds -- no
  new dependency needed for this.

  The returned `handle` is a `GenServer` pid, not the raw `Port` itself:
  `Repl.Sender`'s contract requires exit to show up as an `"XT_EXIT
  <status>"` marker inside the ordinary `:data` stream rather than as a
  `Port`-specific `:exit_status` message, and requires `write/2`/`kill/1`
  to work against the same handle -- so this module owns the real port
  privately and exposes only the generic contract.

  Not supervised -- if the caller dies without calling `kill/1`, this
  GenServer (and the OS process under it) is orphaned. Session/process
  lifecycle beyond that is `Repl.Session`'s and, eventually, `Evaluator`'s
  concern (プロセスアーキテクチャ, E in 課題.mkd), not this module's.
  """

  use GenServer

  @behaviour XipeTotec.Repl.Sender

  @impl XipeTotec.Repl.Sender
  def send(%{"kind" => "repl/launch", "argv" => [exe | args], "env" => env, "cwd" => cwd} = message)
      when is_binary(exe) and is_list(args) and is_map(env) and is_binary(cwd) do
    case System.find_executable(exe) do
      nil ->
        {:error, {:executable_not_found, exe}}

      path ->
        files = Map.get(message, "files", [])
        spawn_args = with_files(args, files)
        port_env = Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
        GenServer.start_link(__MODULE__, {path, spawn_args, cwd, port_env, self()})
    end
  end

  def send(other), do: {:error, {:unsupported_message, other}}

  @impl XipeTotec.Repl.Sender
  def write(handle, text) when is_binary(text), do: GenServer.call(handle, {:write, text})

  @impl XipeTotec.Repl.Sender
  def kill(handle), do: GenServer.call(handle, :kill)

  # `message["files"]` is plain data, opaque to `Repl.Launch` -- this
  # sender decides the only thing it means for *this* delivery mechanism:
  # one `-r <file>` pair per file, inserted before the rest of argv (so it
  # works whether `args` came from the mix-mode default or a scripts-mode
  # override). Exposed (not `defp`) so this decision is unit-testable
  # without spawning a real process.
  @spec with_files([String.t()], [String.t()]) :: [String.t()]
  def with_files(args, files), do: Enum.flat_map(files, &["-r", &1]) ++ args

  # ---------------------------------------------------------------------
  # GenServer: privately owns the real Port, translates its two native
  # message shapes into Repl.Sender's single `{handle, {:data, ...}}`
  # contract (sender.exs has the full rationale).
  # ---------------------------------------------------------------------

  @impl GenServer
  def init({path, args, cwd, env, caller}) do
    port =
      Port.open({:spawn_executable, path}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        cd: cwd,
        env: env
      ])

    {:ok, %{port: port, caller: caller}}
  end

  @impl GenServer
  def handle_call({:write, text}, _from, %{port: port} = state) do
    Port.command(port, text)
    {:reply, :ok, state}
  rescue
    e -> {:reply, {:error, e}, state}
  end

  # `Port.close/1` alone is NOT enough here: closing a port's pipes does
  # not itself guarantee the OS process notices and exits (the well-known
  # Erlang gotcha -- a process that isn't checking stdin/stdout can just
  # keep running as an orphan), and "doesn't notice" is exactly the hung
  # state this callback exists to handle. So this sends a real SIGKILL to
  # the OS process by pid. The port then detects the death on its own and
  # delivers the ordinary `{:exit_status, ...}` message through the same
  # `handle_info` clause below as any other exit (128 + signal number per
  # Erlang's own convention, so SIGKILL shows up as status 137) -- kill/1
  # doesn't need to (and doesn't) synthesize the XT_EXIT marker itself.
  def handle_call(:kill, _from, %{port: port} = state) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> System.cmd("kill", ["-9", Integer.to_string(os_pid)])
      nil -> :ok
    end

    {:reply, :ok, state}
  rescue
    e -> {:reply, {:error, e}, state}
  end

  @impl GenServer
  def handle_info({port, {:data, bin}}, %{port: port, caller: caller} = state) do
    Kernel.send(caller, {self(), {:data, bin}})
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port, caller: caller} = state) do
    Kernel.send(caller, {self(), {:data, "XT_EXIT #{status}\n"}})
    {:stop, :normal, state}
  end
end
