ExUnit.start()

Code.require_file(Path.expand("../lib/id.exs", __DIR__))
Code.require_file(Path.expand("../lib/book.exs", __DIR__))
Code.require_file(Path.expand("../lib/core.exs", __DIR__))
Code.require_file(Path.expand("../lib/repl/eval_template.exs", __DIR__))

# a project's own struct that hides a field from inspect: its display can't
# be read back, so it is repr=binary
defmodule ReplEvalTemplateTest.Hidden do
  @derive {Inspect, only: [:a]}
  defstruct a: 1, b: 2
end

defmodule ReplEvalTemplateTest do
  use ExUnit.Case, async: true

  alias XipeTotec.{Book, Core}
  alias XipeTotec.Repl.EvalTemplate

  defp pure_node(name), do: %{module: "M", name: name, anykey: 1, effect: "pure", effect_source: "user"}

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

  test "a :binding placeholder is left as the bare variable name" do
    # Hand-built rather than derived via entry_for/3: Core.plan_recalc/3 no
    # longer schedules an entry whose inputs contain an unresolved
    # `:binding` (`drop_unresolvable/2` skips the call instead
    # -- see core_test.exs's "...is unresolvable, so the dependent call is
    # skipped" tests). This test now exercises EvalTemplate.call_expression/1's
    # own handling of a `:binding` input directly, the shape
    # `Core.resolve_ref/4` still produces.
    entry = %{
      module: "M",
      name: "f",
      args: ["xt_c5"],
      inputs: [{:binding, %{placeholder: "xt_c5", var: :xt_c5, ref: "c5"}}]
    }

    assert EvalTemplate.call_expression(entry) == "M.f(xt_c5)"
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
      # the timeout (`after`) branch used to skip this,
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

    # Runs the built text in this process the way the session would, with
    # `session` as the session's existing bindings.
    defp run_built(entry, session \\ []) do
      ExUnit.CaptureIO.capture_io(fn -> Code.eval_string(EvalTemplate.build(entry), session) end)
    end

    defp raw_entry(args),
      do: %{call_id: "c1", module: "Kernel", name: "abs", args: args, inputs: [], limits: %{timeout: 2_000, max_heap_words: 50_000_000}}

    test "a compile-time error in the arguments comes back as a crash marker instead of failing the whole statement" do
      # both of these parse, so only compiling them can tell -- before the
      # fix the session rejected the whole statement and the entry waited
      # out the deadline as session_hung
      assert run_built(raw_entry(["undefined_fn(1)"])) =~
               ~s(XT_ERROR_c1 crash {:compile_error, "undefined function undefined_fn/1)

      assert run_built(raw_entry(["x"])) =~ ~s(XT_ERROR_c1 crash {:compile_error, "undefined variable \\"x\\")
    end

    # Function.identity(<expr>): the value under test comes back as the result
    defp value_entry(expr, basis \\ :none),
      do: %{call_id: "c1", module: "Function", name: "identity", args: [expr], inputs: [], basis: basis, limits: %{timeout: 2_000, max_heap_words: 50_000_000}}

    # Enum on a struct raised (Date, URI, the project's own) or walked its
    # elements (MapSet, Range) in the session process: no marker, so the
    # entry read as session_hung and the rest of the pass as aborted
    test "a struct, or a value holding one, is classified and printed like any other value" do
      for {expr, repr} <- [
            {"~D[2026-10-06]", "exact"},
            {~s{URI.parse("http://a")}, "exact"},
            {"MapSet.new([1])", "exact"},
            {"1..3", "exact"},
            {"{:ok, ~D[2026-10-06]}", "exact"},
            {"%{when: ~D[2026-10-06]}", "exact"},
            {"%ReplEvalTemplateTest.Hidden{}", "binary"}
          ] do
        out = run_built(value_entry(expr))
        assert out =~ "XT_BEGIN_c1\nrepr=#{repr}\n", "#{expr}: #{out}"
        assert out =~ "XT_END_c1", expr
      end

      # a pid inside a struct-holding map is still found
      assert run_built(value_entry("%{d: ~D[2026-10-06], p: self()}")) =~ "repr=unsupported"
    end

    test "compare works on structs (the previous value is a struct too)" do
      assert run_built(value_entry("~D[2026-10-06]", {:exact, "~D[2026-10-06]"})) =~ "compare=same"
      assert run_built(value_entry("~D[2026-10-07]", {:exact, "~D[2026-10-06]"})) =~ "compare=changed"
      assert run_built(value_entry("MapSet.new([1])", {:exact, "MapSet.new([1])"})) =~ "compare=same"

      bin = Base.encode64(:erlang.term_to_binary(%ReplEvalTemplateTest.Hidden{b: 5}))
      assert run_built(value_entry("%ReplEvalTemplateTest.Hidden{b: 5}", {:binary, bin})) =~ "compare=same"
      assert run_built(value_entry("%ReplEvalTemplateTest.Hidden{b: 6}", {:binary, bin})) =~ "compare=changed"
    end

    test "reference variables are taken from the session's bindings" do
      out = run_built(raw_entry(["xt_up"]), xt_up: -5, xt_other: 1)
      assert out =~ "XT_BEGIN_c1\nrepr=exact\ntype=integer\ncompare=none\ndisplay=5\nXT_END_c1"
    end
  end
end
