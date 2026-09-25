Code.require_file("../book.exs", __DIR__)
Code.require_file("../id.exs", __DIR__)
Code.require_file("../scanner.exs", __DIR__)

defmodule XipeTotec.Scanner.Elixir.Tracer do
  @moduledoc """
  Compiler-tracer collector used by `XipeTotec.Scanner` (spec §11.1 基本動作:
  "コンパイラトレーサー", Old.md §6's fix F). Handed to
  `Code.put_compiler_option(:tracers, [__MODULE__])`; events are stashed in
  the calling process's dictionary (tracer callbacks run synchronously, in
  the same process that calls `Code.compile_quoted/2`) rather than in module
  state, since tracers are configured as bare module names with no way to
  pass a reference through.
  """

  @key {__MODULE__, :events}

  def with_capture(fun) do
    Process.put(@key, [])
    Code.put_compiler_option(:tracers, [__MODULE__])

    try do
      fun.()
      Enum.reverse(Process.get(@key, []))
    after
      Code.put_compiler_option(:tracers, [])
      Process.delete(@key)
    end
  end

  # Real user code and macro-expansion artifacts of `def`/`defmodule` are
  # not distinguishable by `env.function` alone (some artifacts still carry
  # the enclosing function) -- filtered by an explicit blocklist instead.
  # Version-pinned to this project's Elixir 1.18.4 (../flake.nix); revisit
  # this list if that pin ever moves.
  @noise MapSet.new([
           {:elixir_def, :store_definition, 3},
           {:elixir_utils, :noop, 0},
           {Module, :compile_definition_attributes, 6}
         ])

  def trace({:remote_function, meta, module, name, arity}, env) do
    record(env, {module, name, arity}, meta)
  end

  def trace({:local_function, meta, name, arity}, env) do
    record(env, {env.module, name, arity}, meta)
  end

  def trace(_event, _env), do: :ok

  defp record(env, {module, name, arity}, meta) do
    if {module, name, arity} not in @noise and env.function do
      {caller_name, caller_arity} = env.function

      event = %{
        caller: {module_name(env.module), to_string(caller_name), caller_arity},
        callee: {module_name(module), to_string(name), arity},
        line: meta[:line]
      }

      Process.put(@key, [event | Process.get(@key, [])])
    end

    :ok
  end

  # `extract_defs/1` (in XipeTotec.Scanner) builds module names by joining
  # the raw `__aliases__` identifier atoms (e.g. `XipeScanFixture`), never
  # the resolved BEAM module atom (`:"Elixir.XipeScanFixture"`) that a
  # tracer callback's `env.module`/callee module actually is -- both sides
  # must be normalized to the same plain dotted string or they can never
  # compare equal. A callee that is a raw Erlang module (`:crypto`, no
  # "Elixir." prefix) is left as its own atom's string form, which will
  # simply never match a project node (correct: it isn't one).
  defp module_name(mod) when is_atom(mod) do
    case Atom.to_string(mod) do
      "Elixir." <> rest -> rest
      other -> other
    end
  end
end

