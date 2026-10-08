Code.require_file("book.exs", __DIR__)

defmodule XipeTotec.Core do
  @moduledoc """
  Pure functions over `Book` (spec §4, Old.md §3-§4). No I/O, no
  randomness, no clock reads: every id/timestamp this module needs is
  supplied by the caller so it stays a genuinely pure `apply`. This module
  does not evaluate anything -- see Old.md §4.4's 3-stage split:

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
      result_source: nil,
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

  @doc "Manually set the 前回 (prev) column as an expectation value (spec §6.4, Old.md §2: does not bump eval_count)."
  @spec set_prev(Book.t(), String.t(), String.t()) :: Book.t()
  def set_prev(book, id, prev_value) do
    row = fetch!(book, :calls, id)
    Book.put(book, :calls, id, Map.merge(row, %{prev: prev_value, prev_source: "user"}))
  end

  @doc """
  Directly write a user-supplied literal as a call's `result`, without any
  evaluation (Old.md §16.4/§19, the dependency-chain negotiation's
  "insert a value into X" step). `result_value` must already be valid
  target-language source text for a literal -- `resolve_ref/4`'s own
  "already exact" branch (below) embeds `result` verbatim into a
  dependent call's generated expression, exactly the same as a real eval's
  `display` value would be, so this function needs no new embedding logic
  and no other part of Core needs to know a value was hand-supplied rather
  than evaluated. Always classified `repr: "exact"` (never `"binary"` --
  there's no evaluation step here to produce a `bin_base64`-style binary
  fallback for an unsupported value; the human is expected to supply
  something the target language can read back as a literal). Marked
  `result_source: "user"` (mirrors `set_prev/3`'s `prev_source: "user"`)
  purely for future display/debugging -- nothing in `Core` reads this
  column back.
  """
  @spec set_result(Book.t(), String.t(), String.t()) :: Book.t()
  def set_result(book, id, result_value) do
    row = fetch!(book, :calls, id)

    Book.put(
      book,
      :calls,
      id,
      Map.merge(row, %{
        result: result_value,
        repr: "exact",
        result_source: "user",
        state: "ok",
        error: nil
      })
    )
  end

  @doc """
  A node's display label: `"Module.name/anykey"` -- `"Calc.add/2"` for
  Elixir, whose scanner puts the arity in `anykey` -- or just
  `"Module.name"` when the node has no `anykey`. A node whose arities a
  person declared (`arity/set`) shows them: `"M.scale/1..2"`, `"M.f/1,3"`.
  """
  @spec node_label(map()) :: String.t()
  def node_label(%{module: module, name: name} = node) do
    case {node[:anykey], node[:arities]} do
      {nil, _} -> "#{module}.#{name}"
      {_key, [_, _ | _] = as} -> "#{module}.#{name}/#{arities_text(as)}"
      {key, _} -> "#{module}.#{name}/#{key}"
    end
  end

  @doc "`[1, 2]` -> `\"1..2\"`, `[1, 3]` -> `\"1,3\"`, `[2]` -> `\"2\"`."
  @spec arities_text([non_neg_integer()]) :: String.t()
  def arities_text([first | _] = as) do
    last = List.last(as)
    if length(as) > 1 and as == Enum.to_list(first..last),
      do: "#{first}..#{last}",
      else: Enum.join(as, ",")
  end

  @doc """
  The argument counts a node can be called with: what a person declared
  (`arity/set`, for a function with default arguments: `def f(x, k \\\\ 2)`
  is `f/1` and `f/2`), else its integer anykey alone; `nil` when the node's
  anykey is no argument count (another language's scanner).
  """
  @spec accepted_arities(map()) :: [non_neg_integer()] | nil
  def accepted_arities(node) do
    case {node[:anykey], node[:arities]} do
      {key, [_ | _] = as} when is_integer(key) -> as
      {key, _} when is_integer(key) -> [key]
      _ -> nil
    end
  end

  @doc """
  Declare the argument counts node `node_id` can be called with (crux
  2026-10-08: a person decides, as with `effect/set`; the scanner never
  sets it). Sorted, without duplicates; just the anykey clears it.
  """
  @spec set_arities(Book.t(), String.t(), [non_neg_integer()]) :: Book.t()
  def set_arities(book, node_id, arities) do
    row = fetch!(book, :nodes, node_id)
    as = arities |> Enum.uniq() |> Enum.sort()
    Book.put(book, :nodes, node_id, Map.put(row, :arities, if(as == [row[:anykey]], do: nil, else: as)))
  end

  @doc "Short display label for a call, \"Module.name/arity\" -- same format `GraphQuery`'s own node-label helper uses, reused here for the dependency-chain negotiation's `;; wN <label>` lines. `nil` if the call or its node no longer exists."
  @spec call_label(Book.t(), String.t()) :: String.t() | nil
  def call_label(book, call_id) do
    with call when not is_nil(call) <- Book.get(book, :calls, call_id),
         node when not is_nil(node) <- Book.get(book, :nodes, call.node) do
      # a node with declared arities (arity/set): the one this row calls, scale/1
      case {node[:arities], call[:args]} do
        {[_, _ | _], args} when is_list(args) -> "#{node.module}.#{node.name}/#{length(args)}"
        _ -> node_label(node)
      end
    else
      nil -> nil
    end
  end

  @spec remove_call(Book.t(), String.t()) :: Book.t()
  def remove_call(book, id), do: Book.delete(book, :calls, id)

  @valid_effects ["pure", "reads", "writes", "unknown"]

  @doc "Explicit effect assignment (spec §8.3) -- this is the *only* way effect_source becomes \"user\" in this build (Old.md §4.2: §8.2's automatic inference is out of scope)."
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
  # reachability over the ⟦id⟧ reference graph
  # ---------------------------------------------------------------------

  # every id reachable from `frontier` along `graph`'s edges, `acc` included
  defp bfs(frontier, acc, graph) do
    next =
      frontier
      |> Enum.flat_map(&Map.get(graph, &1, []))
      |> MapSet.new()
      |> MapSet.difference(acc)

    if MapSet.size(next) == 0 do
      acc
    else
      bfs(next, MapSet.union(acc, next), graph)
    end
  end

  @doc """
  The upstream `⟦id⟧` dependency chain of `call_ids` (Old.md §16.3/
  §16.4, 2026-09-19/20-21 co-design): `call_ids` themselves plus every call
  id (transitively) referenced by their own args, ordered deepest-first via
  `topo_sort/2` -- the same "leaves before dependents" order `plan_recalc/3`
  already relies on, and the exact "深い方から浅い方へ" order §16.4's
  planned dependency-chain negotiation needs.

  Walks `reference_graph/1` *forward* (call -> what it references).
  Distinct from `GraphQuery.graph/neighbors`,
  which walks the static `:links` call graph (node calls node, from
  `Scanner`) -- this walks the calc-row dependency graph (call references
  call via `⟦id⟧` in args), a different edge type entirely.

  An id in `call_ids` that isn't in `book.calls` contributes no
  dependencies (silently -- `reference_graph/1` simply has no entry for
  it) rather than erroring; this function is a graph query, not a
  validator. A reference cycle can't be topologically sorted, but
  `topo_sort/2`'s own `done`-marking still terminates (see its
  moduledoc-adjacent comment) rather than looping forever -- the cyclic
  members just come out in a non-meaningful (but stable) order, same as
  everywhere else in `Core` that doesn't special-case cycles beyond not
  hanging.
  """
  @spec upstream_chain(Book.t(), [String.t()]) :: [String.t()]
  def upstream_chain(book, call_ids) do
    graph = reference_graph(book)
    full = bfs(MapSet.new(call_ids), MapSet.new(call_ids), graph)
    topo_sort(MapSet.to_list(full), graph)
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

  @doc """
  Why `plan_recalc/3` leaves `call_id` out of the plan before it ever
  reaches the REPL, as a human-readable reason -- or `nil` if nothing at
  this level excludes it. Mirrors `plan_recalc/3`'s own exclusion order
  (unknown call, circular reference, `filter_by_effect/3`); a call that
  passes all of these but still has no result was dropped later
  (`drop_unresolvable/2` reports those itself as `{:skipped, ref}`).
  Old.md §33: without this, `xipe eval` on an unclassified node printed
  only `1 command(s), 1 ok` and ran nothing.
  """
  @spec exclusion_reason(Book.t(), String.t(), keyword()) :: String.t() | nil
  def exclusion_reason(book, call_id, opts \\ []) do
    include_writes = Keyword.get(opts, :include_writes, false)
    call = Book.get(book, :calls, call_id)
    node = call && Book.get(book, :nodes, call.node)

    cond do
      is_nil(call) -> "unknown call id"
      call_id in cyclic_ids(reference_graph(book)) -> "circular ⟦⟧ reference"
      is_nil(node) -> "its node no longer exists (removed by a rescan?)"
      node.effect_source != "user" -> "effect not classified -- `effect/set id=#{call.node} effect=pure` (or reads) to evaluate"
      node.effect in ["pure", "reads"] -> nil
      include_writes -> nil
      true -> "effect=#{node.effect} -- pass --include-writes (or include_writes=true) to evaluate"
    end
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
  # Plan (Old.md §4.4) -- pure. Never calls a REPL, never reads a
  # clock, never touches git. `ctx` values that need those (commit info)
  # are supplied later, by the caller, to apply_results/3.
  # ---------------------------------------------------------------------

  @doc """
  Build a recalc Plan. `opts`:
    * `:call_ids` - the calc rows to evaluate
    * `:include_writes` - also schedule writes/unknown nodes (still requires
      an explicit `effect/set`, per filter_by_effect/3)

  Only the given rows are evaluated (2026-09-26, Old.md §36): the Book is
  a chronological record, and every evaluation in it is one a command
  asked for. Neither the rows referencing a given row (downstream) nor
  the rows it references (upstream) are added -- to evaluate a chain,
  name its rows together (How to use §2.6); a referenced row evaluated in
  the same pass hands its value over through a session binding.

  A row referencing one whose value the book can't hand over (never
  evaluated, or `unsupported`) and that isn't in the same pass
  can't be evaluated: `drop_unresolvable/2` leaves it out as
  `{:skipped, ref}`.

  Returns `%{pass_id:, entries:, skipped:, cyclic_ids:}`. `skipped` is
  `[%{call_id:, outcome: {:skipped, ref}, ...}]` -- reported with the
  pass's results, never written to the book (`apply_result/3` ignores it:
  nothing was evaluated).
  """
  @spec plan_recalc(Book.t(), String.t(), keyword()) :: map()
  def plan_recalc(book, pass_id, opts \\ []) do
    targets = Keyword.get(opts, :call_ids, [])
    include_writes = Keyword.get(opts, :include_writes, false)

    graph = reference_graph(book)
    cyclic = cyclic_ids(graph)
    acyclic_graph = for {id, refs} <- graph, id not in cyclic, into: %{}, do: {id, Enum.reject(refs, &(&1 in cyclic))}

    requested = targets |> Enum.uniq() |> Enum.filter(&Book.get(book, :calls, &1)) |> Enum.reject(&(&1 in cyclic))
    scheduled = filter_by_effect(book, requested, include_writes: include_writes)
    {runnable, skipped} = drop_unresolvable(book, scheduled)
    order = topo_sort(runnable, acyclic_graph)
    in_plan_set = MapSet.new(order)

    entries = Enum.map(order, &build_entry(book, &1, in_plan_set))

    %{
      pass_id: pass_id,
      entries: entries,
      skipped: skipped,
      cyclic_ids: cyclic
    }
  end

  # A `:binding` input (resolve_ref/4's catch-all) is only ever safe to
  # embed as a bare session-variable reference when its `ref` is itself
  # scheduled in this same pass (an `:in_plan` reference, bound by an
  # earlier entry before this one runs) -- sessions never persist across
  # separate `run_pass` calls (§16.4 addendum: the distributed-session
  # design this branch originally assumed was withdrawn), so a `:binding`
  # pointing outside the pass can never actually resolve. Left alone, the
  # bare variable EvalTemplate embeds inside its `spawn_monitor` closure
  # fails at *compile* time (Elixir resolves variables lexically) -- before
  # `spawn_monitor` is even reached, so no `XT_*` marker is ever printed
  # and the entry silently reads as `session_hung` after the fixed
  # deadline, not a clean error (Old.md §18's unexplained hang;
  # confirmed by code reading 2026-09-22, not reproduced live). Detecting
  # this here -- a pure Book-level check, no REPL involved -- lets the
  # call short-circuit to the existing (previously unproduced) `{:skipped,
  # ref}` outcome instead of ever reaching the REPL. Skipping cascades
  # (anything depending on a skipped call needs the same treatment), so
  # this is a fixed-point removal: each pass rescans the whole remaining
  # set against itself, and stops once nothing in it has an unresolvable
  # binding left.
  @spec drop_unresolvable(Book.t(), [String.t()]) :: {[String.t()], [map()]}
  defp drop_unresolvable(book, scheduled), do: shrink(book, MapSet.new(scheduled), [])

  defp shrink(book, set, skipped) do
    culprit =
      Enum.find_value(set, fn id ->
        case missing_ref(book, id, set) do
          nil -> nil
          ref -> {id, ref}
        end
      end)

    case culprit do
      nil ->
        {MapSet.to_list(set), Enum.reverse(skipped)}

      {id, ref} ->
        # Same result shape as Evaluator's own :aborted/hung results
        # (lib/repl/evaluator.exs) and Repl.Eval.Result.error/3's
        # timeout/max_heap/crash cases: every non-`:ok` outcome carries
        # `compare: "skipped"`/`evaluated_at: nil`/`session_gen: nil` when
        # nothing ever reached a REPL, so apply_result/3's callers and the
        # CLI's own eval-outcome printer (main.exs) don't need a
        # skipped-only special case.
        skip = %{call_id: id, outcome: {:skipped, ref}, compare: "skipped", evaluated_at: nil, session_gen: nil}
        shrink(book, MapSet.delete(set, id), [skip | skipped])
    end
  end

  defp missing_ref(book, id, in_plan_set) do
    book
    |> Book.get(:calls, id)
    |> Map.fetch!(:args)
    |> Enum.flat_map(&elem(resolve_refs(book, &1, in_plan_set), 1))
    |> Enum.find_value(fn
      {:binding, %{ref: ref}} -> ref
      _ -> nil
    end)
  end

  defp build_entry(book, id, in_plan_set) do
    call = Book.get(book, :calls, id)
    node = Book.get(book, :nodes, call.node)

    {args, inputs} =
      Enum.map_reduce(call.args, [], fn arg, inputs_acc ->
        {new_arg, more_inputs} = resolve_refs(book, arg, in_plan_set)
        {new_arg, inputs_acc ++ more_inputs}
      end)

    # basis (compare's "previous value" input): spec §6.4 names this B --
    # "比較の基準Bを決める。Pの出どころがuserならB=P、そうでなければB=R_old"
    # (P = the 前回/prev column, R_old = the result on record right before
    # this evaluation overwrites it). Two cases:
    #
    # 1. `prev_source == "user"` (the user typed an expected value in via
    #    `set_prev/3` -- not reachable through any Dispatch/CLI method yet,
    #    only `Core.set_prev/3` directly, so this branch is currently dead
    #    code in practice, flagged by review 2026-09-18 as a spec gap worth
    #    closing now while it's cheap): B = P = `call.prev`. A user-typed
    #    expectation is plain text the user wrote, not a captured runtime
    #    value with a repr classification of its own -- always reconstructed
    #    as `:exact` (re-run through `Code.eval_string/1` target-side).
    # 2. Otherwise (prev_source auto or unset): B = R_old = whatever is
    #    currently on record (`call.result`/`call.repr`/`call.bin`, about to
    #    be rolled into `prev`/`prev_at` by apply_result once this pass's
    #    result comes back) -- NOT the `prev` column itself, which already
    #    lags one eval further back (apply_result sets `prev: row[:result]`
    #    using the row as it stood *before* the result it's currently
    #    applying). Using `prev` here would silently compare against a stale
    #    value one generation too old (caught live, 2026-09-18: a same-args
    #    re-eval right after a first eval showed basis == :none instead of
    #    the just-stored result).
    #
    # Reconstructing either on the target node needs to know HOW, not just
    # display text -- an `exact` value is re-run through
    # `Code.eval_string/1`, a `binary` one through
    # `Base.decode64!/1 |> :erlang.binary_to_term/1` (EvalTemplate builds the
    # actual snippet; Core only picks which shape applies). A prior
    # `unsupported` value has no reconstructible text at all, so it falls to
    # `:none` same as "never evaluated" -- compare degrades to "skipped" for
    # those, matching Old.md §28 C's "片側でも unsupported なら skipped".
    # This supersedes Old.md §28 B's original `{:text, String.t()} | {:bin,
    # binary()}` sketch.
    basis =
      cond do
        call[:prev_source] == "user" and call[:prev] not in [nil, ""] -> {:exact, call.prev}
        call[:repr] == "exact" and call[:result] not in [nil, ""] -> {:exact, call.result}
        call[:repr] == "binary" and call[:bin] not in [nil, ""] -> {:binary, call.bin}
        true -> :none
      end

    %{
      call_id: id,
      node_id: call.node,
      module: node.module,
      name: node.name,
      anykey: node.anykey,
      args: args,
      inputs: Enum.uniq(inputs),
      basis: basis,
      limits: %{timeout: 5_000, max_heap_words: 50_000_000}
    }
  end

  defp binding_name(call_id), do: String.to_atom("xt_" <> String.replace(call_id, ~r/[^A-Za-z0-9_]/, "_"))

  # Substitutes every ⟦ref⟧ token in `text` per spec §6.3's table, per the
  # Old.md §28 B answer's division of labor: Core only ever does data-level
  # substitution (embed a stored canonical value) or leaves a placeholder
  # token + a typed `inputs` entry describing what belongs there -- it
  # never builds a call expression itself (that's target-language syntax,
  # the REPL adapter's job, §12.2).
  defp resolve_refs(book, text, in_plan_set) do
    refs_in_args([text])
    |> Enum.reduce({text, []}, fn ref, {text, inputs} ->
      token = "⟦#{ref}⟧"
      {replacement, more_inputs} = resolve_ref(book, ref, in_plan_set)
      {String.replace(text, token, replacement), more_inputs ++ inputs}
    end)
  end

  # A plan-internal ref (evaluated later in this same pass) can only ever be
  # a placeholder+binding -- its value does not exist yet when the plan is
  # built (this was the bug fix that motivated the 3-stage split).
  #
  # A plan-external ref with a stored exact repr is embedded as its own
  # literal canonical text -- pure string substitution.
  #
  # Everything else (a plan-external row whose value the book can't hand
  # over -- never evaluated, binary or unsupported -- or a dangling/unknown
  # ref) is a `:binding` to a variable no earlier entry of the pass sets:
  # drop_unresolvable/2 turns the row into `{:skipped, ref}` before it
  # reaches the REPL. The REPL session lives for one pass only, so no
  # binding survives from another. An unsupported value from a pure
  # function used to be handed over by re-embedding its call expression;
  # that ran the referenced function without a record of it, so since
  # 2026-09-26 (Old.md §36) it is left to the caller to evaluate that row
  # in the same pass.
  #
  # A binary value is not handed over either (2026-10-06, Old.md §51): its
  # stored `result` is only its display, which by definition doesn't read
  # back (embedded, `#P.S<a: 1, ...>` made the call a syntax error), and
  # rebuilding it from `bin` is per-language work the plain command path
  # doesn't take on. Such a value is the person's to settle: evaluate the
  # referenced row in the same command, or give a value in its place
  # (`dialogue depends`, which writes it with `row/set-result`).
  defp resolve_ref(book, ref, in_plan_set) do
    var = binding_name(ref)
    placeholder = Atom.to_string(var)
    ref_call = Book.get(book, :calls, ref)

    cond do
      MapSet.member?(in_plan_set, ref) ->
        {placeholder, [{:in_plan, %{placeholder: placeholder, ref: ref, var: var}}]}

      ref_call && ref_call.repr == "exact" ->
        {ref_call.result, []}

      true ->
        {placeholder, [{:binding, %{placeholder: placeholder, var: var, ref: ref}}]}
    end
  end

  # ---------------------------------------------------------------------
  # apply_results (Old.md §4.4) -- pure. `ctx` carries the git info
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

      # reason is already text from Result.error/3 / Evaluator ("session_hung");
      # inspect only what isn't, or the stored error gains a layer of quotes
      {:error, reason} ->
        error = if is_binary(reason), do: reason, else: inspect(reason)
        Book.put(book, :calls, id, Map.merge(row, Map.merge(bump, %{state: "eval_error", error: error})))

      :timeout ->
        Book.put(book, :calls, id, Map.merge(row, Map.merge(bump, %{state: "eval_error", error: "timeout"})))

      :max_heap ->
        Book.put(book, :calls, id, Map.merge(row, Map.merge(bump, %{state: "eval_error", error: "max_heap"})))

      # not evaluated: nothing to record (the book only holds evaluations)
      {:skipped, _upstream_id} ->
        book

      :aborted ->
        book
    end
  end
end
