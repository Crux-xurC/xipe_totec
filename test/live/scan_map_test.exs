# Live verification of the map-only languages read by their own parsers: Go (go/parser through `go run`)
# and PHP (token_get_all through `php`). NOT swept into test/run.sh. Each language's tests are excluded
# without its tool on PATH. For example:
#
#     nix shell <xipe_totec's pin>#go <pin>#php -c elixir test/live/scan_map_test.exs
go? = System.find_executable("go") != nil
php? = System.find_executable("php") != nil
ExUnit.start(exclude: (if go?, do: [], else: [:go]) ++ if(php?, do: [], else: [:php]))

Code.require_file(Path.expand("../../lib/scanner/go.exs", __DIR__))
Code.require_file(Path.expand("../../lib/scanner/php.exs", __DIR__))

defmodule ScanMapLiveTest do
  use ExUnit.Case

  alias XipeTotec.{Book, Scanner}

  defp scan(scanner, root, ext) do
    files = root |> Path.join("**/*.#{ext}") |> Path.wildcard() |> Enum.map(&Path.relative_to(&1, root)) |> Enum.sort()
    {:ok, ctx} = scanner.begin(root, ext, files: files, env: %{"PATH" => System.get_env("PATH")})
    file = fn p -> %{root: root, path: p, source: "", ctx: ctx} end
    book = Enum.reduce(files, Book.new(), fn p, b -> elem(scanner.scan_defs(b, p, file.(p)), 0) end)
    ids = for {id, n} <- book.nodes, into: %{}, do: {{n.module, n.name, n.anykey}, id}

    {book, reports} =
      Enum.reduce(files, {book, []}, fn p, {b, r} ->
        {b, more} = scanner.scan_links_report(b, ids, file.(p))
        {b, r ++ Enum.map(more, &Map.put(&1, :path, p))}
      end)

    nodes = for {_, n} <- book.nodes, into: %{}, do: {"#{n.module}.#{n.name}", n}

    edges =
      for {_, l} <- book.links do
        n = Book.get(book, :nodes, l.node)
        r = Book.get(book, :nodes, l.ref)
        {"#{n.module}.#{n.name}", "#{r.module}.#{r.name}"}
      end

    {nodes, Enum.sort(edges), reports}
  end

  @tag :go
  test "Go: packages by import path, functions and methods, vendor/ and init left out, build-tag variants reported, links" do
    {nodes, edges, reports} = scan(Scanner.Go, Path.expand("../fixtures/go_sample", __DIR__), "go")

    assert nodes |> Map.keys() |> Enum.sort() ==
             Enum.sort(~w(example.com/calc.Add example.com/calc.Add3 example.com/calc.Half example.com/calc.Shout example.com/calc.mark
                          example.com/calc.TestAdd example.com/calc/geo.Point.Dist example.com/calc/geo.Point.Scale
                          example.com/calc/geo.Point.norm example.com/calc/geo.Mid example.com/calc/geo.Map example.com/calc/geo.Name
                          example.com/calc/cmd/tool.main example.com/calc/cmd/tool.run))

    assert %{visibility: "public", anykey: nil, sheet: "geo/os_a.go"} = nodes["example.com/calc/geo.Name"]
    assert %{visibility: "private"} = nodes["example.com/calc/geo.Point.norm"]

    assert edges ==
             Enum.sort([
               {"example.com/calc.Add3", "example.com/calc.Add"},
               {"example.com/calc.Shout", "example.com/calc.mark"},
               {"example.com/calc.TestAdd", "example.com/calc.Add"},
               {"example.com/calc/geo.Mid", "example.com/calc.Half"},
               {"example.com/calc/geo.Point.Scale", "example.com/calc/geo.Point.norm"},
               {"example.com/calc/cmd/tool.main", "example.com/calc.Add"},
               {"example.com/calc/cmd/tool.main", "example.com/calc/geo.Mid"},
               {"example.com/calc/cmd/tool.main", "example.com/calc/cmd/tool.run"},
               {"example.com/calc/cmd/tool.run", "example.com/calc.Add3"}
             ])

    assert [%{path: "geo/os_a.go", reason: r}, %{path: "geo/os_b.go", reason: r}] = Enum.sort_by(reports, & &1.path)
    assert r =~ "example.com/calc/geo.Name is defined in more than one file (geo/os_a.go:5, geo/os_b.go:5"
  end

  @tag :php
  test "PHP: classes by namespace, functions, methods with visibility, closures and anonymous classes left out, guarded helpers reported, links" do
    {nodes, edges, reports} = scan(Scanner.Php, Path.expand("../fixtures/php_sample", __DIR__), "php")

    assert nodes |> Map.keys() |> Enum.sort() ==
             Enum.sort([
               "App\\Calc.add", "App\\Calc.add3", "App\\Calc.secret", "App\\Calc.guarded", "App\\Calc.step", "App\\Calc.label",
               "App\\Base.area", "App\\Base.unit", "App\\Named.name", "App\\Greets.greet", "App\\Suit.color",
               "App\\Geo\\Shapes.area", "App\\Geo\\Shapes.name", "App\\Geo\\Shapes.describe", "App\\Geo\\Shapes.tag",
               "App\\Util.twice", "App\\Util.thrice", "\\.helper"
             ])

    assert %{visibility: "private"} = nodes["App\\Calc.secret"]
    assert %{visibility: "public", sheet: "bootstrap.php"} = nodes["\\.helper"]

    assert edges ==
             Enum.sort([
               {"App\\Calc.add3", "App\\Calc.add"},
               {"App\\Calc.label", "App\\Calc.add"},
               {"App\\Calc.step", "App\\Calc.guarded"},
               {"App\\Calc.step", "App\\Calc.secret"},
               {"App\\Geo\\Shapes.area", "App\\Base.unit"},
               {"App\\Geo\\Shapes.area", "App\\Util.twice"},
               {"App\\Geo\\Shapes.describe", "App\\Calc.add"},
               {"App\\Geo\\Shapes.describe", "App\\Calc.label"},
               {"App\\Geo\\Shapes.describe", "App\\Geo\\Shapes.tag"},
               {"App\\Geo\\Shapes.describe", "App\\Util.thrice"},
               {"App\\Util.thrice", "App\\Util.twice"},
               {"\\.helper", "App\\Util.twice"}
             ])

    assert [%{path: "bootstrap.php", reason: r}, %{path: "legacy/helpers.php", reason: r}] = Enum.sort_by(reports, & &1.path)
    assert r =~ "\\.helper is defined in more than one file (bootstrap.php:4, legacy/helpers.php:4)"
  end

  @tag :php
  test "PHP: a file that does not parse raises PHP's own message" do
    dir = Path.join(System.tmp_dir!(), "xt_php_bad_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "bad.php"), "<?php function f( { }\n")
    {:ok, ctx} = Scanner.Php.begin(dir, "php", files: ["bad.php"], env: %{"PATH" => System.get_env("PATH")})
    assert_raise RuntimeError, ~r/\Abad\.php:1: syntax error/, fn -> Scanner.Php.defs(%{path: "bad.php", ctx: ctx}) end
    File.rm_rf!(dir)
  end

  @tag :go
  test "Go: a file that does not parse raises the parser's own message" do
    dir = Path.join(System.tmp_dir!(), "xt_go_bad_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "bad.go"), "package p\nfunc f( {\n")
    {:ok, ctx} = Scanner.Go.begin(dir, "go", files: ["bad.go"], env: %{"PATH" => System.get_env("PATH")})
    assert_raise RuntimeError, ~r/\Abad\.go:2/, fn -> Scanner.Go.defs(%{path: "bad.go", ctx: ctx}) end
    File.rm_rf!(dir)
  end
end
