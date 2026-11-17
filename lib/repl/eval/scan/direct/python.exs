Code.require_file("iex.exs", __DIR__)

defmodule XipeTotec.Repl.Eval.Scan.Direct.Python do
  @moduledoc """
  `python -i` reached over `Sender.Direct`'s pipe. Like `iex` over the
  same pipe there is no echo or ANSI noise to strip -- only `Sender`'s
  `XT_EXIT` line; the REPL's `>>> ` / `... ` prompts (stderr, forwarded the
  same way) stay in the buffer, inert to the generic `Repl.Eval.Scan` (it
  matches one call id's markers wherever they are).
  """

  @spec clean(String.t()) :: XipeTotec.Repl.Eval.Scan.Direct.Iex.t()
  defdelegate clean(buffer), to: XipeTotec.Repl.Eval.Scan.Direct.Iex
end
