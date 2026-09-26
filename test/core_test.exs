ExUnit.start()

Code.require_file(Path.expand("../lib/book.exs", __DIR__))
Code.require_file(Path.expand("../lib/core.exs", __DIR__))

defmodule CoreTest do
  use ExUnit.Case, async: true

  alias XipeTotec.{Book, Core}

  defp pure_node(name), do: %{module: "M", name: name, anykey: 1, effect: "pure", effect_source: "user"}

  describe "refs_in_args/1" do
    test "extracts every ⟦id⟧ token, de-duplicated" do
      assert Core.refs_in_args(["elem(⟦c1⟧, 1)", "⟦c2⟧ + ⟦c1⟧"]) |> Enum.sort() == ["c1", "c2"]
    end

    test "an arg with no reference yields nothing" do
      assert Core.refs_in_args(["100", "0.1"]) == []
    end
  end

  describe "cyclic_ids/1" do
    test "no cycle in a plain chain" do
      graph = %{"a" => ["b"], "b" => ["c"], "c" => []}
      assert Core.cyclic_ids(graph) == MapSet.new()
    end

    test "a self-loop is a cycle" do
      graph = %{"a" => ["a"]}
      assert Core.cyclic_ids(graph) == MapSet.new(["a"])
    end

    test "a mutual (2-node) cycle is detected" do
      graph = %{"a" => ["b"], "b" => ["a"]}
      assert Core.cyclic_ids(graph) == MapSet.new(["a", "b"])
    end

    test "a diamond (shared dependency, no cycle) is not flagged" do
      graph = %{"a" => ["b", "c"], "b" => ["d"], "c" => ["d"], "d" => []}
      assert Core.cyclic_ids(graph) == MapSet.new()
    end
  end

  describe "upstream_chain/2 (Old.md §16.3/§16.4)" do
    test "a straight chain c1 -> c2 -> c3 comes back deepest-first, self included" do
      book =
        Book.new()
        |> Core.add_call("c1", %{node: "n1", args: ["⟦c2⟧ + 1"]})
        |> Core.add_call("c2", %{node: "n2", args: ["⟦c3⟧ + 1"]})
        |> Core.add_call("c3", %{node: "n3", args: ["1"]})

      assert Core.upstream_chain(book, ["c1"]) == ["c3", "c2", "c1"]
    end

    test "a leaf with no references returns just itself" do
      book = Book.new() |> Core.add_call("c1", %{node: "n1", args: ["1"]})
      assert Core.upstream_chain(book, ["c1"]) == ["c1"]
    end

    test "does not include downstream callers" do
      book =
        Book.new()
        |> Core.add_call("c1", %{node: "n1", args: ["1"]})
        |> Core.add_call("c2", %{node: "n2", args: ["⟦c1⟧ + 1"]})

      assert Core.upstream_chain(book, ["c1"]) == ["c1"]
    end

    test "multiple seeds merge into one ordered chain, shared deps deduplicated" do
      book =
        Book.new()
        |> Core.add_call("c1", %{node: "n1", args: ["⟦shared⟧"]})
        |> Core.add_call("c2", %{node: "n2", args: ["⟦shared⟧"]})
        |> Core.add_call("shared", %{node: "n3", args: ["1"]})

      assert Core.upstream_chain(book, ["c1", "c2"]) |> Enum.sort() == ["c1", "c2", "shared"]
      assert List.last(Core.upstream_chain(book, ["c1", "c2"])) in ["c1", "c2"]
      assert Enum.count(Core.upstream_chain(book, ["c1", "c2"]), &(&1 == "shared")) == 1
    end

    test "an unknown seed id contributes nothing and does not raise" do
      book = Book.new()
      assert Core.upstream_chain(book, ["nonexistent"]) == ["nonexistent"]
    end

    test "a reference cycle terminates instead of looping forever" do
      book =
        Book.new()
        |> Core.add_call("c1", %{node: "n1", args: ["⟦c2⟧"]})
        |> Core.add_call("c2", %{node: "n2", args: ["⟦c1⟧"]})

      assert Core.upstream_chain(book, ["c1"]) |> Enum.sort() == ["c1", "c2"]
    end
  end

  describe "filter_by_effect/3 (fix D: unknown excluded by default; effect_source must be \"user\")" do
    setup do
      book =
        Book.new()
        |> Core.put_node("n_pure", pure_node("f"))
        |> Core.put_node("n_writes", %{module: "M", name: "g", anykey: 1, effect: "writes", effect_source: "user"})
        |> Core.put_node("n_unset", %{module: "M", name: "h", anykey: 1, effect: "unknown", effect_source: nil})
        |> Core.add_call("c_pure", %{node: "n_pure", args: []})
        |> Core.add_call("c_writes", %{node: "n_writes", args: []})
        |> Core.add_call("c_unset", %{node: "n_unset", args: []})

      {:ok, book: book}
    end

    test "pure/reads with an explicit effect/set pass by default", %{book: book} do
      assert Core.filter_by_effect(book, ["c_pure", "c_writes", "c_unset"]) == ["c_pure"]
    end

    test "writes passes only with include_writes: true", %{book: book} do
      assert Core.filter_by_effect(book, ["c_writes"], include_writes: true) == ["c_writes"]
    end

    test "a node nobody ran effect/set on never passes, even with include_writes: true", %{book: book} do
      assert Core.filter_by_effect(book, ["c_unset"], include_writes: true) == []
    end
  end

  describe "exclusion_reason/3 (Old.md §33: why plan_recalc/3 leaves a call out)" do
    defp excl_book(effect, source) do
      Book.new()
      |> Core.put_node("n1", %{module: "M", name: "f", anykey: 1, effect: effect, effect_source: source})
      |> Core.add_call("c1", %{node: "n1", args: ["1"]})
    end

    test "an unclassified node names the effect/set to run" do
      assert Core.exclusion_reason(excl_book("unknown", nil), "c1") =~ "effect/set id=n1"
    end

    test "writes without include_writes points at --include-writes; with it, nothing excludes" do
      assert Core.exclusion_reason(excl_book("writes", "user"), "c1") =~ "--include-writes"
      assert Core.exclusion_reason(excl_book("writes", "user"), "c1", include_writes: true) == nil
    end

    test "pure/reads classified by the user are not excluded" do
      assert Core.exclusion_reason(excl_book("pure", "user"), "c1") == nil
      assert Core.exclusion_reason(excl_book("reads", "user"), "c1") == nil
    end

    test "an unknown call id and a circular reference are named" do
      assert Core.exclusion_reason(Book.new(), "nope") == "unknown call id"

      book =
        excl_book("pure", "user")
        |> Core.add_call("c2", %{node: "n1", args: ["⟦c3⟧"]})
        |> Core.add_call("c3", %{node: "n1", args: ["⟦c2⟧"]})

      assert Core.exclusion_reason(book, "c2") =~ "circular"
    end

    test "a call whose node was removed" do
      book = Book.new() |> Core.add_call("c1", %{node: "gone", args: ["1"]})
      assert Core.exclusion_reason(book, "c1") =~ "no longer exists"
    end
  end

  describe "topo_sort/2" do
    test "dependencies come before dependents" do
      graph = %{"a" => ["b"], "b" => ["c"], "c" => []}
      assert Core.topo_sort(["a", "b", "c"], graph) == ["c", "b", "a"]
    end

    test "unrelated ids in any input order still each appear once" do
      graph = %{"x" => [], "y" => []}
      assert Enum.sort(Core.topo_sort(["y", "x"], graph)) == ["x", "y"]
    end
  end

  describe "plan_recalc/3" do
    setup do
      book =
        Book.new()
        |> Core.put_node("n1", pure_node("f"))
        |> Core.put_node("n2", pure_node("g"))
        |> Core.add_call("c1", %{node: "n1", args: ["1"], result: "1", repr: "exact"})
        |> Core.add_call("c2", %{node: "n2", args: ["⟦c1⟧ + 1"]})

      {:ok, book: book}
    end

    test "a plan-external exact-repr reference is embedded as literal text", %{book: book} do
      plan = Core.plan_recalc(book, "pass1", call_ids: ["c2"])

      assert [%{call_id: "c2", module: "M", name: "g", anykey: 1, args: ["1 + 1"], inputs: []}] =
               plan.entries
    end

    test "a plan-internal reference becomes a placeholder with an :in_plan input, in dependency order", %{book: book} do
      plan = Core.plan_recalc(book, "pass1", call_ids: ["c1", "c2"])
      assert [e1, e2] = plan.entries
      assert e1.call_id == "c1"
      assert e2.call_id == "c2"
      assert [arg] = e2.args
      assert arg != "⟦c1⟧ + 1"
      assert [{:in_plan, %{ref: "c1", var: var, placeholder: placeholder}}] = e2.inputs
      assert placeholder == Atom.to_string(var)
      assert arg == "#{placeholder} + 1"
    end

    # 2026-09-26 (Old.md §36): an unsupported value from a pure function used
    # to be handed over by re-embedding its call; that ran f without a
    # record, so the row referencing it must now be evaluated together with it
    test "a plan-external unsupported+pure reference is not re-run behind the scenes: the dependent call is skipped",
         %{book: book} do
      book =
        book
        |> Core.add_call("c3", %{node: "n1", args: ["99"], result: "#PID<0.1.0>", repr: "unsupported"})
        |> Core.add_call("c4", %{node: "n2", args: ["⟦c3⟧"]})

      plan = Core.plan_recalc(book, "pass1", call_ids: ["c4"])
      assert plan.entries == []
      assert [%{call_id: "c4", outcome: {:skipped, "c3"}}] = plan.skipped

      # named together, c3 runs first and hands its value over in the pass
      plan = Core.plan_recalc(book, "pass1", call_ids: ["c4", "c3"])
      assert [%{call_id: "c3"}, %{call_id: "c4", inputs: [{:in_plan, %{ref: "c3"}}]}] = plan.entries
    end

    # These three used to assert that a plan-external `:binding` fallback
    # gets scheduled as a normal entry -- that was the Old.md §18
    # `session_hung` bug itself (a bare `xt_<id>` reference that nothing in
    # the pass ever binds fails Elixir's *compile*-time variable resolution
    # inside EvalTemplate's `spawn_monitor` closure, before any `XT_*`
    # marker can print). `drop_unresolvable/2` (2026-09-22) now catches this
    # at plan-build time and skips the call instead of scheduling a doomed
    # entry -- see its moduledoc in `core.exs`.
    test "a plan-external unsupported+non-pure reference leaves the dependent call skipped unless evaluated with it",
         %{book: book} do
      book =
        book
        |> Core.put_node("n3", %{module: "M", name: "h", anykey: 0, effect: "writes", effect_source: "user"})
        |> Core.add_call("c5", %{node: "n3", args: [], result: "#PID<0.2.0>", repr: "unsupported", session: 3})
        |> Core.add_call("c6", %{node: "n2", args: ["⟦c5⟧"]})

      plan = Core.plan_recalc(book, "pass1", call_ids: ["c6"])
      assert plan.entries == []
      assert [%{call_id: "c6", outcome: {:skipped, "c5"}}] = plan.skipped

      # named together and allowed to run: c5's fresh value is passed on
      plan = Core.plan_recalc(book, "pass1", call_ids: ["c6", "c5"], include_writes: true)
      assert [%{call_id: "c5"}, %{call_id: "c6", inputs: [{:in_plan, %{ref: "c5"}}]}] = plan.entries
      assert plan.skipped == []
    end

    # 2026-09-26 (Old.md §36): the book records only evaluations a command
    # asked for -- no row is added to the plan on its own
    test "only the requested rows are planned: neither the rows referencing them nor the ones they reference", %{book: book} do
      book = Core.add_call(book, "c20", %{node: "n2", args: ["⟦c2⟧"]})

      # c2 references c1 (exact, embedded) and c20 references c2: only c2 runs
      plan = Core.plan_recalc(book, "pass1", call_ids: ["c2"])
      assert Enum.map(plan.entries, & &1.call_id) == ["c2"]

      # c20 alone: c2 was never evaluated, so there is nothing to hand over
      plan = Core.plan_recalc(book, "pass1", call_ids: ["c20"])
      assert plan.entries == []
      assert [%{call_id: "c20", outcome: {:skipped, "c2"}}] = plan.skipped
    end

    test "a reference into an unsupported cycle is skipped",
         %{book: book} do
      book =
        book
        |> Core.add_call("c8", %{node: "n1", args: ["⟦c9⟧"], result: "#PID<0.3.0>", repr: "unsupported"})
        |> Core.add_call("c9", %{node: "n2", args: ["⟦c8⟧"], result: "#PID<0.4.0>", repr: "unsupported"})
        |> Core.add_call("c10", %{node: "n2", args: ["⟦c8⟧"]})

      # c8 <-> c9 form a static ⟦id⟧ cycle, so they're never scheduled;
      # c8's unsupported value can't be handed over, so c10 is skipped.
      plan = Core.plan_recalc(book, "pass1", call_ids: ["c10"])
      assert plan.entries == []
      assert [%{call_id: "c10", outcome: {:skipped, "c8"}}] = plan.skipped
    end

    test "an unknown/dangling reference is unresolvable, so the dependent call is skipped", %{book: book} do
      book = Core.add_call(book, "c7", %{node: "n2", args: ["⟦missing⟧"]})

      plan = Core.plan_recalc(book, "pass1", call_ids: ["c7"])
      assert plan.entries == []
      assert [%{call_id: "c7", outcome: {:skipped, "missing"}}] = plan.skipped
    end

    test "a call in a cycle is excluded from the plan and reported separately" do
      book =
        Book.new()
        |> Core.put_node("n1", pure_node("f"))
        |> Core.add_call("c1", %{node: "n1", args: ["⟦c2⟧"]})
        |> Core.add_call("c2", %{node: "n1", args: ["⟦c1⟧"]})

      plan = Core.plan_recalc(book, "pass1", call_ids: ["c1", "c2"])
      assert plan.entries == []
      assert plan.cyclic_ids == MapSet.new(["c1", "c2"])
    end

    test "an unresolvable reference cascades: a call depending on a skipped call is skipped too (Old.md §18's session_hung scenario)" do
      # Mirrors the real base->mid->top chain from §18/§19: c_base's node
      # was never classified (no effect_source: "user", as if the row had
      # been poked into Store directly), so filter_by_effect/3 drops
      # c_base from scheduling entirely. c_mid references c_base -- an
      # unresolvable :binding -- and is skipped. c_top references c_mid,
      # which *was* a same-pass (:in_plan) reference right up until c_mid
      # itself got skipped; the fixed-point loop in drop_unresolvable/2
      # must re-check c_top against the shrunk set and skip it too,
      # instead of leaving it scheduled with a now-dangling :in_plan input
      # that would never actually get bound (the same doomed-compile-error
      # shape as a plain :binding).
      book =
        Book.new()
        |> Core.put_node("n1", %{module: "M", name: "base", anykey: 0, effect: "unknown", effect_source: nil})
        |> Core.put_node("n2", pure_node("mid"))
        |> Core.put_node("n3", pure_node("top"))
        |> Core.add_call("c_base", %{node: "n1", args: []})
        |> Core.add_call("c_mid", %{node: "n2", args: ["⟦c_base⟧"]})
        |> Core.add_call("c_top", %{node: "n3", args: ["⟦c_mid⟧"]})

      plan = Core.plan_recalc(book, "pass1", call_ids: ["c_base", "c_mid", "c_top"])

      assert plan.entries == []
      assert [%{call_id: "c_mid", outcome: {:skipped, "c_base"}}, %{call_id: "c_top", outcome: {:skipped, "c_mid"}}] =
               plan.skipped
    end
  end

  describe "plan_recalc/3 -- basis (compare's spec §6.4 B)" do
    test "no prior result at all -> :none" do
      book = Book.new() |> Core.put_node("n1", pure_node("f")) |> Core.add_call("c1", %{node: "n1", args: ["1"]})
      assert [%{basis: :none}] = Core.plan_recalc(book, "pass1", call_ids: ["c1"]).entries
    end

    test "auto (prev_source unset): basis is the value currently on record (R_old), not the prev column" do
      book =
        Book.new()
        |> Core.put_node("n1", pure_node("f"))
        |> Core.add_call("c1", %{node: "n1", args: ["1"], result: "5", repr: "exact", prev: "1", prev_source: "auto"})

      # prev ("1") is one generation further back than result ("5") --
      # basis must be R_old (result), matching spec §6.4's B = R_old rule,
      # not the stale prev column (a real bug found and fixed 2026-09-18)
      assert [%{basis: {:exact, "5"}}] = Core.plan_recalc(book, "pass1", call_ids: ["c1"]).entries
    end

    test "auto, repr binary: basis reconstructs from the bin column" do
      book =
        Book.new()
        |> Core.put_node("n1", pure_node("f"))
        |> Core.add_call("c1", %{node: "n1", args: ["1"], result: "#PID<0.1.0>", repr: "binary", bin: "g3cFaGVsbG8="})

      assert [%{basis: {:binary, "g3cFaGVsbG8="}}] = Core.plan_recalc(book, "pass1", call_ids: ["c1"]).entries
    end

    test "auto, repr unsupported: no reconstructible text -> :none (compare degrades to skipped)" do
      book =
        Book.new()
        |> Core.put_node("n1", pure_node("f"))
        |> Core.add_call("c1", %{node: "n1", args: ["1"], result: "#PID<0.1.0>", repr: "unsupported"})

      assert [%{basis: :none}] = Core.plan_recalc(book, "pass1", call_ids: ["c1"]).entries
    end

    test "prev_source == \"user\": basis is the user-set prev column (P), overriding R_old (spec §6.4's B = P rule)" do
      book =
        Book.new()
        |> Core.put_node("n1", pure_node("f"))
        |> Core.add_call("c1", %{
          node: "n1",
          args: ["1"],
          result: "5",
          repr: "exact",
          prev: "10",
          prev_source: "user"
        })

      assert [%{basis: {:exact, "10"}}] = Core.plan_recalc(book, "pass1", call_ids: ["c1"]).entries
    end

    test "set_prev/3 sets prev_source to \"user\" and plan_recalc picks it up as basis" do
      book =
        Book.new()
        |> Core.put_node("n1", pure_node("f"))
        |> Core.add_call("c1", %{node: "n1", args: ["1"], result: "5", repr: "exact"})
        |> Core.set_prev("c1", "42")

      assert [%{basis: {:exact, "42"}}] = Core.plan_recalc(book, "pass1", call_ids: ["c1"]).entries
    end
  end

  describe "set_result/3 (Old.md §16.4/§19, the dependency-chain negotiation's 'insert a value' step)" do
    setup do
      book =
        Book.new()
        |> Core.put_node("n1", pure_node("f"))
        |> Core.add_call("c1", %{node: "n1", args: ["1"], result: "old", repr: "unsupported", state: "eval_error", error: "boom"})

      {:ok, book: book}
    end

    test "writes result/repr, marks result_source \"user\", clears error", %{book: book} do
      row = Core.set_result(book, "c1", "42") |> Book.get(:calls, "c1")
      assert row.result == "42"
      assert row.repr == "exact"
      assert row.result_source == "user"
      assert row.state == "ok"
      assert row.error == nil
    end

    test "a downstream reference embeds the stubbed value as a literal, same as a real eval would", %{book: book} do
      book =
        book
        |> Core.set_result("c1", "42")
        |> Core.add_call("c2", %{node: "n1", args: ["⟦c1⟧ + 1"]})

      assert [%{args: ["42 + 1"]}] = Core.plan_recalc(book, "pass1", call_ids: ["c2"]).entries
    end

    test "an unknown call id raises, same boundary as set_prev/set_effect", %{book: book} do
      assert_raise RuntimeError, fn -> Core.set_result(book, "nonexistent", "1") end
    end
  end

  describe "call_label/2" do
    test "formats Module.name/arity from the call's node" do
      book =
        Book.new()
        |> Core.put_node("n1", pure_node("f"))
        |> Core.add_call("c1", %{node: "n1", args: []})

      assert Core.call_label(book, "c1") == "M.f/1"
    end

    test "leaves the /anykey suffix off a node without one" do
      assert Core.node_label(%{module: "Hs.Main", name: "go", anykey: nil}) == "Hs.Main.go"
      assert Core.node_label(%{module: "M", name: "f", anykey: 2}) == "M.f/2"
    end

    test "nil for an unknown call id" do
      assert Core.call_label(Book.new(), "nonexistent") == nil
    end

    test "nil for a call whose node no longer exists" do
      book = Book.new() |> Core.add_call("c1", %{node: "gone", args: []})
      assert Core.call_label(book, "c1") == nil
    end
  end

  describe "apply_results/3" do
    setup do
      book = Book.new() |> Core.add_call("c1", %{node: "n1", args: ["1"]})
      ctx = %{commit: "abc123", commit_at: "2026-09-16T00:00:00Z", dirty: false}
      {:ok, book: book, ctx: ctx}
    end

    test "an :ok outcome records the result, rolls prev forward, and bumps eval_count", %{book: book, ctx: ctx} do
      result = %{
        call_id: "c1",
        outcome: {:ok, %{repr: "exact", display: "2", type: "integer", bin: nil}},
        compare: "none",
        evaluated_at: "2026-09-16T00:00:01Z",
        session_gen: 1
      }

      book2 = Core.apply_results(book, ctx, [result])
      row = Book.get(book2, :calls, "c1")
      assert row.result == "2"
      assert row.prev == nil
      assert row.eval_count == 1
      assert row.state == "ok"
      assert row.commit == "abc123"

      result2 = %{result | outcome: {:ok, %{repr: "exact", display: "3", type: "integer", bin: nil}}, compare: "changed"}
      book3 = Core.apply_results(book2, ctx, [result2])
      row3 = Book.get(book3, :calls, "c1")
      assert row3.result == "3"
      assert row3.prev == "2"
      assert row3.eval_count == 2
      assert row3.compare == "changed"
    end

    test ":skipped/:aborted are not written to the book (nothing was evaluated)", %{book: book, ctx: ctx} do
      for outcome <- [{:skipped, "up1"}, :aborted] do
        result = %{call_id: "c1", outcome: outcome, compare: "skipped", evaluated_at: nil, session_gen: 1}
        assert Core.apply_results(book, ctx, [result]) == book
      end
    end

    test ":error/:timeout/:max_heap bump eval_count and set state eval_error", %{book: book, ctx: ctx} do
      for outcome <- [{:error, :boom}, :timeout, :max_heap] do
        result = %{call_id: "c1", outcome: outcome, compare: "skipped", evaluated_at: nil, session_gen: 1}
        row = Core.apply_results(book, ctx, [result]) |> Book.get(:calls, "c1")
        assert row.eval_count == 1
        assert row.state == "eval_error"
      end
    end

    test "an :error reason that is already text is stored as-is, anything else inspected", %{book: book, ctx: ctx} do
      for {reason, stored} <- [{"{:badarith, []}", "{:badarith, []}"}, {"session_hung", "session_hung"}, {:boom, ":boom"}] do
        result = %{call_id: "c1", outcome: {:error, reason}, compare: "skipped", evaluated_at: nil, session_gen: 1}
        row = Core.apply_results(book, ctx, [result]) |> Book.get(:calls, "c1")
        assert row.error == stored
      end
    end
  end
end
