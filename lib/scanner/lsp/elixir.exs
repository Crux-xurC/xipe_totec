Code.require_file("../lsp.exs", __DIR__)

defmodule XipeTotec.Scanner.Lsp.Elixir do
  @moduledoc """
  Elixir through elixir-ls (`Scanner.Lsp`'s dialect for it). What elixir-ls
  reports, checked against elixir-ls 0.30.0 (2026-09-25):

    * `documentSymbol`: modules are kind 2 with their name as written
      (`Inner` for `defmodule Inner` nested in `Calc`); functions are kind
      12, named `add/2`, with `detail` `"def"`/`"defp"`/...
    * `outgoingCalls`: callee items are named fully -- `Calc.Inner.twice/1`,
      `Calc.add/2` for `&add/2`, `Enum.reduce/3` for the standard library
      (no node, so no link) -- while their ranges don't point at the
      definition, hence matching by name.

  The anykey is the arity, as in `Scanner.Elixir`, so a node keeps its id
  whichever of the two read it last.
  """

  @behaviour XipeTotec.Scanner
  @behaviour XipeTotec.Scanner.Lsp.Dialect

  alias XipeTotec.Scanner.Lsp

  @module_kind 2
  @function_kind 12
  @definition_details ~w(def defp defmacro defmacrop defguard defguardp defdelegate)

  @impl XipeTotec.Scanner
  def begin(root, language, opts), do: Lsp.begin(__MODULE__, root, language, opts)

  @impl XipeTotec.Scanner
  def finish(ctx), do: Lsp.finish(ctx)

  @impl XipeTotec.Scanner
  def describe(ctx), do: Lsp.describe(ctx)

  @impl XipeTotec.Scanner
  def scan_defs(book, sheet_id, file), do: Lsp.scan_defs(book, sheet_id, file)

  @impl XipeTotec.Scanner
  def scan_links_report(book, node_ids, file), do: Lsp.scan_links_report(book, node_ids, file)

  @impl XipeTotec.Scanner.Lsp.Dialect
  def language_id, do: "elixir"

  @impl XipeTotec.Scanner.Lsp.Dialect
  def lsp_command, do: ["elixir-ls"]

  @impl XipeTotec.Scanner.Lsp.Dialect
  def container?(%{"kind" => kind}), do: kind == @module_kind

  @impl XipeTotec.Scanner.Lsp.Dialect
  def definition(%{"kind" => @function_kind, "detail" => detail, "name" => name}, [_ | _] = containers)
      when detail in @definition_details do
    case Regex.run(~r{^(.+)/(\d+)$}, name) do
      [_, fun, arity] -> %{module: Enum.join(containers, "."), name: fun, anykey: String.to_integer(arity)}
      nil -> nil
    end
  end

  def definition(_symbol, _containers), do: nil

  @impl XipeTotec.Scanner.Lsp.Dialect
  def callee_key(%{"name" => name}) do
    case Regex.run(~r{^(.+)\.([^.]+)/(\d+)$}, name) do
      [_, module, fun, arity] -> {module, fun, String.to_integer(arity)}
      nil -> nil
    end
  end

  def callee_key(_item), do: nil
end
