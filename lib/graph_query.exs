Code.require_file("book.exs", __DIR__)
Code.require_file("address.exs", __DIR__)

defmodule XipeTotec.GraphQuery do
  @moduledoc """
  `graph/neighbors` and `graph/export` (spec §16.3, Old.md §9,
  2026-09-17). Built on the static `node --role("to")--> ref` call graph in
  `:links` rows -- **not** `Core.reference_graph/1`, which is the `⟦id⟧`
  *calc-row* reference graph Core uses for recalculation propagation. Spec's
  own words for `graph/neighbors` are 受信元/送信先 (incoming/outgoing),
  matching how link rows are described in the glossary ("関数の接続関係を
  表す行。受信元…送信先のセルを持つ") -- a different graph than the one
  Core already builds for a different purpose.

  `Scanner.scan_links/3` only ever writes `role: "to"` (node -> callee) --
  there is no stored `"from"` role, so "incoming" is always a reverse
  lookup over `ref`, never a direct table read (the same asymmetry
  `Core.dep_hash_affected_nodes/2` already relies on).

  Params shape (this module's own design choice -- §16.3 doesn't spell one
  out): `graph/neighbors` takes `{"address": <§6.1 address>, "depth": n,
  "direction": "in"|"out"|"both"}` rather than a flat address like
  `card/get`, since it needs the extra depth/direction controls alongside
  the address. `graph/export` adds `"format": "mermaid"|"dot"|"json"|
  "doctest"`.

  `doctest` format is Old.md §9's 2026-09-17 decision applied: a
  frozen per-card snapshot is not a new storage mechanism, just this export
  format. Only the **table-fallback** path is implemented here (today's
  stored values, no re-evaluation) -- the higher-fidelity "re-run through
  the REPL in isolation first" path needs Evaluator (Tier 3, not built),
  and the precedence between an existing frozen file and a fresh
  table-derived one is still undecided (Old.md §9), so this module
  doesn't attempt file-existence checks at all; that orchestration, if it's
  wanted, belongs a level up.
  """

  alias XipeTotec.{Address, Book}

  @type direction :: :in | :out | :both
  @type format :: String.t()

  @doc """
  Neighbors of the node(s) `address` resolves to, up to `depth` hops away,
  in `direction`. `{:ok, %{"start" => [id,...], "nodes" => %{id => node_row},
  "edges" => [%{"from" => id, "to" => id}]}}` -- `"nodes"` includes the
  start ids themselves. `Address`'s own error passes straight through.
  """
  @spec neighbors(Book.t(), Address.address(), non_neg_integer(), direction) ::
          {:ok, map()} | {:error, {:unsupported_column, String.t()}}
  def neighbors(book, address, depth, direction \\ :both) when is_integer(depth) and depth >= 0 do
    case Address.resolve(book, address) do
      {:error, _reason} = err ->
        err

      {:ok, matches} ->
        start_ids = for {:nodes, id, _row} <- matches, do: id
        {node_ids, edges} = walk(book, start_ids, depth, direction)

        {:ok,
         %{
           "start" => start_ids,
           "nodes" => for(id <- node_ids, into: %{}, do: {id, Book.get(book, :nodes, id)}),
           "edges" => for({from, to} <- edges, do: %{"from" => from, "to" => to})
         }}
    end
  end

  @doc "Render `neighbors/4`'s range in `format`. `{:error, {:bad_format, fmt}}` for an unrecognized one."
  @spec export(Book.t(), Address.address(), non_neg_integer(), format) ::
          {:ok, String.t()} | {:error, {:unsupported_column, String.t()} | {:bad_format, String.t()}}
  def export(book, address, depth, format) when format in ["mermaid", "dot", "json", "doctest"] do
    case neighbors(book, address, depth, :both) do
      {:ok, graph} -> {:ok, render(format, book, graph)}
      {:error, _reason} = err -> err
    end
  end

  def export(_book, _address, _depth, format), do: {:error, {:bad_format, format}}

  # ---------------------------------------------------------------------
  # depth-bounded BFS over the static "to" call graph
  # ---------------------------------------------------------------------

  defp walk(book, start_ids, depth, direction) do
    to_edges = for row <- Map.values(book.links), row.role == "to", do: {row.node, row.ref}
    start_set = MapSet.new(start_ids)

    if depth > 0 do
      do_walk(start_set, start_set, MapSet.new(), to_edges, depth, direction)
    else
      {start_set, MapSet.new()}
    end
  end

  defp do_walk(frontier, visited, edges, to_edges, depth, direction) do
    stepped = step(frontier, to_edges, direction)
    new_ids = stepped |> Enum.map(&other_end(&1, frontier)) |> Enum.reject(&is_nil/1)

    next_frontier = MapSet.new(new_ids) |> MapSet.difference(visited)
    next_visited = MapSet.union(visited, next_frontier)
    next_edges = MapSet.union(edges, MapSet.new(stepped))

    if depth <= 1 or MapSet.size(next_frontier) == 0 do
      {next_visited, next_edges}
    else
      do_walk(next_frontier, next_visited, next_edges, to_edges, depth - 1, direction)
    end
  end

  defp step(frontier, to_edges, :out), do: for({from, to} <- to_edges, MapSet.member?(frontier, from), do: {from, to})
  defp step(frontier, to_edges, :in), do: for({from, to} <- to_edges, MapSet.member?(frontier, to), do: {from, to})
  defp step(frontier, to_edges, :both), do: Enum.uniq(step(frontier, to_edges, :out) ++ step(frontier, to_edges, :in))

  defp other_end({from, to}, frontier) do
    cond do
      MapSet.member?(frontier, from) -> to
      MapSet.member?(frontier, to) -> from
      true -> nil
    end
  end

  # ---------------------------------------------------------------------
  # rendering
  # ---------------------------------------------------------------------

  defp render("json", _book, graph), do: JSON.encode!(graph)
  defp render("mermaid", _book, graph), do: render_mermaid(graph)
  defp render("dot", _book, graph), do: render_dot(graph)
  defp render("doctest", book, graph), do: render_doctest(book, graph)

  defp render_mermaid(graph) do
    node_lines = for {id, row} <- graph["nodes"], do: "  #{id}[\"#{escape(label(row))}\"]"
    edge_lines = for %{"from" => f, "to" => t} <- graph["edges"], do: "  #{f} --> #{t}"
    Enum.join(["graph LR" | node_lines ++ edge_lines], "\n")
  end

  defp render_dot(graph) do
    node_lines = for {id, row} <- graph["nodes"], do: "  \"#{id}\" [label=\"#{escape(label(row))}\"];"
    edge_lines = for %{"from" => f, "to" => t} <- graph["edges"], do: "  \"#{f}\" -> \"#{t}\";"
    Enum.join(["digraph xipe {" | node_lines ++ edge_lines] ++ ["}"], "\n")
  end

  defp render_doctest(book, graph) do
    graph["nodes"]
    |> Enum.map(fn {id, row} -> doctest_block(book, id, row) end)
    |> Enum.join("\n\n")
  end

  defp doctest_block(book, node_id, node_row) do
    calls = for {_id, row} <- book.calls, row.node == node_id, do: row

    lines =
      case calls do
        [] -> ["#   (no calc rows yet)"]
        _ -> Enum.map(calls, &doctest_line(node_row, &1))
      end

    Enum.join(["# #{label(node_row)}" | lines], "\n")
  end

  defp doctest_line(node_row, call_row) do
    args = Enum.join(call_row.args || [], ", ")

    result =
      call_row.result ||
        "(unevaluated -- table-fallback rendering, no REPL re-run; freshness precedence still undecided, Old.md §9)"

    "#   iex> #{node_row.name}(#{args})\n#   #{result}"
  end

  defp label(row), do: "#{row.module}.#{row.name}/#{row.arity}"
  defp escape(text), do: String.replace(text, "\"", "\\\"")
end
