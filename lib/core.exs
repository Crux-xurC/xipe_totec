Code.require_file("book.exs", __DIR__)

defmodule XipeTotec.Core do
  @moduledoc """
  Pure functions over `Book` (spec §4, prebuild.md §3-§4). No I/O, no
  randomness, no clock reads: every id/timestamp this module needs is
  supplied by the caller so it stays a genuinely pure `apply`. This module
  does not evaluate anything -- see prebuild.md §4.4's 3-stage split:

    Core.plan_recalc   (here, pure)   -> Plan
    Evaluator.run       (elsewhere)   -> [Result]   -- the only impure step
    Core.apply_results  (here, pure)  -> Book

  Language independence: reference extraction is a pure text scan of `args`
  for `⟦id⟧` tokens (spec §6.2) -- no target-language parsing, no REPL
  adapter involved anywhere in this module.
  """

  alias XipeTotec.Book

  # ---------------------------------------------------------------------
  # basic mutations -- caller supplies id/timestamps, this stays pure
  # ---------------------------------------------------------------------

  @spec put_sheet(Book.t(), String.t(), map()) :: Book.t()
  def put_sheet(book, id, row), do: Book.put(book, :sheets, id, Map.put_new(row, :status, "live"))

  @spec put_node(Book.t(), String.t(), map()) :: Book.t()
  def put_node(book, id, row) do
    defaults = %{status: "live", effect: "unknown", effect_source: nil}
    Book.put(book, :nodes, id, Map.merge(defaults, row))
  end

  @spec add_call(Book.t(), String.t(), map()) :: Book.t()
  def add_call(book, id, row) do
    defaults = %{
      prev: nil,
      prev_at: nil,
      prev_source: nil,
      result: nil,
      result_type: nil,
      repr: nil,
      bin: nil,
      compare: "none",
      eval_count: 0,
      state: "ok",
      origin: "manual",
      session: nil,
      commit: nil,
      commit_at: nil,
      dirty: nil,
      result_at: nil,
      error: nil
    }

    Book.put(book, :calls, id, Map.merge(defaults, row))
  end

  @spec edit_args(Book.t(), String.t(), [String.t()]) :: Book.t()
  def edit_args(book, id, new_args) do
    row = fetch!(book, :calls, id)
    Book.put(book, :calls, id, Map.put(row, :args, new_args))
  end

  @doc "Manually set the 前回 (prev) column as an expectation value (spec §6.4, prebuild.md §2: does not bump eval_count)."
  @spec set_prev(Book.t(), String.t(), String.t()) :: Book.t()
  def set_prev(book, id, prev_value) do
    row = fetch!(book, :calls, id)
    Book.put(book, :calls, id, Map.merge(row, %{prev: prev_value, prev_source: "user"}))
  end

  @spec remove_call(Book.t(), String.t()) :: Book.t()
  def remove_call(book, id), do: Book.delete(book, :calls, id)

  @valid_effects ["pure", "reads", "writes", "unknown"]

  @doc "Explicit effect assignment (spec §8.3) -- this is the *only* way effect_source becomes \"user\" in this build (prebuild.md §4.2: §8.2's automatic inference is out of scope)."
  @spec set_effect(Book.t(), String.t(), String.t()) :: Book.t()
  def set_effect(book, node_id, effect) when effect in @valid_effects do
    row = fetch!(book, :nodes, node_id)
    Book.put(book, :nodes, node_id, Map.merge(row, %{effect: effect, effect_source: "user"}))
  end

  defp fetch!(book, table, id) do
    Book.get(book, table, id) || raise "unknown #{table} id: #{id}"
  end

  # ---------------------------------------------------------------------
  # reference graph (§6.2) -- pure text scan, no language parsing
  # ---------------------------------------------------------------------

  @ref_re ~r/⟦([^⟧]+)⟧/u

  @doc "IDs referenced by a list of arg expression strings (⟦id⟧ tokens)."
  @spec refs_in_args([String.t()]) :: [String.t()]
  def refs_in_args(args) when is_list(args) do
    args
    |> Enum.flat_map(fn arg -> Regex.scan(@ref_re, arg, capture: :all_but_first) end)
    |> List.flatten()
    |> Enum.uniq()
  end

  @doc "call_id => [referenced call_id] for every call currently in the book."
  @spec reference_graph(Book.t()) :: %{String.t() => [String.t()]}
  def reference_graph(book) do
    for {id, row} <- book.calls, into: %{}, do: {id, refs_in_args(row.args)}
  end

  @doc "The set of call ids that belong to a reference cycle (spec §6.6/§6.7)."
  @spec cyclic_ids(%{String.t() => [String.t()]}) :: MapSet.t()
  def cyclic_ids(graph) do
    {_, cyclic} =
      Enum.reduce(Map.keys(graph), {%{}, MapSet.new()}, fn id, {state, cyclic} ->
        if Map.has_key?(state, id) do
          {state, cyclic}
        else
          visit(id, graph, state, cyclic, [])
        end
      end)

    cyclic
  end

  defp visit(id, graph, state, cyclic, path) do
    state = Map.put(state, id, :in_progress)
    path = [id | path]

    {state, cyclic} =
      graph
      |> Map.get(id, [])
      |> Enum.reduce({state, cyclic}, fn neighbor, {state, cyclic} ->
        case Map.get(state, neighbor) do
          :in_progress ->
            idx = Enum.find_index(path, &(&1 == neighbor))
            members = Enum.take(path, idx + 1)
            {state, Enum.into(members, cyclic)}

          :done ->
            {state, cyclic}

          nil ->
            visit(neighbor, graph, state, cyclic, path)
        end
      end)

    {Map.put(state, id, :done), cyclic}
  end

  # ---------------------------------------------------------------------
  # affected-set / recalc scope (prebuild.md §4.1-§4.3) -- pure graph
  # reachability only, no call_hash comparison anywhere in scoping
  # ---------------------------------------------------------------------

  @doc """
  Node ids whose dep_hash is now stale: `changed_node_ids` plus every node
  that (transitively) calls one of them, per the static call graph in
  `link` rows (fix B in the review: dep_hash, not body_hash -- a node whose
  own source is untouched but whose callee changed must still be included).
  """
  @spec dep_hash_affected_nodes(Book.t(), [String.t()]) :: MapSet.t()
  def dep_hash_affected_nodes(book, changed_node_ids) do
    # reverse of the static "node calls ref" edges (role: "to")
    reverse =
      book.links
      |> Map.values()
      |> Enum.filter(&(&1.role == "to"))
      |> Enum.group_by(& &1.ref, & &1.node)

    seeds = MapSet.new(changed_node_ids)
    bfs(seeds, seeds, reverse)
  end

  @spec calls_for_nodes(Book.t(), Enumerable.t()) :: [String.t()]
  def calls_for_nodes(book, node_ids) do
    node_set = MapSet.new(node_ids)
    for {id, row} <- book.calls, MapSet.member?(node_set, row.node), do: id
  end

  @doc """
  affected集合 (§6.6): explicit call-row targets, plus every call using a
  node whose dep_hash just changed, plus the transitive downstream of all
  of that via the `⟦id⟧` reference graph. Fix C: rows whose effect excludes
  them from evaluation are *not* removed from this set here -- downstream
  of an excluded row still gets scheduled and simply reads that row's
  stored value (filter_by_effect/3 is what actually decides what runs).
  """
  @spec affected_set(Book.t(), [String.t()], [String.t()]) :: MapSet.t()
  def affected_set(book, explicit_call_ids, changed_node_ids) do
    from_nodes = calls_for_nodes(book, dep_hash_affected_nodes(book, changed_node_ids))
    seeds = MapSet.new(explicit_call_ids ++ from_nodes)

    reverse_refs =
      Enum.reduce(reference_graph(book), %{}, fn {caller, refs}, acc ->
        Enum.reduce(refs, acc, fn ref, acc -> Map.update(acc, ref, [caller], &[caller | &1]) end)
      end)

    bfs(seeds, seeds, reverse_refs)
  end

  defp bfs(frontier, acc, reverse_graph) do
    next =
      frontier
      |> Enum.flat_map(&Map.get(reverse_graph, &1, []))
      |> MapSet.new()
      |> MapSet.difference(acc)

    if MapSet.size(next) == 0 do
      acc
    else
      bfs(next, MapSet.union(acc, next), reverse_graph)
    end
  end

  @doc """
  Filter an affected set down to call ids that are actually allowed to run
  (fix D): the node must have an explicit `effect/set` (effect_source ==
  "user" -- §8.2's automatic inference is out of scope for this build, so a
  node nobody has classified never runs, rather than silently defaulting to
  "pure"). `unknown` is treated the same as `writes`.
  """
  @spec filter_by_effect(Book.t(), Enumerable.t(), keyword()) :: [String.t()]
  def filter_by_effect(book, call_ids, opts \\ []) do
    include_writes = Keyword.get(opts, :include_writes, false)

    Enum.filter(call_ids, fn id ->
      call = Book.get(book, :calls, id)
      node = call && Book.get(book, :nodes, call.node)

      cond do
        is_nil(node) -> false
        node.effect_source != "user" -> false
        node.effect in ["pure", "reads"] -> true
        include_writes and node.effect in ["writes", "unknown"] -> true
        true -> false
      end
    end)
  end

  @doc "Topological order of `call_ids`, using only reference edges between members of the set."
  @spec topo_sort([String.t()], %{String.t() => [String.t()]}) :: [String.t()]
  def topo_sort(call_ids, graph) do
    id_set = MapSet.new(call_ids)

    local_graph =
      for id <- call_ids, into: %{} do
        {id, graph |> Map.get(id, []) |> Enum.filter(&MapSet.member?(id_set, &1))}
      end

    {order, _done} =
      Enum.reduce(call_ids, {[], MapSet.new()}, fn id, {order, done} ->
        topo_visit(id, local_graph, order, done)
      end)

    Enum.reverse(order)
  end

  defp topo_visit(id, graph, order, done) do
    if MapSet.member?(done, id) do
      {order, done}
    else
      done = MapSet.put(done, id)

      {order, done} =
        graph
        |> Map.get(id, [])
        |> Enum.reduce({order, done}, fn dep, {order, done} -> topo_visit(dep, graph, order, done) end)

      {[id | order], done}
    end
  end

  # ---------------------------------------------------------------------
  # Plan (prebuild.md §4.4) -- pure. Never calls a REPL, never reads a
  # clock, never touches git. `ctx` values that need those (commit info)
  # are supplied later, by the caller, to apply_results/3.
  # ---------------------------------------------------------------------

  @doc """
  Build a recalc Plan. `opts`:
    * `:call_ids` - explicit calc-row targets (e.g. one just edited)
    * `:changed_node_ids` - nodes whose Scanner-reported dep_hash changed
    * `:include_writes` - also schedule writes/unknown nodes (still requires
      an explicit `effect/set`, per filter_by_effect/3)
    * `:restart_session` - forwarded to the Plan as-is (a border-rule decision, §13.2)
  """
  @spec plan_recalc(Book.t(), String.t(), keyword()) :: map()
  def plan_recalc(book, pass_id, opts \\ []) do
    targets = Keyword.get(opts, :call_ids, [])
    changed_nodes = Keyword.get(opts, :changed_node_ids, [])
    include_writes = Keyword.get(opts, :include_writes, false)
    restart_session = Keyword.get(opts, :restart_session, false)

    graph = reference_graph(book)
    cyclic = cyclic_ids(graph)
    acyclic_graph = for {id, refs} <- graph, id not in cyclic, into: %{}, do: {id, Enum.reject(refs, &(&1 in cyclic))}

    affected = affected_set(book, targets, changed_nodes) |> Enum.reject(&(&1 in cyclic))
    scheduled = filter_by_effect(book, affected, include_writes: include_writes)
    order = topo_sort(scheduled, acyclic_graph)
    in_plan_set = MapSet.new(order)

    entries = Enum.map(order, &build_entry(book, &1, in_plan_set))

    %{
      pass_id: pass_id,
      restart_session: restart_session,
      entries: entries,
      cyclic_ids: cyclic
    }
  end

  defp build_entry(book, id, in_plan_set) do
    call = Book.get(book, :calls, id)
    node = Book.get(book, :nodes, call.node)

    {args, inputs} =
      Enum.map_reduce(call.args, [], fn arg, inputs_acc ->
        {new_arg, more_inputs} = resolve_refs(book, arg, in_plan_set)
        {new_arg, inputs_acc ++ more_inputs}
      end)

    basis =
      cond do
        call[:prev] not in [nil, ""] -> {:text, call.prev}
        true -> :none
      end

    %{
      call_id: id,
      node_id: call.node,
      args: args,
      inputs: Enum.uniq(inputs),
      bind_as: if(node.effect != "pure", do: binding_name(id)),
      basis: basis,
      limits: %{timeout: 5_000, max_heap: 50_000_000}
    }
  end

  defp binding_name(call_id), do: String.to_atom("xt_" <> String.replace(call_id, ~r/[^A-Za-z0-9_]/, "_"))

  # Substitutes every ⟦ref⟧ token in `text` per spec §6.3's table. A
  # plan-internal ref (evaluated later in this same pass) can only ever be a
  # placeholder+binding -- its value does not exist yet when the plan is
  # built (this was the bug fix that motivated the 3-stage split).
  #
  # KNOWN SIMPLIFICATION: the "unsupported + pure" plan-external case is
  # spec'd (§6.3) to re-embed the upstream's own call expression rather
  # than bind a session variable, for full text reproducibility. Building
  # that expression needs the target language's call syntax, which is the
  # REPL adapter's job (§12.2), not Core's -- deferred; for now this case
  # falls back to the same session-binding treatment as "unsupported +
  # non-pure" below, which is less reproducible but not incorrect.
  defp resolve_refs(book, text, in_plan_set) do
    refs_in_args([text])
    |> Enum.reduce({text, []}, fn ref, {text, inputs} ->
      token = "⟦#{ref}⟧"
      var = binding_name(ref)
      ref_call = Book.get(book, :calls, ref)

      cond do
        MapSet.member?(in_plan_set, ref) ->
          {String.replace(text, token, Atom.to_string(var)), [%{ref: ref, var: var, from: :plan} | inputs]}

        ref_call && ref_call.repr in ["exact", "binary"] ->
          {String.replace(text, token, ref_call.result), inputs}

        true ->
          gen = ref_call && ref_call[:session]
          {String.replace(text, token, Atom.to_string(var)), [%{ref: ref, var: var, from: {:session, gen}} | inputs]}
      end
    end)
  end

  # ---------------------------------------------------------------------
  # apply_results (prebuild.md §4.4) -- pure. `ctx` carries the git info
  # the GenServer-side shell fetched (Core itself never touches git).
  # ---------------------------------------------------------------------

  @doc "Fold a completed pass's results into the book. `ctx` = %{commit:, commit_at:, dirty:}."
  @spec apply_results(Book.t(), map(), [map()]) :: Book.t()
  def apply_results(book, ctx, results) do
    Enum.reduce(results, book, &apply_result(&2, ctx, &1))
  end

  # Map.merge/2, not `%{row | ...}` -- rows are open, growing maps (the
  # schema gains columns across spec versions, and a row folded from an
  # older Store line may be missing a newer key), so a strict struct-style
  # update that requires every key to pre-exist would be too brittle.
  defp apply_result(book, ctx, %{call_id: id, outcome: outcome} = result) do
    row = Book.get(book, :calls, id)
    bump = %{eval_count: (row[:eval_count] || 0) + 1}

    case outcome do
      {:ok, %{repr: repr, display: display, type: type, bin: bin}} ->
        Book.put(
          book,
          :calls,
          id,
          Map.merge(row, %{
            result: display,
            result_type: type,
            repr: repr,
            bin: bin,
            result_at: result.evaluated_at,
            commit: ctx[:commit],
            commit_at: ctx[:commit_at],
            dirty: ctx[:dirty],
            session: result.session_gen,
            prev: row[:result],
            prev_at: row[:result_at],
            prev_source: "auto",
            compare: result.compare,
            eval_count: bump.eval_count,
            state: "ok",
            error: nil
          })
        )

      {:error, reason} ->
        Book.put(book, :calls, id, Map.merge(row, Map.merge(bump, %{state: "eval_error", error: inspect(reason)})))

      :timeout ->
        Book.put(book, :calls, id, Map.merge(row, Map.merge(bump, %{state: "eval_error", error: "timeout"})))

      :max_heap ->
        Book.put(book, :calls, id, Map.merge(row, Map.merge(bump, %{state: "eval_error", error: "max_heap"})))

      {:skipped, upstream_id} ->
        Book.put(book, :calls, id, Map.merge(row, %{state: "ref_error", error: "upstream #{upstream_id} did not evaluate"}))

      {:lost, ref} ->
        Book.put(book, :calls, id, Map.merge(row, %{state: "lost", error: "missing binding for #{ref}"}))

      :aborted ->
        book
    end
  end
end
