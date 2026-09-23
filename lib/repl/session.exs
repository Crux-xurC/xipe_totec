defmodule XipeTotec.Repl.Session do
  @moduledoc """
  Generic session-lifecycle orchestration (Old.md §10.2, 2026-09-18):
  built only from `Repl.Sender`'s three primitives (`send/1`, `write/2`,
  `kill/1`) and the per-language values `Repl.Launch` computes
  (`ready_pattern`, `exit_input`) -- no language-specific branching lives
  here at all. Adding a new REPL language later means writing a new
  `Repl.Launch`-equivalent that computes different values; this module
  doesn't change.
  """

  @doc """
  Blocks the calling process until `ready_pattern` appears somewhere in
  the handle's accumulated output, the process exits first (the "XT_EXIT"
  marker turns up before `ready_pattern` ever does -- e.g. a bad launch
  command), or `timeout` elapses with neither.
  """
  @spec await_ready(term(), String.t(), timeout()) ::
          :ok | {:error, :timeout} | {:error, {:exited_before_ready, String.t()}}
  def await_ready(handle, ready_pattern, timeout \\ 10_000), do: scan_ready(handle, ready_pattern, "", timeout)

  defp scan_ready(handle, ready_pattern, buffer, timeout) do
    receive do
      {^handle, {:data, chunk}} ->
        buffer = buffer <> chunk

        cond do
          String.contains?(buffer, ready_pattern) ->
            :ok

          match = Regex.run(~r/XT_EXIT (\S+)/, buffer) ->
            {:error, {:exited_before_ready, Enum.at(match, 1)}}

          true ->
            scan_ready(handle, ready_pattern, buffer, timeout)
        end
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc """
  Graceful-then-forceful shutdown: writes `exit_input` via `sender.write/2`,
  then waits up to `graceful_timeout` for the "XT_EXIT" marker. If it
  doesn't show up (Old.md §10.2's caveat -- the session wasn't
  reading stdin, whether busy or hung), escalates to `sender.kill/1` and
  waits again with no timeout, since `kill/1` is documented to always end
  the session eventually. Either way this always returns once exit has
  actually been observed -- never just "gave up waiting".
  """
  @spec close(module(), term(), String.t(), timeout()) :: :ok
  def close(sender, handle, exit_input, graceful_timeout \\ 5_000) do
    sender.write(handle, exit_input)

    case await_exit(handle, "", graceful_timeout) do
      :ok ->
        :ok

      {:error, :timeout} ->
        sender.kill(handle)
        :ok = await_exit(handle, "", :infinity)
        :ok
    end
  end

  defp await_exit(handle, buffer, timeout) do
    receive do
      {^handle, {:data, chunk}} ->
        buffer = buffer <> chunk
        if String.contains?(buffer, "XT_EXIT "), do: :ok, else: await_exit(handle, buffer, timeout)
    after
      timeout -> {:error, :timeout}
    end
  end
end
