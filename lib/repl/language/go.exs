Code.require_file("../language.exs", __DIR__)
Code.require_file("../../scanner/go.exs", __DIR__)

defmodule XipeTotec.Repl.Language.Go do
  @moduledoc """
  Go's `Repl.Language` self-declaration: a **map-only** language. Its files
  are read by Go's own parser (`Scanner.Go`) and its functions and methods
  are cards and links; no REPL, so no calc rows
  ([D-map-only-language](../../../document/verification/lib-repl-language.exs.md#d-map-only-language);
  why: `document/evolving.md` §4.3, decided 2026-11-20: Go stops at the
  map, a driver is left to whoever needs one).
  """
  @behaviour XipeTotec.Repl.Language

  @impl true
  def extensions, do: ["go"]

  @impl true
  def build_tools, do: [%{"name" => "go", "markers" => ["go.mod"]}]

  @impl true
  def scanner, do: [XipeTotec.Scanner.Go]
end
