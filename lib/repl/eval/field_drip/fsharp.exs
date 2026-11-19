Code.require_file("elixir.exs", __DIR__)

defmodule XipeTotec.Repl.Eval.FieldDrip.FSharp do
  @moduledoc """
  F#'s `FieldDrip`: `embody.fsx` writes the same
  `repr=`/`type=`/`compare=`/`display=` (and `bin_base64=`) body every
  language does, so the reading is Elixir's. `type` is written the F# way
  (`int`, `int list`, `struct (int * string)`, `int -> int`), else the
  .NET name with its namespace (`Sample.Point`,
  `System.Collections.Generic.List<int>`).
  """

  @behaviour XipeTotec.Repl.Eval.FieldDrip

  @impl true
  defdelegate parse(body), to: XipeTotec.Repl.Eval.FieldDrip.Elixir
end
