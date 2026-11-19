Code.require_file("iex.exs", __DIR__)

defmodule XipeTotec.Repl.Eval.Scan.Direct.Fsi do
  @moduledoc """
  `dotnet fsi --quiet` reached over `Sender.Direct`'s pipe. Like `iex` over
  the same pipe there is no echo or ANSI noise to strip -- only `Sender`'s
  `XT_EXIT` line. fsi's own diagnostics for a submission that does not
  compile stay in the buffer (the build's output goes to a log), inert
  to the generic `Repl.Eval.Scan` (it matches one call id's markers
  wherever they are).
  """

  @spec clean(String.t()) :: XipeTotec.Repl.Eval.Scan.Direct.Iex.t()
  defdelegate clean(buffer), to: XipeTotec.Repl.Eval.Scan.Direct.Iex
end
