ExUnit.start()

Code.require_file(Path.expand("../lib/id.exs", __DIR__))
Code.require_file(Path.expand("../lib/book.exs", __DIR__))
Code.require_file(Path.expand("../lib/core.exs", __DIR__))
Code.require_file(Path.expand("../lib/repl/eval_template.exs", __DIR__))

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

  describe "build/1" do
    test "produces syntactically valid Elixir for a plain call, and binds xt_<call_id> at the top level" do
      book = Book.new() |> Core.put_node("n1", pure_node("f")) |> Core.add_call("c1", %{node: "n1", args: ["1", "2"]})
      entry = entry_for(book, "c1", ["c1"])

      code = EvalTemplate.build(entry)
      assert {:ok, _quoted} = Code.string_to_quoted(code)
      assert code =~ "M.f(1, 2)"
      assert code =~ "xt_c1 ="
      assert code =~ "XT_BEGIN_c1"
      assert code =~ "XT_END_c1"
      assert code =~ "XT_ERROR_c1"
      assert code =~ "max_heap_size, 50000000"
      assert code =~ "type="
      assert code =~ "compare="
      # width: :infinity on every inspect/2+ call whose text can end up in a
      # marker line (display= AND the crash reason) -- otherwise Elixir's
      # default 80-col pretty-printing can wrap a large value/reason across
      # multiple lines and break the line-based marker parser
      assert Regex.scan(~r/inspect\([^)]*width: :infinity/, code) |> length() == 4
      # every receive branch that can end the wait demonitors -- fixed
      # 2026-09-18: the timeout (`after`) branch used to skip this,
      # leaking an unflushed :DOWN message into the session's mailbox
      # every time an eval timed out.
      assert Regex.scan(~r/Process\.demonitor/, code) |> length() == 3
    end

    test "no basis (first evaluation) skips the reconstruction machinery and reports compare=none" do
      book = Book.new() |> Core.put_node("n1", pure_node("f")) |> Core.add_call("c1", %{node: "n1", args: ["1"]})
      entry = entry_for(book, "c1", ["c1"])
      assert entry.basis == :none

      code = EvalTemplate.build(entry)
      assert {:ok, _quoted} = Code.string_to_quoted(code)
      assert code =~ ~s(xt_compare = "none")
      refute code =~ "xt_eq ="
    end

    test "an :exact basis reconstructs the previous value via Code.eval_string for comparison" do
      book =
        Book.new()
        |> Core.put_node("n1", pure_node("f"))
        |> Core.add_call("c1", %{node: "n1", args: ["1"], result: "5", repr: "exact"})

      entry = entry_for(book, "c1", ["c1"])
      assert entry.basis == {:exact, "5"}

      code = EvalTemplate.build(entry)
      assert {:ok, _quoted} = Code.string_to_quoted(code)
      assert code =~ "Code.eval_string(\"5\")"
      assert code =~ "xt_eq ="
    end

    test "a :binary basis reconstructs the previous value via Base.decode64!/binary_to_term for comparison" do
      b64 = Base.encode64(:erlang.term_to_binary(self()))

      book =
        Book.new()
        |> Core.put_node("n1", pure_node("f"))
        |> Core.add_call("c1", %{node: "n1", args: ["1"], result: "#PID<0.1.0>", repr: "binary", bin: b64})

      entry = entry_for(book, "c1", ["c1"])
      assert entry.basis == {:binary, b64}

      code = EvalTemplate.build(entry)
      assert {:ok, _quoted} = Code.string_to_quoted(code)
      assert code =~ "Base.decode64!()"
      assert code =~ ":erlang.binary_to_term()"
    end

    test "a call_id with characters unsafe in a bare variable name is sanitized for the internal helper names" do
      book = Book.new() |> Core.put_node("n1", pure_node("f")) |> Core.add_call("c-1.x", %{node: "n1", args: ["1"]})
      entry = entry_for(book, "c-1.x", ["c-1.x"])

      code = EvalTemplate.build(entry)
      assert {:ok, _quoted} = Code.string_to_quoted(code)
      # the marker text itself keeps the raw call_id (just a string, no identifier constraint)
      assert code =~ "XT_BEGIN_c-1.x"
    end
  end
end
