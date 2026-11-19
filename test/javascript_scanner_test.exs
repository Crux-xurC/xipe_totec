ExUnit.start()

Code.require_file(Path.expand("../lib/repl/language/javascript.exs", __DIR__))
Code.require_file(Path.expand("../lib/repl/language/typescript.exs", __DIR__))

defmodule JavaScriptScannerTest do
  use ExUnit.Case, async: true

  alias XipeTotec.{Book, Scanner}
  alias XipeTotec.Repl.Language

  @fixture_dir Path.expand("fixtures/js_sample", __DIR__)
  @files ["src/util.js", "src/index.ts", "src/lib/index.js", "src/cjs.js", "src/types.d.ts", "src/wrapped.js"]

  defp file(path), do: %{root: @fixture_dir, path: path, source: File.read!(Path.join(@fixture_dir, path))}

  defp defs(path), do: Scanner.JavaScript.definitions(file(path).source, path)

  describe "declarations" do
    test "JavaScript and TypeScript are map-only: no REPL, the shared scanner" do
      for mod <- [Language.JavaScript, Language.TypeScript] do
        refute Language.evaluated?(mod)
        assert mod.scanner() == [Scanner.JavaScript]
      end

      assert "ts" in Language.TypeScript.extensions()
      assert "mjs" in Language.JavaScript.extensions()
    end
  end

  describe "Scanner.JavaScript" do
    test "module names: the path without its extension" do
      assert Scanner.JavaScript.module_name("src/util.js") == "src/util"
      assert Scanner.JavaScript.module_name("./src/lib/index.js") == "src/lib/index"
    end

    test "definitions: function declarations and functions bound to const; exported ones public" do
      assert Enum.map(defs("src/util.js"), &{&1.name, &1.visibility, &1.span}) ==
               [{"add", "public", 2}, {"hidden", "private", 6}, {"twice", "public", 11}, {"main", "public", 15}]

      # a generic arrow function, exported apart from its definition; a class's method is not a node
      assert Enum.map(defs("src/index.ts"), &{&1.name, &1.visibility}) == [{"run", "public"}, {"typed", "public"}]
      assert Enum.map(defs("src/lib/index.js"), &{&1.name, &1.visibility}) == [{"helper", "public"}]
      assert Enum.map(defs("src/cjs.js"), &{&1.name, &1.visibility}) == [{"useAll", "public"}]
      # a declaration file has no definitions
      assert defs("src/types.d.ts") == []
      assert Enum.all?(defs("src/util.js"), &(&1.module == "src/util" and &1.anykey == nil))
    end

    test "a file wrapped in one function called at once (an IIFE): its body is the top level; what it publishes is public" do
      assert Enum.map(defs("src/wrapped.js"), &{&1.name, &1.visibility, &1.span}) ==
               [{"load", "public", 5}, {"parse", "private", 9}, {"helper", "private", 13}]

      # not a wrapper: two statements at column 0
      assert Scanner.JavaScript.definitions("(function () {\n  function a() {}\n})();\nfunction b() {}\n", "x.js") |> Enum.map(& &1.name) == ["b"]
    end

    test "relative specifiers found on disk: without an extension, .js naming the file, a directory's index; packages are not" do
      assert Scanner.JavaScript.resolve(@fixture_dir, "src/index.ts", "./util") == "src/util"
      assert Scanner.JavaScript.resolve(@fixture_dir, "src/index.ts", "./util.js") == "src/util"
      assert Scanner.JavaScript.resolve(@fixture_dir, "src/cjs.js", "./lib") == "src/lib/index"
      assert Scanner.JavaScript.resolve(@fixture_dir, "src/lib/index.js", "../util") == "src/util"
      assert Scanner.JavaScript.resolve(@fixture_dir, "src/index.ts", "./missing") == nil
      assert Scanner.JavaScript.resolve(@fixture_dir, "src/index.ts", "react") == nil
    end

    test "comments and strings blanked, offsets and lines kept" do
      source = ~s|a("x(y)") // b(c)\n/* d(\ne) */ f(`g${h(i)}`)\n|
      text = Scanner.JavaScript.blank(source)
      refute text =~ "x(y)"
      refute text =~ "b(c)"
      refute text =~ "d("
      refute text =~ "h(i)"
      assert text =~ "f(`"
      assert byte_size(text) == byte_size(source)
      assert length(String.split(text, "\n")) == 4
    end

    test "links: same-module names, named / aliased / default / namespace imports, require; not comments, strings or methods" do
      book =
        Enum.reduce(@files, Book.new(), fn path, book -> elem(Scanner.JavaScript.scan_defs(book, path, file(path)), 0) end)

      ids = for {id, n} <- book.nodes, into: %{}, do: {{n.module, n.name, nil}, id}
      book = Enum.reduce(@files, book, fn path, book -> book |> Scanner.JavaScript.scan_links_report(ids, file(path)) |> elem(0) end)

      edges =
        for({_, l} <- book.links, do: {Book.get(book, :nodes, l.node).name, Book.get(book, :nodes, l.ref).name})
        |> Enum.sort()

      assert edges == [
               {"hidden", "add"},
               {"main", "hidden"},
               {"main", "twice"},
               {"run", "add"},
               {"run", "main"},
               {"run", "twice"},
               {"twice", "add"},
               {"typed", "twice"},
               {"useAll", "add"},
               {"useAll", "helper"},
               # inside the wrapper
               {"helper", "load"},
               {"load", "parse"}
             ] |> Enum.sort()
    end
  end
end
