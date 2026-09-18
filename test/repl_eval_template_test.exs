ExUnit.start()

Code.require_file(Path.expand("../lib/id.exs", __DIR__))
Code.require_file(Path.expand("../lib/book.exs", __DIR__))
Code.require_file(Path.expand("../lib/core.exs", __DIR__))
Code.require_file(Path.expand("../lib/repl_eval_template.exs", __DIR__))

defmodule ReplEvalTemplateTest do
  use ExUnit.Case, async: true

  alias XipeTotec.{Book, Core}
  alias XipeTotec.Repl.EvalTemplate

  defp pure_node(name), do: %{module: "M", name: name, arity: 1, effect: "pure", effect_source: "user"}

  defp entry_for(book, id, targets) do
    plan = Core.plan_recalc(book, "pass1", call_ids: targets)
    Enum.find(plan.entries, &(&1.call_id == id))
  end

  test "a call with no references assembles plainly" do
    book = Book.new() |> Core.put_node("n1", pure_node("f")) |> Core.add_call("c1", %{node: "n1", args: ["1", "2"]})
    entry = entry_for(book, "c1", ["c1"])

    assert EvalTemplate.call_expression(entry) == "M.f(1, 2)"
  end

  test "a plan-external exact-repr reference is already embedded by Core -- no further work needed" do
    book =
      Book.new()
      |> Core.put_node("n1", pure_node("f"))
      |> Core.put_node("n2", pure_node("g"))
      |> Core.add_call("c1", %{node: "n1", args: ["1"], result: "1", repr: "exact"})
      |> Core.add_call("c2", %{node: "n2", args: ["⟦c1⟧ + 1"]})

    entry = entry_for(book, "c2", ["c2"])
    assert EvalTemplate.call_expression(entry) == "M.g(1 + 1)"
  end

  test "a plan-internal (:in_plan) reference resolves to the bound variable name" do
    book =
      Book.new()
      |> Core.put_node("n1", pure_node("f"))
      |> Core.put_node("n2", pure_node("g"))
      |> Core.add_call("c1", %{node: "n1", args: ["1"]})
      |> Core.add_call("c2", %{node: "n2", args: ["⟦c1⟧ + 1"]})

    entry = entry_for(book, "c2", ["c1", "c2"])
    [{:in_plan, %{var: var}}] = entry.inputs
    assert EvalTemplate.call_expression(entry) == "M.g(#{var} + 1)"
  end

  test "an unsupported+non-pure reference (:binding) resolves to the bound variable name" do
    book =
      Book.new()
      |> Core.put_node("n1", pure_node("f"))
      |> Core.put_node("n3", %{module: "M", name: "h", arity: 0, effect: "writes", effect_source: "user"})
      |> Core.add_call("c5", %{node: "n3", args: [], result: "#PID<0.1.0>", repr: "unsupported", session: 3})
      |> Core.add_call("c6", %{node: "n1", args: ["⟦c5⟧"]})

    entry = entry_for(book, "c6", ["c6"])
    [{:binding, %{var: var}}] = entry.inputs
    assert EvalTemplate.call_expression(entry) == "M.f(#{var})"
  end

  test "an unsupported+pure reference (:inline_call) is re-embedded as the nested call expression" do
    book =
      Book.new()
      |> Core.put_node("n1", pure_node("f"))
      |> Core.put_node("n2", pure_node("g"))
      |> Core.add_call("c3", %{node: "n1", args: ["99"], result: "#PID<0.1.0>", repr: "unsupported"})
      |> Core.add_call("c4", %{node: "n2", args: ["⟦c3⟧"]})

    entry = entry_for(book, "c4", ["c4"])
    assert EvalTemplate.call_expression(entry) == "M.g(M.f(99))"
  end

  test "an inline_call cycle expands to a nested call but stops at the occurs-check binding, matching Core's own recursion" do
    book =
      Book.new()
      |> Core.put_node("n1", pure_node("f"))
      |> Core.put_node("n2", pure_node("g"))
      |> Core.add_call("c8", %{node: "n1", args: ["⟦c9⟧"], result: "#PID<0.3.0>", repr: "unsupported"})
      |> Core.add_call("c9", %{node: "n2", args: ["⟦c8⟧"], result: "#PID<0.4.0>", repr: "unsupported"})
      |> Core.add_call("c10", %{node: "n2", args: ["⟦c8⟧"]})

    entry = entry_for(book, "c10", ["c10"])
    [{:binding, %{var: var}}] = for {:binding, _} = i <- entry.inputs, do: i

    assert EvalTemplate.call_expression(entry) == "M.g(M.f(M.g(#{var})))"
  end
end
