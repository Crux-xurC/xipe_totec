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

  @ready_marker "XT_READY"

  @doc """
  Blocks the calling process until the REPL `message` (`Repl.Launch`)
  launched is ready for input, in two stages (Old.md §25.3, 2026-09-26):

    1. `message["ready_pattern"]` (the REPL's own banner) appears in the
       output -- skipped when `nil`
    2. `message["ready_probe"]` is written with `sender.write/2` and the
       REPL prints `XT_READY` -- skipped when `nil`

  Fails if the process exits first (the "XT_EXIT" marker turns up -- e.g. a
  bad launch command or a compile error at boot) or `timeout` (for both
  stages together) elapses.
  """
  @spec await_ready(module(), term(), map(), timeout()) ::
          :ok | {:error, :timeout} | {:error, {:exited_before_ready, String.t()}}
  def await_ready(sender, handle, message, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    with {:ok, rest} <- wait_for(handle, message["ready_pattern"], "", deadline) do
      case message["ready_probe"] do
        nil ->
          :ok

        probe ->
          sender.write(handle, probe)

          case wait_for(handle, @ready_marker, rest, deadline) do
            {:ok, _rest} -> :ok
            error -> error
          end
      end
    end
  end

  # `{:ok, output after pattern}` once `pattern` is in the output (`nil`:
  # right away)
  defp wait_for(_handle, nil, buffer, _deadline), do: {:ok, buffer}

  defp wait_for(handle, pattern, buffer, deadline) do
    cond do
      String.contains?(buffer, pattern) ->
        [_, rest] = String.split(buffer, pattern, parts: 2)
        {:ok, rest}

      match = Regex.run(~r/XT_EXIT (\S+)/, buffer) ->
        {:error, {:exited_before_ready, Enum.at(match, 1)}}

      true ->
        receive do
          {^handle, {:data, chunk}} -> wait_for(handle, pattern, buffer <> chunk, deadline)
        after
          max(deadline - System.monotonic_time(:millisecond), 0) -> {:error, :timeout}
        end
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
