ExUnit.start()
# see test/run.sh
System.put_env("XIPE_TOTEC_LSP", "off")

Code.require_file(Path.expand("../lib/runner.exs", __DIR__))

defmodule RunnerTest.EchoSender do
  # Same shape as repl_evaluator_test.exs's EchoSender -- answers every
  # eval write with a canned exact-repr success, no real iex needed.
  @behaviour XipeTotec.Repl.Sender

  def send(message) do
    handle = self()
    Kernel.send(handle, {handle, {:data, message["ready_pattern"] <> "\nXT_READY\n"}})
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
  def interrupt(_handle), do: :ok
end

# a second, made-up language for a mixed-language
# project -- it reuses Elixir's adapter (EchoSender answers in its format)
defmodule RunnerTest.ToyLanguage do
  def extensions, do: ["toy"]
  def repl, do: "toy"
  def build_tools, do: []
  def scanner, do: XipeTotec.Scanner.Elixir
  def adapter do
    %{
      launch: XipeTotec.Repl.Launch,
      eval_template: XipeTotec.Repl.EvalTemplate,
      scan: XipeTotec.Repl.Eval.Scan.Direct.Iex,
      field_drip: XipeTotec.Repl.Eval.FieldDrip.Elixir
    }
  end
  def launch_opts(_root, _build_tool, _files), do: {[argv: ["toy-repl"]], fn -> :ok end}
end

# refuses to launch the toy language's REPL, echoes for any other
defmodule RunnerTest.ToyRefusingSender do
  @behaviour XipeTotec.Repl.Sender
  alias RunnerTest.EchoSender

  def send(%{"argv" => ["toy-repl" | _]}), do: {:error, :refused}
  def send(message), do: EchoSender.send(message)
  def write(handle, text), do: EchoSender.write(handle, text)
  def kill(handle), do: EchoSender.kill(handle)
  def interrupt(handle), do: EchoSender.interrupt(handle)
end

