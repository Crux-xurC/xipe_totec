Code.require_file("elixir.exs", __DIR__)

defmodule XipeTotec.Repl.Eval.FieldDrip.CSharp do
  @moduledoc """
  C#'s `FieldDrip`: `embody.fsx` (with C#'s seam `embody.cs`) writes the
  same `repr=`/`type=`/`compare=`/`display=` (and `bin_base64=`) body
  every language does, so the reading is Elixir's. `type` is written the
  F# way for F#'s own types and primitives (`int`, `int[]`, `struct (int *
  string)`, `unit` for an awaited `Task`), else the .NET name with its
  namespace (`Sample.Geo.Point`, `System.Collections.Generic.List<int>`).
  """

  @behaviour XipeTotec.Repl.Eval.FieldDrip

  @impl true
  defdelegate parse(body), to: XipeTotec.Repl.Eval.FieldDrip.Elixir
end
