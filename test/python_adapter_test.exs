ExUnit.start()

Code.require_file(Path.expand("../lib/repl/language/python.exs", __DIR__))

defmodule PythonAdapterTest do
  use ExUnit.Case, async: true

  alias XipeTotec.{Book, Scanner}
  alias XipeTotec.Repl.Language.Python
  alias XipeTotec.Repl.Python.{EvalTemplate, Launch}

  @fixture_dir Path.expand("fixtures/python_sample", __DIR__)
  @files ["target.py", "src/geo/__init__.py", "src/geo/shape.py", "src/geo/units.py"]

  describe "EvalTemplate" do
    test "one line: embody.py's run with the id, the binding, the time, the module and the call as a string" do
      entry = %{call_id: "c1", module: "geo.shape", name: "area", args: ["1", "xt_c0"], limits: %{timeout: 5000, max_heap_words: 1}}

      assert EvalTemplate.build(entry) ==
               ~s|_xt_embody.run("c1", "xt_c1", 5000, "geo.shape", "geo.shape.area((1), (xt_c0))", None)\n|
    end

    test "arguments in parentheses, none is an empty call; quotes and newlines escaped; both bases" do
      assert EvalTemplate.call_expression(%{module: "m", name: "f", args: []}) == "m.f()"
      assert EvalTemplate.call_expression(%{module: "m", name: "f", args: ["-1", "(1, 2)"]}) == "m.f((-1), ((1, 2)))"

      base = %{call_id: "c-1", module: "m", name: "s", args: [~s|"a\\"b"|, "[1,\n2]"], limits: %{timeout: 10, max_heap_words: 1}}
      text = EvalTemplate.build(base)
      assert text =~ ~s|"xt_c_1"|
      assert text =~ ~s|"m.s((\\"a\\\\\\"b\\"), ([1,\\n2]))"|
      assert length(String.split(text, "\n", trim: true)) == 1
      assert EvalTemplate.build(Map.put(base, :basis, {:exact, ~s|"x"|})) =~ ~s|("exact", "\\"x\\""))\n|
      assert EvalTemplate.build(Map.put(base, :basis, {:binary, "AA=="})) =~ ~s|("binary", "AA=="))\n|
    end
  end

  describe "Launch" do
    test "python -i -q -u with the init file; no bytecode written; no banner, a probe, quit()" do
      message = Launch.build(cwd: "/p", init: "/tmp/init.py", argv: ["/p/.venv/bin/python"])
      assert message["argv"] == ~w(/p/.venv/bin/python -i -q -u /tmp/init.py)
      assert message["env"] == %{"PYTHONDONTWRITEBYTECODE" => "1"}
      assert %{"files" => [], "ready_pattern" => nil, "exit_input" => "quit()\n", "interruptible" => true} = message
      assert message["ready_probe"] == ~s|print("XT_" + "READY")\n|
    end

    test "the init file imports embody from its directory and installs the project's modules" do
      text = Launch.init_file([{"geo.shape", "/p/src/geo/shape.py"}, {"t", ~s|/p/"q".py|}])
      assert text =~ ~s|sys.path.insert(0, "#{Launch.embody_dir()}")|
      assert text =~ "import embody as _xt_embody\ndel sys.path[0]\n"
      assert text =~ ~s|_xt_embody.install({"geo.shape": "/p/src/geo/shape.py", "t": "/p/\\"q\\".py"})|
    end
  end

  describe "Language" do
    test "py files; build tools by their lock files; one adapter" do
      assert Python.extensions() == ["py"]
      assert Python.repl() == "python"
      assert Enum.map(Python.build_tools(), & &1["name"]) == ~w(uv poetry pip)
      assert Python.scanner() == [Scanner.Python]
      assert Python.adapter().launch == Launch
    end

    test "the modules: the src layout left out, packages by their __init__.py, one file per name" do
      assert Python.modules(@fixture_dir, @files ++ ["geo/units.py"]) == [
               {"target", Path.join(@fixture_dir, "target.py")},
               {"geo", Path.join(@fixture_dir, "src/geo/__init__.py")},
               {"geo.shape", Path.join(@fixture_dir, "src/geo/shape.py")},
               {"geo.units", Path.join(@fixture_dir, "src/geo/units.py")}
             ]
    end

    test "launch_opts: python3 without a .venv, an init file removed by the cleanup" do
      {opts, cleanup} = Python.launch_opts(@fixture_dir, nil, @files)
      assert opts[:argv] == ["python3"]
      assert File.read!(opts[:init]) =~ ~s|"geo.units": "#{Path.join(@fixture_dir, "src/geo/units.py")}"|
      cleanup.()
      refute File.exists?(opts[:init])
    end
  end

  describe "Scanner.Python" do
    defp file(path), do: %{root: @fixture_dir, path: path, source: File.read!(Path.join(@fixture_dir, path))}

    test "module names from paths" do
      assert Scanner.Python.module_name(@fixture_dir, "target.py") == "target"
      assert Scanner.Python.module_name(@fixture_dir, "src/geo/shape.py") == "geo.shape"
      assert Scanner.Python.module_name(@fixture_dir, "src/geo/__init__.py") == "geo"
      assert Scanner.Python.module_name("/nowhere", "pkg/sub/__init__.py") == "pkg.sub"
      assert Scanner.Python.module_name("/nowhere", "./a.py") == "a"
    end

    test "top-level functions only: not methods, classes, comments or strings; every node public" do
      defs = Scanner.Python.definitions(file("target.py").source, "target")

      assert Enum.map(defs, & &1.name) ==
               ~w(add square _hidden later boom spin cyc lam naturals floaty multi point)

      assert Enum.all?(defs, &(&1.module == "target" and &1.anykey == nil and &1.visibility == "public"))
      # a def over several lines is one block, its body included
      multi = Enum.find(defs, &(&1.name == "multi"))
      assert multi.text =~ "return [a, b]"
      assert %{span: 12} = Enum.find(defs, &(&1.name == "add"))
    end

    test "comments and strings blanked, lines kept" do
      text = Scanner.Python.blank(~s|x = "a(b)" # c(d)\ny = '''e(\nf)''' + r'\\'' + g(h)\n|)
      refute text =~ "a(b)"
      refute text =~ "c(d)"
      refute text =~ "e("
      assert text =~ "g(h)"
      assert length(String.split(text, "\n")) == 4
    end

    test "links: same-module names, from-imports (aliased, relative) and module.attribute calls" do
      book = Book.new()

      {book, ids} =
        Enum.reduce(@files, {book, %{}}, fn path, {book, ids} ->
          {book, more} = Scanner.Python.scan_defs(book, path, file(path))
          {book, Map.merge(ids, more)}
        end)

      book = Enum.reduce(@files, book, fn path, book -> book |> Scanner.Python.scan_links_report(ids, file(path)) |> elem(0) end)

      edges =
        for({_, l} <- book.links, do: {Book.get(book, :nodes, l.node).name, Book.get(book, :nodes, l.ref).name})
        |> Enum.sort()

      # square calls add (not the comment, not the string); a method's call
      # (Point.moved -> square) is no node's; area -> scale (relative import);
      # grow -> add (aliased as plus), square (target.square), scale
      assert edges == [{"area", "scale"}, {"grow", "add"}, {"grow", "scale"}, {"grow", "square"}, {"square", "add"}]
    end
  end
end
