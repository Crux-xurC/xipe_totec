# Live verification of Java through Scala 3's REPL: Java's adapter (Repl.Language.Java) with embody.scala
# and Java's seam embody.java (evolving.md §4.6). NOT swept into test/run.sh. Needs a JDK (`java`, `javac`),
# maven with its plugins in its local repository (build test/fixtures/java_sample once online: `mvn
# compile dependency:build-classpath`) and `scala` (Scala 3) on PATH, and embody (../embody next to this
# checkout, or $XIPE_TOTEC_EMBODY_DIR); without them every test is excluded. For example:
#
#     nix shell <xipe_totec's pin>#jdk <pin>#maven <pin>#scala_3 -c elixir test/live/repl_java_test.exs
#
# Target is a copy of test/fixtures/java_sample/ (one maven module).
tools? = Enum.all?(~w(java javac mvn scala), &System.find_executable/1)
ExUnit.start(exclude: if(tools?, do: [], else: [:java]), timeout: 300_000)
unless tools?, do: IO.puts("repl_java_test: no java, javac, mvn or scala on PATH -- every test excluded")

Code.require_file(Path.expand("../../lib/repl/evaluator.exs", __DIR__))
Code.require_file(Path.expand("../../lib/repl/language/java.exs", __DIR__))

defmodule ReplLiveJavaTest do
  use ExUnit.Case

  alias XipeTotec.{Book, Core, Scanner}
  alias XipeTotec.Repl.Evaluator
  alias XipeTotec.Repl.Language.Java

  @moduletag :java
  @fixture_dir Path.expand("../fixtures/java_sample", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "xipe_totec_java_live_#{System.unique_integer([:positive])}")
    File.cp_r!(@fixture_dir, dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp files(dir), do: dir |> Path.join("**/*.java") |> Path.wildcard() |> Enum.map(&Path.relative_to(&1, dir)) |> Enum.sort()

  # one pass over `calls`: {id, "pkg.Type.method", args} or {id, "pkg.Type.method", args, anykey, marks} (the node
  # as Java's scanner gives it); the results by call id, or the pass's own error. A row already in `book` keeps its value.
  defp run(dir, calls, book \\ Book.new()) do
    book =
      Enum.reduce(calls, book, fn call, book ->
        {id, node, args, key, marks} =
          case call do
            {id, node, args} -> {id, node, args, "(#{length(args)})", []}
            {_, _, _, _, _} = c -> c
          end

        parts = String.split(node, ".")
        {module, name} = {parts |> Enum.drop(-1) |> Enum.join("."), List.last(parts)}
        node_id = "n_#{node}#{key}"

        book =
          Core.put_node(book, node_id, %{
            module: module, name: name, anykey: key, shape: [length(args)], marks: marks, effect: "pure", effect_source: "user"
          })

        if Book.get(book, :calls, id), do: book, else: Core.add_call(book, id, %{node: node_id, args: args})
      end)

    {launch_opts, cleanup} = Java.launch_opts(dir, "maven", files(dir))

    try do
      Evaluator.run_pass(book, "pass1",
        cwd: dir,
        call_ids: Enum.map(calls, &elem(&1, 0)),
        launch_opts: launch_opts,
        boot_timeout_ms: 120_000,
        launch_module: XipeTotec.Repl.Java.Launch,
        eval_template_module: XipeTotec.Repl.Java.EvalTemplate,
        scan_module: XipeTotec.Repl.Eval.Scan.Direct.Scala,
        field_drip_module: XipeTotec.Repl.Eval.FieldDrip.Java
      )
      |> case do
        {:ok, book, results} -> {book, Map.new(results, &{&1.call_id, &1})}
        error -> error
      end
    after
      cleanup.()
    end
  end

  test "the scan: the JDK's parser; types as anykey, the shape, marks, the refusal, visibility, links", %{dir: dir} do
    {:ok, ctx} = Scanner.Java.begin(dir, "java", files: files(dir), env: %{"PATH" => System.get_env("PATH")})
    file = fn path -> %{root: dir, path: path, source: "", ctx: ctx} end
    calc = Map.new(Scanner.Java.defs(file.("src/main/java/sample/Calc.java")), &{{&1.name, &1.anykey}, &1})

    assert %{shape: [2], visibility: "public", marks: []} = calc[{"add", "(int, int)"}]
    assert %{marks: ["typed"]} = calc[{"over", "(String)"}]
    assert %{marks: ["varargs"]} = calc[{"sum", "(int...)"}]
    assert %{marks: ["async"]} = calc[{"later", "(int)"}]
    assert %{refusal: "its type parameter T" <> _} = calc[{"make", "()"}]
    assert %{refusal: nil} = calc[{"id", "(T)"}]
    for n <- ["hidden", "secret", "step"], do: assert(%{visibility: "private"} = calc[{n, "(int)"}])

    book = Enum.reduce(files(dir), Book.new(), fn p, b -> elem(Scanner.Java.scan_defs(b, p, file.(p)), 0) end)
    ids = for {id, n} <- book.nodes, into: %{}, do: {{n.module, n.name, n.anykey}, id}
    book = Enum.reduce(files(dir), book, fn p, b -> b |> Scanner.Java.scan_links_report(ids, file.(p)) |> elem(0) end)

    edges =
      for {_, l} <- book.links do
        n = Book.get(book, :nodes, l.node)
        r = Book.get(book, :nodes, l.ref)
        {"#{n.module}.#{n.name}#{n.anykey}", "#{r.module}.#{r.name}#{r.anykey}"}
      end

    for edge <- [
          {"sample.Calc.add(int, int, int)", "sample.Calc.add(int, int)"},
          {"sample.Ops.triple(int)", "sample.Calc.add(int, int)"},
          {"sample.geo.Shapes.twiceAdd(int)", "sample.Calc.add(int, int)"},
          {"sample.geo.Shapes.describe(Point)", "sample.geo.Shapes.Inner.label(Point)"},
          {"sample.geo.Shapes.describe(Point)", "sample.Calc.half(double)"}
        ] do
      assert edge in edges, inspect(edge)
    end
  end

  test "Java's static methods with Scala arguments: values, overloads by count and by type, varargs, futures awaited, references within the pass", %{dir: dir} do
    {book, r} =
      run(dir, [
        {"a", "sample.Calc.add", ["2", "3"], "(int, int)", []},
        {"a3", "sample.Calc.add", ["⟦a⟧", "1", "1"], "(int, int, int)", []},
        {"h", "sample.Calc.half", ["1.0"]},
        {"r", "sample.Calc.range", ["3"]},
        {"l", "sample.Calc.rangeList", ["⟦a⟧"]},
        {"m", "sample.Calc.counts", [~s|"aab"|]},
        {"o", "sample.Calc.maybe", ["true"]},
        {"oe", "sample.Calc.maybe", ["false"]},
        {"tw", "sample.Calc.twice", [~s|"a"|]},
        {"oi", "sample.Calc.over", ["1"], "(int)", ["typed"]},
        {"os", "sample.Calc.over", ["null"], "(String)", ["typed"]},
        {"od", "sample.Calc.over", ["1"], "(double)", ["typed"]},
        {"w", "sample.Calc.wide", ["1"], "(long)", []},
        {"v", "sample.Calc.sum", ["Array(1, 2, 3)"], "(int...)", ["varargs"]},
        {"v0", "sample.Calc.sum", ["Array[Int]()"], "(int...)", ["varargs"]},
        {"f", "sample.Calc.later", ["1"], "(int)", ["async"]},
        {"id", "sample.Calc.id", ["5"], "(T)", []},
        {"n", "sample.Calc.next", ["sample.Color.RED"], "(Color)", []},
        {"t", "sample.Ops.triple", ["2"], "(int)", []},
        {"in", "sample.geo.Shapes.Inner.label", ["sample.Point(1.0, 2.0)"], "(Point)", []}
      ])

    assert {:ok, %{repr: "exact", type: "Int", display: "5"}} = r["a"].outcome
    assert {:ok, %{display: "7"}} = r["a3"].outcome
    assert {:ok, %{type: "Double", display: "0.5"}} = r["h"].outcome
    assert {:ok, %{type: "Array[Int]", display: "Array(0, 1, 2)"}} = r["r"].outcome
    assert {:ok, %{repr: "exact", display: "java.util.ArrayList[java.lang.Integer](java.util.List.of[java.lang.Integer](0, 1, 2, 3, 4))"}} = r["l"].outcome
    assert {:ok, %{repr: "exact", display: "java.util.HashMap[String, java.lang.Integer](" <> _}} = r["m"].outcome
    assert {:ok, %{repr: "exact", display: ~s|java.util.Optional.of[String]("yes")|}} = r["o"].outcome
    assert {:ok, %{repr: "exact", display: "java.util.Optional.empty()"}} = r["oe"].outcome
    assert {:ok, %{repr: "exact", display: ~s|java.util.List.of[String]("a", "a")|}} = r["tw"].outcome
    assert {:ok, %{display: ~s|"int 1"|}} = r["oi"].outcome
    assert {:ok, %{display: ~s|"string null"|}} = r["os"].outcome
    assert {:ok, %{display: ~s|"double 1.0"|}} = r["od"].outcome
    assert {:ok, %{type: "Long", display: "2L"}} = r["w"].outcome
    assert {:ok, %{display: "6"}} = r["v"].outcome
    assert {:ok, %{display: "0"}} = r["v0"].outcome
    assert {:ok, %{type: "Int", display: "2"}} = r["f"].outcome
    assert {:ok, %{display: "5"}} = r["id"].outcome
    assert {:ok, %{repr: "exact", display: "sample.Color.BLUE"}} = r["n"].outcome
    assert {:ok, %{display: "6"}} = r["t"].outcome
    assert {:ok, %{display: ~s|"(1.0, 2.0)"|}} = r["in"].outcome
    assert Book.get(book, :calls, "a").result == "5"
    # maven wrote target/ into the project, as it does; nothing else
    assert File.ls!(dir) |> Enum.sort() == ["pom.xml", "src", "target"]
    refute File.exists?(Path.join(dir, "target/xipe_totec.cp"))
  end

  test "records written as their constructor's call: a later row's argument; compare same, changed, a List inside; others binary or unsupported", %{dir: dir} do
    calls = [
      {"p", "sample.Calc.mid", ["sample.Point(1.0, 2.0)", "sample.Point(3.0, 4.0)"], "(Point, Point)", []},
      {"b", "sample.Calc.fill", [~s|"x"|, "2"], "(String, int)", []},
      {"g", "sample.Calc.mark", [~s|"m"|], "(String)", []},
      {"fn", "sample.Calc.task", [], "()", []}
    ]

    {book, r} = run(dir, calls)
    assert {:ok, %{repr: "exact", type: "sample.Point", display: "sample.Point(2.0, 3.0)"}} = r["p"].outcome

    assert {:ok, %{repr: "exact", display: ~s|sample.Bag("x", java.util.ArrayList[java.lang.Integer](java.util.List.of[java.lang.Integer](0, 1)))|}} =
             r["b"].outcome

    assert {:ok, %{repr: "binary", type: "sample.Tag"}} = r["g"].outcome
    assert {:ok, %{repr: "unsupported", type: "Function"}} = r["fn"].outcome

    {book, r} = run(dir, calls, book)
    for id <- ~w(p b g), do: assert(r[id].compare == "same", id)

    book = Book.put(book, :calls, "b", %{Book.get(book, :calls, "b") | args: [~s|"x"|, "3"]})
    {book, r} = run(dir, [{"b", "sample.Calc.fill", [~s|"x"|, "3"], "(String, int)", []}], book)
    assert r["b"].compare == "changed"

    # the stored record, embedded as its literal into another row
    {_book, r} = run(dir, [{"p2", "sample.Calc.mid", ["⟦p⟧", "⟦p⟧"], "(Point, Point)", []}], book)
    assert {:ok, %{display: "sample.Point(2.0, 3.0)"}} = r["p2"].outcome
  end

  test "failures each row's own, in Java's terms: package-private first, exceptions checked or not, an instance method, the overloads", %{dir: dir} do
    {_book, r} =
      run(dir, [
        {"e1", "sample.Calc.hidden", ["1"], "(int)", []},
        {"e2", "sample.Calc.boom", ["1"], "(int)", []},
        {"e3", "sample.Calc.checked", ["1"], "(int)", []},
        {"e4", "sample.Calc.step", ["1"], "(int)", []},
        {"e5", "sample.Calc.over", ["1", "2", "3"], "(int)", []},
        {"e6", "sample.Calc.add", ["1", ~s|"x"|], "(int, int)", []},
        {"e7", "sample.Nope.f", ["1"], "(int)", []},
        {"e8", "sample.Calc.secret", ["1"], "(int)", []},
        {"ok", "sample.Calc.add", ["2", "2"], "(int, int)", []}
      ])

    head = "the call did not compile: "
    assert {:error, ^head <> "sample.Calc.hidden is package-private: only public static methods are called"} = r["e1"].outcome
    assert {:error, "java.lang.IllegalStateException: boom: 1"} = r["e2"].outcome
    assert {:error, "java.io.IOException: io: 1"} = r["e3"].outcome
    assert {:error, ^head <> "sample.Calc.step is an instance method: only public static methods are called (int step(int))"} = r["e4"].outcome
    assert {:error, ^head <> "sample.Calc.over takes 1 argument(s), got 3: " <> _} = r["e5"].outcome
    assert {:error, ^head <> "the arguments do not fit static int add(int, int); static int add(int, int, int)" <> _} = r["e6"].outcome
    assert {:error, ^head <> "no object sample.Nope in what was loaded"} = r["e7"].outcome
    assert {:error, ^head <> "sample.Calc.secret is private: only public static methods are called"} = r["e8"].outcome
    assert {:ok, %{display: "4"}} = r["ok"].outcome
  end

  test "a build that fails: every row a crash naming maven's first error", %{dir: dir} do
    File.write!(Path.join(dir, "src/main/java/sample/Broken.java"), "package sample; public class Broken { int x = ; }\n")
    {_book, r} = run(dir, [{"a", "sample.Calc.add", ["1", "2"], "(int, int)", []}])
    assert {:error, "the call did not compile: no object sample.Calc in what was loaded (the build failed: " <> why} = r["a"].outcome
    assert why =~ "Broken.java"
  end

  test "a timeout: the rest of the pass in a new session, the build not run again", %{dir: dir} do
    {_book, r} =
      run(dir, [
        {"s", "sample.Calc.spin", [], "()", []},
        {"a", "sample.Calc.add", ["1", "2"], "(int, int)", []}
      ])

    assert r["s"].outcome == :timeout
    assert {:ok, %{display: "3"}} = r["a"].outcome
  end

  test "an embody whose embody.java speaks another protocol: the start ends at once, naming it", %{dir: dir} do
    old = Path.join(dir, "old_embody")
    File.mkdir_p!(old)
    real = XipeTotec.Repl.Embody.dir()
    File.cp!(Path.join(real, "embody.scala"), Path.join(old, "embody.scala"))
    File.write!(Path.join(old, "embody.java"), String.replace(File.read!(Path.join(real, "embody.java")), "PROTOCOL = 1;", "PROTOCOL = 0;"))
    before = System.get_env("XIPE_TOTEC_EMBODY_DIR")
    System.put_env("XIPE_TOTEC_EMBODY_DIR", old)

    try do
      assert {:error, {:boot_failed, {:exited_before_ready, "1", reason}}} = run(dir, [{"a", "sample.Calc.add", ["1", "2"], "(int, int)", []}])

      assert reason ==
               "embody.java at #{old}/embody.java does not speak protocol 1 (embodyjava.embody.PROTOCOL): update embody (git pull) to the one this Xipe Totec was made with"
    after
      if before, do: System.put_env("XIPE_TOTEC_EMBODY_DIR", before), else: System.delete_env("XIPE_TOTEC_EMBODY_DIR")
    end
  end
end
