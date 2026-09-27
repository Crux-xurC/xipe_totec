ExUnit.start()

Code.require_file(Path.expand("../lib/repl/language/ocaml.exs", __DIR__))

defmodule OcamlAdapterTest do
  # not async: one test sets XIPE_TOTEC_EMBODY_DIR, which the others read
  use ExUnit.Case

  alias XipeTotec.{Book, Scanner}
  alias XipeTotec.Repl.Language.Ocaml
  alias XipeTotec.Repl.Ocaml.{EvalTemplate, Launch}

  @fixture_dir Path.expand("fixtures/ocaml_sample", __DIR__)

  describe "EvalTemplate" do
    test "one complete Embody.run phrase per entry, the call inside a string" do
      entry = %{call_id: "c1", module: "Geometry", name: "add", args: ["1", "xt_c0"], limits: %{timeout: 5000, max_heap_words: 1}}

      assert EvalTemplate.build(entry) ==
               ~s|Embody.run "c1" "xt_c1" 5000 "let xt_c1 = Geometry.add (1) (xt_c0);;" None;;\n|
    end

    test "arguments in parentheses; none is the value itself" do
      assert EvalTemplate.call_expression(%{module: "M", name: "f", args: ["-1", "Some 2"]}) == "M.f (-1) (Some 2)"
      assert EvalTemplate.call_expression(%{module: "M", name: "origin", args: []}) == "M.origin"
    end

    test "an exact previous value is compared; a binary one isn't; quotes and newlines stay inside the string" do
      base = %{call_id: "c-1", module: "M", name: "s", args: [~s|"a\\"b"|], limits: %{timeout: 10, max_heap_words: 1}}

      assert EvalTemplate.build(Map.put(base, :basis, {:exact, ~s|"x\ny"|})) ==
               ~s|Embody.run "c-1" "xt_c_1" 10 "let xt_c_1 = M.s (\\"a\\\\\\"b\\");;" (Some "\\"x\\ny\\"");;\n|

      assert EvalTemplate.build(Map.put(base, :basis, {:binary, "AAA="})) =~ ~r/ None;;\n$/
    end
  end

  describe "Launch" do
    test "ocaml -init <file>; no banner, a probe, #quit;;, interruptible, no -r files" do
      message = Launch.build(cwd: "/p", init: "/tmp/i.ml")

      assert %{
               "argv" => ["ocaml", "-init", "/tmp/i.ml"],
               "cwd" => "/p",
               "files" => [],
               "ready_pattern" => nil,
               "ready_probe" => ~s|print_endline ("XT_" ^ "READY");;\n|,
               "exit_input" => "#quit;;\n",
               "interruptible" => true
             } = message
    end

    test "the init file loads embody, then every file through it" do
      text = Launch.init_file("/tmp/d/src", ["/p/a.ml", "/p/b.ml"])
      assert text =~ ~s|#load "unix.cma";;|
      assert text =~ ~s|#mod_use #{Launch.string(Launch.embody_path())};;|
      assert text =~ ~s|Embody.load_all ~aliases:[] "/tmp/d/src" ["/p/a.ml"; "/p/b.ml"];;|
      refute text =~ "dune_deps"
      assert File.exists?(Launch.embody_path())
    end

    test "embody.ml comes from ~/my_app/embody (its own repository), or $XIPE_TOTEC_EMBODY_DIR" do
      assert Launch.embody_path() == Path.expand("../../embody/embody.ml", __DIR__)
      System.put_env("XIPE_TOTEC_EMBODY_DIR", "/elsewhere")

      try do
        assert Launch.embody_path() == "/elsewhere/embody.ml"
      after
        System.delete_env("XIPE_TOTEC_EMBODY_DIR")
      end
    end

    test "a dune project: its dependencies first, then the files with the library aliases" do
      text = Launch.init_file("/tmp/d/src", ["/p/lib/a.ml"], dune_root: "/p", aliases: [{"Mylib", ["A", "B"]}])
      assert text =~ ~s|Embody.dune_deps "/p";;\nEmbody.load_all ~aliases:[("Mylib", ["A"; "B"])] "/tmp/d/src" ["/p/lib/a.ml"];;|
    end
  end

  test "Language: .ml, the ocaml REPL, dune by its marker; launch_opts writes the init file and cleans up" do
    assert Ocaml.extensions() == ["ml"]
    assert Ocaml.repl() == "ocaml"
    assert [%{"name" => "dune", "markers" => ["dune-project"]}] = Ocaml.build_tools()

    {[init: init], cleanup} = Ocaml.launch_opts(@fixture_dir, nil, ["area.ml", "geometry.ml"])
    assert File.read!(init) =~ Path.join(@fixture_dir, "geometry.ml")
    cleanup.()
    refute File.exists?(Path.dirname(init))
  end

  describe "dune" do
    @dune_dir Path.expand("fixtures/ocaml_dune", __DIR__)
    @dune_files ["bin/main.ml", "lib/stats.ml", "lib/words.ml"]

    test "a wrapped library's alias from its dune file; an executable has none" do
      assert Ocaml.dune_aliases(@dune_dir, @dune_files) == [{"Mylib", ["Stats", "Words"]}]
    end

    test "no alias for (wrapped false), a library with its own main module, or several libraries in one file" do
      dir = Path.join(System.tmp_dir!(), "xipe_totec_dune_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)

      for {sub, dune, files} <- [
            {"a", "(library (name a) (wrapped false))", ["x.ml"]},
            {"b", "(library (name b))", ["b.ml", "y.ml"]},
            {"c", "(library (name c) (modules x)) (library (name d) (modules y))", ["x.ml", "y.ml"]}
          ] do
        File.mkdir_p!(Path.join(dir, sub))
        File.write!(Path.join([dir, sub, "dune"]), dune)
        assert Ocaml.dune_aliases(dir, Enum.map(files, &Path.join(sub, &1))) == [], sub
      end
    end

    test "launch_opts with dune: the project's dependencies and the aliases go into the init file" do
      {[init: init], cleanup} = Ocaml.launch_opts(@dune_dir, "dune", @dune_files)
      text = File.read!(init)
      cleanup.()
      assert text =~ ~s|Embody.dune_deps #{Launch.string(@dune_dir)};;|
      assert text =~ ~s|~aliases:[("Mylib", ["Stats"; "Words"])]|
    end
  end

  describe "Scanner.Ocaml" do
    defp file(name), do: %{root: @fixture_dir, path: name, source: File.read!(Path.join(@fixture_dir, name))}

    test "top-level value definitions only: not effects, types, comments or strings" do
      names = Scanner.Ocaml.definitions("geometry.ml", file("geometry.ml").source) |> Enum.map(& &1.name)
      assert names == ~w(pi area shapes origin add square adder spin first label)
    end

    test "a file is the module its name gives; the last of a redefined name is the node" do
      assert Scanner.Ocaml.module_name("lib/my_mod.ml") == "My_mod"
      defs = Scanner.Ocaml.definitions("x.ml", "let f = 1\nlet g = 2\nlet f = 3\n")
      assert [%{name: "g", span: 2}, %{name: "f", span: 3}] = defs
      assert Enum.all?(defs, &(&1.module == "X" and &1.anykey == nil and &1.visibility == "public"))
    end

    test "`and` continues a let, not a type" do
      source = "type a = A\nand b = B\nlet rec even n = n = 0 || odd (n - 1)\nand odd n = n <> 0 && even (n - 1)\n"
      assert ~w(even odd) == Scanner.Ocaml.definitions("x.ml", source) |> Enum.map(& &1.name)
    end

    test "blank keeps lines and code, removes comments (nested), strings and char literals" do
      source = "let a = \"(* x *)\" (* c (* d *) e *)\nlet b = '\"' ^ 'x'\n"
      blanked = Scanner.Ocaml.blank(source)
      assert String.length(blanked) == String.length(source)
      assert String.split(blanked, "\n") |> length() == 3
      refute blanked =~ "x"
      assert blanked =~ "let a = \""
      assert blanked =~ "let b ="
    end

    test "two passes over the project: nodes, then links within and across files" do
      book = Book.new()
      {book, ids_a} = Scanner.Ocaml.scan_defs(book, "sa", file("area.ml"))
      {book, ids_g} = Scanner.Ocaml.scan_defs(book, "sg", file("geometry.ml"))
      ids = Map.merge(ids_a, ids_g)

      {book, []} = Scanner.Ocaml.scan_links_report(book, ids, file("area.ml"))
      {book, []} = Scanner.Ocaml.scan_links_report(book, ids, file("geometry.ml"))

      edges =
        for {_, l} <- book.links do
          {Book.get(book, :nodes, l.node).name, Book.get(book, :nodes, l.ref).name}
        end
        |> Enum.sort()

      # spin calls itself: no self link
      assert edges == [{"adder", "add"}, {"area", "pi"}, {"of_shape", "area"}, {"square", "add"}, {"total", "of_shape"}]
    end
  end
end
