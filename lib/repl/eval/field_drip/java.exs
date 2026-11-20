Code.require_file("scala.exs", __DIR__)

defmodule XipeTotec.Repl.Eval.FieldDrip.Java do
  @moduledoc """
  Java's `FieldDrip`: `embody.scala` (with Java's seam `embody.java`) writes
  the same `repr=`/`type=`/`compare=`/`display=` (and `bin_base64=`) body
  every language does, so the reading is Scala's. `type` is written the
  Scala way for what Scala names (`Int`, `String`, `Array[Int]`), else the
  JVM class with its package (`sample.Point`, `java.util.ArrayList`).
  """

  @behaviour XipeTotec.Repl.Eval.FieldDrip

  @impl true
  defdelegate parse(body), to: XipeTotec.Repl.Eval.FieldDrip.Scala
end
