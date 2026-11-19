Code.require_file("iex.exs", __DIR__)

defmodule XipeTotec.Repl.Eval.Scan.Direct.Scala do
  @moduledoc """
  Scala 3's REPL reached over `Sender.Direct`'s pipe. Its prompt
  (`scala> `), the echo of each definition (`val xt_<id>: T = …`, in ANSI
  colours) and the compiler's messages stay in the buffer, inert to the
  generic `Repl.Eval.Scan` (it matches one call id's markers wherever they
  are, after a prompt too); only `Sender`'s `XT_EXIT` line is removed.
  """

  @spec clean(String.t()) :: XipeTotec.Repl.Eval.Scan.Direct.Iex.t()
  defdelegate clean(buffer), to: XipeTotec.Repl.Eval.Scan.Direct.Iex
end
