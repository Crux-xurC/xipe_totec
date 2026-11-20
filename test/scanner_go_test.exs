ExUnit.start()

Code.require_file(Path.expand("../lib/scanner/go.exs", __DIR__))

# Scanner.Go on a canned answer of scan.go (no Go needed); the real parse is in test/live/scan_map_test.exs
defmodule ScannerGoTest do
  use ExUnit.Case, async: true

  alias XipeTotec.{Book, Scanner}

  @root Path.expand("fixtures/go_sample", __DIR__)

  defp d(name, calls, opts \\ []),
    do: %{"name" => name, "line" => 1, "hash" => "h", "exported" => Keyword.get(opts, :exported, true), "calls" => calls, "recv" => Keyword.get(opts, :recv, "")}

  defp ctx do
    files = %{
      "calc.go" => %{"path" => "calc.go", "error" => "", "package" => "calc", "imports" => [], "defs" => [d("Add", []), d("Add3", ["Add"]), d("mark", [], exported: false)]},
      "geo/geo.go" => %{
        "path" => "geo/geo.go",
        "error" => "",
        "package" => "geo",
        "imports" => [%{"path" => "example.com/calc", "name" => ""}, %{"path" => "math", "name" => ""}],
        "defs" => [d("Point.Scale", ["p.norm", "math.Hypot"], recv: "p"), d("Point.norm", [], recv: "p", exported: false), d("Mid", ["calc.Add"])]
      },
      "geo/os_a.go" => %{"path" => "geo/os_a.go", "error" => "", "package" => "geo", "imports" => [], "defs" => [d("Name", [])]},
      "geo/os_b.go" => %{"path" => "geo/os_b.go", "error" => "", "package" => "geo", "imports" => [], "defs" => [d("Name", [])]},
      "cmd/tool/main.go" => %{
        "path" => "cmd/tool/main.go",
        "error" => "",
        "package" => "main",
        "imports" => [%{"path" => "example.com/calc", "name" => "c"}, %{"path" => "example.com/calc/geo", "name" => ""}],
        "defs" => [d("main", ["c.Add", "geo.Mid", "p.Scale", "run"], exported: false), d("run", [], exported: false)]
      },
      "bad.go" => %{"path" => "bad.go", "error" => "bad.go:1:1: expected 'package', found x", "package" => "", "imports" => [], "defs" => []}
    }

    modules = Map.new(Map.keys(files), &{&1, Scanner.Go.module_name(@root, &1)})
    # collisions as begin/3 computes them (a private function: exercised through scan_links_report)
    {:ok, %{files: files, modules: modules, collisions: collisions(files, modules)}}
    |> elem(1)
  end

  defp collisions(files, modules) do
    # the same rule as Scanner.Go's: the first file (sorted) keeps the card
    for {path, %{"defs" => defs}} <- files, dd <- defs, reduce: %{} do
      acc -> Map.update(acc, {modules[path], dd["name"]}, [path], &[path | &1])
    end
    |> Enum.filter(fn {_, ps} -> length(ps) > 1 end)
    |> Enum.flat_map(fn {{m, n}, ps} ->
      ps = Enum.sort(ps)
      for p <- ps, do: {p, %{module: m, name: n, reason: "#{m}.#{n} is defined in more than one file", first: hd(ps)}}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp file(path), do: %{root: @root, path: path, source: "", ctx: ctx()}

  test "a package by its import path: the nearest go.mod's module and the directory under it" do
    assert Scanner.Go.module_name(@root, "calc.go") == "example.com/calc"
    assert Scanner.Go.module_name(@root, "geo/geo.go") == "example.com/calc/geo"
    assert Scanner.Go.module_name(@root, "cmd/tool/main.go") == "example.com/calc/cmd/tool"
    assert Scanner.Go.module_name("/no/such/dir", "a/b.go") == "a"
  end

  test "definitions: functions and methods (T.M), exported or not; vendor/ and testdata/ read for nothing; a parse error raised" do
    assert [%{module: "example.com/calc", name: "Add", anykey: nil, visibility: "public"} | _] = Scanner.Go.defs(file("calc.go"))
    assert %{visibility: "private"} = Enum.find(Scanner.Go.defs(file("calc.go")), &(&1.name == "mark"))
    assert Enum.map(Scanner.Go.defs(file("geo/geo.go")), & &1.name) == ["Point.Scale", "Point.norm", "Mid"]
    assert Scanner.Go.skipped?("vendor/example.org/x/x.go")
    assert Scanner.Go.skipped?("geo/testdata/t.go")
    assert Scanner.Go.defs(%{file("calc.go") | path: "vendor/x/x.go"}) == []
    assert_raise RuntimeError, ~r/expected 'package'/, fn -> Scanner.Go.defs(file("bad.go")) end
  end

  test "a name two files of a package define: the first file's card, the other's left to it" do
    assert [%{name: "Name"}] = Scanner.Go.defs(file("geo/os_a.go"))
    assert Scanner.Go.defs(file("geo/os_b.go")) == []
  end

  test "links: the own package, an import by its name or alias, the receiver's methods; calls on other values not" do
    paths = ["calc.go", "geo/geo.go", "geo/os_a.go", "cmd/tool/main.go"]
    book = Enum.reduce(paths, Book.new(), fn p, b -> elem(Scanner.Go.scan_defs(b, p, file(p)), 0) end)
    ids = for {id, n} <- book.nodes, into: %{}, do: {{n.module, n.name, n.anykey}, id}
    book = Enum.reduce(paths, book, fn p, b -> b |> Scanner.Go.scan_links_report(ids, file(p)) |> elem(0) end)

    edges =
      for {_, l} <- book.links do
        n = Book.get(book, :nodes, l.node)
        r = Book.get(book, :nodes, l.ref)
        {"#{n.module}.#{n.name}", "#{r.module}.#{r.name}"}
      end

    assert Enum.sort(edges) ==
             Enum.sort([
               {"example.com/calc.Add3", "example.com/calc.Add"},
               {"example.com/calc/geo.Point.Scale", "example.com/calc/geo.Point.norm"},
               {"example.com/calc/geo.Mid", "example.com/calc.Add"},
               {"example.com/calc/cmd/tool.main", "example.com/calc.Add"},
               {"example.com/calc/cmd/tool.main", "example.com/calc/geo.Mid"},
               {"example.com/calc/cmd/tool.main", "example.com/calc/cmd/tool.run"}
             ])
  end
end
