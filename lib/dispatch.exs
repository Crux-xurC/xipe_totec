Code.require_file("book.exs", __DIR__)
Code.require_file("core.exs", __DIR__)
Code.require_file("id.exs", __DIR__)
Code.require_file("project.exs", __DIR__)
Code.require_file("address.exs", __DIR__)
Code.require_file("graph_query.exs", __DIR__)
Code.require_file("methods.exs", __DIR__)
Code.require_file("project_env.exs", __DIR__)

defmodule XipeTotec.Dispatch do
  @moduledoc """
  §16.3 client -> server method table (Old.md §9, 2026-09-17). Stays as
  pure as `Core` -- `handle/4` takes a `Book` and returns a `Book`. The one
  exception is `scan/run`, which needs `ctx.root` to read source files off
  disk (the same "orchestration one level above pure Core" shape
  `XipeTotec.Project` itself already has). No method here ever touches
  `Store` -- `Serve.Project` (not yet built) is the one place that diffs the
  book before/after a `handle/4` call and persists whatever changed, the
  same way `Project.persist_scan` already diffs `scan_dir`'s before/after --
  just generalized from sheets/nodes/links to all six tables.

  Tier map (Old.md §9): only Tier 1 methods actually do anything here.
  Tier 2-5 methods are still real entries in `@not_implemented` (so an
  unknown-method error and a not-implemented-yet error are visibly
  different things to a client) but every one of them returns a clean
  `{:error, book, reason}` instead of touching `Book` -- no half-fulfilled
  contracts. `row/update` and `eval/run` are here too, only as a fallback:
  they are `pipelines.json` methods, which `Runner` and `Serve.Project`
  hand to `Pipeline` before a call ever reaches this module (Old.md §37).

  `initialize`/`subscribe` are deliberately not entries here at all (not
  even in `@not_implemented`) -- they're transport/session bookkeeping
  (Old.md §9: session state lives in `Serve.Socket`, not
  `Serve.Project`), not `Book` operations. `Serve.Socket` intercepts them
  before a message ever reaches here.
  """

  alias XipeTotec.{Address, Book, Core, GraphQuery, Id, Methods, Project, ProjectEnv}

  @type ctx :: %{optional(:root) => String.t(), optional(:project_dir) => Path.t() | nil}
  @type result :: {:ok, Book.t(), map()} | {:error, Book.t(), map()}

  @valid_effects ["pure", "reads", "writes", "unknown"]

  # Real methods (spec §16.3), genuinely not built yet -- see moduledoc --
  # plus the pipelines.json ones, as a fallback for a caller that reaches
  # here without checking Pipeline.handles?/1 first (XipeTotec.Methods).
  @not_implemented Methods.names([:pipeline, :not_implemented])

  @check_conditions ["error", "changed", "unevaluated"]

  @spec handle(Book.t(), String.t(), map(), ctx) :: result
  def handle(book, method, params, ctx \\ %{})

  def handle(book, "scan/run", _params, ctx) do
    root = Map.fetch!(ctx, :root)
    # the project's saved surface table (課題 ④) and environment
    # (ProjectEnv, for a language server the scan starts itself), when the
    # caller has a project
    project_dir = Map.get(ctx, :project_dir)
    {env, env_status} = ProjectEnv.resolve(root, project_dir)
    table_file = if project_dir, do: Path.join(project_dir, "table")
    report = Project.scan_dir_report(book, root, table_file: table_file, scanner_opts: [env: env])
    %{book: new_book, paths: paths, link_failures: link_failures} = report

    result = %{
      "paths" => paths,
      "sheets" => map_size(new_book.sheets),
      "nodes" => map_size(new_book.nodes),
      "links" => map_size(new_book.links),
      "link_failures" =>
        Enum.map(link_failures, &%{"path" => &1.path, "module" => &1.module, "reason" => &1.reason}),
      "scanners" => report.scanners
    }

    {:ok, new_book, if(project_dir, do: Map.put(result, "env", env_status), else: result)}
  end

  def handle(book, "row/add", %{"node" => node_id, "args" => args}, _ctx)
      when is_binary(node_id) and is_list(args) do
    # A calc row is one call to one scanned node, so the node has to exist
    # and the args have to match its arity -- checked here rather than left
    # to the REPL, where an arity mismatch would only surface as a crash at
    # eval time. Old.md §32: `xipe do row/add ... args=3,` used to silently
    # mint a 2-arg row for a 1-arity function.
    case check_args(book, node_id, args, "row/add") do
      :ok ->
        id = Id.ulid()
        new_book = Core.add_call(book, id, %{node: node_id, args: args})
        {:ok, new_book, %{"id" => id, "row" => Book.get(new_book, :calls, id)}}

      {:error, error} ->
        {:error, book, error}
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
    # client (Old.md §9: deferred, no client implements it yet), so for
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

  # Reclassified Tier 1 (was mistakenly left in @not_implemented, 2026-09-17
  # -- see README's Tier table history): spec §6.3 says cell/resolve returns
  # a reference's current value/repr/state, which is exactly what's already
  # sitting on the referenced :calls row (Core.add_call/apply_result already
  # maintain result/repr/state) -- a pure Book lookup, no Evaluator involved.
  # `ref` must be a full "⟦id⟧" token (Core.refs_in_args/1's own extraction
  # regex), not a bare id -- consistent with how refs appear everywhere else
  # (arg strings, doctest export), so a client never needs a second format.
  def handle(book, "cell/resolve", %{"ref" => ref}, _ctx) when is_binary(ref) do
    case Core.refs_in_args([ref]) do
      [id] ->
        case Book.get(book, :calls, id) do
          nil -> {:error, book, not_found("call", id)}
          row -> {:ok, book, %{"value" => row.result, "repr" => row.repr, "state" => row.state}}
        end

      _ ->
        {:error, book, invalid_params("cell/resolve needs \"ref\" to be a single \"⟦id⟧\" token")}
    end
  end

  def handle(book, "cell/resolve", _params, _ctx),
    do: {:error, book, invalid_params("cell/resolve needs \"ref\" (string, e.g. \"⟦01ABC...⟧\")")}

  # Old.md §16.3/§16.4 (2026-09-19/20-21): the upstream ⟦id⟧
  # dependency chain, not §16.3's original method table -- new ground, not
  # a v0.4 spec method. "row/" matches row/add|remove's existing calc-row-
  # level namespace; deliberately not under "graph/" (that prefix already
  # means the static :links call graph, GraphQuery -- a different edge
  # type, see Core.upstream_chain/2's own moduledoc).
  def handle(book, "row/depends", %{"call_ids" => call_ids}, _ctx) when is_list(call_ids) do
    if Enum.all?(call_ids, &is_binary/1) do
      {:ok, book, %{"chain" => Core.upstream_chain(book, call_ids)}}
    else
      {:error, book, invalid_params("row/depends needs call_ids ([string])")}
    end
  end

  def handle(book, "row/depends", _params, _ctx),
    do: {:error, book, invalid_params("row/depends needs call_ids ([string])")}

  # Old.md §16.4/§19 (2026-09-22): the dependency-chain negotiation's
  # "insert a value into X" step -- writes a user-supplied literal straight
  # into a call's result, no REPL involved (Core.set_result/3 is pure, so
  # this fits Dispatch's synchronous Book-in-Book-out contract exactly,
  # unlike "eval"/Runner's REPL-bound pseudo-method). New ground, not a v0.4
  # spec method; "row/" namespace for the same reason row/depends picked it.
  def handle(book, "row/set-result", %{"id" => call_id, "result" => result}, _ctx)
      when is_binary(call_id) and is_binary(result) do
    try do
      {:ok, Core.set_result(book, call_id, result), %{"id" => call_id, "result" => result}}
    rescue
      # Core.set_result/3 -> fetch!/3 raises on an unknown call id, same
      # boundary-conversion reasoning as effect/set's own rescue above.
      RuntimeError -> {:error, book, not_found("call", call_id)}
    end
  end

  def handle(book, "row/set-result", _params, _ctx),
    do: {:error, book, invalid_params("row/set-result needs id (string) and result (string)")}

  # The calc rows as a list (2026-09-26): what `xipe show` prints and a
  # client can render as the table. `call_ids` (optional) narrows it to
  # those rows, in that order; otherwise every row, oldest first (ULIDs
  # sort by creation time).
  def handle(book, "row/list", params, _ctx) when is_map(params) do
    with {:ok, ids} <- call_ids(book, params) do
      {:ok, book, %{"rows" => Enum.map(ids, &list_row(book, &1))}}
    else
      {:error, error} -> {:error, book, error}
    end
  end

  # An address (spec §6.1, the same columns card/get takes) to the one node
  # it names (2026-09-26), so a command list can go on with `$N.id` instead
  # of a copied ULID: `node/resolve module=Calc name=square arity=1 --
  # row/add node=$0.id ...`. A `row=<call id>` address names that row's
  # node. No match is not_found; several are "ambiguous", with the
  # candidates in `data`.
  def handle(book, "node/resolve", params, _ctx) when is_map(params) and map_size(params) > 0 do
    case Address.resolve(book, params) do
      {:ok, matches} ->
        # a row whose node a rescan removed names no node
        case matches |> Enum.map(&match_node_id/1) |> Enum.uniq() |> Enum.filter(&Book.get(book, :nodes, &1)) do
          [id] ->
            {:ok, book, %{"id" => id, "label" => Core.node_label(Book.get(book, :nodes, id))}}

          [] ->
            {:error, book, %{"code" => "not_found", "message" => "no node matches #{inspect(params)}"}}

          ids ->
            candidates = for id <- ids, do: %{"id" => id, "label" => Core.node_label(Book.get(book, :nodes, id))}

            {:error, book,
             %{
               "code" => "ambiguous",
               "message" => "#{length(ids)} nodes match #{inspect(params)}: #{Enum.map_join(candidates, ", ", & &1["label"])}",
               "data" => %{"candidates" => candidates}
             }}
        end

      {:error, {:unsupported_column, col}} ->
        {:error, book, %{"code" => "unsupported_column", "message" => col}}
    end
  end

  def handle(book, "node/resolve", _params, _ctx),
    do: {:error, book, invalid_params("node/resolve needs an address (file/module/name/arity/row)")}

  # Fails when a row is in one of the `on` conditions (2026-09-26), so a
  # command list ending in `row/check` fails -- and `xipe do` exits 1 -- on
  # a regression: `... -- eval -- row/check on=error,changed`. Reads each
  # row's current columns, so after an `eval` earlier in the same list it
  # sees that pass's results. `on` (default `error`): `error` (state isn't
  # ok: a crash, timeout or skipped reference), `changed` (compare
  # is changed), `unevaluated` (never evaluated). `call_ids` as row/list.
  def handle(book, "row/check", params, _ctx) when is_map(params) do
    on = params |> Map.get("on", ["error"]) |> List.wrap()

    with :ok <- check_conditions(on),
         {:ok, ids} <- call_ids(book, params) do
      failed =
        for id <- ids,
            row = Book.get(book, :calls, id),
            reasons = Enum.filter(on, &check_fails?(row, &1)),
            reasons != [],
            do: %{"id" => id, "label" => Core.call_label(book, id), "reasons" => reasons}

      case failed do
        [] ->
          {:ok, book, %{"checked" => length(ids), "on" => on}}

        _ ->
          {:error, book,
           %{
             "code" => "check_failed",
             "message" =>
               "#{length(failed)} of #{length(ids)} row(s): " <>
                 Enum.map_join(failed, "; ", &"#{&1["id"]} #{&1["label"]} #{Enum.join(&1["reasons"], ",")}"),
             "data" => %{"failed" => failed}
           }}
      end
    else
      {:error, error} -> {:error, book, error}
    end
  end

  def handle(book, method, _params, _ctx) when method in @not_implemented,
    do: {:error, book, %{"code" => "not_implemented", "message" => "#{method}: not implemented yet (Old.md §9 tier map)"}}

  def handle(book, method, _params, _ctx),
    do: {:error, book, %{"code" => "unknown_method", "message" => method}}

  @doc """
  Whether `args` can be a calc row's arguments for node `node_id`: a list of
  strings, for a node that exists, isn't private, and (when its anykey is
  an integer) takes that many. Shared by `row/add` and `row/update`'s edit
  stage (`Pipeline`); `method` prefixes the messages.
  """
  @spec check_args(Book.t(), String.t(), term(), String.t()) :: :ok | {:error, map()}
  def check_args(book, node_id, args, method) do
    node = Book.get(book, :nodes, node_id)

    cond do
      not (is_list(args) and Enum.all?(args, &is_binary/1)) ->
        {:error, invalid_params("#{method} needs args ([string])")}

      node == nil ->
        {:error, not_found("node", node_id)}

      # a calc row is evaluated by calling the function from the REPL, which
      # can't reach a private one (Elixir's defp) -- it would only crash there
      node[:visibility] == "private" ->
        {:error, invalid_params("#{method}: #{Core.node_label(node)} is private; the REPL can't call it")}

      # only an integer anykey is an argument count (Scanner.Elixir's arity);
      # another scanner's anykey says nothing about how many args to expect
      is_integer(node[:anykey]) and length(args) != node.anykey ->
        {:error,
         invalid_params("#{method}: #{Core.node_label(node)} takes #{node.anykey} arg(s), got #{length(args)}: #{inspect(args)}")}

      true ->
        :ok
    end
  end

  defp invalid_params(message), do: %{"code" => "invalid_params", "message" => message}

  # `call_ids` for row/list and row/check: omitted or empty means every row
  # (oldest first); given ones must all exist.
  defp call_ids(book, params) do
    case params |> Map.get("call_ids", []) |> List.wrap() do
      [] ->
        {:ok, book.calls |> Map.keys() |> Enum.sort()}

      ids ->
        cond do
          not Enum.all?(ids, &is_binary/1) -> {:error, invalid_params("call_ids must be [string]")}
          missing = Enum.find(ids, &(Book.get(book, :calls, &1) == nil)) -> {:error, not_found("call", missing)}
          true -> {:ok, ids}
        end
    end
  end

  defp list_row(book, id) do
    row = Book.get(book, :calls, id)

    %{
      "id" => id,
      "node" => row.node,
      "label" => Core.call_label(book, id),
      "args" => row.args,
      "value" => row[:result],
      "repr" => row[:repr],
      "state" => row[:state],
      "compare" => row[:compare],
      "error" => row[:error],
      "eval_count" => row[:eval_count] || 0
    }
  end

  defp match_node_id({:nodes, id, _row}), do: id
  defp match_node_id({:calls, _id, row}), do: row.node

  defp check_conditions(on) do
    case Enum.find(on, &(&1 not in @check_conditions)) do
      nil -> :ok
      bad -> {:error, invalid_params("row/check: unknown condition #{inspect(bad)} (#{Enum.join(@check_conditions, "|")})")}
    end
  end

  defp check_fails?(row, "error"), do: row[:state] not in [nil, "ok"]
  defp check_fails?(row, "changed"), do: row[:compare] == "changed"
  defp check_fails?(row, "unevaluated"), do: (row[:eval_count] || 0) == 0
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

  # A "row=<call_id>" address resolves straight to a single :calls row
  # (Address.resolve/2's own doing), but card/get's whole point is to
  # return a card (spec glossary: "カード = 1関数分の行のまとまり"), not a
  # bare row -- so compose the owning card the same way a module/name/arity
  # address already does, just entering through the call's own `node`
  # column instead of a direct node match (crux 2026-09-22 co-design: this
  # unifies the two address styles onto one response shape now, rather than
  # deferring it as a later addition).
  defp render_match(book, {:calls, _id, row}), do: compose_card(book, row.node, Book.get(book, :nodes, row.node))

  # spec glossary: "カード = 1関数分の行のまとまり" -- a node plus its own
  # calc rows and link rows, not just the bare node row.
  defp compose_card(book, node_id, node_row) do
    calls = for {id, row} <- book.calls, row.node == node_id, do: Map.put(row, :id, id)
    links = for {id, row} <- book.links, row.node == node_id, do: Map.put(row, :id, id)
    %{"id" => node_id, "node" => node_row, "calls" => calls, "links" => links}
  end
end
