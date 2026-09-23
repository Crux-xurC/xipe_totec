Code.require_file("../language.exs", __DIR__)

defmodule XipeTotec.Repl.Language.Elixir do
  @moduledoc "Elixir's `Repl.Language` self-declaration."
  @behaviour XipeTotec.Repl.Language

  @impl true
  def extensions, do: ["ex", "exs"]
end
