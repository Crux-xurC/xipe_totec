ExUnit.start()

Code.require_file(Path.expand("../lib/repl/language/haskell.exs", __DIR__))

defmodule HaskellAdapterTest do
  use ExUnit.Case, async: true

  alias XipeTotec.{Book, Scanner}
  alias XipeTotec.Repl.Language.Haskell
  alias XipeTotec.Repl.Haskell.{EvalTemplate, Launch}

  @fixture_dir Path.expand("fixtures/haskell_sample", __DIR__)
  @files ["Target.hs", "app/Main.hs", "src/Geo/Shape.hs"]

  describe "EvalTemplate" do
    test "six GHCi lines: the call and every step bound with let, then one run" do
      entry = %{call_id: "c1", module: "Target", name: "add", args: ["1", "xt_c0"], limits: %{timeout: 5000, max_heap_words: 1}}

      assert EvalTemplate.build(entry) == """
             let xt_c1 = Target.add (1) (xt_c0)
             let xt_c1_w = Embody.whnf xt_c1
             let xt_c1_x = Embody.exact Nothing xt_c1
             let xt_c1_s = Embody.shown xt_c1
             let xt_c1_t = Embody.typed xt_c1
             Embody.run "c1" 5000000 xt_c1_w xt_c1_x xt_c1_s xt_c1_t
             """
    end

    test "arguments in parentheses, none is the value; an exact previous value is compared; one line per let" do
      assert EvalTemplate.call_expression(%{module: "M.N", name: "f", args: ["-1", "Just 2"]}) == "M.N.f (-1) (Just 2)"
      assert EvalTemplate.call_expression(%{module: "M", name: "nats", args: []}) == "M.nats"

      base = %{call_id: "c-1", module: "M", name: "s", args: [~s|"a\\"b"|, "[1,\n2]"], limits: %{timeout: 10, max_heap_words: 1}}
      text = EvalTemplate.build(Map.put(base, :basis, {:exact, ~s|"x"|}))
      assert text =~ ~s|let xt_c_1 = M.s ("a\\"b") ([1, 2])\n|
      assert text =~ ~s|let xt_c_1_x = Embody.exact (Just "\\"x\\"") xt_c_1\n|
      assert length(String.split(text, "\n", trim: true)) == 6
      assert EvalTemplate.build(Map.put(base, :basis, {:binary, "AA=="})) =~ "Embody.exact Nothing"
    end
  end

  describe "Launch" do
    test "ghci -v0 with deferred type errors, the search path and the script; no banner, a probe, :quit" do
      message = Launch.build(cwd: "/p", script: "/tmp/l.ghci", include: ["/p/src", "/p"])

      assert message["argv"] ==
               ~w(ghci -v0 -w -fdefer-type-errors -Wno-deferred-type-errors -Wno-deferred-out-of-scope-variables -i/p/src -i/p -ghci-script /tmp/l.ghci)

      assert %{"files" => [], "ready_pattern" => nil, "exit_input" => ":quit\n", "interruptible" => true} = message
      assert message["ready_probe"] == ~s|putStrLn ("XT_" ++ "READY")\n|
    end

    test "the script loads embody.hs with the files, then every module as *M" do
      script = Launch.script(["/p/A.hs", "/p/my dir/B.hs"], ["A", "B.C"])
      assert script == ":load #{Launch.embody_path()} /p/A.hs \"/p/my dir/B.hs\"\n:module + *A *B.C\n"
      assert File.exists?(Launch.embody_path())
    end
  end

  test "Language: .hs, ghci, stack before cabal" do
    assert Haskell.extensions() == ["hs"]
    assert Haskell.repl() == "ghci"
    assert ["stack", "cabal"] == Enum.map(Haskell.build_tools(), & &1["name"])
  end

  describe "launch_opts" do
    test "each file's module and source root; the script and the search path" do
      assert [
               %{path: "Target.hs", module: "Target", source_root: "."},
               %{path: "app/Main.hs", module: "Main", source_root: "app"},
               %{path: "src/Geo/Shape.hs", module: "Geo.Shape", source_root: "src"}
             ] = Haskell.load_plan(@fixture_dir, @files)

      {[argv: ["ghci"], script: script, include: include], cleanup} = Haskell.launch_opts(@fixture_dir, nil, @files)
      text = File.read!(script)
      cleanup.()
      refute File.exists?(script)
      assert text =~ Path.join(@fixture_dir, "src/Geo/Shape.hs")
      assert text =~ ":module + *Target *Main *Geo.Shape"
      assert include == Enum.map([".", "app", "src"], &Path.expand(&1, @fixture_dir))
    end

    test "the build tool only changes how GHCi is started: under cabal exec (offline) or stack exec" do
      cabal = ["sh", "-c", ~s|cabal build --offline all > /dev/null 2>&1; exec "$@"|, "sh"] ++ ~w(cabal exec --offline -- ghci)

      for {tool, argv} <- [{"cabal", cabal}, {"stack", ~w(stack exec -- ghci)}, {nil, ["ghci"]}] do
        {opts, cleanup} = Haskell.launch_opts(@fixture_dir, tool, @files)
        cleanup.()
        assert opts[:argv] == argv
        assert hd(Launch.build([{:cwd, "/p"} | opts])["argv"] |> Enum.take(-2)) == "-ghci-script"
        assert Enum.take(Launch.build([{:cwd, "/p"} | opts])["argv"], length(argv)) == argv
      end
    end

    test "several Main modules can't load together: none of them is loaded" do
      dir = Path.join(System.tmp_dir!(), "xipe_totec_hs_mains_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      File.write!(Path.join(dir, "a.hs"), "main = pure ()\n")
      File.write!(Path.join(dir, "b.hs"), "module Main where\nmain = pure ()\n")
      File.write!(Path.join(dir, "Lib.hs"), "module Lib where\nx = 1\n")
      assert [%{module: "Lib"}] = Haskell.load_plan(dir, ["Lib.hs", "a.hs", "b.hs"])
    end
  end

  describe "Scanner.Haskell" do
    defp file(path), do: %{root: @fixture_dir, path: path, source: File.read!(Path.join(@fixture_dir, path))}

    test "top-level definitions: not signatures, declarations, comments or strings; every node public" do
      defs = Scanner.Haskell.definitions(file("Target.hs").source)

      assert Enum.map(defs, & &1.name) ==
               ~w(add square hidden nats area shapes table adder spin first opaque label)

      assert Enum.all?(defs, &(&1.module == "Target" and &1.anykey == nil and &1.visibility == "public"))
      # two clauses, one definition, at the first
      assert %{span: 23} = Enum.find(defs, &(&1.name == "area"))
    end

    test "the module is the header's, else Main" do
      assert Scanner.Haskell.module_name("{- m -}\nmodule Geo.Shape (x) where\n") == "Geo.Shape"
      assert Scanner.Haskell.module_name("main = print 1\n") == "Main"
    end

    test "guards, where, operators and signatures" do
      source = """
      module M where
      f, g :: Int -> Int
      f x
        | x > 0 = g x
        | otherwise = 0
      g x = x where y = 1
      (<+>) a b = a
      x <.> y = x
      h :: Int
      h = 1 == 1 `seq` 2
      """

      assert ~w(f g h) == Enum.map(Scanner.Haskell.definitions(source), & &1.name)
    end

    test "blank: comments (nested, and -- not in an operator), strings, char literals; primes stay" do
      source = "f' x = '\"' : \"a -- b\" {- c {- d -} e -} ++ x --> y -- note\n"
      blanked = Scanner.Haskell.blank(source)
      assert String.length(blanked) == String.length(source)
      assert blanked =~ "f' x = "
      assert blanked =~ "x --> y"
      refute blanked =~ "note"
      refute blanked =~ ~r/[bcde]/
    end

    test "two passes: links within a module, through an alias, and through an unqualified import" do
      book = Book.new()

      {book, ids} =
        Enum.reduce(@files, {book, %{}}, fn path, {book, ids} ->
          {book, more} = Scanner.Haskell.scan_defs(book, path, file(path))
          {book, Map.merge(ids, more)}
        end)

      book = Enum.reduce(@files, book, fn path, book -> book |> Scanner.Haskell.scan_links_report(ids, file(path)) |> elem(0) end)

      edges =
        for({_, l} <- book.links, do: {Book.get(book, :nodes, l.node).name, Book.get(book, :nodes, l.ref).name})
        |> Enum.sort()

      # spin calls itself (no self link); square's comment names spin (no link)
      assert edges == [{"adder", "add"}, {"greet", "perimeter"}, {"perimeter", "add"}, {"square", "add"}, {"total", "area"}]
    end
  end
end
