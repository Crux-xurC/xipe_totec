Code.require_file("../language.exs", __DIR__)
Code.require_file("../../scanner/php.exs", __DIR__)

defmodule XipeTotec.Repl.Language.Php do
  @moduledoc """
  PHP's `Repl.Language` self-declaration: a **map-only** language. Its
  files are read by PHP's own lexer (`Scanner.Php`) and its functions and
  methods are cards and links; no REPL, so no calc rows
  ([D-map-only-language](../../../document/verification/lib-repl-language.exs.md#d-map-only-language);
  why: `document/evolving.md` §4.7, decided 2026-11-20: PHP stops at the
  map, a driver is left to whoever needs one).
  """
  @behaviour XipeTotec.Repl.Language

  @impl true
  def extensions, do: ["php"]

  @impl true
  def build_tools, do: [%{"name" => "composer", "markers" => ["composer.json"]}]

  @impl true
  def scanner, do: [XipeTotec.Scanner.Php]
end
