defmodule XipeTotec.Repl.Eval.Scan.Direct.Iex do
  @moduledoc """
  Per-(transport, REPL) preprocessing for an `iex` session reached over
  `XipeTotec.Repl.Sender.Direct`'s plain pipe: extracts `XT_HEARTBEAT`
  and `XT_EXIT <status>` occurrences out of the buffer before it reaches
  the generic `Repl.Eval.Scan` (2026-09-18, crux's call -- since this
  layer already has to do noise cleanup, sweeping heartbeat/exit
  recognition in here too avoids a second independent pass over the same
  buffer).

  The module path is two-dimensional on purpose (`Scan.<transport>.
  <repl>`, 2026-09-18 -- crux's revision after noticing `Launch`/
  `FieldDrip` are keyed by REPL/language while a transport-only `Scan.
  Direct` broke that consistency): the noise this layer strips is
  empirically a transport property (PTY echo/ANSI vs. plain-pipe silence,
  confirmed live -- `XipeTotec_prebuild.md` §10.4), but a given REPL
  could turn out to have its own quirks beyond that, so both axes get an
  explicit place rather than picking one and hoping it's the only one
  that ever varies. Today only this one combination (`Direct` + `Iex`)
  exists; `lib/repl/eval/scan/pty/` is an empty placeholder for when a
  PTY-backed `Sender` exists.

  Confirmed live that a plain, non-PTY pipe has no input echo and no ANSI
  noise, so `clean/1` here has nothing else to strip beyond
  heartbeat/exit -- it stays this simple only because of what `Direct`
  actually is; a `Scan.Pty.*` module would need real echo/ANSI handling.
  """

  @type t :: %{buffer: String.t(), heartbeats: non_neg_integer(), exit_status: String.t() | nil}

  @doc """
  Strips every `XT_HEARTBEAT` line and the `XT_EXIT <status>` line (if
  any -- a session only ever exits once) out of `buffer`. Returns the
  cleaned buffer plus a heartbeat count and the exit status seen, if any.
  """
  @spec clean(String.t()) :: t()
  def clean(buffer) do
    {buffer, heartbeats} = strip_all(buffer, "XT_HEARTBEAT\n")
    {buffer, exit_status} = strip_exit(buffer)
    %{buffer: buffer, heartbeats: heartbeats, exit_status: exit_status}
  end

  # One `String.split/2` pass over the whole buffer, not one
  # `String.replace/3` pass *per occurrence* -- with the default 5s
  # heartbeat interval this ran O(occurrences * buffer size) before (fixed
  # 2026-09-18, wiring review): a long-running session's buffer could
  # accumulate many heartbeats between scans, and every single one used to
  # re-scan the entire buffer from scratch.
  defp strip_all(buffer, marker) do
    case String.split(buffer, marker) do
      [only] -> {only, 0}
      parts -> {Enum.join(parts, ""), length(parts) - 1}
    end
  end

  defp strip_exit(buffer) do
    case Regex.run(~r/XT_EXIT (\S+)\n/, buffer) do
      [whole, status] -> {String.replace(buffer, whole, "", global: false), status}
      nil -> {buffer, nil}
    end
  end
end