defmodule RunnerTest do
  use ExUnit.Case, async: true

  alias XipeTotec.{Book, Core}
  alias XipeTotec.Runner
  alias RunnerTest.EchoSender

  # The eval tests evaluate "." -- xipe_totec itself, which holds an OCaml
  # fixture too -- with rows whose functions have no file: the language is
  # given (`language: "elixir"`) rather than told from the surface table.
  defp pure_node(name), do: %{module: "M", name: name, anykey: 1, effect: "pure", effect_source: "user"}

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

  test "$n.path indexes a list with a number and reads a Book row's atom keys" do
    book = Book.new() |> Core.put_node("n1", pure_node("f")) |> Core.put_node("n2", pure_node("g"))

    commands = [
      %{"method" => "card/get", "params" => %{"name" => "f"}},
      %{"method" => "row/add", "params" => %{"node" => "$0.matches.0.id", "args" => ["1"]}},
      %{"method" => "row/add", "params" => %{"node" => "n2", "args" => ["$1.row.args.0"]}},
      # not there: nil, not a crash
      %{"method" => "row/add", "params" => %{"node" => "$0.matches.9.id", "args" => ["1"]}}
    ]

    {_book, [_card, first, second, missing]} = Runner.run(book, ".", commands)

    assert first.result["row"].node == "n1"
    assert second.result["row"].args == ["1"]
    refute missing.ok?
  end

  test "⟦$n.path⟧ inside a string becomes a cell reference to that id" do
    book = Book.new() |> Core.put_node("n1", pure_node("f"))

    commands = [
      %{"method" => "row/add", "params" => %{"node" => "n1", "args" => ["3"]}},
      %{"method" => "row/add", "params" => %{"node" => "n1", "args" => ["⟦$0.id⟧ + 1"]}},
      # a reference that doesn't resolve is left as written
      %{"method" => "row/add", "params" => %{"node" => "n1", "args" => ["⟦$7.id⟧"]}}
    ]

    {_book, [first, second, third]} = Runner.run(book, ".", commands)

    assert second.result["row"].args == ["⟦#{first.result["id"]}⟧ + 1"]
    assert third.result["row"].args == ["⟦$7.id⟧"]
  end

  test "$n.path substitutes inside a list value too" do
    book =
      Book.new()
      |> Core.put_node("n1", pure_node("f"))
      |> Core.put_node("n2", %{pure_node("g") | anykey: 2})
      |> Core.add_call("c1", %{node: "n1", args: ["1"]})

    commands = [
      %{"method" => "cell/resolve", "params" => %{"ref" => "⟦c1⟧"}},
      %{"method" => "row/add", "params" => %{"node" => "n2", "args" => ["$0.state", "2"]}}
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
    {new_book, [outcome]} = Runner.run(book, ".", commands, sender: EchoSender, launch_opts: [], language: "elixir")

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

    {new_book, [outcome]} = Runner.run(book, ".", commands, sender: EchoSender, launch_opts: [], language: "elixir")

    assert outcome.ok?
    assert length(outcome.result["results"]) == 2
    assert Book.get(new_book, :calls, "c1").eval_count == 1
    assert Book.get(new_book, :calls, "c2").eval_count == 1
  end

  test "an \"eval\" command excludes a writes-effect row by default (filter_by_effect/3's own default)" do
    book =
      Book.new()
      |> Core.put_node("n1", %{module: "M", name: "f", anykey: 1, effect: "writes", effect_source: "user"})
      |> Core.add_call("c1", %{node: "n1", args: ["1"]})

    commands = [%{"method" => "eval", "params" => %{"call_ids" => ["c1"]}}]
    {new_book, [outcome]} = Runner.run(book, ".", commands, sender: EchoSender, launch_opts: [], language: "elixir")

    assert outcome.ok?
    assert outcome.result["results"] == []
    assert Book.get(new_book, :calls, "c1").eval_count == 0
  end

  test "an eval over an unclassified node reports it under not_run instead of silently doing nothing" do
    book =
      Book.new()
      |> Core.put_node("n1", %{module: "M", name: "f", anykey: 1, effect: "unknown", effect_source: nil})
      |> Core.add_call("c1", %{node: "n1", args: ["1"]})

    commands = [%{"method" => "eval", "params" => %{"call_ids" => ["c1"]}}]
    {_new_book, [outcome]} = Runner.run(book, ".", commands, sender: EchoSender, launch_opts: [], language: "elixir")

    assert outcome.ok?
    assert outcome.result["results"] == []
    assert [%{"id" => "c1", "reason" => reason}] = outcome.result["not_run"]
    assert reason =~ "effect/set"
  end

  test "\"include_writes\" => true in an \"eval\" command's params opts a writes-effect row in (previously unwired)" do
    book =
      Book.new()
      |> Core.put_node("n1", %{module: "M", name: "f", anykey: 1, effect: "writes", effect_source: "user"})
      |> Core.add_call("c1", %{node: "n1", args: ["1"]})

    commands = [%{"method" => "eval", "params" => %{"call_ids" => ["c1"], "include_writes" => true}}]
    {new_book, [outcome]} = Runner.run(book, ".", commands, sender: EchoSender, launch_opts: [], language: "elixir")

    assert outcome.ok?
    assert [%{call_id: "c1", outcome: {:ok, _}}] = outcome.result["results"]
    assert Book.get(new_book, :calls, "c1").eval_count == 1
  end

  test "\"include_writes\" also accepts the plain string \"true\" that `xipe do`'s generic key=value parsing produces" do
    book =
      Book.new()
      |> Core.put_node("n1", %{module: "M", name: "f", anykey: 1, effect: "writes", effect_source: "user"})
      |> Core.add_call("c1", %{node: "n1", args: ["1"]})

    commands = [%{"method" => "eval", "params" => %{"call_ids" => ["c1"], "include_writes" => "true"}}]
    {_new_book, [outcome]} = Runner.run(book, ".", commands, sender: EchoSender, launch_opts: [], language: "elixir")

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
      def interrupt(_handle), do: :ok
    end

    {new_book, [outcome]} = Runner.run(book, ".", commands, sender: RefusingSender, launch_opts: [], language: "elixir")

    refute outcome.ok?
    assert outcome.error["code"] == "eval_failed"
    assert new_book == book
  end

  test "a REPL that exits while booting is reported with its output, not only the exit status" do
    message = Runner.failure_message({:boot_failed, {:exited_before_ready, "1", "** (SyntaxError) calc.exs:3\n  def sub(a, b), do: a -"}})

    assert message ==
             "boot_failed: the REPL exited before it was ready (exit status 1). Its last output:\n" <>
               "    ** (SyntaxError) calc.exs:3\n" <>
               "      def sub(a, b), do: a -"

    assert Runner.failure_message({:boot_failed, {:exited_before_ready, "127", ""}}) =~ "exit status 127), printing nothing"
    assert Runner.failure_message({:launch_failed, :nope}) == "{:launch_failed, :nope}"
  end

  test "add a row, mark it pure, then eval it -- all three chained by $n.path in one command list" do
    book = Book.new() |> Core.put_node("n1", pure_node("f") |> Map.merge(%{effect: "unknown", effect_source: nil}))

    commands = [
      %{"method" => "row/add", "params" => %{"node" => "n1", "args" => ["1"]}},
      %{"method" => "effect/set", "params" => %{"id" => "n1", "effect" => "pure"}},
      %{"method" => "eval", "params" => %{"call_ids" => ["$0.id"]}}
    ]

    {new_book, [added, effect_set, evaluated]} = Runner.run(book, ".", commands, sender: EchoSender, launch_opts: [], language: "elixir")

    assert added.ok?
    assert effect_set.ok?
    assert evaluated.ok?
    assert Book.get(new_book, :calls, added.result["id"]).result == "1"
  end

  test "a $n.path that found nothing never turns an \"eval\" into every call in the book" do
    book =
      Book.new()
      |> Core.put_node("n1", pure_node("f"))
      |> Core.add_call("c1", %{node: "n1", args: ["1"]})

    # row/add fails (no such node), so $0.id is nil: call_ids=$0.id (a plain
    # string, as `xipe do ... call_ids=$0.id` gives) and [$0.id] both refuse
    for ids <- ["$0.id", ["$0.id"]] do
      commands = [
        %{"method" => "row/add", "params" => %{"node" => "nope", "args" => ["1"]}},
        %{"method" => "eval", "params" => %{"call_ids" => ids}}
      ]

      {new_book, [added, evaluated]} = Runner.run(book, ".", commands, sender: EchoSender, launch_opts: [], language: "elixir")

      refute added.ok?
      refute evaluated.ok?
      assert %{"code" => "invalid_params", "message" => "eval: call_ids is empty" <> _} = evaluated.error
      assert Book.get(new_book, :calls, "c1").eval_count == 0
    end
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

    @impl true
    def interrupt(_handle), do: :ok
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

  test "the default (no :launch_opts) eval path uses mix-mode (empty launch_opts) when root has a mix.exs" do
    dir = Path.join(System.tmp_dir!(), "xipe_totec_runner_launch_mix_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    File.write!(Path.join(dir, "mix.exs"), "")

    book = Book.new() |> Core.put_node("n1", pure_node("f")) |> Core.add_call("c1", %{node: "n1", args: ["1"]})
    commands = [%{"method" => "eval", "params" => %{"call_ids" => ["c1"]}}]

    {_book, [outcome]} = Runner.run(book, dir, commands, sender: RecordingSender)

    refute outcome.ok?
    message = Process.get(:recorded_launch_message)
    # mix-mode passes launch_opts: [] through -- Repl.Launch.build/1's own
    # default argv (["iex", "-S", "mix"]) is what actually shows up here.
    assert message["argv"] == ["iex", "-S", "mix"]
    assert message["files"] == []
  end

  test "an eval under a root with no file of a registered language is refused, not run with a guessed REPL" do
    dir = Path.join(System.tmp_dir!(), "xipe_totec_runner_nolang_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    # a language xipe_totec has no adapter for (Clojure)
    File.write!(Path.join(dir, "core.clj"), "(defn f [x] x)\n")

    book = Book.new() |> Core.put_node("n1", pure_node("f")) |> Core.add_call("c1", %{node: "n1", args: ["1"]})
    commands = [%{"method" => "eval", "params" => %{"call_ids" => ["c1"]}}]

    {^book, [outcome]} = Runner.run(book, dir, commands, sender: RecordingSender)

    refute outcome.ok?
    assert outcome.error["code"] == "no_language"
    assert Process.get(:recorded_launch_message) == nil
  end

  test "an explicit :language must be registered in info.json" do
    book = Book.new() |> Core.put_node("n1", pure_node("f")) |> Core.add_call("c1", %{node: "n1", args: ["1"]})
    commands = [%{"method" => "eval", "params" => %{"call_ids" => ["c1"]}}]

    {^book, [outcome]} = Runner.run(book, ".", commands, sender: EchoSender, launch_opts: [], language: "clojure")

    refute outcome.ok?
    assert outcome.error["code"] == "language_not_registered"
  end

  test "eval/run and row/update route through Pipeline, not Dispatch's own @not_implemented" do
    book = Book.new()
    commands = [%{"method" => "eval/run", "params" => %{}}, %{"method" => "row/update", "params" => %{}}]

    {^book, [eval_run, row_update]} = Runner.run(book, ".", commands)

    # Dispatch's @not_implemented would answer not_implemented for both
    assert eval_run.ok?
    refute row_update.ok?
    assert row_update.error["message"] =~ "row/update needs id"
  end

  # the pipeline's eval stage is this module's own "eval"
  test "row/update edits a row and evaluates it, and only it, through Runner's eval" do
    book =
      Book.new()
      |> Core.put_node("n1", pure_node("f"))
      |> Core.add_call("c1", %{node: "n1", args: ["1"]})
      |> Core.add_call("c2", %{node: "n1", args: ["⟦c1⟧"]})

    command = %{"method" => "row/update", "params" => %{"id" => "c1", "args" => ["9"]}}
    {new_book, [outcome]} = Runner.run(book, ".", [command], sender: EchoSender, launch_opts: [], language: "elixir")

    assert outcome.ok?
    assert outcome.result["id"] == "c1"
    assert Enum.map(outcome.result["results"], & &1.call_id) == ["c1"]
    assert Book.get(new_book, :calls, "c1").args == ["9"]
    assert Book.get(new_book, :calls, "c1").eval_count == 1
    assert Book.get(new_book, :calls, "c2").eval_count == 0
  end

  describe "a mixed-language project" do
    setup do
      dir = Path.join(System.tmp_dir!(), "xipe_totec_runner_mixed_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "lib"))
      File.write!(Path.join(dir, "lib/a.ex"), "defmodule M do\n  def f(x), do: x\nend\n")
      File.write!(Path.join(dir, "lib/b.toy"), "g x = x\n")
      on_exit(fn -> File.rm_rf!(dir) end)

      info = %{
        "languages" => ["elixir", "toy"],
        "extensions" => %{"ex" => ["elixir"], "exs" => ["elixir"], "toy" => ["toy"]},
        "language_repls" => %{"elixir" => "iex", "toy" => "toy"},
        "build_tools" => %{"elixir" => [], "toy" => []}
      }

      book =
        Book.new()
        |> Core.put_sheet("s1", %{path: "lib/a.ex"})
        |> Core.put_sheet("s2", %{path: "lib/b.toy"})
        |> Core.put_node("ne", Map.put(pure_node("f"), :sheet, "s1"))
        |> Core.put_node("nt", %{pure_node("g") | module: "T"} |> Map.put(:sheet, "s2"))
        |> Core.add_call("c1", %{node: "ne", args: ["1"]})
        |> Core.add_call("c2", %{node: "nt", args: ["2"]})
        # toy row referencing an Elixir row: across languages
        |> Core.add_call("c3", %{node: "nt", args: ["⟦c1⟧"]})
        # Elixir row referencing an Elixir row: handed over within its REPL
        |> Core.add_call("c4", %{node: "ne", args: ["⟦c1⟧"]})

      {:ok, dir: dir, book: book, opts: [info: info, language_modules: %{"toy" => RunnerTest.ToyLanguage}]}
    end

    test "each language's rows are evaluated in its own REPL; a reference across languages is not run", %{dir: dir, book: book, opts: opts} do
      command = %{"method" => "eval", "params" => %{}}
      {new_book, [outcome]} = Runner.run(book, dir, [command], opts ++ [sender: EchoSender, launch_opts: []])

      assert outcome.ok?
      assert outcome.result["results"] |> Enum.map(& &1.call_id) |> Enum.sort() == ["c1", "c2", "c4"]
      assert [%{"id" => "c3", "reason" => reason}] = outcome.result["not_run"]
      assert reason =~ "⟦c1⟧ is a elixir row"
      # one pass, whichever REPL a row went through
      assert outcome.result["results"] |> Enum.map(& &1.session_gen) |> Enum.uniq() |> length() == 1

      assert Book.get(new_book, :calls, "c1").eval_count == 1
      assert Book.get(new_book, :calls, "c2").eval_count == 1
      assert Book.get(new_book, :calls, "c3").eval_count == 0
    end

    test "a language whose REPL can't start leaves its rows not run; the other language's still evaluate",
         %{dir: dir, book: book, opts: opts} do
      command = %{"method" => "eval", "params" => %{"call_ids" => ["c1", "c2"]}}
      {new_book, [outcome]} = Runner.run(book, dir, [command], opts ++ [sender: RunnerTest.ToyRefusingSender])

      assert outcome.ok?
      assert Enum.map(outcome.result["results"], & &1.call_id) == ["c1"]
      assert [%{"id" => "c2", "reason" => reason}] = outcome.result["not_run"]
      assert reason =~ "the toy REPL"
      assert Book.get(new_book, :calls, "c2").eval_count == 0
    end

    test "only one language requested: the other language's REPL is never started", %{dir: dir, book: book, opts: opts} do
      command = %{"method" => "eval", "params" => %{"call_ids" => ["c1"]}}
      # ToyRefusingSender would refuse the toy REPL -- it isn't asked for
      {_book, [outcome]} = Runner.run(book, dir, [command], opts ++ [sender: RunnerTest.ToyRefusingSender])

      assert outcome.ok?
      assert Enum.map(outcome.result["results"], & &1.call_id) == ["c1"]
      assert outcome.result["not_run"] == []
    end
  end
end
