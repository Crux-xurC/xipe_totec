# Live verification against Scala 3's REPL, the Scala counterpart of
# repl_iex_test.exs. NOT swept into test/run.sh. Needs `sbt`, `scala-cli`
# and `scala` (Scala 3.3.6) on PATH, with what the fixtures need already in
# the coursier cache (sbt 1.12.4, Scala 3.3.6: nothing is fetched), and
# embody.scala (../embody next to this checkout, or $XIPE_TOTEC_EMBODY_DIR);
# without `sbt` every test is excluded. For example:
#
#     nix shell github:NixOS/nixpkgs/<xipe_totec's pin>#sbt github:NixOS/nixpkgs/<pin>#scala-cli \
#       github:NixOS/nixpkgs/<pin>#scala_3 -c elixir test/live/repl_scala_test.exs
#
# (build the fixtures once with sbt and scala-cli online to fill the cache).
#
# Targets are copies of test/fixtures/scala_sample/ (an sbt project and two
# scripts whose top level must never run) and test/fixtures/scala_cli_sample/.
tools? = Enum.all?(~w(sbt scala-cli scala), &System.find_executable/1)
ExUnit.start(exclude: if(tools?, do: [], else: [:scala]), timeout: 600_000)
unless tools?, do: IO.puts("repl_scala_test: no sbt, scala-cli or scala on PATH -- every test excluded")

Code.require_file(Path.expand("../../lib/repl/evaluator.exs", __DIR__))
Code.require_file(Path.expand("../../lib/repl/language/scala.exs", __DIR__))

