ExUnit.start()
# see test/run.sh
System.put_env("XIPE_TOTEC_LSP", "off")

Code.require_file(Path.expand("../lib/in_out.exs", __DIR__))
Code.require_file(Path.expand("../lib/input.exs", __DIR__))
Code.require_file(Path.expand("../lib/outcome_text.exs", __DIR__))

# Boots, answers every entry at once, and tells the test what it was sent
defmodule DialogueUpdateTest.TellingSender do
  @behaviour XipeTotec.Repl.Sender

  def send(message) do
    handle = self()
    Kernel.send(handle, {handle, {:data, message["ready_pattern"] <> "\nXT_READY\n"}})
    {:ok, handle}
  end

  def write(handle, text) do
    case Regex.run(~r/XT_BEGIN_([^"\s]+)/, text) do
      [_, call_id] ->
        Kernel.send(Process.get(:telling), {:sent, call_id, text})
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

defmodule DialogueUpdateTest do
  use ExUnit.Case, async: true

  alias XipeTotec.{Book, Core, Dispatch, InOut, Input, LogBuffer, Methods, OutcomeText, ProjectConfig, Runner}
  alias XipeTotec.Dialogue.Update

  setup do
    dir = Path.join(System.tmp_dir!(), "xipe_totec_update_test_#{System.unique_integer([:positive])}")
    project_dir = Path.join(dir, "001_calc")
    File.mkdir_p!(project_dir)
    File.write!(Path.join(project_dir, "project.json"), JSON.encode!(%{"path" => "/work/calc"}) <> "\n")
    on_exit(fn -> File.rm_rf!(dir) end)

    log = Path.join(dir, "logging_buffer.txt")
    %{dir: dir, own: Path.join(project_dir, "project.json"), log: log, ctx: %{book: Book.new(), root: "/work/calc", project_dir: project_dir, log_file: log}}
  end

  defp turns(ctx, params, lines) do
    Enum.reduce(lines, Update.start(params, ctx), fn line, turn ->
      {:hold, state, _text} = turn
      Update.answer(state, %{"text" => line}, ctx)
    end)
  end

  describe "ProjectConfig" do
    test "the time limits have defaults, take whole numbers in range, and are stored as numbers", %{ctx: ctx, own: own} do
      assert %{"timeout" => 5000, "boot_timeout" => 15000} = ProjectConfig.load(ctx.project_dir)["eval"]
      assert :ok = ProjectConfig.put(ctx.project_dir, "eval.timeout", "12000")
      assert ProjectConfig.load(ctx.project_dir)["eval"]["timeout"] == 12000
      # the registry's own key is kept
      assert %{"path" => "/work/calc", "eval" => %{"timeout" => 12000}} = JSON.decode!(File.read!(own))

      assert {:error, "eval.timeout must be a whole number of ms from 100 to 600000" <> _} = ProjectConfig.put(ctx.project_dir, "eval.timeout", "5")
      assert {:error, _} = ProjectConfig.put(ctx.project_dir, "eval.timeout", "fast")
      assert {:error, "unknown setting eval.nope" <> _} = ProjectConfig.put(ctx.project_dir, "eval.nope", "1")
      assert ProjectConfig.allowed_text("eval.boot_timeout") == "1000..1800000 ms"
      assert ProjectConfig.allowed_text("env.path") == "prepend|replace"
    end

    test "each setting says where its value comes from: the project's file, the defaults file, or built in", %{ctx: ctx, own: own, dir: dir} do
      defaults = Path.join(dir, "defaults.json")
      File.write!(defaults, JSON.encode!(%{"eval" => %{"timeout" => 7000, "nope" => 1}, "env" => %{"path" => "sideways"}}))
      :ok = ProjectConfig.put(ctx.project_dir, "env.refresh", "manual")

      entries = ProjectConfig.entries(ctx.project_dir, defaults)
      assert {"env.refresh", "manual", ^own} = List.keyfind(entries, "env.refresh", 0)
      assert {"eval.timeout", 7000, ^defaults} = List.keyfind(entries, "eval.timeout", 0)
      # a wrong value in the defaults file falls back to the built-in one
      assert {"env.path", "prepend", _} = List.keyfind(entries, "env.path", 0)
      # ... and a key the file lacks is built in
      assert {"eval.boot_timeout", 15000, nil} = List.keyfind(entries, "eval.boot_timeout", 0)
      assert List.keyfind(entries, "eval.nope", 0) == nil

      assert ProjectConfig.load(nil, Path.join(dir, "missing.json"))["eval"] == %{"timeout" => 5000, "boot_timeout" => 15000}
    end

    test "the committed defaults file holds every key, in range" do
      defaults = JSON.decode!(File.read!(ProjectConfig.defaults_file()))
      for {key, value} <- ProjectConfig.flatten(defaults), do: assert({:ok, _} = ProjectConfig.check(key, to_string(value)))
      assert Enum.map(ProjectConfig.flatten(defaults), &elem(&1, 0)) == ProjectConfig.keys()
    end
  end

  describe "LogBuffer" do
    test "keeps the last 100 lines, oldest pushed out; nil is nowhere", %{log: log} do
      assert LogBuffer.lines(log) == []
      LogBuffer.append(log, "one\n\ntwo\n")
      assert LogBuffer.lines(log) == ["one", "two"]
      LogBuffer.append(log, for(n <- 1..150, do: "line #{n}"))
      assert length(LogBuffer.lines(log)) == 100
      assert hd(LogBuffer.lines(log)) == "line 51"
      assert List.last(LogBuffer.lines(log)) == "line 150"

      assert LogBuffer.append(nil, "x") == :ok
      assert LogBuffer.lines(nil) == []
      assert LogBuffer.recent_files(nil) == []
    end

    test "the files lines named: a .json path last inside parentheses, latest first, each once, five at most", %{log: log} do
      LogBuffer.append(log, [
        "  eval: limit 5s per row (eval.timeout, /t/a/project.json), 15s to boot (eval.boot_timeout, /x/defaults.json)",
        "  running  pass p1  elixir  2s  1 row(s) (not changeable until it ends)",
        "  eval: env stale (/work/flake.nix): changed",
        "config/set  ok  eval.timeout=9000 (eval.timeout, /t/b/project.json)",
        "  eval: limit 9s per row (eval.timeout, /t/a/project.json)"
      ])

      assert LogBuffer.recent_files(log) == ["/t/a/project.json", "/t/b/project.json", "/x/defaults.json"]
      assert LogBuffer.recent_files(log, 2) == ["/t/a/project.json", "/t/b/project.json"]
    end
  end

  describe "a pass's time limits" do
    setup %{ctx: ctx} do
      book =
        Book.new()
        |> Core.put_node("n1", %{module: "M", name: "f", anykey: 1, effect: "pure", effect_source: "user"})
        |> Core.add_call("c1", %{node: "n1", args: ["1"]})

      Process.put(:telling, self())
      opts = [sender: DialogueUpdateTest.TellingSender, launch_opts: [], language: "elixir", project_dir: ctx.project_dir]
      %{book: book, opts: opts, commands: [%{"method" => "eval", "params" => %{"call_ids" => ["c1"]}}]}
    end

    test "are the project's settings, read as the pass starts, and said once with the file each came from",
         %{ctx: ctx, book: book, opts: opts, commands: commands, own: own} do
      {_book, [outcome]} = Runner.run(book, "/nonexistent", commands, opts)
      assert_received {:sent, "c1", text}
      # the built-in 5s, as the Elixir template writes its `after` clause
      assert text =~ "5000 ->"

      defaults = ProjectConfig.defaults_file()
      assert %{"timeout" => %{"ms" => 5000, "key" => "eval.timeout", "file" => ^defaults}} = outcome.result["limits"]
      assert OutcomeText.text([outcome]) =~ "  eval: limit 5s per row (eval.timeout, #{defaults}), 15s to boot (eval.boot_timeout, #{defaults})"

      :ok = ProjectConfig.put(ctx.project_dir, "eval.timeout", "12500")
      {_book, [outcome]} = Runner.run(book, "/nonexistent", commands, opts)
      assert_received {:sent, "c1", text}
      assert text =~ "12500 ->"
      assert OutcomeText.text([outcome]) =~ "  eval: limit 12.5s per row (eval.timeout, #{own}), 15s to boot"
    end

    test "without a project directory nothing is said", %{book: book, opts: opts, commands: commands} do
      {_book, [outcome]} = Runner.run(book, "/nonexistent", commands, Keyword.delete(opts, :project_dir))
      refute Map.has_key?(outcome.result, "limits")
      refute OutcomeText.text([outcome]) =~ "limit"
    end
  end

  describe "config/set" do
    test "writes the open project's file and names it; a wrong value or no project is refused", %{ctx: ctx, own: own} do
      pctx = %{root: "/work/calc", project_dir: ctx.project_dir}
      book = ctx.book

      assert {:ok, ^book, %{"key" => "eval.timeout", "value" => 9000, "file" => ^own} = result} =
               Dispatch.handle(book, "config/set", %{"key" => "eval.timeout", "value" => "9000"}, pctx)

      assert ProjectConfig.load(ctx.project_dir)["eval"]["timeout"] == 9000
      assert OutcomeText.text([%{method: "config/set", ok?: true, result: result, error: nil}]) =~ "config/set  ok  eval.timeout=9000 (eval.timeout, #{own})"

      assert {:error, ^book, %{"code" => "invalid_params", "message" => "config/set: eval.timeout must be" <> _}} =
               Dispatch.handle(book, "config/set", %{"key" => "eval.timeout", "value" => "1"}, pctx)

      assert {:error, ^book, %{"code" => "no_project"}} = Dispatch.handle(book, "config/set", %{"key" => "eval.timeout", "value" => "9000"}, %{})
      assert {:error, ^book, %{"code" => "invalid_params"}} = Dispatch.handle(book, "config/set", %{"key" => "eval.timeout"}, pctx)
    end

    test "is confirmed like a write, though it never changes the Book" do
      assert %{writes: false, confirm: true, args: "key=<setting> value=<value>"} = Methods.get("config/set")
      refute Methods.get("row/list").confirm
    end
  end

  describe "the dialogue" do
    test "nothing named a file yet: the project's own is taken and said; then the key, the value, y", %{ctx: ctx, own: own} do
      assert {:hold, %{file: ^own, key: nil}, text} = Update.start(%{}, ctx)
      lines = String.split(text, "\n")
      assert hd(lines) == "file: #{own}"
      assert "  eval.timeout = 5000  (100..600000 ms)  default" in lines
      assert "  env.path = prepend  (prepend|replace)  default" in lines
      assert List.last(lines) == "key?"

      assert {:hold, %{key: "eval.timeout"}, "eval.timeout? (100..600000 ms)"} = turns(ctx, %{}, ["eval.timeout"])

      assert {:hold, %{inner: inner}, text} = turns(ctx, %{}, ["eval.timeout", "20000"])
      assert inner != nil
      assert text == "written to #{own}\nconfig/set\n  key = eval.timeout\n  value = 20000\nRun it? (y/n)"

      assert {:done, "Running config/set.", [%{"method" => "config/set", "params" => %{"key" => "eval.timeout", "value" => "20000"}}]} =
               turns(ctx, %{}, ["eval.timeout", "20000", "y"])

      assert {:done, "Nothing was run.", []} = turns(ctx, %{}, ["eval.timeout", "20000", "n"])
    end

    test "a wrong key or value says why and asks again", %{ctx: ctx} do
      assert {:hold, %{key: nil}, "no such setting: eval.nope\n" <> _} = turns(ctx, %{}, ["eval.nope"])
      assert {:hold, %{key: "eval.timeout", inner: nil}, text} = turns(ctx, %{}, ["eval.timeout", "soon"])
      assert text =~ "eval.timeout must be a whole number of ms from 100 to 600000"
      assert text =~ "eval.timeout? (100..600000 ms)"
    end

    test "the files named lately are offered numbered, latest first, this project's always among them", %{ctx: ctx, own: own, log: log} do
      defaults = ProjectConfig.defaults_file()
      LogBuffer.append(log, ["  eval: limit 5s per row (eval.timeout, #{defaults}), 15s to boot (eval.boot_timeout, #{defaults})", "config/set  ok  x=1 (x, /t/other/project.json)"])

      assert {:hold, %{file: nil, files: ["/t/other/project.json", ^defaults, ^own]}, text} = Update.start(%{}, ctx)

      assert text ==
               "  1  /t/other/project.json  (not this project's)\n  2  #{defaults}  (the defaults)\n  3  #{own}  (this project's settings)\nfile? (1-3)"

      # another project's can't be changed from here
      assert {:hold, %{file: nil}, "/t/other/project.json is another project's: open that project" <> _} = turns(ctx, %{}, ["1"])
      assert {:hold, %{file: nil}, "9 is not one of them\n" <> _} = turns(ctx, %{}, ["9"])
      assert {:hold, %{file: ^own}, _} = turns(ctx, %{}, ["3"])
      assert {:hold, %{file: ^own}, _} = turns(ctx, %{}, [own])
    end

    test "choosing the defaults says the change goes to this project's file, and it does", %{ctx: ctx, own: own, log: log} do
      defaults = ProjectConfig.defaults_file()
      LogBuffer.append(log, "  eval: limit 5s per row (eval.timeout, #{defaults})")

      assert {:hold, %{file: ^defaults}, text} = turns(ctx, %{}, ["1"])
      assert text =~ "#{defaults} holds the defaults, which are every project's: the change is written to #{own}"

      assert {:done, _, [%{"method" => "config/set"}]} = turns(ctx, %{}, ["1", "eval.boot_timeout", "60000", "y"])
    end

    test "the line may give the file and the key; the value is asked for", %{ctx: ctx, own: own, log: log} do
      LogBuffer.append(log, "  eval: limit 5s per row (eval.timeout, #{ProjectConfig.defaults_file()})")

      assert {:hold, %{file: ^own, key: "eval.timeout"}, "eval.timeout? (100..600000 ms)"} = Update.start(%{"file" => "2", "key" => "eval.timeout"}, ctx)
      assert {:hold, %{file: ^own, key: nil}, _} = Update.start(%{"file" => own}, ctx)
      # a wrong file is asked for, and the key after it is not taken
      assert {:hold, %{file: nil, key: nil}, "7 is not one of them\n" <> _} = Update.start(%{"file" => "7", "key" => "eval.timeout"}, ctx)
    end

    test "without an open project it ends saying so", %{ctx: ctx} do
      assert {:done, "dialogue update: settings are a registered project's" <> _, []} = Update.start(%{}, %{ctx | project_dir: nil})
    end

    test "InOut runs it to the write, with the buffer's file from its opts", %{ctx: ctx, own: own, log: log} do
      opts = [project_dir: ctx.project_dir, log_file: log]
      first = %{"method" => "dialogue/update", "params" => %{"key" => "eval.timeout"}}
      # the key alone on the line: the file is settled first (only one), then the key taken
      {dialogue, book, %{hold: true, text: text}} = InOut.handle(nil, ctx.book, ctx.root, first, opts)
      assert text =~ "eval.timeout? (100..600000 ms)"

      {dialogue, book, %{hold: true}} = InOut.handle(dialogue, book, ctx.root, %{"method" => "dialogue/answer", "params" => %{"text" => "30000"}}, opts)

      {nil, _book, %{hold: false, ok?: true, result: %{"outcomes" => [%{method: "config/set", ok?: true}]}}} =
        InOut.handle(dialogue, book, ctx.root, %{"method" => "dialogue/answer", "params" => %{"text" => "y"}}, opts)

      assert %{"eval" => %{"timeout" => 30000}} = JSON.decode!(File.read!(own))
    end

    test "the window's line: the file and the key may be given, never the value" do
      assert {:commands, [%{"method" => "dialogue/update", "params" => %{}}]} = Input.parse("dialogue update")
      assert {:commands, [%{"method" => "dialogue/update", "params" => %{"file" => "1", "key" => "eval.timeout"}}]} = Input.parse("dialogue update 1 eval.timeout")
      assert {:error, "dialogue update: write dialogue update" <> _} = Input.parse("dialogue update 1 eval.timeout 9000")
    end
  end
end
