Code.require_file("../scanner.exs", __DIR__)
Code.require_file("../session.exs", __DIR__)
Code.require_file("../lsp/transport/relay.exs", __DIR__)
Code.require_file("../lsp/transport/stdio.exs", __DIR__)

defmodule XipeTotec.Scanner.Lsp.Dialect do
  @moduledoc """
  What `Scanner.Lsp` needs to know about one language's server output --
  the only language-specific part of an LSP-backed scanner. Everything
  else (connecting, opening files, the requests, the book-keeping) is
  shared.
  """

  @doc "The LSP `languageId` for `textDocument/didOpen`."
  @callback language_id() :: String.t()

  @doc "The command that starts the language server over stdio, for `Lsp.Transport.Stdio` (looked up on PATH)."
  @callback lsp_command() :: [String.t()]

  @doc "Whether a `DocumentSymbol` is a container whose name prefixes the definitions inside it (a module)."
  @callback container?(symbol :: map()) :: boolean()

  @doc """
  The definition a `DocumentSymbol` is, given the names of the containers
  around it (outermost first), or `nil` if it isn't one:
  `%{module:, name:, anykey:, visibility:}` -- the node's natural key and
  whether the REPL can call it (`Scanner.definition/0`).
  """
  @callback definition(symbol :: map(), containers :: [String.t()]) ::
              %{module: String.t(), name: String.t(), anykey: term(), visibility: String.t()} | nil

  @doc "The natural key a call hierarchy item (a callee) refers to, or `nil`."
  @callback callee_key(item :: map()) :: {String.t(), String.t(), term()} | nil
end

