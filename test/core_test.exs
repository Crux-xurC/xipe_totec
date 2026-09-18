ExUnit.start()

Code.require_file(Path.expand("../lib/book.exs", __DIR__))
Code.require_file(Path.expand("../lib/core.exs", __DIR__))

defmodule CoreTest do
  use ExUnit.Case, async: true

  alias XipeTotec.{Book, Core}

  defp pure_node(name), do: %{module: "M", name: name, arity: 1, effect: "pure", effect_source: "user"}

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

  describe "dep_hash_affected_nodes/2 (fix B: dep_hash, not body_hash, propagation)" do
    test "a node that calls a changed node is included even though its own body is untouched" do
      book =
        Book.new()
        |> Book.put(:links, "l1", %{node: "n1", role: "to", ref: "n2", clause: nil, guard: nil})

      assert Core.dep_hash_affected_nodes(book, ["n2"]) == MapSet.new(["n1", "n2"])
    end

    test "propagates transitively (n1 -> n2 -> n3, n3 changed)" do
      book =
        Book.new()
        |> Book.put(:links, "l1", %{node: "n1", role: "to", ref: "n2"})
        |> Book.put(:links, "l2", %{node: "n2", role: "to", ref: "n3"})

      assert Core.dep_hash_affected_nodes(book, ["n3"]) == MapSet.new(["n1", "n2", "n3"])
    end

    test "an unrelated node is not included" do
      book = Book.new() |> Book.put(:links, "l1", %{node: "n1", role: "to", ref: "n2"})
      assert Core.dep_hash_affected_nodes(book, ["n9"]) == MapSet.new(["n9"])
    end
  end

  describe "affected_set/3" do
    test "includes explicit targets plus their downstream (via ⟦id⟧), not their upstream" do
      book =
        Book.new()
        |> Core.add_call("c1", %{node: "n1", args: ["1"]})
        |> Core.add_call("c2", %{node: "n2", args: ["⟦c1⟧ + 1"]})

      assert Core.affected_set(book, ["c1"], []) == MapSet.new(["c1", "c2"])
      assert Core.affected_set(book, ["c2"], []) == MapSet.new(["c2"])
    end

    test "a call using a dep_hash-affected node is pulled in even without being an explicit target" do
      # n0 calls n1; n1 changed -- n0's dep_hash goes stale too (fix B), and
      # c1 (which uses n0, not n1) must be scheduled even though c1 never
      # references n1 directly.
      book =
        Book.new()
        |> Core.add_call("c1", %{node: "n0", args: []})
        |> Book.put(:links, "l1", %{node: "n0", role: "to", ref: "n1"})

      assert Core.affected_set(book, [], ["n1"]) == MapSet.new(["c1"])
    end
  end

  describe "filter_by_effect/3 (fix D: unknown excluded by default; effect_source must be \"user\")" do
    setup do
      book =
        Book.new()
        |> Core.put_node("n_pure", pure_node("f"))
        |> Core.put_node("n_writes", %{module: "M", name: "g", arity: 1, effect: "writes", effect_source: "user"})
        |> Core.put_node("n_unset", %{module: "M", name: "h", arity: 1, effect: "unknown", effect_source: nil})
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

      assert [%{call_id: "c2", module: "M", name: "g", arity: 1, args: ["1 + 1"], inputs: []}] =
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

    test "a plan-external unsupported+pure reference is re-embedded as an inline_call, recursively resolving its own args",
         %{book: book} do
      book =
        book
        |> Core.add_call("c3", %{node: "n1", args: ["99"], result: "#PID<0.1.0>", repr: "unsupported"})
        |> Core.add_call("c4", %{node: "n2", args: ["⟦c3⟧"]})

      plan = Core.plan_recalc(book, "pass1", call_ids: ["c4"])
      assert [%{call_id: "c4", args: [arg], inputs: inputs}] = plan.entries

      assert [{:inline_call, %{module: "M", name: "f", args: ["99"], placeholder: placeholder}}] = inputs
      assert arg == placeholder
    end

    test "a plan-external unsupported+non-pure reference falls back to a session binding", %{book: book} do
      book =
        book
        |> Core.put_node("n3", %{module: "M", name: "h", arity: 0, effect: "writes", effect_source: "user"})
        |> Core.add_call("c5", %{node: "n3", args: [], result: "#PID<0.2.0>", repr: "unsupported", session: 3})
        |> Core.add_call("c6", %{node: "n2", args: ["⟦c5⟧"]})

      plan = Core.plan_recalc(book, "pass1", call_ids: ["c6"])
      assert [%{call_id: "c6", args: [arg], inputs: inputs}] = plan.entries

      assert [{:binding, %{var: var, gen: 3, placeholder: placeholder}}] = inputs
      assert placeholder == Atom.to_string(var)
      assert arg == placeholder
    end

    test "an inline_call cycle (a reaches back into itself through unsupported+pure refs) terminates via an occurs-check, falling back to a binding for the repeat",
         %{book: book} do
      book =
        book
        |> Core.add_call("c8", %{node: "n1", args: ["⟦c9⟧"], result: "#PID<0.3.0>", repr: "unsupported"})
        |> Core.add_call("c9", %{node: "n2", args: ["⟦c8⟧"], result: "#PID<0.4.0>", repr: "unsupported"})
        |> Core.add_call("c10", %{node: "n2", args: ["⟦c8⟧"]})

      # c8 <-> c9 form a static ⟦id⟧ cycle, so they're excluded from
      # scheduling -- but c10 (not itself cyclic) still reaches into them
      # via inline_call, which must not loop forever expanding c8 -> c9 -> c8.
      plan = Core.plan_recalc(book, "pass1", call_ids: ["c10"])
      assert [%{call_id: "c10", inputs: inputs}] = plan.entries

      assert [{:inline_call, c8_call}, {:inline_call, c9_call}, {:binding, _}] = inputs
      assert c8_call.module == "M" and c8_call.name == "f"
      assert c9_call.module == "M" and c9_call.name == "g"
    end

    test "an unknown/dangling reference falls back to a session binding with no gen", %{book: book} do
      book = Core.add_call(book, "c7", %{node: "n2", args: ["⟦missing⟧"]})

      plan = Core.plan_recalc(book, "pass1", call_ids: ["c7"])
      assert [%{call_id: "c7", args: [arg], inputs: inputs}] = plan.entries

      assert [{:binding, %{var: var, gen: nil, placeholder: placeholder}}] = inputs
      assert placeholder == Atom.to_string(var)
      assert arg == placeholder
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

    test ":skipped/:lost/:aborted do not bump eval_count", %{book: book, ctx: ctx} do
      for outcome <- [{:skipped, "up1"}, {:lost, "up1"}, :aborted] do
        result = %{call_id: "c1", outcome: outcome, compare: "skipped", evaluated_at: nil, session_gen: 1}
        row = Core.apply_results(book, ctx, [result]) |> Book.get(:calls, "c1")
        assert row.eval_count == 0
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
  end
end
