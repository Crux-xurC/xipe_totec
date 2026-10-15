Code.require_file("book.exs", __DIR__)
Code.require_file("core.exs", __DIR__)
Code.require_file("id.exs", __DIR__)
Code.require_file("project.exs", __DIR__)
Code.require_file("address.exs", __DIR__)
Code.require_file("graph_query.exs", __DIR__)
Code.require_file("methods.exs", __DIR__)
Code.require_file("passes.exs", __DIR__)
Code.require_file("tables.exs", __DIR__)
Code.require_file("card_table.exs", __DIR__)
Code.require_file("project_config.exs", __DIR__)
Code.require_file("project_env.exs", __DIR__)
Code.require_file("scanner/elixir.exs", __DIR__)

defmodule XipeTotec.Dispatch do
  @moduledoc """
  The client -> server method table. As pure as `Core`: `handle/4` takes a
  `Book` and returns a `Book`. The one exception is `scan/run`, which needs
  `ctx.root` to read source files. No method here touches `Store`; the
  caller (`Serve.Project`, the CLI) persists what changed.

  A reserved but unbuilt method (`@not_implemented`) answers
  `not_implemented`, so a client can tell it from an unknown method; it
  never touches the `Book`. `row/update` and `eval/run` are in that set
  only as a fallback: they are `pipelines.json` methods, which `Runner`
  and `Serve.Project` hand to `Pipeline` before a call reaches this module.

  `initialize`/`subscribe` are not entries here: they are session
  bookkeeping, which `Serve.Socket` answers itself.
  """

  alias XipeTotec.{Address, Book, Core, GraphQuery, Id, Methods, Project, ProjectEnv}

  @type ctx :: %{optional(:root) => String.t(), optional(:project_dir) => Path.t() | nil}
  @type result :: {:ok, Book.t(), map()} | {:error, Book.t(), map()}

  @valid_effects ["pure", "reads", "writes", "unknown"]

  # Real methods, genuinely not built yet -- see moduledoc --
  # plus the pipelines.json ones, as a fallback for a caller that reaches
  # here without checking Pipeline.handles?/1 first (XipeTotec.Methods).
  @not_implemented Methods.names([:pipeline, :not_implemented])

  @check_conditions ["error", "changed", "unevaluated"]

  @spec handle(Book.t(), String.t(), map(), ctx) :: result
  def handle(book, method, params, ctx \\ %{})

  def handle(book, "scan/run", _params, ctx) do
    root = Map.fetch!(ctx, :root)
    # the project's saved surface table and environment
    # (ProjectEnv, for a language server the scan starts itself), when the
    # caller has a project
    project_dir = Map.get(ctx, :project_dir)
    {env, env_status} = ProjectEnv.resolve(root, project_dir)
    table_file = if project_dir, do: Path.join(project_dir, "table")
    case Project.scan_dir_report(book, root, table_file: table_file, scanner_opts: [env: env]) do
      {:error, message} -> {:error, book, %{"code" => "scan_failed", "message" => message <> " -- nothing of the scan was kept"}}
      report -> scan_result(report, project_dir, env_status)
    end
  end

  def handle(book, "row/add", %{"node" => node_id, "args" => args}, ctx)
      when is_binary(node_id) and is_list(args) do
    # A calc row is one call to one scanned node, so the node has to exist
    # and the args have to match its arity -- checked here rather than left
    # to the REPL, where an arity mismatch would only surface as a crash at
    # eval time.
    case check_args(book, node_id, args, "row/add", ctx[:root]) do
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

  def handle(book, "row/remove", %{"id" => call_id}, ctx) when is_binary(call_id) do
    case XipeTotec.Passes.refuse(ctx[:project_dir], call_id) do
      nil -> {:ok, Core.remove_call(book, call_id), %{"id" => call_id}}
      error -> {:error, book, error}
    end
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

  # the argument counts a function with default arguments can be called with
  #: a person declares them, as effect/set -- the scanner
  # only suggests (a refused row/add, scan/run's arity_misses)
  def handle(book, "arity/set", %{"id" => node_id, "arities" => arities}, _ctx) when is_binary(node_id) do
    node = Book.get(book, :nodes, node_id)
    as = arities |> List.wrap() |> Enum.map(&to_arity/1)

    cond do
      node == nil ->
        {:error, book, not_found("node", node_id)}

      not is_integer(node[:anykey]) ->
        {:error, book, invalid_params("arity/set: #{Core.node_label(node)} has no argument count (this language's node is not told apart by arity)")}

      as == [] or Enum.any?(as, &is_nil/1) ->
        {:error, book, invalid_params("arity/set needs arities (whole numbers, e.g. arities=[1,2])")}

      node.anykey not in as ->
        {:error, book, invalid_params("arity/set: arities must include #{node.anykey} (#{Core.node_label(node)} as defined)")}

      Enum.any?(as, &(&1 > node.anykey)) ->
        {:error, book, invalid_params("arity/set: #{Core.node_label(node)} takes at most #{node.anykey} arg(s)")}

      true ->
        new_book = Core.set_arities(book, node_id, as)
        node = Book.get(new_book, :nodes, node_id)
        {:ok, new_book, %{"id" => node_id, "arities" => Core.accepted_arities(node), "label" => Core.node_label(node)}}
    end
  end

  def handle(book, "arity/set", _params, _ctx),
    do: {:error, book, invalid_params("arity/set needs id (string) and arities (e.g. arities=[1,2])")}

  def handle(book, "effect/set", _params, _ctx),
    do:
      {:error, book,
       invalid_params("effect/set needs id (string) and effect (#{Enum.join(@valid_effects, "|")})")}

  def handle(book, method, params, _ctx) when method in ["card/get", "card/search"] and is_map(params) do
    # card/get and card/search run the same address resolution
    case Address.resolve(book, params) do
      {:ok, matches} ->
        {:ok, book, %{"matches" => Enum.map(matches, &render_match(book, &1))}}

      {:error, reason} ->
        {:error, book, address_error(reason)}
    end
  end

  def handle(book, method, _params, _ctx) when method in ["card/get", "card/search"],
    do: {:error, book, invalid_params("#{method} needs an address object")}

  def handle(book, "graph/neighbors", %{"address" => address} = params, _ctx) when is_map(address) do
    with {:ok, depth} <- normalize_depth(Map.get(params, "depth", 1)),
         {:ok, direction} <- parse_direction(Map.get(params, "direction", "both")),
         {:ok, result} <- GraphQuery.neighbors(book, address, depth, direction) do
      {:ok, book, result}
    else
      {:error, {:unsupported_column, _} = reason} -> {:error, book, address_error(reason)}
      {:error, {:bad_value, _, _} = reason} -> {:error, book, address_error(reason)}
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
      {:error, {:unsupported_column, _} = reason} -> {:error, book, address_error(reason)}
      {:error, {:bad_value, _, _} = reason} -> {:error, book, address_error(reason)}
      {:error, message} when is_binary(message) -> {:error, book, invalid_params(message)}
    end
  end

  def handle(book, "graph/export", _params, _ctx),
    do:
      {:error, book,
       invalid_params("graph/export needs address, format (mermaid|dot|json|doctest) under \"address\"/\"format\"")}

  # cell/resolve returns a reference's current value/repr/state, which is
  # what sits on the referenced :calls row -- a pure Book lookup.
  # `ref` must be a full "⟦id⟧" token, not a bare id, as refs appear
  # everywhere else (arg strings, doctest export).
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

  # The upstream ⟦id⟧ dependency chain. Under "row/" (the calc-row level),
  # not "graph/", which means the static :links call graph (GraphQuery).
  def handle(book, "row/depends", %{"call_ids" => call_ids}, _ctx) when is_list(call_ids) do
    if Enum.all?(call_ids, &is_binary/1) do
      {:ok, book, %{"chain" => Core.upstream_chain(book, call_ids)}}
    else
      {:error, book, invalid_params("row/depends needs call_ids ([string])")}
    end
  end

  def handle(book, "row/depends", _params, _ctx),
    do: {:error, book, invalid_params("row/depends needs call_ids ([string])")}

  # Writes a user-supplied literal straight into a call's result, no REPL
  # involved (Core.set_result/3 is pure).
  def handle(book, "row/set-result", %{"id" => call_id, "result" => result}, ctx)
      when is_binary(call_id) and is_binary(result) do
    try do
      case XipeTotec.Passes.refuse(ctx[:project_dir], call_id) do
        nil -> {:ok, Core.set_result(book, call_id, result), %{"id" => call_id, "result" => result}}
        error -> {:error, book, error}
      end
    rescue
      # Core.set_result/3 -> fetch!/3 raises on an unknown call id, same
      # boundary-conversion reasoning as effect/set's own rescue above.
      RuntimeError -> {:error, book, not_found("call", call_id)}
    end
  end

  def handle(book, "row/set-result", _params, _ctx),
    do: {:error, book, invalid_params("row/set-result needs id (string) and result (string)")}

  # The passes being evaluated now (XipeTotec.Passes): each
  # language group's rows, the row it is on, its phase and for how long.
  # Read from files, so the CLI sees a server's pass and the other way
  # round. Serve.Project adds its own queue ("queued").
  def handle(book, "eval/status", _params, ctx) do
    now = DateTime.utc_now()

    running =
      for record <- XipeTotec.Passes.running(ctx[:project_dir]) do
        current =
          case record["current"] do
            %{"call_id" => id, "since" => since} = c ->
              Map.merge(c, %{"label" => label(book, id), "seconds" => seconds_since(since, now)})

            _ ->
              nil
          end

        %{
          "pass_id" => record["pass_id"],
          "language" => record["language"],
          "started_at" => record["started_at"],
          "seconds" => seconds_since(record["started_at"], now),
          "call_ids" => record["call_ids"] || [],
          "current" => current
        }
      end

    {:ok, book, %{"running" => running}}
  end

  # The expectation a row's next evaluation is compared with, set by hand
  # (Core.set_prev/3). The evaluation after that replaces it, as always.
  def handle(book, "row/set-prev", %{"id" => call_id, "prev" => prev}, ctx)
      when is_binary(call_id) and is_binary(prev) do
    cond do
      Book.get(book, :calls, call_id) == nil -> {:error, book, not_found("call", call_id)}
      error = XipeTotec.Passes.refuse(ctx[:project_dir], call_id) -> {:error, book, error}
      true -> {:ok, Core.set_prev(book, call_id, prev), %{"id" => call_id, "prev" => prev}}
    end
  end

  def handle(book, "row/set-prev", _params, _ctx),
    do: {:error, book, invalid_params("row/set-prev needs id (string) and prev (string)")}

  # A row's arguments changed without evaluating it (row/update is the one
  # that also evaluates). Checked as row/add's are. The row keeps the
  # result of its last evaluation -- of the old arguments -- until `eval`.
  def handle(book, "row/set-args", %{"id" => call_id, "args" => args}, ctx) when is_binary(call_id) do
    refused = XipeTotec.Passes.refuse(ctx[:project_dir], call_id)

    case Book.get(book, :calls, call_id) do
      nil ->
        {:error, book, not_found("call", call_id)}

      _row when refused != nil ->
        {:error, book, refused}

      row ->
        case check_args(book, row.node, args, "row/set-args", ctx[:root]) do
          :ok -> {:ok, Core.edit_args(book, call_id, args), %{"id" => call_id, "args" => args}}
          {:error, error} -> {:error, book, error}
        end
    end
  end

  def handle(book, "row/set-args", _params, _ctx),
    do: {:error, book, invalid_params("row/set-args needs id (string) and args ([string])")}

  # Asks a running pass to stop (XipeTotec.Passes' "Stopping a pass"): the
  # process running it kills its REPL's process group and ends the pass,
  # recording nothing. `pass_id` may be left out while only one pass runs.
  # Serve.Project answers for its own queue and running pass before this.
  def handle(book, "eval/cancel", params, ctx) when is_map(params) do
    running = XipeTotec.Passes.running(ctx[:project_dir])
    ids = running |> Enum.map(& &1["pass_id"]) |> Enum.uniq()

    case {Map.get(params, "pass_id"), ids} do
      {nil, []} ->
        {:error, book, %{"code" => "no_pass", "message" => "no pass is running (eval/status shows the running and queued passes)"}}

      {nil, [id]} ->
        cancel_pass(book, ctx, running, id)

      {nil, _many} ->
        {:error, book, invalid_params("eval/cancel: #{length(ids)} passes are running (#{Enum.join(ids, ", ")}) -- give pass_id")}

      {id, _} when is_binary(id) ->
        if id in ids,
          do: cancel_pass(book, ctx, running, id),
          else: {:error, book, %{"code" => "no_pass", "message" => "no running pass #{id} (eval/status shows the running and queued passes)"}}

      _ ->
        {:error, book, invalid_params("eval/cancel takes pass_id (string), or nothing while one pass runs")}
    end
  end

  def handle(book, "eval/cancel", _params, _ctx),
    do: {:error, book, invalid_params("eval/cancel takes pass_id (string), or nothing while one pass runs")}

  # One of the open project's settings (XipeTotec.ProjectConfig): written to
  # its own project.json, never to the defaults. Not the Book's.
  def handle(book, "config/set", %{"key" => key, "value" => value}, ctx) when is_binary(key) and is_binary(value) do
    case ctx[:project_dir] do
      nil ->
        {:error, book, %{"code" => "no_project", "message" => "config/set: settings are a registered project's, and none is open here"}}

      project_dir ->
        case XipeTotec.ProjectConfig.put(project_dir, key, value) do
          :ok ->
            {:ok, stored} = XipeTotec.ProjectConfig.check(key, value)
            {:ok, book, %{"key" => key, "value" => stored, "file" => XipeTotec.ProjectConfig.file(project_dir)}}

          {:error, message} ->
            {:error, book, invalid_params("config/set: " <> message)}
        end
    end
  end

  def handle(book, "config/set", _params, _ctx),
    do: {:error, book, invalid_params("config/set needs key (string) and value (string)")}

  # The tables `search` reads (XipeTotec.Tables): each one's name, the flag
  # that names it in a search turn, its columns, and the ones that can be
  # rewritten by hand.
  def handle(book, "roster", _params, _ctx) do
    tables =
      for t <- XipeTotec.Tables.all(),
          do: %{
            "name" => t.name,
            "flag" => t.flag,
            "summary" => t.summary,
            "columns" => t.columns,
            # column => the method that rewrites it (dialogue rewrite)
            "writes" => Map.new(t.writes, fn {column, w} -> {column, w.method} end)
          }

    {:ok, book, %{"tables" => tables}}
  end

  # The calc rows as a list: what `xipe show` prints and a
  # client can render as the table. Each row carries where its function is
  # defined (`path` from the project's root, `line`), so a client can open it. `call_ids` (optional) narrows it to
  # those rows, in that order; otherwise every row, oldest first (ULIDs
  # sort by creation time).
  def handle(book, "row/list", params, _ctx) when is_map(params) do
    with {:ok, ids} <- call_ids(book, params) do
      {:ok, book, %{"rows" => Enum.map(ids, &list_row(book, &1))}}
    else
      {:error, error} -> {:error, book, error}
    end
  end

  # Every function a scan found, whole (XipeTotec.CardTable): its label,
  # effect and visibility, where it is defined (`path` from the project's
  # root, `line`), and how many calc rows it has. In file order. Picking and
  # sorting are the reader's -- card/get and card/search take an address.
  def handle(book, "card/list", _params, _ctx),
    do: {:ok, book, %{"cards" => XipeTotec.CardTable.rows(book)}}

  # An address (the same columns card/get takes) to the one node
  # it names, so a command list can go on with `$N.id` instead
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

      {:error, reason} ->
        {:error, book, address_error(reason)}
    end
  end

  def handle(book, "node/resolve", _params, _ctx),
    do: {:error, book, invalid_params("node/resolve needs an address (file/module/name/arity/row)")}

  # Fails when a row is in one of the `on` conditions, so a
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
    do: {:error, book, %{"code" => "not_implemented", "message" => "#{method}: not implemented yet"}}

  def handle(book, method, _params, _ctx),
    do: {:error, book, %{"code" => "unknown_method", "message" => method}}

  @doc """
  Whether `args` can be a calc row's arguments for node `node_id`: a list of
  strings, for a node that exists, isn't private, and (when its anykey is
  an integer) takes that many. Shared by `row/add` and `row/update`'s edit
  stage (`Pipeline`); `method` prefixes the messages.
  """
  @spec check_args(Book.t(), String.t(), term(), String.t(), String.t() | nil) :: :ok | {:error, map()}
  def check_args(book, node_id, args, method, root \\ nil) do
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
      # another scanner's anykey says nothing about how many args to expect.
      # Default arguments: the counts a person declared (arity/set)
      is_list(Core.accepted_arities(node)) and length(args) not in Core.accepted_arities(node) ->
        takes = node |> Core.accepted_arities() |> Core.arities_text()

        {:error,
         invalid_params("#{method}: #{Core.node_label(node)} takes #{takes} arg(s), got #{length(args)}: #{inspect(args)}" <>
           arity_hint(book, node_id, node, length(args), root))}

      true ->
        :ok
    end
  end

  defp invalid_params(message), do: %{"code" => "invalid_params", "message" => message}

  # Address.resolve/2's refusals as errors
  defp address_error({:unsupported_column, col}), do: %{"code" => "unsupported_column", "message" => col}

  defp address_error({:bad_value, col, value}),
    do: invalid_params("#{col} is neither a number nor a string (#{inspect(value)} -- a $n.… reference that names nothing, or a […] or {…} was written). Nothing was looked up")

  # a refused arg count: what xipe_totec's own reading of the source says
  # (Scanner.Elixir.default_arities) -- shown, never set
  defp arity_hint(book, node_id, node, n, root) do
    with true <- is_binary(root),
         %{path: path} <- Book.get(book, :sheets, node[:sheet]),
         {:ok, source} <- File.read(Path.join(root, path)),
         [_, _ | _] = as <- XipeTotec.Scanner.Elixir.default_arities(source, node.module, node.name, node.anykey),
         true <- n in as,
         false <- as == Core.accepted_arities(node) do
      " -- the source shows default arguments, callable as #{Core.arities_text(as)}: declare them first with arity/set id=#{node_id} arities=[#{Enum.join(as, ",")}]"
    else
      _ -> ""
    end
  end

  defp to_arity(n) when is_integer(n) and n >= 0, do: n
  defp to_arity(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end
  defp to_arity(_), do: nil

  defp arity_miss_note(book, m) do
    node = Book.get(book, :nodes, m.node) || %{}
    %{
      "path" => m.path, "module" => m.module, "node" => m.node,
      "message" =>
        "called as #{m.label}/#{m.called}, but the node is #{Core.node_label(Map.merge(%{module: "", name: ""}, node))}" <>
          " -- if these are default arguments, declare them with arity/set id=#{m.node} arities=[...] (a refused row/add suggests the counts)"
    }
  end

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

  # `linked`: whether the row's node still
  # exists. A rescan that removed it (a half-typed save, a commented-out
  # function) leaves the row pointing at the old id for good -- a rescan
  # of the restored function mints a new one -- while the row's `state`
  # stays what its last eval left. A client shows this; it doesn't guess
  # from `label` being nil.
  defp list_row(book, id) do
    row = Book.get(book, :calls, id)
    # where the row's function is defined (nil when a rescan removed it)
    {path, line} = XipeTotec.CardTable.place(book, row.node)

    %{
      "id" => id,
      "node" => row.node,
      "linked" => Book.get(book, :nodes, row.node) != nil,
      "label" => Core.call_label(book, id),
      "path" => path,
      "line" => line,
      "args" => row.args,
      "value" => row[:result],
      "repr" => row[:repr],
      "state" => row[:state],
      "compare" => row[:compare],
      "error" => row[:error],
      "eval_count" => row[:eval_count] || 0
    }
  end

  defp cancel_pass(book, ctx, running, pass_id) do
    case XipeTotec.Passes.request_cancel(ctx[:project_dir], pass_id) do
      :ok ->
        call_ids = for r <- running, r["pass_id"] == pass_id, id <- r["call_ids"] || [], do: id
        {:ok, book, %{"pass_id" => pass_id, "status" => "cancelling", "call_ids" => call_ids}}

      {:error, message} ->
        {:error, book, %{"code" => "not_cancelled", "message" => message}}
    end
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

  # A "row=<call_id>" address resolves to a single :calls row, but
  # card/get returns a card, so the owning card is composed the same way a
  # module/name/arity address does, entering through the call's `node`
  # column.
  defp render_match(book, {:calls, _id, row}), do: compose_card(book, row.node, Book.get(book, :nodes, row.node))

  # A card: a node plus its own calc rows and link rows.
  defp compose_card(book, node_id, node_row) do
    calls = for {id, row} <- book.calls, row.node == node_id, do: Map.put(row, :id, id)
    links = for {id, row} <- book.links, row.node == node_id, do: Map.put(row, :id, id)
    %{"id" => node_id, "node" => node_row, "calls" => calls, "links" => links}
  end

  defp label(book, call_id) do
    Core.call_label(book, call_id) || call_id
  rescue
    _ -> call_id
  end

  defp seconds_since(iso, now) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, t, _} -> DateTime.diff(now, t)
      _ -> nil
    end
  end

  defp seconds_since(_iso, _now), do: nil


  # scan/run's answer from a scan that went through (Project.scan_dir_report/3)
  defp scan_result(report, project_dir, env_status) do
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

    # calls that matched no node only by arity -- most likely default arguments
    # not declared yet (arity/set); left out when there are none
    result =
      case Map.get(report, :arity_misses, []) do
        [] -> result
        misses -> Map.put(result, "arity_misses", Enum.map(misses, &arity_miss_note(new_book, &1)))
      end


    {:ok, new_book, if(project_dir, do: Map.put(result, "env", env_status), else: result)}
  end
end
