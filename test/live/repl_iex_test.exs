ExUnit.start()

Code.require_file(Path.expand("../../lib/id.exs", __DIR__))
Code.require_file(Path.expand("../../lib/book.exs", __DIR__))
Code.require_file(Path.expand("../../lib/core.exs", __DIR__))
Code.require_file(Path.expand("../../lib/repl/eval_template.exs", __DIR__))
Code.require_file(Path.expand("../../lib/repl/launch.exs", __DIR__))
Code.require_file(Path.expand("../../lib/repl/sender_direct.exs", __DIR__))
Code.require_file(Path.expand("../../lib/repl/session.exs", __DIR__))
Code.require_file(Path.expand("../../lib/repl/eval/parser.exs", __DIR__))
Code.require_file(Path.expand("../../lib/repl/eval/scan/direct/iex.exs", __DIR__))
Code.require_file(Path.expand("../../lib/repl/eval/field_drip/elixir.exs", __DIR__))

# Live verification against a real `iex`, not a stand-in `sh`/`cat`/`sleep`
# (unlike the rest of the Repl.* test suite, per Old.md §28 G's split of pure/
# fast-testable logic from live-process checks). NOT swept into test/run.sh
# (its glob is `test/*_test.exs`, non-recursive -- this lives one directory
# deeper on purpose). Run directly: `elixir test/live/repl_iex_test.exs`.
#
# Target is test/fixtures/calc_sample/calc.exs -- a small, dependency-free
# Elixir module (no mix, no external libs) kept around specifically so it
# can be reused later for scan/card verification too, not just here.
defmodule ReplLiveIexTest do
  use ExUnit.Case

  alias XipeTotec.{Book, Core}
  alias XipeTotec.Repl.{EvalTemplate, Launch, Session}
  alias XipeTotec.Repl.Sender.Direct
  alias XipeTotec.Repl.Eval.Parser
  alias XipeTotec.Repl.Eval.Scan.Direct.Iex, as: ScanDirectIex
  alias XipeTotec.Repl.Eval.FieldDrip.Elixir, as: FieldDripElixir

  @fixture_dir Path.expand("../fixtures/calc_sample", __DIR__)

  setup do
    message = Launch.build(cwd: @fixture_dir, argv: ["iex"], files: ["calc.exs"])
    {:ok, handle} = Direct.send(message)
    assert :ok = Session.await_ready(handle, message["ready_pattern"], 15_000)
    on_exit(fn -> if Process.alive?(handle), do: Direct.kill(handle) end)
    {:ok, handle: handle, message: message}
  end

  defp pure_node(module, name, arity), do: %{module: module, name: name, arity: arity, effect: "pure", effect_source: "user"}

  defp entry_for(book, id, targets) do
    plan = Core.plan_recalc(book, "pass1", call_ids: targets)
    Enum.find(plan.entries, &(&1.call_id == id))
  end

  defp collect_until(handle, needle, timeout), do: collect_until(handle, needle, "", timeout)

  defp collect_until(handle, needle, buffer, timeout) do
    receive do
      {^handle, {:data, chunk}} ->
        buffer = buffer <> chunk
        if String.contains?(buffer, needle), do: buffer, else: collect_until(handle, needle, buffer, timeout)
    after
      timeout -> flunk("never saw #{inspect(needle)}, buffer so far: #{inspect(buffer)}")
    end
  end

  test "boot -> a manual marker round-trip -> graceful close", %{handle: handle, message: message} do
    code = "IO.puts(\"XT_LIVE_CHECK_\" <> to_string(Calc.add(2, 3)))\n"
    assert :ok = Direct.write(handle, code)

    output = collect_until(handle, "XT_LIVE_CHECK_5", 5_000)
    assert output =~ "XT_LIVE_CHECK_5"

    assert :ok = Session.close(Direct, handle, message["exit_input"], 5_000)
  end

  test "a plain successful eval reports repr=exact with the right value", %{handle: handle} do
    book = Book.new() |> Core.put_node("n1", pure_node("Calc", "add", 2)) |> Core.add_call("c1", %{node: "n1", args: ["2", "3"]})
    entry = entry_for(book, "c1", ["c1"])

    Direct.write(handle, EvalTemplate.build(entry))
    out = collect_until(handle, "XT_END_c1", 5_000)

    assert out =~ "XT_BEGIN_c1\nrepr=exact\ntype=integer\ncompare=none\ndisplay=5\nXT_END_c1"
  end

  test "a value wide enough to trigger Elixir's default pretty-printing still comes back on one display= line", %{
    handle: handle
  } do
    book =
      Book.new()
      |> Core.put_node("n1", pure_node("Calc", "wide_list", 0))
      |> Core.add_call("c1", %{node: "n1", args: []})

    entry = entry_for(book, "c1", ["c1"])

    Direct.write(handle, EvalTemplate.build(entry))
    out = collect_until(handle, "XT_END_c1", 5_000)

    # if width: :infinity weren't applied, this list (well over 80 columns
    # as a plain inspect) would wrap across multiple lines and the marker
    # region would no longer be exactly "XT_BEGIN..type..display..XT_END"
    assert [_, body] = String.split(out, "XT_BEGIN_c1\n", parts: 2)
    assert [body, _] = String.split(body, "\nXT_END_c1", parts: 2)
    lines = String.split(body, "\n")
    assert length(lines) == 4
    assert Enum.at(lines, 0) == "repr=exact"
    assert Enum.at(lines, 1) == "type=list"
    assert Enum.at(lines, 2) == "compare=none"
    assert Enum.at(lines, 3) =~ ~r/^display=\[1, 2, 3.*100\]$/
  end

  test "an :in_plan reference to an earlier call in the same pass uses the real bound value, not a wrapped status", %{
    handle: handle
  } do
    book =
      Book.new()
      |> Core.put_node("n1", pure_node("Calc", "add", 2))
      |> Core.put_node("n2", pure_node("Calc", "square", 1))
      |> Core.add_call("c1", %{node: "n1", args: ["2", "3"]})
      |> Core.add_call("c2", %{node: "n2", args: ["⟦c1⟧"]})

    plan = Core.plan_recalc(book, "pass1", call_ids: ["c1", "c2"])
    [e1, e2] = plan.entries
    assert [{:in_plan, _}] = e2.inputs

    Direct.write(handle, EvalTemplate.build(e1))
    collect_until(handle, "XT_END_c1", 5_000)

    Direct.write(handle, EvalTemplate.build(e2))
    out = collect_until(handle, "XT_END_c2", 5_000)

    # square(5) == 25 -- if xt_c1 had been left as the wrapped {:xt_ok, 5}
    # status, this would crash instead (the bug caught and fixed 2026-09-18)
    assert out =~ "XT_BEGIN_c2\nrepr=exact\ntype=integer\ncompare=none\ndisplay=25\nXT_END_c2"
  end

  test "an unsupported value (a pid) is classified as such and still printed", %{handle: handle} do
    book = Book.new() |> Core.put_node("n1", pure_node("Kernel", "self", 0)) |> Core.add_call("c1", %{node: "n1", args: []})
    entry = entry_for(book, "c1", ["c1"])

    Direct.write(handle, EvalTemplate.build(entry))
    out = collect_until(handle, "XT_END_c1", 5_000)

    assert out =~ "XT_BEGIN_c1\nrepr=unsupported\ntype=pid\ncompare=none\ndisplay=#PID<"
  end

  test "a raised exception is reported as XT_ERROR without crashing the session", %{handle: handle} do
    book = Book.new() |> Core.put_node("n1", pure_node("Calc", "sub", 2)) |> Core.add_call("c1", %{node: "n1", args: ["1", "\"x\""]})
    entry = entry_for(book, "c1", ["c1"])

    Direct.write(handle, EvalTemplate.build(entry))
    out = collect_until(handle, "XT_ERROR_c1", 5_000)
    assert out =~ "XT_ERROR_c1 crash"

    # session must still be alive/responsive after a crash in the spawned eval process
    Direct.write(handle, "IO.puts(\"XT_LIVE_CHECK_still_alive\")\n")
    assert collect_until(handle, "XT_LIVE_CHECK_still_alive", 5_000) =~ "XT_LIVE_CHECK_still_alive"
  end

  test "an unclosed arg expression is caught before ever touching the session -- no iex continuation prompt, no hang",
       %{handle: handle} do
    # review finding, 2026-09-18: this used to put iex into its "...(N)>"
    # continuation prompt, silently absorbing everything sent afterward
    # (including the *next* entry's own template) forever -- confirms
    # EvalTemplate.build_syntax_error/3 fires instead of ever writing an
    # unparseable form to the session.
    entry = %{
      call_id: "c_bad",
      module: "Calc",
      name: "add",
      args: ["[1, 2", "3"],
      inputs: [],
      limits: %{timeout: 5_000, max_heap_words: 50_000_000}
    }

    Direct.write(handle, EvalTemplate.build(entry))
    out = collect_until(handle, "XT_ERROR_c_bad", 5_000)
    assert out =~ "XT_ERROR_c_bad crash invalid call expression:"

    # the session was never left in a continuation prompt -- an ordinary
    # eval right after resolves normally, not swallowed into a stuck form
    book = Book.new() |> Core.put_node("n1", pure_node("Calc", "add", 2)) |> Core.add_call("c_good", %{node: "n1", args: ["2", "3"]})
    good_entry = entry_for(book, "c_good", ["c_good"])
    Direct.write(handle, EvalTemplate.build(good_entry))
    good_out = collect_until(handle, "XT_END_c_good", 5_000)
    assert good_out =~ "XT_BEGIN_c_good\nrepr=exact\ntype=integer\ncompare=none\ndisplay=5\nXT_END_c_good"
  end

  test "heartbeat_input keeps beating while a slow-but-not-timed-out eval is still running" do
    # dedicated session with a short interval (not the shared `setup`
    # handle/message, which uses the slower 5s default) -- keeps this
    # test fast rather than needing to wait out several 5s intervals
    message = Launch.build(cwd: @fixture_dir, argv: ["iex"], files: ["calc.exs"], heartbeat_interval_ms: 200)
    {:ok, handle} = Direct.send(message)
    assert :ok = Session.await_ready(handle, message["ready_pattern"], 15_000)

    assert :ok = Direct.write(handle, message["heartbeat_input"])

    entry = %{
      call_id: "c_slow",
      module: ":timer",
      name: "sleep",
      args: ["1200"],
      inputs: [],
      limits: %{timeout: 5_000, max_heap_words: 50_000_000}
    }

    Direct.write(handle, EvalTemplate.build(entry))
    run = run_parser(handle, "c_slow", "", 0, 5_000)

    # a 200ms heartbeat over a ~1.2s wait should land several beats;
    # asserting >= 2 keeps this tolerant of scheduling jitter
    assert run.heartbeats >= 2
    assert run.result.outcome == {:ok, %{repr: "exact", type: "atom", display: ":ok", bin: nil}}

    Direct.kill(handle)
  end

  # Returns %{result: <Evaluator.Result>, heartbeats: <count seen while waiting>}
  # -- heartbeats accumulate across every :pending step, not just the last
  # one, since a slow eval can span many chunks/heartbeat ticks.
  defp run_parser(handle, call_id, buffer, session_gen, timeout, heartbeats \\ 0) do
    case Parser.step(buffer, call_id, ScanDirectIex, FieldDripElixir, session_gen) do
      {:ok, result, cleaned} ->
        %{result: result, heartbeats: heartbeats + cleaned.heartbeats}

      {:pending, cleaned} ->
        receive do
          {^handle, {:data, chunk}} ->
            run_parser(handle, call_id, cleaned.buffer <> chunk, session_gen, timeout, heartbeats + cleaned.heartbeats)
        after
          timeout -> flunk("Parser.step never resolved for #{call_id}, buffer so far: #{inspect(cleaned.buffer)}")
        end
    end
  end

  test "the full pipeline (Scan.Direct.Iex + Scan + FieldDrip.Elixir + Result) turns real iex output into a real Evaluator.Result",
       %{handle: handle} do
    book = Book.new() |> Core.put_node("n1", pure_node("Calc", "add", 2)) |> Core.add_call("c1", %{node: "n1", args: ["2", "3"]})
    entry = entry_for(book, "c1", ["c1"])

    Direct.write(handle, EvalTemplate.build(entry))
    run = run_parser(handle, "c1", "", 4, 5_000)
    result = run.result

    assert result.call_id == "c1"
    assert result.outcome == {:ok, %{repr: "exact", type: "integer", display: "5", bin: nil}}
    assert result.compare == "none"
    assert result.session_gen == 4
    assert {:ok, _, _} = DateTime.from_iso8601(result.evaluated_at)
  end

  test "a call that runs longer than its timeout is killed and reported as XT_ERROR ... timeout", %{handle: handle} do
    entry = %{
      call_id: "c_timeout",
      module: ":timer",
      name: "sleep",
      args: ["5000"],
      inputs: [],
      limits: %{timeout: 300, max_heap_words: 50_000_000}
    }

    started = System.monotonic_time(:millisecond)
    Direct.write(handle, EvalTemplate.build(entry))
    out = collect_until(handle, "XT_ERROR_c_timeout", 5_000)
    elapsed = System.monotonic_time(:millisecond) - started

    assert out =~ "XT_ERROR_c_timeout timeout"
    assert elapsed < 2_000
  end

  test "a call that exceeds max_heap is killed and reported as XT_ERROR ... max_heap (distinct from a generic crash)",
       %{handle: handle} do
    entry = %{
      call_id: "c_heap",
      module: "Enum",
      name: "to_list",
      args: ["1..2_000_000"],
      inputs: [],
      limits: %{timeout: 5_000, max_heap_words: 1_000}
    }

    Direct.write(handle, EvalTemplate.build(entry))
    out = collect_until(handle, "XT_ERROR_c_heap", 5_000)
    assert out =~ "XT_ERROR_c_heap max_heap"

    # session must still be alive/responsive after a max_heap kill, same
    # guarantee as an ordinary crash (spawn_monitor isolation)
    Direct.write(handle, "IO.puts(\"XT_LIVE_CHECK_still_alive\")\n")
    assert collect_until(handle, "XT_LIVE_CHECK_still_alive", 5_000) =~ "XT_LIVE_CHECK_still_alive"
  end

  test "compare reports same for a repeat eval with the same result, changed after the args change",
       %{handle: handle} do
    book =
      Book.new()
      |> Core.put_node("n1", pure_node("Calc", "add", 2))
      |> Core.add_call("c1", %{node: "n1", args: ["2", "3"]})

    entry1 = entry_for(book, "c1", ["c1"])
    assert entry1.basis == :none

    Direct.write(handle, EvalTemplate.build(entry1))
    r1 = run_parser(handle, "c1", "", 1, 5_000)
    assert r1.result.compare == "none"

    book2 = Core.apply_results(book, %{commit: nil, commit_at: nil, dirty: nil}, [r1.result])

    plan2 = Core.plan_recalc(book2, "pass2", call_ids: ["c1"])
    entry2 = Enum.find(plan2.entries, &(&1.call_id == "c1"))
    assert entry2.basis == {:exact, "5"}

    Direct.write(handle, EvalTemplate.build(entry2))
    r2 = run_parser(handle, "c1", "", 1, 5_000)
    assert r2.result.compare == "same"

    book3 = Core.edit_args(book2, "c1", ["10", "20"])
    plan3 = Core.plan_recalc(book3, "pass3", call_ids: ["c1"])
    entry3 = Enum.find(plan3.entries, &(&1.call_id == "c1"))

    Direct.write(handle, EvalTemplate.build(entry3))
    r3 = run_parser(handle, "c1", "", 1, 5_000)
    assert r3.result.compare == "changed"
    assert r3.result.outcome == {:ok, %{repr: "exact", type: "integer", display: "30", bin: nil}}
  end
end