defmodule XipeTotec.Scanner.Lsp do
  @moduledoc """
  An `XipeTotec.Scanner` over a language server (spec §11.1's main path,
  Old.md §21.4). Per file: `textDocument/documentSymbol` gives the
  definitions (pass 1); per definition, `textDocument/prepareCallHierarchy`
  at its name and `callHierarchy/outgoingCalls` give what it calls (pass 2).
  Callees are matched to nodes by the natural key the dialect reads off the
  callee item's name, not by position -- elixir-ls reports callee ranges
  that don't point at the definition.

  Language-specific scanners are thin: a dialect module (see
  `Scanner.Lsp.Dialect`) that implements `XipeTotec.Scanner` by delegating
  here with itself as the dialect -- `Scanner.Lsp.Elixir`.

  The server is reached through an `Lsp.Transport`, tried in order (spec
  §11.3): `Lsp.Transport.Relay` (tezcatl's `/lsp`, configured from the
  `:lsp`/`:fs_root` scanner options, the running `xipe start` session's
  record, `XIPE_TOTEC_LSP_RELAY`/`XIPE_TOTEC_LSP_FS_ROOT`, and the
  `TEZCATL_RELAY_PORT`/`TEZCATL_FS_ROOT` a tezcatl-spawned xipe inherits),
  then `Lsp.Transport.Stdio` (the dialect's `lsp_command/0`, started by us).
  When neither works, `begin/4` refuses and the language's next scanner
  reads the files instead. `describe/1` says which one was used.

  A server without `callHierarchyProvider` still gives cards; every module
  is then reported in `link_failures` and keeps the links it had.

  ## Files the server sees differently from the disk

  A card has to match what the REPL will load, and the REPL loads the
  file on disk. A shared server (tezcatl's relay) may instead hold an
  editor's unsaved buffer of the same file -- the relay forwards only the
  first `didOpen` of a file, so ours is dropped while the editor has it
  open. Its positions then point into text we don't have. Each file's
  definitions are checked against the disk (the definition's name must be
  on the line its `selectionRange` starts at); a file that fails is read by
  the language's next scanner instead (`opts[:next]` from
  `Project.scan_dir_report/3`, used only if it needs no `begin/3`), both
  passes, and reported by `fallbacks/1`. The check catches shifted lines,
  not every edit: a function removed below all the others, or a changed
  call inside a body, still goes by the buffer.
  """

  alias XipeTotec.{Scanner, Session}

  @request_timeout 30_000

  @doc """
  `Scanner.begin/3` for `dialect`. `opts[:files]` are the language's files
  (relative to `root`); `opts[:env]` is the project's environment
  (`ProjectEnv`) a server started over stdio runs in. `XIPE_TOTEC_LSP=off` turns LSP scanning off (the
  test suite does, so a tezcatl running on the same machine can't change
  its results) unless `opts[:transport]` names one explicitly.
  """
  def begin(dialect, root, language, opts) do
    if System.get_env("XIPE_TOTEC_LSP") == "off" and not Keyword.has_key?(opts, :transport),
      do: {:error, "LSP scanning is off (XIPE_TOTEC_LSP=off)"},
      else: connect(dialect, root, language, opts)
  end

  # Transports in spec §11.3's order -- tezcatl's relay (already running,
  # shared with the editor), then a server of our own -- unless the caller
  # names one. The first that connects and initializes wins; if none does,
  # every one's reason is reported.
  defp connect(dialect, root, language, opts) do
    candidates =
      case Keyword.fetch(opts, :transport) do
        {:ok, transport} ->
          [{transport, Keyword.get_lazy(opts, :transport_config, fn -> relay_config(opts) end)}]

        :error ->
          [
            {XipeTotec.Lsp.Transport.Relay, relay_config(opts)},
            {XipeTotec.Lsp.Transport.Stdio, %{command: dialect.lsp_command(), env: Keyword.get(opts, :env, %{})}}
          ]
      end

    case Keyword.get(opts, :files, []) do
      [] ->
        {:error, "no #{language} files"}

      [first | _] ->
        Enum.reduce_while(candidates, [], fn {transport, config}, reasons ->
          case open(dialect, transport, config, root, language, Path.join(root, first)) do
            {:ok, ctx} -> {:halt, {:ok, Map.put(ctx, :fallback, fallback(opts))}}
            {:error, reason} -> {:cont, ["#{via(transport)}: #{reason}" | reasons]}
          end
        end)
        |> case do
          {:ok, ctx} -> {:ok, ctx}
          reasons -> {:error, reasons |> Enum.reverse() |> Enum.join("; ")}
        end
    end
  end

  defp open(dialect, transport, config, root, language, file) do
    with {:ok, conn} <- transport.connect(root, language, file, config) do
      case initialize(transport, conn, root) do
        {:ok, %{"capabilities" => caps}} when is_map(caps) ->
          if caps["documentSymbolProvider"] in [nil, false] do
            transport.close(conn)
            {:error, "the #{language} language server has no documentSymbol"}
          else
            {:ok, positions} = Agent.start_link(fn -> %{} end)

            {:ok,
             %{
               transport: transport,
               conn: conn,
               dialect: dialect,
               call_hierarchy?: caps["callHierarchyProvider"] not in [nil, false],
               positions: positions
             }}
          end

        {:ok, other} ->
          transport.close(conn)
          {:error, "unexpected initialize result: #{inspect(other)}"}

        {:error, reason} ->
          transport.close(conn)
          {:error, reason}
      end
    end
  end

  # the next scanner in the language's line, if it can read a file cold
  defp fallback(opts) do
    case Keyword.get(opts, :next, []) do
      [scanner | _] ->
        Code.ensure_loaded(scanner)
        if function_exported?(scanner, :begin, 3), do: nil, else: scanner

      [] ->
        nil
    end
  end

  @doc "`Scanner.describe/1`: how the server was reached (`\"relay\"`/`\"stdio\"`), for the scan report."
  def describe(%{transport: transport}), do: via(transport)

  defp via(XipeTotec.Lsp.Transport.Relay), do: "relay"
  defp via(XipeTotec.Lsp.Transport.Stdio), do: "stdio"
  defp via(transport), do: inspect(transport)

  @doc """
  `Scanner.fallbacks/1`: the files the server saw differently from the disk,
  `[%{"path" => path, "reason" => text}]` -- read by the fallback scanner
  if there was one, else by the server anyway (`"reason"` then says so).
  Empty when every file matched.
  """
  def fallbacks(%{positions: positions}) do
    notes = for {{:stale, _uri}, {path, reason, _fell_back?}} <- Agent.get(positions, & &1), do: %{"path" => path, "reason" => reason}
    Enum.sort_by(notes, & &1["path"])
  end

  @doc "`Scanner.finish/1`: close every file this scan opened, and the connection."
  def finish(%{transport: transport, conn: conn, positions: positions}) do
    for uri <- Agent.get(positions, &Map.keys/1), is_binary(uri),
        do: transport.notify(conn, "textDocument/didClose", %{"textDocument" => %{"uri" => uri}})

    Agent.stop(positions)
    transport.close(conn)
  end

  @doc "`Scanner.scan_defs/3` for the dialect in `file.ctx`."
  def scan_defs(book, sheet_id, %{ctx: ctx} = file) do
    uri = uri(file)

    ctx.transport.notify(ctx.conn, "textDocument/didOpen", %{
      "textDocument" => %{"uri" => uri, "languageId" => ctx.dialect.language_id(), "version" => 1, "text" => file.source}
    })

    symbols =
      case ctx.transport.request(ctx.conn, "textDocument/documentSymbol", %{"textDocument" => %{"uri" => uri}}, @request_timeout) do
        {:ok, list} when is_list(list) -> list
        _ -> []
      end

    lines = String.split(file.source, "\n")
    found = definitions(ctx.dialect, symbols, [])

    # every opened uri gets an entry, so finish/1 closes it
    case stale(found, lines) do
      nil ->
        put_defs(book, sheet_id, uri, found, lines, ctx)

      reason when ctx.fallback != nil ->
        Agent.update(ctx.positions, &(&1 |> Map.put(uri, []) |> Map.put({:stale, uri}, {file.path, reason, true})))
        ctx.fallback.scan_defs(book, sheet_id, file)

      reason ->
        note = reason <> "; no fallback scanner, read from the server anyway"
        Agent.update(ctx.positions, &Map.put(&1, {:stale, uri}, {file.path, note, false}))
        put_defs(book, sheet_id, uri, found, lines, ctx)
    end
  end

  # the first definition whose name isn't where the server says it starts
  defp stale(found, lines) do
    Enum.find_value(found, fn {def, symbol} ->
      line = symbol["selectionRange"]["start"]["line"]
      text = Enum.at(lines, line)

      if text == nil or not String.contains?(text, def.name),
        do: "#{def.module}.#{def.name} is not on line #{line + 1} on disk (an unsaved editor buffer?)"
    end)
  end

  defp put_defs(book, sheet_id, uri, found, lines, ctx) do
    defs =
      for {def, symbol} <- found do
        range = symbol["range"]

        Map.merge(def, %{
          span: range["start"]["line"] + 1,
          body_hash: body_hash(lines, range)
        })
      end

    {book, node_ids} = Scanner.put_defs(book, sheet_id, defs)

    entries =
      for {def, symbol} <- found do
        {node_ids[{def.module, def.name, def.anykey}], def.module, symbol["selectionRange"]["start"]}
      end

    Agent.update(ctx.positions, &Map.put(&1, uri, entries))
    {book, node_ids}
  end

  @doc "`Scanner.scan_links_report/3` for the dialect in `file.ctx`."
  def scan_links_report(book, node_ids, %{ctx: ctx} = file) do
    uri = uri(file)

    case Agent.get(ctx.positions, &Map.get(&1, {:stale, uri})) do
      {_path, _reason, true} -> ctx.fallback.scan_links_report(book, node_ids, file)
      _ -> links_from_server(book, node_ids, uri, Agent.get(ctx.positions, &Map.get(&1, uri, [])), ctx)
    end
  end

  defp links_from_server(book, node_ids, uri, entries, ctx) do
    if ctx.call_hierarchy? do
      results = for {node, module, position} <- entries, do: {node, module, outgoing(ctx, uri, position)}

      links =
        for {node, _module, {:ok, keys}} <- results,
            key <- keys,
            ref = Scanner.node_for(book, node_ids, key),
            do: %{node: node, ref: ref}

      looked_at = for {node, _module, {:ok, _}} <- results, do: node

      failures =
        for {_node, module, {:error, reason}} <- results, uniq: true, do: %{module: module, reason: reason}

      # one failed function spoils its whole module, like a module that
      # didn't compile for Scanner.Elixir: none of its links are swept
      failed = MapSet.new(failures, & &1.module)
      own = for {node, module, _} <- results, node in looked_at, not MapSet.member?(failed, module), do: node

      {Scanner.put_links(book, links, own), failures}
    else
      failures =
        for {_node, module, _} <- entries, uniq: true,
            do: %{module: module, reason: "the language server has no callHierarchy"}

      {book, failures}
    end
  end

  # ---------------------------------------------------------------------

  defp initialize(transport, conn, root) do
    transport.request(
      conn,
      "initialize",
      %{
        "processId" => nil,
        "rootUri" => "file://" <> root,
        "capabilities" => %{
          "textDocument" => %{
            "documentSymbol" => %{"hierarchicalDocumentSymbolSupport" => true},
            "callHierarchy" => %{}
          }
        }
      },
      @request_timeout
    )
  end

  defp outgoing(ctx, uri, position) do
    params = %{"textDocument" => %{"uri" => uri}, "position" => position}

    with {:ok, [item | _]} <- ctx.transport.request(ctx.conn, "textDocument/prepareCallHierarchy", params, @request_timeout),
         {:ok, calls} <- ctx.transport.request(ctx.conn, "callHierarchy/outgoingCalls", %{"item" => item}, @request_timeout) do
      {:ok, for(%{"to" => to} <- calls || [], key = ctx.dialect.callee_key(to), do: key)}
    else
      {:ok, _no_item} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  # hierarchical DocumentSymbol trees: containers pass their name down
  defp definitions(dialect, symbols, containers) do
    Enum.flat_map(symbols, fn symbol ->
      own =
        case dialect.definition(symbol, containers) do
          nil -> []
          def -> [{def, symbol}]
        end

      inner = if dialect.container?(symbol), do: containers ++ [symbol["name"]], else: containers
      own ++ definitions(dialect, symbol["children"] || [], inner)
    end)
  end

  defp body_hash(lines, %{"start" => %{"line" => from}, "end" => %{"line" => to}}) do
    text = lines |> Enum.slice(from..to//1) |> Enum.map_join("\n", &String.trim/1)
    :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
  end

  defp uri(file), do: "file://" <> Path.expand(Path.join(file.root, file.path))

  defp relay_config(opts) do
    session =
      case Session.read() do
        {:ok, record} -> record
        :none -> %{}
      end

    port = System.get_env("TEZCATL_RELAY_PORT") || "4100"

    %{
      url:
        opts[:lsp] || session["lsp"] || System.get_env("XIPE_TOTEC_LSP_RELAY") ||
          "ws://127.0.0.1:#{port}/lsp",
      fs_root:
        opts[:fs_root] || session["fs_root"] || System.get_env("XIPE_TOTEC_LSP_FS_ROOT") ||
          System.get_env("TEZCATL_FS_ROOT")
    }
  end
end
