ExUnit.start()

Code.require_file(Path.expand("../lib/passes.exs", __DIR__))
Code.require_file(Path.expand("../lib/runner.exs", __DIR__))
Code.require_file(Path.expand("../lib/outcome_text.exs", __DIR__))

# Answers every entry at once, and first tells the test what Passes holds
# right then (the record a running pass leaves)
defmodule PassesTest.PeekingSender do
  @behaviour XipeTotec.Repl.Sender

  def send(message) do
    handle = self()
    Kernel.send(handle, {handle, {:data, message["ready_pattern"] <> "\nXT_READY\n"}})
    {:ok, handle}
  end

  def write(handle, text) do
    case Regex.run(~r/XT_BEGIN_([^"\s]+)/, text) do
      [_, call_id] ->
        [test, dir] = Process.get(:peek)
        Kernel.send(test, {:peek, call_id, XipeTotec.Passes.running(dir)})
        body = "XT_CALLED_#{call_id}\nXT_BEGIN_#{call_id}\nrepr=exact\ntype=integer\ncompare=none\ndisplay=1\nXT_END_#{call_id}\n"
        Kernel.send(handle, {handle, {:data, body}})

      nil ->
        if text == "System.halt()\n", do: Kernel.send(handle, {handle, {:data, "XT_EXIT 0\n"}})
    end

    :ok
  end

  def kill(_handle), do: :ok
  def interrupt(_handle), do: :ok
end

defmodule PassesTest do
  use ExUnit.Case, async: true

  alias XipeTotec.{Book, Core, Dispatch, OutcomeText, Passes, Pipeline, Runner}

  setup do
    dir = Path.join(System.tmp_dir!(), "xipe_totec_passes_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    book =
      Book.new()
      |> Core.put_node("n1", %{module: "M", name: "f", anykey: 1, effect: "pure", effect_source: "user"})
      |> Core.add_call("c1", %{node: "n1", args: ["1"]})
      |> Core.add_call("c2", %{node: "n1", args: ["2"]})

    %{dir: dir, book: book}
  end

  test "a running group is recorded, shows its row and phase, and goes when it finishes", %{dir: dir} do
    assert Passes.running(dir) == []
    h = Passes.start(dir, "p1", "elixir", ["c1", "c2"])
    assert [%{"pass_id" => "p1", "language" => "elixir", "call_ids" => ["c1", "c2"], "current" => nil}] = Passes.running(dir)

    Passes.progress(h, "c1", "classifying")
    assert [%{"current" => %{"call_id" => "c1", "phase" => "classifying"}}] = Passes.running(dir)

    Passes.finish(h)
    assert Passes.running(dir) == []
  end

  test "without a project_dir nothing is written or locked" do
    assert Passes.start(nil, "p1", "elixir", ["c1"]) == nil
    assert Passes.progress(nil, "c1", "calling") == :ok
    assert Passes.running(nil) == []
    assert Passes.refuse(nil, "c1") == nil
  end

  test "a record whose process is gone is not running, and is removed", %{dir: dir} do
    path = Path.join([dir, "passes", "p9-elixir.json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(%{"pass_id" => "p9", "call_ids" => ["c1"], "os_pid" => "999999999", "os_started" => "never", "started_at" => "x"}))

    assert Passes.running(dir) == []
    refute File.exists?(path)
    assert Passes.refuse(dir, "c1") == nil
  end

  test "clear/2 removes every group of a pass (a server's pass process that died)", %{dir: dir} do
    Passes.start(dir, "p1", "elixir", ["c1"])
    Passes.start(dir, "p1", "haskell", ["c2"])
    Passes.start(dir, "p2", "elixir", ["c3"])
    Passes.clear(dir, "p1")
    assert [%{"pass_id" => "p2"}] = Passes.running(dir)
  end

  describe "a row of a running pass can't be changed" do
    setup %{dir: dir} do
      h = Passes.start(dir, "p1", "elixir", ["c1"])
      on_exit(fn -> Passes.finish(h) end)
      :ok
    end

    test "row/update, row/set-result and row/remove answer row_in_pass; another row is free", %{dir: dir, book: book} do
      ctx = %{root: dir, project_dir: dir, eval: fn b, _ -> {b, %{method: "eval", ok?: true, result: %{}, error: nil}} end}

      assert {:error, ^book, %{"code" => "row_in_pass", "message" => msg}} =
               Pipeline.run("row/update", book, %{"id" => "c1", "args" => ["5"]}, ctx)

      assert msg =~ "row c1 is being evaluated (pass p1)"
      assert msg =~ "eval/status"

      assert {:error, ^book, %{"code" => "row_in_pass"}} = Dispatch.handle(book, "row/set-result", %{"id" => "c1", "result" => "3"}, ctx)
      assert {:error, ^book, %{"code" => "row_in_pass"}} = Dispatch.handle(book, "row/remove", %{"id" => "c1"}, ctx)

      assert {:ok, _, _} = Pipeline.run("row/update", book, %{"id" => "c2", "args" => ["5"]}, ctx)
      assert {:ok, _, _} = Dispatch.handle(book, "row/set-result", %{"id" => "c2", "result" => "3"}, ctx)
      assert {:ok, _, _} = Dispatch.handle(book, "row/remove", %{"id" => "c2"}, ctx)
    end

    test "eval/status shows the pass, the row it is on and its phase", %{dir: dir, book: book} do
      [path] = Path.wildcard(Path.join([dir, "passes", "*.json"]))
      Passes.progress(path, "c1", "classifying")

      assert {:ok, ^book, %{"running" => [p]}} = Dispatch.handle(book, "eval/status", %{}, %{root: dir, project_dir: dir})
      assert %{"pass_id" => "p1", "language" => "elixir", "call_ids" => ["c1"]} = p
      assert %{"call_id" => "c1", "label" => "M.f/1", "phase" => "classifying"} = p["current"]
      assert is_integer(p["seconds"]) and is_integer(p["current"]["seconds"])

      text = OutcomeText.text([%{method: "eval/status", ok?: true, result: %{"running" => [p], "queued" => [%{"pass_id" => "p2", "call_ids" => []}]}, error: nil}])
      assert text =~ "running  pass p1  elixir"
      assert text =~ "1 row(s) (not changeable until it ends)"
      assert text =~ "now  c1  M.f/1  classifying"
      assert text =~ "queued   pass p2  every row"
    end
  end

  test "eval/status with nothing running" do
    assert {:ok, _, %{"running" => []}} = Dispatch.handle(Book.new(), "eval/status", %{}, %{project_dir: nil})
    assert OutcomeText.text([%{method: "eval/status", ok?: true, result: %{"running" => []}, error: nil}]) =~ "nothing is being evaluated"
  end

  test "Runner records each pass group while it runs, with the row and phase, and removes it after", %{dir: dir, book: book} do
    Process.put(:peek, [self(), dir])
    commands = [%{"method" => "eval", "params" => %{"call_ids" => ["c1", "c2"]}}]

    {new_book, [outcome]} =
      Runner.run(book, dir, commands, sender: PassesTest.PeekingSender, launch_opts: [], language: "elixir", project_dir: dir, pass_id: "pX")

    assert outcome.ok?
    assert Book.get(new_book, :calls, "c2").result == "1"

    assert_received {:peek, "c1", [%{"pass_id" => "pX", "call_ids" => ["c1", "c2"], "current" => %{"call_id" => "c1", "phase" => "calling"}}]}
    assert_received {:peek, "c2", [%{"current" => %{"call_id" => "c2", "phase" => "calling"}}]}
    assert Passes.running(dir) == []
  end

  test "a skipped row's line says how to settle its upstream (same command, or dialogue depends)" do
    out = %{method: "eval", ok?: true, result: %{"results" => [%{call_id: "c2", outcome: {:skipped, "c1"}, compare: "skipped"}]}, error: nil}
    text = OutcomeText.text([out])
    assert text =~ "skipped  upstream c1 has no value that can be written into the call"
    assert text =~ "`dialogue depends c2`"
  end
end
