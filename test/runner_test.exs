ExUnit.start()

Code.require_file(Path.expand("../lib/runner.exs", __DIR__))

defmodule RunnerTest.EchoSender do
  # Same shape as repl_evaluator_test.exs's EchoSender -- answers every
  # eval write with a canned exact-repr success, no real iex needed.
  @behaviour XipeTotec.Repl.Sender

  def send(message) do
    handle = self()
    Kernel.send(handle, {handle, {:data, message["ready_pattern"] <> "\n"}})
    {:ok, handle}
  end

  def write(handle, text) do
    case Regex.run(~r/XT_BEGIN_([^"\s]+)/, text) do
      [_, call_id] ->
        body = "XT_BEGIN_#{call_id}\nrepr=exact\ntype=integer\ncompare=none\ndisplay=1\nXT_END_#{call_id}\n"
        Kernel.send(handle, {handle, {:data, body}})

      nil ->
        if text == "System.halt()\n", do: Kernel.send(handle, {handle, {:data, "XT_EXIT 0\n"}})
    end

    :ok
  end

  def kill(_handle), do: :ok
end

defmodule RunnerTest do
  use ExUnit.Case, async: true

  alias XipeTotec.{Book, Core}
  alias XipeTotec.Runner
  alias RunnerTest.EchoSender

  defp pure_node(name), do: %{module: "M", name: name, arity: 1, effect: "pure", effect_source: "user"}

  test "a single Dispatch command runs and folds into the book" do
    book = Book.new() |> Core.put_node("n1", pure_node("f"))
    commands = [%{"method" => "row/add", "params" => %{"node" => "n1", "args" => ["1"]}}]

    {new_book, [outcome]} = Runner.run(book, ".", commands)

    assert outcome.method == "row/add"
    assert outcome.ok?
    assert is_binary(outcome.result["id"])
    assert map_size(new_book.calls) == 1
  end

  test "a failing command reports an error and does not touch the book, later commands still run" do
    book = Book.new() |> Core.put_node("n1", pure_node("f"))

    commands = [
      %{"method" => "row/add", "params" => %{}},
      %{"method" => "row/add", "params" => %{"node" => "n1", "args" => ["1"]}}
    ]

    {new_book, [bad, good]} = Runner.run(book, ".", commands)

    refute bad.ok?
    assert bad.error["code"] == "invalid_params"
    assert good.ok?
    assert map_size(new_book.calls) == 1
  end

  test "$n.path pulls a value out of an earlier command's result, resolved at run time" do
    book = Book.new() |> Core.put_node("n1", pure_node("f"))

    commands = [
      %{"method" => "row/add", "params" => %{"node" => "n1", "args" => ["1"]}},
      %{"method" => "row/remove", "params" => %{"id" => "$0.id"}}
    ]

    {new_book, [added, removed]} = Runner.run(book, ".", commands)

    assert added.ok?
    assert removed.ok?
    assert removed.result["id"] == added.result["id"]
    assert new_book.calls == %{}
  end

  test "a reference into a failed command's (missing) result resolves to nil rather than crashing" do
    book = Book.new()

    commands = [
      %{"method" => "row/add", "params" => %{}},
      %{"method" => "row/remove", "params" => %{"id" => "$0.id"}}
    ]

    {_book, [bad, second]} = Runner.run(book, ".", commands)

    refute bad.ok?
    refute second.ok?
    assert second.error["code"] == "invalid_params"
  end

  test "$n.path substitutes inside a list value too" do
    book = Book.new() |> Core.put_node("n1", pure_node("f")) |> Core.add_call("c1", %{node: "n1", args: ["1"]})

    commands = [
      %{"method" => "cell/resolve", "params" => %{"ref" => "⟦c1⟧"}},
      %{"method" => "row/add", "params" => %{"node" => "n1", "args" => ["$0.state", "2"]}}
    ]

    {_book, [resolved, added]} = Runner.run(book, ".", commands)

    assert resolved.ok?
    assert added.ok?
    assert added.result["row"].args == ["ok", "2"]
  end

  test "an \"eval\" command routes to Evaluator, not Dispatch, and folds its results into the book" do
    book = Book.new() |> Core.put_node("n1", pure_node("f")) |> Core.add_call("c1", %{node: "n1", args: ["1"]})

    commands = [%{"method" => "eval", "params" => %{"call_ids" => ["c1"]}}]

    # explicit launch_opts: skips Runner's own scripts-mode inference (which
    # would otherwise sanitize+scan this whole checkout via
    # Project.find_sheets(".") -- slow and beside the point of this test,
    # which is about method routing, not launch-opt inference)
    {new_book, [outcome]} = Runner.run(book, ".", commands, sender: EchoSender, launch_opts: [])

    assert outcome.method == "eval"
    assert outcome.ok?
    assert [%{call_id: "c1", outcome: {:ok, _}}] = outcome.result["results"]
    assert Book.get(new_book, :calls, "c1").result == "1"
  end

  test "an \"eval\" command with call_ids omitted evaluates every call in the book, matching `xipe eval`'s own default" do
    book =
      Book.new()
      |> Core.put_node("n1", pure_node("f"))
      |> Core.add_call("c1", %{node: "n1", args: ["1"]})
      |> Core.add_call("c2", %{node: "n1", args: ["2"]})

    commands = [%{"method" => "eval", "params" => %{}}]

    {new_book, [outcome]} = Runner.run(book, ".", commands, sender: EchoSender, launch_opts: [])

    assert outcome.ok?
    assert length(outcome.result["results"]) == 2
    assert Book.get(new_book, :calls, "c1").eval_count == 1
    assert Book.get(new_book, :calls, "c2").eval_count == 1
  end

  test "an \"eval\" command excludes a writes-effect row by default (filter_by_effect/3's own default)" do
    book =
      Book.new()
      |> Core.put_node("n1", %{module: "M", name: "f", arity: 1, effect: "writes", effect_source: "user"})
      |> Core.add_call("c1", %{node: "n1", args: ["1"]})

    commands = [%{"method" => "eval", "params" => %{"call_ids" => ["c1"]}}]
    {new_book, [outcome]} = Runner.run(book, ".", commands, sender: EchoSender, launch_opts: [])

    assert outcome.ok?
    assert outcome.result["results"] == []
    assert Book.get(new_book, :calls, "c1").eval_count == 0
  end

  test "\"include_writes\" => true in an \"eval\" command's params opts a writes-effect row in (prebuild.md §16.2/§16.4, previously unwired)" do
    book =
      Book.new()
      |> Core.put_node("n1", %{module: "M", name: "f", arity: 1, effect: "writes", effect_source: "user"})
      |> Core.add_call("c1", %{node: "n1", args: ["1"]})

    commands = [%{"method" => "eval", "params" => %{"call_ids" => ["c1"], "include_writes" => true}}]
    {new_book, [outcome]} = Runner.run(book, ".", commands, sender: EchoSender, launch_opts: [])

    assert outcome.ok?
    assert [%{call_id: "c1", outcome: {:ok, _}}] = outcome.result["results"]
    assert Book.get(new_book, :calls, "c1").eval_count == 1
  end

  test "\"include_writes\" also accepts the plain string \"true\" that `xipe do`'s generic key=value parsing produces" do
    book =
      Book.new()
      |> Core.put_node("n1", %{module: "M", name: "f", arity: 1, effect: "writes", effect_source: "user"})
      |> Core.add_call("c1", %{node: "n1", args: ["1"]})

    commands = [%{"method" => "eval", "params" => %{"call_ids" => ["c1"], "include_writes" => "true"}}]
    {_new_book, [outcome]} = Runner.run(book, ".", commands, sender: EchoSender, launch_opts: [])

    assert [%{call_id: "c1"}] = outcome.result["results"]
  end

  test "a launch failure in an \"eval\" command is reported without touching the book" do
    book = Book.new() |> Core.put_node("n1", pure_node("f")) |> Core.add_call("c1", %{node: "n1", args: ["1"]})
    commands = [%{"method" => "eval", "params" => %{"call_ids" => ["c1"]}}]

    defmodule RefusingSender do
      @behaviour XipeTotec.Repl.Sender
      def send(_message), do: {:error, :nope}
      def write(_handle, _text), do: :ok
      def kill(_handle), do: :ok
    end

    {new_book, [outcome]} = Runner.run(book, ".", commands, sender: RefusingSender, launch_opts: [])

    refute outcome.ok?
    assert outcome.error["code"] == "eval_failed"
    assert new_book == book
  end

  test "add a row, mark it pure, then eval it -- all three chained by $n.path in one command list" do
    book = Book.new() |> Core.put_node("n1", pure_node("f") |> Map.merge(%{effect: "unknown", effect_source: nil}))

    commands = [
      %{"method" => "row/add", "params" => %{"node" => "n1", "args" => ["1"]}},
      %{"method" => "effect/set", "params" => %{"id" => "n1", "effect" => "pure"}},
      %{"method" => "eval", "params" => %{"call_ids" => ["$0.id"]}}
    ]

    {new_book, [added, effect_set, evaluated]} = Runner.run(book, ".", commands, sender: EchoSender, launch_opts: [])

    assert added.ok?
    assert effect_set.ok?
    assert evaluated.ok?
    assert Book.get(new_book, :calls, added.result["id"]).result == "1"
  end

  defmodule RecordingSender do
    # Records the launch message via the process dictionary (this all runs
    # synchronously in the test process, so Process.put/get round-trips
    # within the same test) instead of answering anything -- this test only
    # cares what Runner *built*, not a full eval round-trip.
    @behaviour XipeTotec.Repl.Sender

    @impl true
    def send(message) do
      Process.put(:recorded_launch_message, message)
      {:error, :not_actually_launching}
    end

    @impl true
    def write(_handle, _text), do: :ok

    @impl true
    def kill(_handle), do: :ok
  end

  test "the default (no :launch_opts) eval path sanitizes scripts-mode's file list, and cleans up the temp dir after" do
    dir = Path.join(System.tmp_dir!(), "xipe_totec_runner_launch_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    File.write!(Path.join(dir, "calc.exs"), "defmodule RunnerLaunchCalc do\n  def add(a, b), do: a + b\nend\n")

    book = Book.new() |> Core.put_node("n1", pure_node("f")) |> Core.add_call("c1", %{node: "n1", args: ["1"]})
    commands = [%{"method" => "eval", "params" => %{"call_ids" => ["c1"]}}]

    {_book, [outcome]} = Runner.run(book, dir, commands, sender: RecordingSender)

    refute outcome.ok?
    message = Process.get(:recorded_launch_message)
    assert message["argv"] == ["iex"]
    assert [sanitized_path] = message["files"]
    # sanitized -- not the original project file -- and already cleaned up
    # by the time run/4 returns (Runner's cleanup runs right after
    # Evaluator.run_pass, regardless of outcome)
    refute sanitized_path == Path.join(dir, "calc.exs")
    assert Path.basename(sanitized_path) =~ "calc.exs"
    refute File.exists?(sanitized_path)
  end

  test "eval/run and row/update route through Pipeline, not Dispatch's own @not_implemented" do
    book = Book.new()
    commands = [%{"method" => "eval/run", "params" => %{}}, %{"method" => "row/update", "params" => %{}}]

    {^book, [eval_run, row_update]} = Runner.run(book, ".", commands)

    # Dispatch's @not_implemented would answer with "not_implemented" too,
    # so the real proof this went through Pipeline (not Dispatch) is which
    # *stage* the message names -- Dispatch has no concept of stages at all.
    refute eval_run.ok?
    assert eval_run.error["message"] =~ "\"eval\""
    refute row_update.ok?
    assert row_update.error["message"] =~ "\"edit\""
  end
end
