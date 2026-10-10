defmodule XipeTotec.Repl.Eval.Scan.Direct.Iex do
  @moduledoc """
  Per-(transport, REPL) preprocessing for an `iex` session reached over
  `XipeTotec.Repl.Sender.Direct`'s plain pipe: extracts the `XT_EXIT
  <status>` occurrence out of the buffer before it reaches the generic
  `Repl.Eval.Scan`.

  The module path has two axes, `Scan.<transport>.<repl>`: the noise this
  layer strips is mostly a transport property (PTY echo/ANSI vs. a silent
  plain pipe), but a REPL can have quirks of its own.

  Confirmed live that a plain, non-PTY pipe has no input echo and no ANSI
  noise, so `clean/1` here has nothing else to strip beyond exit -- it
  stays this simple only because of what `Direct` actually is; a
  `Scan.Pty.*` module would need real echo/ANSI handling.
  """

  @type t :: %{buffer: String.t(), exit_status: String.t() | nil}

  @doc """
  Strips the `XT_EXIT <status>` line (if any -- a session only ever exits
  once) out of `buffer`. Returns the cleaned buffer plus the exit status
  seen, if any.
  """
  @spec clean(String.t()) :: t()
  def clean(buffer) do
    {buffer, exit_status} = strip_exit(buffer)
    %{buffer: buffer, exit_status: exit_status}
  end

  defp strip_exit(buffer) do
    case Regex.run(~r/XT_EXIT (\S+)\n/, buffer) do
      [whole, status] -> {String.replace(buffer, whole, "", global: false), status}
      nil -> {buffer, nil}
    end
  end
end
