ExUnit.start()

Code.require_file(Path.expand("../lib/scanner/java.exs", __DIR__))

# Scanner.Java on a canned answer of scan.java (no JDK needed); the real parse is in test/live/repl_java_test.exs
defmodule ScannerJavaTest do
  use ExUnit.Case, async: true

  alias XipeTotec.{Book, Scanner}

  defp def_(module, name, anykey, refs, opts \\ []) do
    %{
      "module_" => module,
      "name" => name,
      "anykey" => anykey,
      "shape" => [Keyword.get(opts, :shape, Scanner.Java.key_arity(anykey))],
      "public" => Keyword.get(opts, :public, true),
      "line" => 1,
      "hash" => "h",
      "async" => Keyword.get(opts, :async, false),
      "varargs" => Keyword.get(opts, :varargs, false),
      "unbound" => Keyword.get(opts, :unbound, []),
      "scopes" => Keyword.get(opts, :scopes, [module]),
      "package" => Keyword.get(opts, :package, "sample"),
      "imports" => Keyword.get(opts, :imports, []),
      "wildcards" => Keyword.get(opts, :wildcards, []),
      "statics" => Keyword.get(opts, :statics, []),
      "refs" => Enum.map(refs, fn {n, c} -> %{"name" => n, "argc" => c} end)
    }
  end

  defp answer do
    %{
      "src/main/java/sample/Calc.java" => %{
        "path" => "src/main/java/sample/Calc.java",
        "error" => nil,
        "defs" => [
          def_("sample.Calc", "add", "(int, int)", []),
          def_("sample.Calc", "add", "(int, int, int)", [{"add", 2}, {"add", 2}]),
          def_("sample.Calc", "over", "(int)", []),
          def_("sample.Calc", "over", "(String)", []),
          def_("sample.Calc", "over", "(Map<String, Integer>, int)", []),
          def_("sample.Calc", "sum", "(int...)", [], varargs: true),
          def_("sample.Calc", "later", "(int)", [{"CompletableFuture.supplyAsync", 1}], async: true),
          def_("sample.Calc", "make", "()", [], unbound: ["T"]),
          def_("sample.Calc", "use", "()", [{"over", 1}, {"this.sum", 3}, {"list.add", 1}]),
          def_("sample.Calc", "step", "(int)", [], public: false)
        ]
      },
      "src/main/java/sample/geo/Shapes.java" => %{
        "path" => "src/main/java/sample/geo/Shapes.java",
        "error" => nil,
        "defs" => [
          def_("sample.geo.Shapes", "twiceAdd", "(int)", [{"add", 2}],
            package: "sample.geo",
            statics: ["sample.Calc.add"]
          ),
          def_("sample.geo.Shapes", "describe", "(Point)", [{"Inner.label", 1}, {"sample.Calc.sum", 1}, {"Ops.triple", 1}],
            package: "sample.geo",
            imports: ["sample.Point"],
            wildcards: ["sample"]
          ),
          def_("sample.geo.Shapes.Inner", "label", "(Point)", [], package: "sample.geo", scopes: ["sample.geo.Shapes.Inner", "sample.geo.Shapes"])
        ]
      },
      "src/main/java/sample/Ops.java" => %{
        "path" => "src/main/java/sample/Ops.java",
        "error" => nil,
        "defs" => [def_("sample.Ops", "triple", "(int)", [{"Calc.add", 2}])]
      },
      "Bad.java" => %{"path" => "Bad.java", "error" => "Bad.java:1: class, interface, enum, or record expected", "defs" => []}
    }
  end

  @paths ["src/main/java/sample/Calc.java", "src/main/java/sample/geo/Shapes.java", "src/main/java/sample/Ops.java"]

  defp file(path), do: %{root: "/p", path: path, source: "", ctx: %{files: answer()}}

  test "definitions: anykey the parameters' types, the shape, visibility; a file that did not parse raises its error" do
    defs = Scanner.Java.defs(file("src/main/java/sample/Calc.java"))
    assert %{module: "sample.Calc", anykey: "(int, int)", shape: [2], visibility: "public"} = hd(defs)
    assert %{visibility: "private"} = Enum.find(defs, &(&1.name == "step"))
    assert_raise RuntimeError, "Bad.java:1: class, interface, enum, or record expected", fn -> Scanner.Java.defs(file("Bad.java")) end
  end

  test "marks: async, varargs, typed for overloads sharing a count; a refusal for a type parameter in no parameter" do
    defs = Map.new(Scanner.Java.defs(file("src/main/java/sample/Calc.java")), &{{&1.name, &1.anykey}, &1})
    assert defs[{"later", "(int)"}].marks == ["async"]
    assert defs[{"sum", "(int...)"}].marks == ["varargs"]
    assert defs[{"over", "(int)"}].marks == ["typed"]
    assert defs[{"over", "(String)"}].marks == ["typed"]
    # another count: not typed
    assert defs[{"over", "(Map<String, Integer>, int)"}].marks == []
    assert defs[{"add", "(int, int)"}].marks == []
    assert defs[{"make", "()"}].refusal =~ "its type parameter T appears in no parameter"
    assert defs[{"add", "(int, int)"}].refusal == nil

    {book, _} = Scanner.Java.scan_defs(Book.new(), "src/main/java/sample/Calc.java", file("src/main/java/sample/Calc.java"))
    assert %{marks: ["async"], shape: [1]} = Enum.find(Map.values(book.nodes), &(&1.name == "later"))
  end

  test "key_arity: top-level commas, generics nested" do
    assert Scanner.Java.key_arity("()") == 0
    assert Scanner.Java.key_arity("(int...)") == 1
    assert Scanner.Java.key_arity("(Map<String, List<Integer>>, int)") == 2
  end

  test "links: the enclosing type, this., static imports, nested types, the package, imports, on-demand imports; overloads by count" do
    book = Enum.reduce(@paths, Book.new(), fn path, book -> elem(Scanner.Java.scan_defs(book, path, file(path)), 0) end)
    ids = for {id, n} <- book.nodes, into: %{}, do: {{n.module, n.name, n.anykey}, id}
    book = Enum.reduce(@paths, book, fn path, book -> book |> Scanner.Java.scan_links_report(ids, file(path)) |> elem(0) end)

    edges =
      for {_, l} <- book.links do
        n = Book.get(book, :nodes, l.node)
        r = Book.get(book, :nodes, l.ref)
        {"#{n.name}#{n.anykey}", "#{r.module}.#{r.name}#{r.anykey}"}
      end
      |> Enum.sort()

    assert edges ==
             Enum.sort([
               # add(add(a, b), c): the two-argument overload
               {"add(int, int, int)", "sample.Calc.add(int, int)"},
               # over(x): every overload of that count; this.sum(1, 2, 3): no overload of 3, so every one of the name
               {"use()", "sample.Calc.over(int)"},
               {"use()", "sample.Calc.over(String)"},
               {"use()", "sample.Calc.sum(int...)"},
               # import static sample.Calc.add
               {"twiceAdd(int)", "sample.Calc.add(int, int)"},
               # a nested type of the enclosing one; a fully qualified call; an on-demand import (sample.*)
               {"describe(Point)", "sample.geo.Shapes.Inner.label(Point)"},
               {"describe(Point)", "sample.Calc.sum(int...)"},
               {"describe(Point)", "sample.Ops.triple(int)"},
               # Calc from sample.Ops: the same package
               {"triple(int)", "sample.Calc.add(int, int)"}
             ])
  end
end
