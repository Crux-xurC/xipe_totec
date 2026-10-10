Code.require_file("elixir.exs", __DIR__)

defmodule XipeTotec.Repl.Eval.FieldDrip.Haskell do
  @moduledoc """
  Haskell's `FieldDrip`: `embody.hs` writes the same
  `repr=`/`type=`/`compare=`/`display=` body every language does. `type` is
  the value's `Typeable` type (`[Shape]`, `Map [Char] Int`).
  """

  @behaviour XipeTotec.Repl.Eval.FieldDrip

  @impl true
  defdelegate parse(body), to: XipeTotec.Repl.Eval.FieldDrip.Elixir
end
