Code.require_file("elixir.exs", __DIR__)

defmodule XipeTotec.Repl.Eval.FieldDrip.Ocaml do
  @moduledoc """
  OCaml's `FieldDrip` (Old.md §42): `embody.ml` writes the same
  `repr=`/`type=`/`compare=`/`display=` body every language does, so the
  reading is Elixir's. `type` is the toplevel's own type text
  (`Target.shape list`), finer than Elixir's (`next_step.md` §2.6).
  """

  @behaviour XipeTotec.Repl.Eval.FieldDrip

  @impl true
  defdelegate parse(body), to: XipeTotec.Repl.Eval.FieldDrip.Elixir
end
