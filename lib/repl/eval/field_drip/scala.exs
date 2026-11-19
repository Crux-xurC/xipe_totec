Code.require_file("elixir.exs", __DIR__)

defmodule XipeTotec.Repl.Eval.FieldDrip.Scala do
  @moduledoc """
  Scala's `FieldDrip`: `embody.scala` writes the same
  `repr=`/`type=`/`compare=`/`display=` (and `bin_base64=`) body every
  language does, so the reading is Elixir's. `type` is the running value's
  (`Int`, `List[Int]`, `(Int, String)`, `calc.Point`): the static type is
  not known at run time.
  """

  @behaviour XipeTotec.Repl.Eval.FieldDrip

  @impl true
  defdelegate parse(body), to: XipeTotec.Repl.Eval.FieldDrip.Elixir
end