defmodule ReplLiveScalaTest do
  use ExUnit.Case

  alias XipeTotec.{Book, Core, Scanner}
  alias XipeTotec.Repl.Evaluator
  alias XipeTotec.Repl.Language.Scala

  @moduletag :scala
  @fixture_dir Path.expand("../fixtures/scala_sample", __DIR__)
  @cli_fixture_dir Path.expand("../fixtures/scala_cli_sample", __DIR__)
  @files ["scripts/broken.sc", "scripts/tool.sc", "src/main/scala/sample/Calc.scala"]

  setup do
    dir = Path.join(System.tmp_dir!(), "xipe_totec_scala_live_#{System.unique_integer([:positive])}")
    File.cp_r!(@fixture_dir, dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  # one pass over `calls` ([{id, "pkg.Obj.f", shape, args}] -- the anykey
  # is the shape's text, enough to tell nodes apart here); the results by
  # call id. A row already in `book` keeps its value.
  defp run(dir, calls, book \\ Book.new(), opts \\ []) do
    {tool, files} = Keyword.get(opts, :project, {"sbt", @files})

    book =
      Enum.reduce(calls, book, fn {id, node, shape, args}, book ->
        parts = String.split(node, ".")
        {module, name} = {parts |> Enum.drop(-1) |> Enum.join("."), List.last(parts)}
        node_id = "n_#{node}/#{inspect(shape)}"

        book =
          Core.put_node(book, node_id, %{module: module, name: name, anykey: inspect(shape), shape: shape, effect: "pure", effect_source: "user"})

        if Book.get(book, :calls, id), do: book, else: Core.add_call(book, id, %{node: node_id, args: args})
      end)

    {launch_opts, cleanup} = Scala.launch_opts(dir, tool, files)

    try do
      {:ok, book, results} =
        Evaluator.run_pass(book, "pass1",
          cwd: dir,
          call_ids: Enum.map(calls, &elem(&1, 0)),
          launch_opts: launch_opts,
          boot_timeout_ms: 180_000,
          launch_module: XipeTotec.Repl.Scala.Launch,
          eval_template_module: XipeTotec.Repl.Scala.EvalTemplate,
          scan_module: XipeTotec.Repl.Eval.Scan.Direct.Scala,
          field_drip_module: XipeTotec.Repl.Eval.FieldDrip.Scala
        )

      {book, Map.new(results, &{&1.call_id, &1})}
    after
      cleanup.()
    end
  end

  # sbt wrote only its own directories into the project; no script's top level ran
  defp untouched!(dir) do
    assert File.ls!(dir) |> Enum.sort() == ["build.sbt", "project", "scripts", "src", "target"]
    refute File.exists?(Path.join(dir, "TOP_LEVEL_RAN"))
  end

  test "the scan: Scala's parser; types as anykey, the shape, private, overloads, scripts, links", %{dir: dir} do
    {:ok, ctx} = Scanner.Scala.begin(dir, "scala", files: @files, env: %{"PATH" => System.get_env("PATH")})
    file = fn path -> %{root: dir, path: path, source: File.read!(Path.join(dir, path)), ctx: ctx} end

    calc = Scanner.Scala.defs(file.("src/main/scala/sample/Calc.scala"))
    keys = Enum.map(calc, &{&1.module, &1.name, &1.anykey, &1.shape, &1.visibility})
    assert {"sample.Calc", "add", "(Int, Int)", [2], "public"} in keys
    assert {"sample.Calc", "curried", "(Int)(Int)", [1, 1], "public"} in keys
    assert {"sample.Calc", "answer", "()", [0], "public"} in keys
    assert {"sample.Calc", "overload", "(Int)", [1], "public"} in keys
    assert {"sample.Calc", "overload", "(String)", [1], "public"} in keys
    assert {"sample.Calc", "secret", "(Int)", [1], "private"} in keys
    assert {"sample.Geo.Inner", "label", "(String)", [1], "public"} in keys
    assert {"sample", "twice", "(Double)", [1], "public"} in keys

    assert Enum.map(Scanner.Scala.defs(file.("scripts/tool.sc")), &{&1.module, &1.name}) ==
             [{"scripts/tool", "sq"}, {"scripts/tool", "scale"}, {"scripts/tool.Text", "shout"}]

    # the project's own compiler, from sbt without building
    assert Scanner.Scala.describe(ctx) =~ "the project's own compiler (scala3-compiler_3-3.3.6)"
    refute File.exists?(Path.join(dir, "target/scala-3.3.6/classes"))

    book = Enum.reduce(@files, Book.new(), fn path, book -> elem(Scanner.Scala.scan_defs(book, path, file.(path)), 0) end)
    ids = for {id, n} <- book.nodes, into: %{}, do: {{n.module, n.name, n.anykey}, id}
    book = Enum.reduce(@files, book, fn path, book -> book |> Scanner.Scala.scan_links_report(ids, file.(path)) |> elem(0) end)
    edges = for {_, l} <- book.links, do: {Book.get(book, :nodes, l.node).name, Book.get(book, :nodes, l.ref).name}

    for edge <- [{"add3", "add"}, {"callsSecret", "secret"}, {"scale", "sq"}] -- [{"scale", "sq"}] do
      assert edge in edges, inspect(edge)
    end

    assert %{shape: [1, 1]} = Book.get(book, :nodes, ids[{"sample.Calc", "curried", "(Int)(Int)"}])
  end

  test "exact values and their types; curried and parameterless calls; scripts' functions; references within the pass", %{dir: dir} do
    {book, r} =
      run(dir, [
        {"a", "sample.Calc.add", [2], ["2", "3"]},
        {"a3", "sample.Calc.add3", [3], ["⟦a⟧", "1", "1"]},
        {"cu", "sample.Calc.curried", [1, 1], ["2", "3"]},
        {"u", "sample.Calc.answer", [0], []},
        {"h", "sample.Calc.half", [1], ["1.0"]},
        {"r", "sample.Calc.range", [1], ["3"]},
        {"l", "sample.Calc.rangeList", [1], ["⟦a⟧"]},
        {"pr", "sample.Calc.pair", [1], ["4"]},
        {"d", "sample.Calc.counts", [1], [~s|"aab"|]},
        {"g", "sample.Calc.greet", [1], [~s|"x"|]},
        {"m", "sample.Calc.maybe", [1], ["false"]},
        {"o1", "sample.Calc.overload", [1], ["1"]},
        {"o2", "sample.Calc.overload", [1], [~s|"a"|]},
        {"mid", "sample.Geo.mid", [2], ["sample.Point(1.0, 2.0)", "sample.Point(3.0, 4.0)"]},
        {"n", "sample.Geo.next", [1], ["sample.Color.Red"]},
        {"lb", "sample.Geo.Inner.label", [1], [~s|"x"|]},
        {"tw", "sample.twice", [1], ["2.5"]},
        {"sq", "scripts/tool.sq", [1], ["3"]},
        {"sc", "scripts/tool.scale", [1], ["5"]},
        {"sh", "scripts/tool.Text.shout", [1], [~s|"hi"|]}
      ])

    assert {:ok, %{repr: "exact", type: "Int", display: "5"}} = r["a"].outcome
    assert {:ok, %{display: "7"}} = r["a3"].outcome
    assert {:ok, %{display: "6"}} = r["cu"].outcome
    assert {:ok, %{display: "42"}} = r["u"].outcome
    assert {:ok, %{repr: "exact", type: "Double", display: "0.5"}} = r["h"].outcome
    assert {:ok, %{repr: "exact", type: "Array[Int]", display: "Array(0, 1, 2)"}} = r["r"].outcome
    assert {:ok, %{repr: "exact", type: "List[Int]", display: "List(0, 1, 2, 3, 4)"}} = r["l"].outcome
    assert {:ok, %{repr: "exact", type: "(Int, String)", display: ~s|(4, "4")|}} = r["pr"].outcome
    assert {:ok, %{repr: "exact", type: "Map[String, Int]"}} = r["d"].outcome
    assert {:ok, %{repr: "exact", display: ~s|"hello, x {not a brace}"|}} = r["g"].outcome
    assert {:ok, %{repr: "exact", display: "None"}} = r["m"].outcome
    assert {:ok, %{display: "2"}} = r["o1"].outcome
    assert {:ok, %{display: ~s|"a!"|}} = r["o2"].outcome
    assert {:ok, %{repr: "exact", type: "sample.Point", display: "sample.Point(2.0, 3.0)"}} = r["mid"].outcome
    assert {:ok, %{repr: "exact", type: "sample.Color", display: "sample.Color.Green"}} = r["n"].outcome
    assert {:ok, %{display: ~s|"X"|}} = r["lb"].outcome
    assert {:ok, %{display: "5.0"}} = r["tw"].outcome
    assert {:ok, %{display: "9"}} = r["sq"].outcome
    assert {:ok, %{display: "15"}} = r["sc"].outcome
    assert {:ok, %{display: ~s|"HI!"|}} = r["sh"].outcome
    assert Book.get(book, :calls, "a").result == "5"
    untouched!(dir)
  end

  test "a case class's literal is a later call's argument; compare same, changed", %{dir: dir} do
    calls = [
      {"c", "sample.Calc.add", [2], ["1", "2"]},
      {"m", "sample.Geo.mid", [2], ["sample.Point(1.0, 2.0)", "sample.Point(3.0, 4.0)"]}
    ]

    {book, _} = run(dir, calls)
    {book, r} = run(dir, calls, book)
    for id <- ~w(c m), do: assert(r[id].compare == "same", id)

    book = Book.put(book, :calls, "c", %{Book.get(book, :calls, "c") | args: ["2", "2"]})
    {book, r} = run(dir, [{"c", "sample.Calc.add", [2], ["2", "2"]}], book)
    assert r["c"].compare == "changed"

    {_book, r} = run(dir, [{"m2", "sample.Geo.mid", [2], ["⟦m⟧", "⟦m⟧"]}], book)
    assert {:ok, %{display: "sample.Point(2.0, 3.0)"}} = r["m2"].outcome
  end

  test "values that are not literals; an exception, calls that don't compile, an unclosed argument, a script that did not load", %{dir: dir} do
    {_book, r} =
      run(dir, [
        {"f", "sample.Calc.adder", [1], ["1"]},
        {"e1", "sample.Calc.boom", [1], ["1"]},
        {"e2", "sample.Calc.add", [2], ["1", ~s|"x"|]},
        {"e3", "sample.Calc.secret", [1], ["1"]},
        {"e4", "sample.Calc.add", [2], ["(1", "2"]},
        {"e5", "sample.Nope.f", [1], ["1"]},
        {"e6", "sample.Calc.nothere", [1], ["1"]},
        {"e7", "scripts/broken.plusN", [1], ["1"]},
        {"ok", "sample.Calc.add", [2], ["2", "2"]}
      ])

    assert {:ok, %{repr: "unsupported", type: "Function"}} = r["f"].outcome
    assert {:error, "java.lang.IllegalStateException: boom 1"} = r["e1"].outcome
    assert {:error, "the call did not compile: the arguments do not fit add(" <> _} = r["e2"].outcome
    assert {:error, "the call did not compile: sample.Calc.secret is private"} = r["e3"].outcome
    assert {:error, "the call was not sent: an unclosed ("} = r["e4"].outcome
    assert {:error, "the call did not compile: no object sample.Nope in what was loaded" <> _} = r["e5"].outcome
    assert {:error, "the call did not compile: sample.Calc has no function nothere"} = r["e6"].outcome
    assert {:error, "the call did not compile: the script scripts/broken.sc did not load" <> _} = r["e7"].outcome
    assert {:ok, %{display: "4"}} = r["ok"].outcome
    untouched!(dir)
  end

  test "a timeout: the rest of the pass in a new session, the build not run again; an earlier exact value handed over", %{dir: dir} do
    {_book, r} =
      run(dir, [
        {"a", "sample.Calc.add", [2], ["1", "2"]},
        {"b", "sample.Calc.spin", [1], ["1"]},
        {"c", "sample.Calc.add", [2], ["⟦a⟧", "10"]}
      ])

    assert {:ok, %{display: "3"}} = r["a"].outcome
    assert r["a"].session_gen == "pass1"
    assert :timeout = r["b"].outcome
    assert {:ok, %{display: "13"}} = r["c"].outcome
    assert r["c"].session_gen == "pass1/2"
  end

  test "scripts of one file name in two directories: two modules, each evaluated from its own copy", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "more"))
    File.write!(Path.join(dir, "more/tool.sc"), "def sq(a: Int): Int = a * a * 10\n")
    files = ["more/tool.sc" | @files]
    {:ok, ctx} = Scanner.Scala.begin(dir, "scala", files: files, env: %{"PATH" => System.get_env("PATH")})
    assert ctx.collisions == %{}

    {_book, r} = run(dir, [{"a", "scripts/tool.sq", [1], ["3"]}, {"b", "more/tool.sq", [1], ["3"]}], Book.new(), project: {"sbt", files})
    assert {:ok, %{display: "9"}} = r["a"].outcome
    assert {:ok, %{display: "90"}} = r["b"].outcome
  end

  test "no build tool (scripts alone): read and evaluated with the scala on PATH", %{dir: dir} do
    File.rm!(Path.join(dir, "build.sbt"))
    {:ok, ctx} = Scanner.Scala.begin(dir, "scala", files: ["scripts/tool.sc"], env: %{"PATH" => System.get_env("PATH")})
    assert Scanner.Scala.describe(ctx) == "Scala's parser: the scala on PATH (no build tool)"
    {_book, r} = run(dir, [{"a", "scripts/tool.sq", [1], ["3"]}], Book.new(), project: {nil, ["scripts/tool.sc"]})
    assert {:ok, %{display: "9"}} = r["a"].outcome
  end

  test "a build that fails: the rows crash naming the compiler's error", %{dir: dir} do
    File.write!(Path.join(dir, "src/main/scala/sample/Broken.scala"), "package sample\nobject Broken { def x: Int = \"s\" }\n")
    {_book, r} = run(dir, [{"a", "sample.Calc.add", [2], ["1", "2"]}])
    assert {:error, "the call did not compile: no object sample.Calc in what was loaded (the build failed: [error]" <> _} = r["a"].outcome
  end

  test "an sbt server running on the build: sbt is not started, the rows crash naming it", %{dir: dir} do
    sock = Path.join(System.tmp_dir!(), "xt_sbt_#{System.unique_integer([:positive])}.sock")
    {:ok, listen} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, sock}, active: false])
    File.mkdir_p!(Path.join(dir, "project/target"))
    File.write!(Path.join(dir, "project/target/active.json"), ~s|{"uri":"local://#{sock}"}|)

    try do
      {_book, r} = run(dir, [{"a", "sample.Calc.add", [2], ["1", "2"]}])
      assert {:error, "the call did not compile: no object sample.Calc in what was loaded (an sbt server is running for this build" <> _} = r["a"].outcome
      refute File.exists?(Path.join(dir, "target"))
    after
      :gen_tcp.close(listen)
      File.rm(sock)
    end
  end

  test "scala-cli: the class path from scala-cli, the compiler of the project's version", %{dir: _dir} do
    dir = Path.join(System.tmp_dir!(), "xipe_totec_scala_cli_live_#{System.unique_integer([:positive])}")
    File.cp_r!(@cli_fixture_dir, dir)

    try do
      {:ok, ctx} = Scanner.Scala.begin(dir, "scala", files: ["Calc.scala"], env: %{"PATH" => System.get_env("PATH")})
      assert Scanner.Scala.describe(ctx) =~ "the project's own compiler (scala3-compiler_3-3.3.6)"

      {_book, r} = run(dir, [{"a", "clisample.Calc.add", [2], ["1", "2"]}], Book.new(), project: {"scala-cli", ["Calc.scala", "project.scala"]})
      assert {:ok, %{repr: "exact", display: "3"}} = r["a"].outcome
    after
      File.rm_rf!(dir)
    end
  end
end
