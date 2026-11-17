Code.require_file("elixir.exs", __DIR__)

defmodule XipeTotec.Repl.Eval.FieldDrip.Python do
  @moduledoc """
  Python's `FieldDrip`: `embody.py` writes the same
  `repr=`/`type=`/`compare=`/`display=` (and `bin_base64=`) body every
  language does, so the reading is Elixir's. `type` is the value's class,
  qualified by its module unless it is a builtin (`geo.shape.Point`, `int`).
  """

  @behaviour XipeTotec.Repl.Eval.FieldDrip

  @impl true
  defdelegate parse(body), to: XipeTotec.Repl.Eval.FieldDrip.Elixir
end
