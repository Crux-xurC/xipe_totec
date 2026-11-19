Code.require_file("../language.exs", __DIR__)
Code.require_file("../../scanner/javascript.exs", __DIR__)

defmodule XipeTotec.Repl.Language.TypeScript do
  @moduledoc """
  TypeScript's `Repl.Language` self-declaration: a **map-only** language. Its
  files are scanned (`Scanner.JavaScript`, shared with JavaScript) and its
  functions are cards and links; no REPL, so no calc rows
  ([D-map-only-language](../../../document/verification/lib-repl-language.exs.md#d-map-only-language);
  why: `document/evolving.md` §4.1).
  """
  @behaviour XipeTotec.Repl.Language

  @impl true
  def extensions, do: ["ts", "tsx", "mts", "cts"]

  # the lock file names the package manager; package.json alone is npm
  @impl true
  def build_tools,
    do: [
      %{"name" => "pnpm", "markers" => ["pnpm-lock.yaml"]},
      %{"name" => "yarn", "markers" => ["yarn.lock"]},
      %{"name" => "bun", "markers" => ["bun.lockb", "bun.lock"]},
      %{"name" => "npm", "markers" => ["package-lock.json", "package.json"]}
    ]

  @impl true
  def scanner, do: [XipeTotec.Scanner.JavaScript]
end
