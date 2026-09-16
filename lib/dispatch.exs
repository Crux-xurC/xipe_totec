Code.require_file("book.exs", __DIR__)
Code.require_file("core.exs", __DIR__)
Code.require_file("id.exs", __DIR__)
Code.require_file("project.exs", __DIR__)
Code.require_file("address.exs", __DIR__)
Code.require_file("graph_query.exs", __DIR__)

defmodule XipeTotec.Dispatch do
  @moduledoc """
  §16.3 client -> server method table (prebuild.md §9, 2026-09-17). Stays as
  pure as `Core` -- `handle/4` takes a `Book` and returns a `Book`. The one
  exception is `scan/run`, which needs `ctx.root` to read source files off
  disk (the same "orchestration one level above pure Core" shape
  `XipeTotec.Project` itself already has). No method here ever touches
  `Store` -- `Serve.Project` (not yet built) is the one place that diffs the
  book before/after a `handle/4` call and persists whatever changed, the
  same way `Project.persist_scan` already diffs `scan_dir`'s before/after --
  just generalized from sheets/nodes/links to all six tables.

  Tier map (prebuild.md §9): only Tier 1 methods actually do anything here.
  Tier 2-5 methods are still real entries in `@not_implemented` (so an
  unknown-method error and a not-implemented-yet error are visibly
  different things to a client) but every one of them returns a clean
  `{:error, book, reason}` instead of touching `Book` -- no half-fulfilled
  contracts. `row/update`'s spec text explicitly promises a recalc result
  back; the edit half (`Core.edit_args`/`set_prev`) is done and waiting, but
  since the promised result can't be produced without Evaluator, the whole
  method stays unimplemented rather than silently only doing the edit half.

  `initialize`/`subscribe` are deliberately not entries here at all (not
  even in `@not_implemented`) -- they're transport/session bookkeeping
  (prebuild.md §9: session state lives in `Serve.Socket`, not
  `Serve.Project`), not `Book` operations. `Serve.Socket` intercepts them
  before a message ever reaches here.
  """

  alias XipeTotec.{Address, Book, Core, GraphQuery, Id, Project}

  @type ctx :: %{optional(:root) => String.t()}
  @type result :: {:ok, Book.t(), map()} | {:error, Book.t(), map()}

  @valid_effects ["pure", "reads", "writes", "unknown"]

  # Real methods (spec §16.3), genuinely not built yet -- see moduledoc.
  @not_implemented ~w(
    row/update eval/run cell/complete edit/propose edit/apply
    trace/start trace/stop trace/get trace/import provider/recheck
  )

  @spec handle(Book.t(), String.t(), map(), ctx) :: result
  def handle(book, method, params, ctx \\ %{})

  def handle(book, "scan/run", _params, ctx) do
    root = Map.fetch!(ctx, :root)
    {new_book, paths} = Project.scan_dir(book, root)

    {:ok, new_book,
     %{
       "paths" => paths,
       "sheets" => map_size(new_book.sheets),
       "nodes" => map_size(new_book.nodes),
       "links" => map_size(new_book.links)
     }}
  end

  def handle(book, "row/add", %{"node" => node_id, "args" => args}, _ctx)
      when is_binary(node_id) and is_list(args) do
    if Enum.all?(args, &is_binary/1) do
      id = Id.ulid()
      new_book = Core.add_call(book, id, %{node: node_id, args: args})
      {:ok, new_book, %{"id" => id, "row" => Book.get(new_book, :calls, id)}}
    else
      {:error, book, invalid_params("row/add needs node (string) and args ([string])")}
    end
  end

  def handle(book, "row/add", _params, _ctx),
    do: {:error, book, invalid_params("row/add needs node (string) and args ([string])")}

  def handle(book, "row/remove", %{"id" => call_id}, _ctx) when is_binary(call_id) do
    {:ok, Core.remove_call(book, call_id), %{"id" => call_id}}
  end

  def handle(book, "row/remove", _params, _ctx),
    do: {:error, book, invalid_params("row/remove needs id (string)")}

  def handle(book, "effect/set", %{"id" => node_id, "effect" => effect}, _ctx)
      when is_binary(node_id) and effect in @valid_effects do
    try do
      {:ok, Core.set_effect(book, node_id, effect), %{"id" => node_id, "effect" => effect}}
    rescue
      # Core.set_effect/3 -> fetch!/3 raises a plain RuntimeError on an
      # unknown node id -- fine inside Core's own trusted-caller tests, not
      # fine at this JSON-RPC boundary, so it's turned into a clean error
      # reply here rather than crashing the session (Serve.Socket/Project).
      RuntimeError -> {:error, book, not_found("node", node_id)}
    end
  end

  def handle(book, "effect/set", _params, _ctx),
    do:
      {:error, book,
       invalid_params("effect/set needs id (string) and effect (#{Enum.join(@valid_effects, "|")})")}

  def handle(book, method, params, _ctx) when method in ["card/get", "card/search"] and is_map(params) do
    # card/search's spec text additionally promises "型による逆引き"
    # (reverse lookup by type) -- that needs a provider/* round trip to the
    # client (prebuild.md §9: deferred, no client implements it yet), so for
    # now both methods just run the same address resolution.
    case Address.resolve(book, params) do
      {:ok, matches} ->
        {:ok, book, %{"matches" => Enum.map(matches, &render_match(book, &1))}}

      {:error, {:unsupported_column, col}} ->
        {:error, book, %{"code" => "unsupported_column", "message" => col}}
    end
  end

  def handle(book, method, _params, _ctx) when method in ["card/get", "card/search"],
    do: {:error, book, invalid_params("#{method} needs an address object (spec §6.1)")}

  def handle(book, "graph/neighbors", %{"address" => address} = params, _ctx) when is_map(address) do
    with {:ok, depth} <- normalize_depth(Map.get(params, "depth", 1)),
         {:ok, direction} <- parse_direction(Map.get(params, "direction", "both")),
         {:ok, result} <- GraphQuery.neighbors(book, address, depth, direction) do
      {:ok, book, result}
    else
      {:error, {:unsupported_column, col}} -> {:error, book, %{"code" => "unsupported_column", "message" => col}}
      {:error, message} when is_binary(message) -> {:error, book, invalid_params(message)}
    end
  end

  def handle(book, "graph/neighbors", _params, _ctx),
    do: {:error, book, invalid_params("graph/neighbors needs an address object under \"address\"")}

  def handle(book, "graph/export", %{"address" => address, "format" => format} = params, _ctx)
      when is_map(address) and format in ["mermaid", "dot", "json", "doctest"] do
    with {:ok, depth} <- normalize_depth(Map.get(params, "depth", 1)),
         {:ok, text} <- GraphQuery.export(book, address, depth, format) do
      {:ok, book, %{"format" => format, "text" => text}}
    else
      {:error, {:unsupported_column, col}} -> {:error, book, %{"code" => "unsupported_column", "message" => col}}
      {:error, message} when is_binary(message) -> {:error, book, invalid_params(message)}
    end
  end

  def handle(book, "graph/export", _params, _ctx),
    do:
      {:error, book,
       invalid_params("graph/export needs address, format (mermaid|dot|json|doctest) under \"address\"/\"format\"")}

  def handle(book, method, _params, _ctx) when method in @not_implemented,
    do: {:error, book, %{"code" => "not_implemented", "message" => "#{method}: not implemented yet (prebuild.md §9 tier map)"}}

  def handle(book, method, _params, _ctx),
    do: {:error, book, %{"code" => "unknown_method", "message" => method}}

  defp invalid_params(message), do: %{"code" => "invalid_params", "message" => message}
  defp not_found(kind, id), do: %{"code" => "not_found", "message" => "unknown #{kind} id: #{id}"}

  defp normalize_depth(d) when is_integer(d) and d >= 0, do: {:ok, d}

  defp normalize_depth(d) when is_binary(d) do
    case Integer.parse(d) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, "depth must be a non-negative integer"}
    end
  end

  defp normalize_depth(_), do: {:error, "depth must be a non-negative integer"}

  defp parse_direction("in"), do: {:ok, :in}
  defp parse_direction("out"), do: {:ok, :out}
  defp parse_direction("both"), do: {:ok, :both}
  defp parse_direction(other), do: {:error, "direction must be one of in|out|both, got #{inspect(other)}"}

  defp render_match(book, {:nodes, id, row}), do: compose_card(book, id, row)
  defp render_match(_book, {:calls, id, row}), do: %{"id" => id, "row" => row}

  # spec glossary: "カード = 1関数分の行のまとまり" -- a node plus its own
  # calc rows and link rows, not just the bare node row.
  defp compose_card(book, node_id, node_row) do
    calls = for {id, row} <- book.calls, row.node == node_id, do: Map.put(row, :id, id)
    links = for {id, row} <- book.links, row.node == node_id, do: Map.put(row, :id, id)
    %{"id" => node_id, "node" => node_row, "calls" => calls, "links" => links}
  end
end
