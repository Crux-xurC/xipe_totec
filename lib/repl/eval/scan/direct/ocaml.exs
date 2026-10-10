Code.require_file("iex.exs", __DIR__)

defmodule XipeTotec.Repl.Eval.Scan.Direct.Ocaml do
  @moduledoc """
  The plain `ocaml` toplevel reached over `Sender.Direct`'s pipe.
  Like `iex` over the same pipe there is no echo or ANSI noise to
  strip -- only `Sender`'s `XT_EXIT` line; the toplevel's own prompts and
  `- : unit = ()` lines stay in the buffer, inert to the generic
  `Repl.Eval.Scan` (it only ever matches one call id's markers).
  """

  @spec clean(String.t()) :: XipeTotec.Repl.Eval.Scan.Direct.Iex.t()
  defdelegate clean(buffer), to: XipeTotec.Repl.Eval.Scan.Direct.Iex
end