defmodule XipeTotec.Scanner.Elixir do
  @moduledoc """
  Basic-behavior scan (spec §11.1/§14.1): given one Elixir source file's
  text, extract its `node` rows (module/function/arity/span/body_hash) via
  `Code.string_to_quoted!/2`, and its outgoing `link` rows via the compiler
  tracer (Old.md fix F: compiled with `Code.compile_quoted/2` in this
  process -- a separate BEAM from any live target application -- never by
  executing the file's own top-level code).

  A caller-side node whose callee does not resolve to a *known project
  node* (e.g. `Enum.map`, anything outside the scanned sheets) produces no
  link row -- only project-internal edges are recorded.
  """

  @behaviour XipeTotec.Scanner

  alias XipeTotec.{Book, Id}
  alias XipeTotec.Scanner.Elixir.Tracer

  @doc """
  Convenience wrapper for a single, self-contained file (its own calls only
  reference its own definitions): `scan_defs/3` then `scan_links/4` in one
  step. A multi-file project must instead run `scan_defs/3` over *every*
  file first, and only then `scan_links/4` over every file, so that
  cross-file callees are already registered by the time links are resolved
  (single-pass-per-file cannot handle a call to a not-yet-scanned file).
  """
  @spec scan(Book.t(), String.t(), String.t()) :: {Book.t(), %{tuple() => String.t()}}
  def scan(book, sheet_id, source) do
    quoted = Code.string_to_quoted!(source, columns: true)
    {book, node_ids} = scan_defs(book, sheet_id, quoted)
    {scan_links(book, node_ids, quoted), node_ids}
  end

  @doc """
  Pass 1: register this sheet's `node` rows (module/function/anykey/span/
  body_hash -- `anykey` is the arity: `add/2` and `add/3` are different
  functions), reusing existing ids on an exact (module, name, anykey) match
  (§7.3 minimal rule) and minting a fresh id otherwise. Returns `{book,
  node_ids}`, `node_ids` mapping `{module, name, arity} => id` for this
  sheet's own definitions -- pass every sheet's `node_ids`, merged, into
  `scan_links/4` once all sheets have been through this pass.
  """
  @spec scan_defs(Book.t(), String.t(), String.t() | Macro.t()) :: {Book.t(), %{tuple() => String.t()}}
  @impl XipeTotec.Scanner
  def scan_defs(book, sheet_id, %{source: source}), do: scan_defs(book, sheet_id, source)

  def scan_defs(book, sheet_id, source) when is_binary(source),
    do: scan_defs(book, sheet_id, Code.string_to_quoted!(source, columns: true))

  def scan_defs(book, sheet_id, quoted) do
    {book, node_ids} =
      Enum.reduce(extract_defs(quoted), {book, %{}}, fn def, {book, node_ids} ->
        key = {def.module, def.name, def.arity}
        id = Book.find_node_by_natural_key(book, def.module, def.name, def.arity) || Id.ulid()
        prior = Book.get(book, :nodes, id) || %{}

        row = %{
          sheet: sheet_id,
          module: def.module,
          name: def.name,
          anykey: def.arity,
          span: def.span,
          body_hash: def.body_hash,
          status: "live",
          effect: prior[:effect] || "unknown",
          effect_source: prior[:effect_source]
        }

        {Book.put(book, :nodes, id, row), Map.put(node_ids, key, id)}
      end)

    # a function that used to live in this sheet but no longer appears
    # (deleted, renamed past what §7.3's minimal rule can follow) drops out
    # of the book entirely -- persist_scan/3 turns that into a tombstone row
    kept = MapSet.new(Map.values(node_ids))

    removed_ids =
      for {id, row} <- book.nodes, row.sheet == sheet_id, not MapSet.member?(kept, id), do: id

    book = Enum.reduce(removed_ids, book, &Book.delete(&2, :nodes, &1))

    # its own outgoing/incoming links go with it -- `scan_links/3` only
    # cleans up links for nodes still present in `node_ids`, so a removed
    # node's edges would otherwise survive as dangling rows
    removed_set = MapSet.new(removed_ids)

    book =
      Enum.reduce(book.links, book, fn {id, row}, book ->
        if MapSet.member?(removed_set, row.node) or MapSet.member?(removed_set, row.ref) do
          Book.delete(book, :links, id)
        else
          book
        end
      end)

    {book, node_ids}
  end

  @doc """
  Pass 2: compile `source`/`quoted` to trace its outgoing calls and record
  `link` rows for every callee that resolves to a *known* project node
  (via `node_ids`, the union of every sheet's own `scan_defs/3` result, or
  an id already in `book`). A callee that resolves to neither (stdlib, a
  dependency, anything not yet scanned) produces no link row. Stale edges
  for this file's own nodes (ones that no longer appear) are dropped.
  """
  @spec scan_links(Book.t(), %{tuple() => String.t()}, String.t() | Macro.t()) :: Book.t()
  def scan_links(book, node_ids, source), do: book |> scan_links_report(node_ids, source) |> elem(0)

  @doc """
  `scan_links/3`, plus the `defmodule` forms whose links could not be
  extracted: `[%{module: "Mod.Name", reason: String.t()}]`.

  Each `defmodule` is compiled on its own, and one that fails to compile in
  xipe_totec's own BEAM is skipped rather than failing the whole scan --
  real projects are full of these (`use ExUnit.Case` without ExUnit
  running, `use` of a dependency that isn't loaded here). Its nodes are
  still in the book (`scan_defs/3` is a pure AST walk); only its outgoing
  links are unknown, so its existing link rows are kept as they were
  rather than dropped as stale -- "couldn't look" is not "no calls" (P9).
  """
  @spec scan_links_report(Book.t(), %{tuple() => String.t()}, String.t() | Macro.t()) ::
          {Book.t(), [%{module: String.t(), reason: String.t()}]}
  @impl XipeTotec.Scanner
  def scan_links_report(book, node_ids, %{source: source}), do: scan_links_report(book, node_ids, source)

  def scan_links_report(book, node_ids, source) when is_binary(source),
    do: scan_links_report(book, node_ids, Code.string_to_quoted!(source, columns: true))

  def scan_links_report(book, node_ids, quoted) do
    {edges, failures} = extract_edges(quoted)
    links = resolve_links(book, node_ids, edges)

    # `node_ids` spans every scanned file (cross-file callees resolve
    # through it), so the stale sweep is narrowed to this file's own
    # modules -- sweeping them all would drop every other file's links --
    # minus the ones that failed to compile.
    failed_modules = MapSet.new(failures, & &1.module)
    own_modules = quoted |> only_defmodules() |> Enum.flat_map(&module_names/1) |> MapSet.new()

    own_ids =
      for {{module, _, _}, id} <- node_ids,
          MapSet.member?(own_modules, module) and not MapSet.member?(failed_modules, module),
          do: id

    fresh = Map.new(links, &{Book.link_id(&1.node, &1.role, &1.ref, &1[:clause]), &1})
    book = Enum.reduce(fresh, book, fn {id, link}, book -> Book.put(book, :links, id, link) end)
    book = stale_link_ids(book, own_ids, fresh) |> Enum.reduce(book, &Book.delete(&2, :links, &1))
    {book, failures}
  end

  # links whose `node` is one of this file's nodes but were not just
  # re-emitted (`fresh` -- i.e. the edge disappeared from the source) get dropped
  defp stale_link_ids(book, node_ids, fresh) do
    node_set = MapSet.new(node_ids)

    for {id, row} <- book.links,
        MapSet.member?(node_set, row.node),
        not Map.has_key?(fresh, id),
        do: id
  end

  # --- node extraction (pure AST walk, no compilation) ---

  defp extract_defs(quoted) do
    {_, defs} = Macro.prewalk(quoted, [], fn node, acc -> walk_defmodule(node, acc) end)
    defs
  end

  defp walk_defmodule({:defmodule, _, [{:__aliases__, _, alias_parts}, [do: body]]} = node, acc) do
    module = Enum.map_join(alias_parts, ".", &to_string/1)
    defs = for d <- extract_def_clauses(body, module), do: d
    {node, acc ++ defs}
  end

  defp walk_defmodule(node, acc), do: {node, acc}

  defp extract_def_clauses(body, module) do
    body
    |> flatten_block()
    |> Enum.flat_map(fn
      {kind, meta, [{name, _, args} | _]} when kind in [:def, :defp] and is_atom(name) ->
        arity = if is_list(args), do: length(args), else: 0
        [%{module: module, name: to_string(name), arity: arity, span: span_of(meta), body_hash: body_hash({kind, name, arity, args})}]

      _ ->
        []
    end)
  end

  defp flatten_block({:__block__, _, stmts}), do: stmts
  defp flatten_block(other), do: [other]

  defp span_of(meta), do: meta[:line]

  # normalized "position stripped" hash (§9.2 body_hash) -- a real
  # implementation would strip line/column meta from the *entire* clause
  # body, not just hash the head; left simple pending the live-project pass
  defp body_hash(term) do
    :crypto.hash(:sha256, :erlang.term_to_binary(strip_meta(term)))
    |> Base.encode16(case: :lower)
  end

  defp strip_meta({a, _meta, c}) when is_list(c) or is_nil(c), do: {a, [], strip_meta(c)}
  defp strip_meta({a, _meta, c}), do: {a, [], strip_meta(c)}
  defp strip_meta(list) when is_list(list), do: Enum.map(list, &strip_meta/1)
  defp strip_meta(other), do: other

  # --- link extraction (compiles the AST in-process; §F) ---

  # Fix F: compile *only* the defmodule forms, never the full file AST -- a
  # `.exs` script's other top-level statements (Application.ensure_all_started,
  # Supervisor.start_link, ...) must never execute just from being scanned.
  #
  # One `defmodule` at a time, in source order (so a module can still use a
  # macro from one defined above it in the same file). Returns
  # `{edges, failures}`; a failing form contributes no edges, and every
  # module name inside it (nested ones too -- `extract_defs/1` keys those by
  # their own alias) is reported, so all of their nodes keep their links.
  defp extract_edges(quoted) do
    {edges, failures} =
      Enum.reduce(only_defmodules(quoted), {[], []}, fn form, {edges, failures} ->
        case compile_for_edges(form) do
          {:ok, these} -> {[these | edges], failures}
          {:error, reason} -> {edges, Enum.reverse(Enum.map(module_names(form), &%{module: &1, reason: reason})) ++ failures}
        end
      end)

    {edges |> Enum.reverse() |> Enum.concat(), Enum.reverse(failures)}
  end

  # `Code.with_diagnostics` both captures the real error text (the raised
  # CompileError only says "errors have been logged") and keeps it off
  # stderr. `catch` covers exits too -- `mix.exs`'s `use Mix.Project` exits
  # on a GenServer call to Mix.ProjectStack, which isn't running here.
  defp compile_for_edges(form) do
    {result, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          {:ok, Tracer.with_capture(fn -> Code.compile_quoted(form, "xipe_totec_scan.ex") end)}
        rescue
          e -> {:error, Exception.message(e)}
        catch
          kind, value -> {:error, Exception.format_banner(kind, value)}
        end
      end)

    case {result, for(%{severity: :error, message: m} <- diagnostics, do: m)} do
      {{:error, _}, [_ | _] = messages} -> {:error, Enum.join(messages, "; ")}
      _ -> result
    end
  end

  defp module_names(form) do
    {_, names} =
      Macro.prewalk(form, [], fn
        {:defmodule, _, [{:__aliases__, _, parts} | _]} = node, acc -> {node, [Enum.map_join(parts, ".", &to_string/1) | acc]}
        node, acc -> {node, acc}
      end)

    Enum.reverse(names)
  end

  @doc """
  Every top-level `defmodule` form in `quoted`, everything else dropped --
  the Fix F filter itself (see moduledoc), exposed so other callers that
  need the same "load only the module definitions, never execute a
  script's other top-level statements" guarantee don't reimplement it.
  `XipeTotec.Repl.SourceSanitize` is the other caller (2026-09-18, review
  finding: the eval-launch path's `-r <file>` had reopened exactly the
  hazard this filter exists to close).
  """
  @spec only_defmodules(Macro.t()) :: [Macro.t()]
  def only_defmodules({:__block__, _, stmts}), do: Enum.filter(stmts, &defmodule?/1)
  def only_defmodules(form), do: if(defmodule?(form), do: [form], else: [])

  defp defmodule?({:defmodule, _, _}), do: true
  defp defmodule?(_), do: false

  defp resolve_links(book, node_ids, edges) do
    for %{caller: {cmod, cname, carity}, callee: {gmod, gname, garity}} <- edges,
        node = Map.get(node_ids, {cmod, cname, carity}) ||
                 Book.find_node_by_natural_key(book, cmod, cname, carity),
        ref = Map.get(node_ids, {gmod, gname, garity}) ||
                Book.find_node_by_natural_key(book, gmod, gname, garity),
        node != nil and ref != nil do
      %{node: node, role: "to", ref: ref, clause: nil, guard: nil}
    end
  end
end
