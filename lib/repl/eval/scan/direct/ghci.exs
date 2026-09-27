Code.require_file("iex.exs", __DIR__)

defmodule XipeTotec.Repl.Eval.Scan.Direct.Ghci do
  @moduledoc """
  GHCi reached over `Sender.Direct`'s pipe (Old.md §46). With `-v0` there is
  no banner or prompt, and a pipe has no echo -- only `Sender`'s `XT_EXIT`
  line to strip; GHCi's own messages (a parse error) stay in the buffer,
  inert to the generic `Repl.Eval.Scan`.
  """

  @spec clean(String.t()) :: XipeTotec.Repl.Eval.Scan.Direct.Iex.t()
  defdelegate clean(buffer), to: XipeTotec.Repl.Eval.Scan.Direct.Iex
end
