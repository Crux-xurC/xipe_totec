ExUnit.start()

Code.require_file(Path.expand("../lib/scanner/csharp.exs", __DIR__))

defmodule ScannerCSharpTest do
  use ExUnit.Case, async: true

  alias XipeTotec.{Book, Scanner}

  @fixture_dir Path.expand("fixtures/csharp_sample", __DIR__)
  @files ["src/Calc.cs", "src/Calls.cs", "src/Edge.cs", "src/Geo/Shapes.cs"]

  defp file(path), do: %{root: @fixture_dir, path: path, source: File.read!(Path.join(@fixture_dir, path))}
  defp defs(path), do: Scanner.CSharp.definitions(file(path).source, path)

  describe "Scanner.CSharp" do
    test "definitions: every method, module = namespace + types, anykey = the parameters' types; public only for public static of public types" do
      assert Enum.map(defs("src/Calc.cs"), &{&1.module, &1.name, &1.anykey, &1.visibility, &1.span}) == [
               {"Sample.Calc", "Add", "(int, int)", "public", 16},
               {"Sample.Calc", "Add", "(int, int, int)", "public", 18},
               {"Sample.Calc", "Half", "(double)", "public", 20},
               {"Sample.Calc", "Range", "(int)", "public", 22},
               {"Sample.Calc", "RangeList", "(int)", "public", 29},
               {"Sample.Calc", "Pair", "(int)", "public", 31},
               {"Sample.Calc", "Counts", "(string)", "public", 33},
               {"Sample.Calc", "Greet", "(string)", "public", 40},
               {"Sample.Calc", "Maybe", "(bool)", "public", 42},
               {"Sample.Calc", "UnitArea", "()", "public", 44},
               {"Sample.Calc", "Boom", "(int)", "public", 46},
               {"Sample.Calc", "Spin", "()", "public", 48},
               {"Sample.Calc", "Adder", "(int)", "public", 50},
               # internal, private, an instance method
               {"Sample.Calc", "Hidden", "(int)", "private", 52},
               {"Sample.Calc", "Secret", "(int)", "private", 54},
               {"Sample.Counter", "Step", "(int)", "private", 62},
               {"Sample.Counter", "Bump", "(int)", "private", 64}
             ]

      # a file-scoped namespace, a nested type, a generic type (its static method too), records and an enum without methods;
      # braces inside strings (verbatim, raw, interpolated) and comments do not count
      assert Enum.map(defs("src/Geo/Shapes.cs"), &{&1.module, &1.name, &1.anykey, &1.visibility}) == [
               {"Sample.Geo.Shapes", "Mid", "(Point, Point)", "public"},
               {"Sample.Geo.Shapes", "Area", "(Circle)", "public"},
               {"Sample.Geo.Shapes", "Next", "(Color)", "public"},
               {"Sample.Geo.Shapes", "Describe", "(Point)", "public"},
               {"Sample.Geo.Shapes.Inner", "Label", "(Point)", "public"},
               {"Sample.Geo.Box", "Of", "(T)", "private"},
               {"Sample.Geo.Box", "Get", "()", "private"}
             ]
    end

    test "overloads of one count, async, generics, out, optional and params: anykey, the shape, marks, a refusal" do
      got = for d <- defs("src/Calls.cs"), do: {d.name, d.anykey, d.shape, d.marks, d.refusal != nil}

      assert got == [
               # overloads sharing a count: each a node of its own
               {"Over", "(int)", [1], ["typed"], false},
               {"Over", "(string)", [1], ["typed"], false},
               {"Over", "(double)", [1], ["typed"], false},
               {"Wide", "(long)", [1], [], false},
               # Task<T>, Task, ValueTask<T>: awaited
               {"LaterAsync", "(int)", [1], ["async"], false},
               {"Done", "()", [0], ["async"], false},
               {"Soon", "(string)", [1], ["async"], false},
               # a type parameter inferred from a parameter: callable; one in no parameter: refused
               {"Id", "(T)", [1], [], false},
               {"Twice", "(T)", [1], [], false},
               {"Make", "()", [0], [], true},
               # out: in anykey, not in the shape; an optional parameter counted; params one
               {"Out", "(int, out int)", [1], [], false},
               {"Opt", "(int, int)", [2], [], false},
               {"Params", "(params int[])", [1], [], false},
               {"Use", "()", [0], [], false},
               {"Fill", "(string, int)", [2], [], false},
               {"Mark", "(string)", [1], [], false},
               {"Anon", "(int)", [1], [], false}
             ]

      make = Enum.find(defs("src/Calls.cs"), &(&1.name == "Make"))
      assert make.refusal =~ "type parameter T appears in no parameter"
    end

    test "parameters: written out in one form; tuple names, attributes, this and defaults left out" do
      texts = &Enum.map(Scanner.CSharp.parameters(&1), fn p -> p.text end)
      assert texts.("List< int > xs, Dictionary<string,List<int>> d") == ["List<int>", "Dictionary<string, List<int>>"]
      assert texts.("(int a, string b) p, out int r, ref double x, in Point q") == ["(int, string)", "out int", "ref double", "in Point"]
      assert texts.("[NotNull] this string s, int? n = null, Func<int, int> f = null") == ["string", "int?", "Func<int, int>"]
      assert texts.("global::System.Int32 y, int[,] m") == ["global::System.Int32", "int[,]"]
      assert texts.("") == []
      assert [%{optional?: false}, %{optional?: true}] = Scanner.CSharp.parameters("int a, int b = 2")
      assert Scanner.CSharp.key_arity("(string, out int)") == 1
      assert Scanner.CSharp.key_arity("()") == 0
    end

    test "put_defs keeps the shape, the marks and the refusal on the node" do
      {book, _} = Scanner.CSharp.scan_defs(Book.new(), "src/Calls.cs", file("src/Calls.cs"))
      nodes = Map.values(book.nodes)
      assert %{shape: [1], marks: ["async"], refusal: nil} = Enum.find(nodes, &(&1.name == "LaterAsync"))
      assert %{shape: [0], refusal: "its type parameter T" <> _} = Enum.find(nodes, &(&1.name == "Make"))
      assert length(Enum.filter(nodes, &(&1.name == "Over"))) == 3
    end

    test "headers: tuple and generic return types, generic methods, constraints; constructors, properties and operators are not methods" do
      source = """
      namespace N {
        public static class T {
          public static (int, string) A(int x) => (x, "");
          public static Dictionary<string, List<int>> B<K>(K k, int y = 1) where K : class, new() { return null; }
          static T() { }
          public static int P { get; } = 1;
          public static int Q => 2;
          public static implicit operator int(T t) => 0;
          public static Func<int, int> F = x => { return x; };
          [Obsolete("x")] public static void C(params int[] xs) { }
          public static int D(Func<int, int> f, (int, int) p) => f(p.Item1);
        }
      }
      """

      assert Enum.map(Scanner.CSharp.definitions(source, "t.cs"), &{&1.name, &1.anykey, &1.refusal}) ==
               [{"A", "(int)", nil}, {"B", "(K, int)", nil}, {"C", "(params int[])", nil}, {"D", "(Func<int, int>, (int, int))", nil}]
    end
    test "comments, strings, chars and preprocessor lines blanked, offsets and lines kept" do
      source = ~s|a("x(y)") // b(c)\n#region r(\n/* d(\ne) */ f($"g{h(i)}", @"j""(", '(', """k(""")\n|
      text = Scanner.CSharp.blank(source)
      for gone <- ["x(y)", "b(c)", "r(", "d(", "j", "k("], do: refute(text =~ gone, gone)
      # an interpolation hole is code: its calls are links
      assert text =~ "f("
      assert text =~ "h(i)"
      refute text =~ "'('"
      assert byte_size(text) == byte_size(source)
      assert length(String.split(text, "\n")) == length(String.split(source, "\n"))
    end

    test "an interpolation hole's own strings, braces in strings, chars and comments: no method lost after them" do
      assert Enum.map(defs("src/Edge.cs"), &{&1.module, &1.name, &1.anykey}) == [
               {"Sample.Edge.Text", "Holes", "(int)"},
               {"Sample.Edge.Text", "Verbatim", "()"},
               {"Sample.Edge.Text", "Raw", "(int)"},
               {"Sample.Edge.Text", "Open", "()"},
               {"Sample.Edge.Text", "Branch", "()"},
               {"Sample.Edge.Text", "After", "()"},
               {"Sample.Edge.Generic", "First", "(T[])"},
               {"Sample.Edge.Generic", "Zero", "()"}
             ]

      text = Scanner.CSharp.blank(file("src/Edge.cs").source)
      assert text =~ "{Calc.Add(x, 1)}" |> String.replace(["{", "}"], " ")
      refute text =~ "quoted"
    end

    test "#if: the first branch read, #elif / #else blanked, nested ones too" do
      source = """
      #if A
      x1
      #if B
      x2
      #else
      x3
      #endif
      #elif C
      x4
      #else
      x5
      #endif
      x6
      """

      text = Scanner.CSharp.blank(source)
      for kept <- ["x1", "x2", "x6"], do: assert(text =~ kept, kept)
      for gone <- ["x3", "x4", "x5", "#"], do: refute(text =~ gone, gone)
      assert byte_size(text) == byte_size(source)
    end

    test "a byte order mark before a file-scoped namespace" do
      source = "\uFEFFnamespace N;\npublic static class T { public static int F() => 1; }\n"
      assert [%{module: "N.T", name: "F", span: 2}] = Scanner.CSharp.definitions(source, "t.cs")
      assert byte_size(Scanner.CSharp.blank(source)) == byte_size(source)
    end

    test "links: own and enclosing types, using static, Type.Name and Ns.Type.Name, this.; overloads by the arguments' count" do
      book = Enum.reduce(@files, Book.new(), fn path, book -> elem(Scanner.CSharp.scan_defs(book, path, file(path)), 0) end)
      ids = for {id, n} <- book.nodes, into: %{}, do: {{n.module, n.name, n.anykey}, id}
      book = Enum.reduce(@files, book, fn path, book -> book |> Scanner.CSharp.scan_links_report(ids, file(path)) |> elem(0) end)

      edges =
        for {_, l} <- book.links do
          n = Book.get(book, :nodes, l.node)
          r = Book.get(book, :nodes, l.ref)
          {"#{n.name}#{n.anykey}", "#{r.module}.#{r.name}#{r.anykey}"}
        end
        |> Enum.sort()

      assert edges ==
               Enum.sort([
                 # Add(Add(a, b), c): the two-argument overload
                 {"Add(int, int, int)", "Sample.Calc.Add(int, int)"},
                 {"RangeList(int)", "Sample.Calc.Range(int)"},
                 # using static Sample.Geo.Shapes
                 {"UnitArea()", "Sample.Geo.Shapes.Area(Circle)"},
                 {"Secret(int)", "Sample.Calc.Hidden(int)"},
                 # inside an interpolation hole; Calc found from Sample.Edge as C# looks it up
                 {"Holes(int)", "Sample.Calc.Add(int, int)"},
                 {"After()", "Sample.Edge.Text.Branch()"},
                 {"Step(int)", "Sample.Counter.Bump(int)"},
                 # a nested type by its name; Label's own text is not a call
                 {"Describe(Point)", "Sample.Geo.Shapes.Inner.Label(Point)"},
                 # Over(1): every overload of that count (the argument's type is not known)
                 {"Use()", "Sample.Calls.Over(int)"},
                 {"Use()", "Sample.Calls.Over(string)"},
                 {"Use()", "Sample.Calls.Over(double)"},
                 # Opt(1), Params(1, 2, 3): no overload of that count, every one of the name
                 {"Use()", "Sample.Calls.Opt(int, int)"},
                 {"Use()", "Sample.Calls.Params(params int[])"}
               ])
    end
  end
end
