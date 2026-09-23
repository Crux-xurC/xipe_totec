defmodule XipeTotec.Repl.Eval.Scan.Direct.Iex do
  @moduledoc """
  Per-(transport, REPL) preprocessing for an `iex` session reached over
  `XipeTotec.Repl.Sender.Direct`'s plain pipe: extracts the `XT_EXIT
  <status>` occurrence out of the buffer before it reaches the generic
  `Repl.Eval.Scan`.

  Heartbeat marker stripping (`XT_HEARTBEAT`) was removed here 2026-09-22
  (Old.md §23) along with the rest of the heartbeat mechanism --
  hang detection is now `Sender.interrupt/1` + a fixed deadline, not
  heartbeat liveness, so there is nothing left to strip. `XT_EXIT`
  handling is unrelated to hang detection (it is `Sender`'s own exit
  signal, §16.3's own protocol note) and stays.

  The module path is two-dimensional on purpose (`Scan.<transport>.
  <repl>`, 2026-09-18 -- crux's revision after noticing `Launch`/
  `FieldDrip` are keyed by REPL/language while a transport-only `Scan.
  Direct` broke that consistency): the noise this layer strips is
  empirically a transport property (PTY echo/ANSI vs. plain-pipe silence,
  confirmed live -- `Old.md` §10.4), but a given REPL
  could turn out to have its own quirks beyond that, so both axes get an
  explicit place rather than picking one and hoping it's the only one
  that ever varies. Today only this one combination (`Direct` + `Iex`)
  exists; `lib/repl/eval/scan/pty/` is an empty placeholder for when a
  PTY-backed `Sender` exists.

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
