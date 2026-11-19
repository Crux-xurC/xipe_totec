# Live verification against a real `dotnet fsi`, the F# counterpart of
# repl_iex_test.exs. NOT swept into test/run.sh. Needs `dotnet` (an SDK that
# builds net8.0 without fetching anything: the .NET 8 SDK) on PATH and
# embody.fsx (../embody next to this checkout, or $XIPE_TOTEC_EMBODY_DIR);
# without `dotnet` every test is excluded. For example:
#
#     nix shell github:NixOS/nixpkgs/<xipe_totec's pin>#dotnet-sdk_8 -c elixir test/live/repl_fsi_test.exs
#
# Target is a copy of test/fixtures/fsharp_sample/ (one project, Sample.dll,
# and two scripts whose top level must never run).
dotnet? = System.find_executable("dotnet") != nil
ExUnit.start(exclude: if(dotnet?, do: [], else: [:dotnet]), timeout: 300_000)
unless dotnet?, do: IO.puts("repl_fsi_test: no `dotnet` on PATH -- every test excluded")

Code.require_file(Path.expand("../../lib/repl/evaluator.exs", __DIR__))
Code.require_file(Path.expand("../../lib/repl/language/fsharp.exs", __DIR__))

defmodule ReplLiveFsiTest do
  use ExUnit.Case

  alias XipeTotec.{Book, Core, Scanner}
  alias XipeTotec.Repl.Evaluator
  alias XipeTotec.Repl.Language.FSharp

  @moduletag :dotnet
  @fixture_dir Path.expand("../fixtures/fsharp_sample", __DIR__)
  @files ["scripts/more.fsx", "scripts/tool.fsx", "src/Calc.fs", "src/Geo.fs"]

  setup do
    dir = Path.join(System.tmp_dir!(), "xipe_totec_fsi_live_#{System.unique_integer([:positive])}")
    File.cp_r!(@fixture_dir, dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp pure_node(module, name, n), do: %{module: module, name: name, anykey: n, effect: "pure", effect_source: "user"}

  # one pass over `calls` ([{id, "Ns.Module.f", args}]); the results by
  # call id. A row already in `book` keeps its value.
  defp run(dir, calls, book \\ Book.new(), opts \\ []) do
    book =
      Enum.reduce(calls, book, fn {id, node, args}, book ->
        parts = String.split(node, ".")
        {module, name} = {parts |> Enum.drop(-1) |> Enum.join("."), List.last(parts)}
        node_id = "n_#{node}/#{length(args)}"
        book = Core.put_node(book, node_id, pure_node(module, name, length(args)))
        if Book.get(book, :calls, id), do: book, else: Core.add_call(book, id, %{node: node_id, args: args})
      end)

    {launch_opts, cleanup} = FSharp.launch_opts(dir, "dotnet", @files)

    try do
      {:ok, book, results} =
        Evaluator.run_pass(
          book,
          "pass1",
          [
            cwd: dir,
            call_ids: Enum.map(calls, &elem(&1, 0)),
            launch_opts: launch_opts,
            boot_timeout_ms: 90_000,
            launch_module: XipeTotec.Repl.FSharp.Launch,
            eval_template_module: XipeTotec.Repl.FSharp.EvalTemplate,
            scan_module: XipeTotec.Repl.Eval.Scan.Direct.Fsi,
            field_drip_module: XipeTotec.Repl.Eval.FieldDrip.FSharp
          ] ++ opts
        )

      {book, Map.new(results, &{&1.call_id, &1})}
    after
      cleanup.()
    end
  end

  # the build wrote only obj/ into the project (bin/ goes to the temp dir);
  # no script's top level ran (it would write TOP_LEVEL_RAN)
  defp untouched!(dir), do: assert(File.ls!(dir) |> Enum.sort() == ["Sample.fsproj", "obj", "scripts", "src"])

  test "the scan: F#'s parser in dotnet fsi; definitions with their curried arguments, links", %{dir: dir} do
    {:ok, ctx} = Scanner.FSharp.begin(dir, "fsharp", files: @files, env: %{"PATH" => System.get_env("PATH")})
    file = fn path -> %{root: dir, path: path, source: File.read!(Path.join(dir, path)), ctx: ctx} end

    calc = Scanner.FSharp.defs(file.("src/Calc.fs"))
    keys = Enum.map(calc, &{&1.name, &1.anykey, &1.visibility})
    assert {"add", 2, "public"} in keys
    assert {"addPair", 1, "public"} in keys
    assert {"answer", 1, "public"} in keys
    assert {"secret", 1, "private"} in keys
    assert {"hidden", 1, "private"} in keys
    # values, not functions
    refute Enum.any?(calc, &(&1.name in ["limit", "addTen"]))

    assert [%{module: "Sample.Geo"} | _] = Scanner.FSharp.defs(file.("src/Geo.fs"))
    assert Enum.map(Scanner.FSharp.defs(file.("scripts/tool.fsx")), &{&1.module, &1.name}) == [{"Tool", "sq"}, {"Tool", "scale"}, {"Tool.Text", "shout"}]

    book = Enum.reduce(@files, Book.new(), fn path, book -> elem(Scanner.FSharp.scan_defs(book, path, file.(path)), 0) end)
    ids = for {id, n} <- book.nodes, into: %{}, do: {{n.module, n.name, n.anykey}, id}
    book = Enum.reduce(@files, book, fn path, book -> book |> Scanner.FSharp.scan_links_report(ids, file.(path)) |> elem(0) end)

    edges =
      for {_, l} <- book.links do
        {Book.get(book, :nodes, l.node).name, Book.get(book, :nodes, l.ref).name}
      end

    for edge <- [{"add3", "add"}, {"rangeList", "range"}, {"unitArea", "area"}, {"hidden", "secret"}, {"cube", "sq"}, {"scale", "factor"}] -- [{"scale", "factor"}] do
      assert edge in edges, inspect(edge)
    end
  end

  test "exact values and their types: F#'s own, records, unions, enums; scripts' functions; references within the pass", %{dir: dir} do
    {book, r} =
      run(dir, [
        {"a", "Sample.Calc.add", ["2", "3"]},
        {"a3", "Sample.Calc.add3", ["⟦a⟧", "1", "1"]},
        {"p", "Sample.Calc.addPair", ["(1, 2)"]},
        {"u", "Sample.Calc.answer", ["()"]},
        {"h", "Sample.Calc.half", ["1.0"]},
        {"r", "Sample.Calc.range", ["3"]},
        {"l", "Sample.Calc.rangeList", ["⟦a⟧"]},
        {"pr", "Sample.Calc.pair", ["4"]},
        {"d", "Sample.Calc.counts", [~s|"aab"|]},
        {"g", "Sample.Calc.greet", [~s|"x"|]},
        {"m", "Sample.Calc.maybe", ["false"]},
        {"tw", "Sample.Calc.twice", ["2.5"]},
        {"fi", "Sample.Calc.first", [~s|["a"; "b"]|]},
        {"mid", "Sample.Geo.mid", ["{ Sample.Point.X = 1.0; Y = 2.0 }", "{ Sample.Point.X = 3.0; Y = 4.0 }"]},
        {"gr", "Sample.Geo.grow", ["2.0", "Sample.Rect (1.0, 1.5)"]},
        {"e", "Sample.Geo.grow", ["2.0", "Sample.Empty"]},
        {"n", "Sample.Geo.next", ["Sample.Color.Red"]},
        {"lb", "Sample.Geo.Inner.label", [~s|"x"|]},
        {"sq", "Tool.sq", ["3"]},
        {"sc", "Tool.scale", ["5"]},
        {"sh", "Tool.Text.shout", [~s|"hi"|]},
        {"cu", "More.cube", ["3"]}
      ])

    assert {:ok, %{repr: "exact", type: "int", display: "5"}} = r["a"].outcome
    assert {:ok, %{display: "7"}} = r["a3"].outcome
    assert {:ok, %{display: "3"}} = r["p"].outcome
    assert {:ok, %{display: "42"}} = r["u"].outcome
    assert {:ok, %{repr: "exact", type: "float", display: "0.5"}} = r["h"].outcome
    assert {:ok, %{repr: "exact", type: "int[]", display: "[|0; 1; 2|]"}} = r["r"].outcome
    assert {:ok, %{repr: "exact", type: "int list", display: "[0; 1; 2; 3; 4]"}} = r["l"].outcome
    assert {:ok, %{repr: "exact", type: "struct (int * string)", display: ~s|struct (4, "4")|}} = r["pr"].outcome

    assert {:ok, %{repr: "exact", display: ~s|System.Collections.Generic.Dictionary(dict [("a", 2); ("b", 1)])|}} =
             r["d"].outcome

    assert {:ok, %{repr: "exact", display: ~s|"hello, x {not a brace}"|}} = r["g"].outcome
    assert {:ok, %{repr: "exact", type: "string option", display: "None"}} = r["m"].outcome
    assert {:ok, %{type: "float", display: "5.0"}} = r["tw"].outcome
    assert {:ok, %{display: ~s|"a"|}} = r["fi"].outcome
    assert {:ok, %{repr: "exact", type: "Sample.Point", display: "{ Sample.Point.X = 2.0; Y = 3.0 }"}} = r["mid"].outcome
    assert {:ok, %{repr: "exact", type: "Sample.Shape", display: "Sample.Shape.Rect (2.0, 3.0)"}} = r["gr"].outcome
    assert {:ok, %{repr: "exact", type: "Sample.Shape", display: "Sample.Shape.Empty"}} = r["e"].outcome
    assert {:ok, %{repr: "exact", type: "Sample.Color", display: "Sample.Color.Blue"}} = r["n"].outcome
    assert {:ok, %{display: ~s|"X"|}} = r["lb"].outcome
    assert {:ok, %{display: "9"}} = r["sq"].outcome
    assert {:ok, %{display: "15"}} = r["sc"].outcome
    assert {:ok, %{display: ~s|"HI!"|}} = r["sh"].outcome
    assert {:ok, %{display: "27"}} = r["cu"].outcome
    assert Book.get(book, :calls, "a").result == "5"
    untouched!(dir)
  end

  test "a record's literal is a later call's argument; compare same, changed", %{dir: dir} do
    calls = [
      {"c", "Sample.Calc.add", ["1", "2"]},
      {"m", "Sample.Geo.mid", ["{ Sample.Point.X = 1.0; Y = 2.0 }", "{ Sample.Point.X = 3.0; Y = 4.0 }"]},
      {"g", "Sample.Geo.grow", ["2.0", "Sample.Circle 1.0"]}
    ]

    {book, _} = run(dir, calls)
    {book, r} = run(dir, calls, book)
    for id <- ~w(c m g), do: assert(r[id].compare == "same", id)

    book = Book.put(book, :calls, "c", %{Book.get(book, :calls, "c") | args: ["2", "2"]})
    {book, r} = run(dir, [{"c", "Sample.Calc.add", ["2", "2"]}], book)
    assert r["c"].compare == "changed"

    # the stored record, embedded as its literal into another row
    {_book, r} = run(dir, [{"m2", "Sample.Geo.mid", ["⟦m⟧", "⟦m⟧"]}], book)
    assert {:ok, %{display: "{ Sample.Point.X = 2.0; Y = 3.0 }"}} = r["m2"].outcome
  end

  test "values that are not literals: a function (unsupported); an exception, calls that don't compile, and a timeout are each row's own", %{dir: dir} do
    {_book, r} =
      run(dir, [
        {"f", "Sample.Calc.adder", ["1"]},
        {"e1", "Sample.Calc.boom", ["1"]},
        {"e2", "Sample.Calc.add", ["1", ~s|"x"|]},
        {"e3", "Sample.Calc.secret", ["1"]},
        {"e4", "Sample.Calc.add", ["[|1", "2"]},
        {"e5", "Sample.Nope.f", ["1"]},
        {"e6", "Sample.Calc.add", ["1", "2", "3"]},
        {"e7", "Sample.Calc.limit", ["1"]},
        {"ok", "Sample.Calc.add", ["2", "2"]}
      ])

    assert {:ok, %{repr: "unsupported", type: "int -> int"}} = r["f"].outcome
    assert {:error, "System.Exception: boom: 1"} = r["e1"].outcome
    assert {:error, "the call did not compile: the arguments do not fit add : int -> int -> int" <> _} = r["e2"].outcome
    assert {:error, "the call did not compile: Sample.Calc.secret is private or internal"} = r["e3"].outcome
    assert {:error, "the call was not sent: an unclosed ["} = r["e4"].outcome
    assert {:error, "the call did not compile: no module Sample.Nope in what was loaded"} = r["e5"].outcome
    assert {:error, "the call did not compile: Sample.Calc.add takes 2 argument(s), got 3: add : int -> int -> int"} = r["e6"].outcome
    assert {:error, "the call did not compile: Sample.Calc.limit is a value, not a function"} = r["e7"].outcome
    assert {:ok, %{display: "4"}} = r["ok"].outcome
  end

  test "a timeout: the rest of the pass in a new session, fsi started again without building; an earlier exact value handed over", %{dir: dir} do
    {_book, r} =
      run(dir, [
        {"a", "Sample.Calc.add", ["1", "2"]},
        {"b", "Sample.Calc.spin", ["()"]},
        {"c", "Sample.Calc.add", ["⟦a⟧", "10"]},
        {"d", "Sample.Calc.add", ["⟦b⟧", "1"]}
      ])

    assert r["a"].session_gen == "pass1"
    assert :timeout = r["b"].outcome
    assert r["b"].session_gen == "pass1"
    assert {:ok, %{display: "13"}} = r["c"].outcome
    assert r["c"].session_gen == "pass1/2"
    assert r["d"].outcome == {:skipped, "b"}
  end

  test "a build that fails: every project row a crash naming the build's first error; the scripts still load", %{dir: dir} do
    File.write!(Path.join(dir, "src/Calc.fs"), "module Sample.Calc\nlet add a b = undefined a b\n")
    {_book, r} = run(dir, [{"b", "Sample.Calc.add", ["1", "2"]}, {"s", "Tool.sq", ["2"]}])
    assert {:error, "the call did not compile: no module Sample.Calc in what was loaded (the build failed: " <> _} = r["b"].outcome
    assert {:ok, %{display: "4"}} = r["s"].outcome
  end

  test "a package not in the NuGet cache: the restore's error, not a boot timeout", %{dir: dir} do
    project = Path.join(dir, "Sample.fsproj")

    File.write!(
      project,
      String.replace(File.read!(project), "</Project>", """
        <ItemGroup><PackageReference Include="Xipe.Totec.No.Such.Package" Version="1.0.0" /></ItemGroup>
      </Project>
      """)
    )

    {_book, r} = run(dir, [{"b", "Sample.Calc.add", ["1", "2"]}])
    assert {:error, "the call did not compile: no module Sample.Calc in what was loaded (the build failed: " <> why} = r["b"].outcome
    assert why =~ "NU1101"
  end

  test "a script whose definitions use a value its top level computes: it does not load, and says so", %{dir: dir} do
    File.write!(Path.join(dir, "scripts/tool.fsx"), "let computed = System.Random.Shared.Next 10\nlet sq x = x * x + computed * 0\n")
    {_book, r} = run(dir, [{"s", "Tool.sq", ["2"]}, {"a", "Sample.Calc.add", ["1", "1"]}])
    # more.fsx #loads tool.fsx: neither loads
    assert {:error, "the call did not compile: no module Tool in what was loaded (did not load: " <> why} = r["s"].outcome
    assert why =~ "scripts/tool.fsx"
    assert why =~ "scripts/more.fsx"
    assert {:ok, %{display: "2"}} = r["a"].outcome
  end
end
