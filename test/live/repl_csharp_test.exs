# Live verification of C# through `dotnet fsi`: C#'s adapter (Repl.Language.CSharp) with embody.fsx and
# C#'s seam embody.cs (evolving.md §4.4). NOT swept into test/run.sh. Needs `dotnet` (the .NET 8 SDK,
# which builds net8.0 without fetching anything) on PATH and embody (../embody next to this checkout, or
# $XIPE_TOTEC_EMBODY_DIR); without `dotnet` every test is excluded. For example:
#
#     nix shell github:NixOS/nixpkgs/<xipe_totec's pin>#dotnet-sdk_8 -c elixir test/live/repl_csharp_test.exs
#
# Target is a copy of test/fixtures/csharp_sample/ (one project, Sample.dll).
dotnet? = System.find_executable("dotnet") != nil
ExUnit.start(exclude: if(dotnet?, do: [], else: [:dotnet]), timeout: 300_000)
unless dotnet?, do: IO.puts("repl_csharp_test: no `dotnet` on PATH -- every test excluded")

Code.require_file(Path.expand("../../lib/repl/evaluator.exs", __DIR__))
Code.require_file(Path.expand("../../lib/repl/language/csharp.exs", __DIR__))

defmodule ReplLiveCSharpTest do
  use ExUnit.Case

  alias XipeTotec.{Book, Core}
  alias XipeTotec.Repl.Evaluator
  alias XipeTotec.Repl.Language.CSharp

  @moduletag :dotnet
  @fixture_dir Path.expand("../fixtures/csharp_sample", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "xipe_totec_cs_live_#{System.unique_integer([:positive])}")
    File.cp_r!(@fixture_dir, dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  # one pass over `calls`: {id, "Ns.Type.Method", args} or {id, "Ns.Type.Method", args, anykey, marks}
  # (the node as C#'s scanner gives it); the results by call id. A row already in `book` keeps its value.
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

    {launch_opts, cleanup} = CSharp.launch_opts(dir, "dotnet", ["src/Calc.cs"])

    try do
      Evaluator.run_pass(book, "pass1",
          cwd: dir,
          call_ids: Enum.map(calls, &elem(&1, 0)),
          launch_opts: launch_opts,
          boot_timeout_ms: 90_000,
          launch_module: XipeTotec.Repl.CSharp.Launch,
          eval_template_module: XipeTotec.Repl.CSharp.EvalTemplate,
          scan_module: XipeTotec.Repl.Eval.Scan.Direct.Fsi,
          field_drip_module: XipeTotec.Repl.Eval.FieldDrip.CSharp
      )
      |> case do
        {:ok, book, results} -> {book, Map.new(results, &{&1.call_id, &1})}
        # a start that ended before ready: the pass's own error
        error -> error
      end
    after
      cleanup.()
    end
  end

  # the build wrote only obj/ into the project (bin/ goes to the temp dir; the seam is built there too)
  defp untouched!(dir), do: assert(File.ls!(dir) |> Enum.sort() == ["CsharpSample.csproj", "obj", "src"])

  test "C#'s static methods with F# arguments: values, overloads by count and by type, async awaited, references within the pass", %{dir: dir} do
    {book, r} =
      run(dir, [
        {"a", "Sample.Calc.Add", ["2", "3"], "(int, int)", []},
        {"a3", "Sample.Calc.Add", ["⟦a⟧", "1", "1"], "(int, int, int)", []},
        {"h", "Sample.Calc.Half", ["1.0"]},
        {"r", "Sample.Calc.Range", ["3"]},
        {"l", "Sample.Calc.RangeList", ["⟦a⟧"]},
        {"p", "Sample.Calc.Pair", ["4"]},
        {"g", "Sample.Calc.Greet", [~s|"x"|]},
        # overloads of one count: the argument given its parameter's type (null picks the string one by the type, not by luck)
        {"oi", "Sample.Calls.Over", ["1"], "(int)", ["typed"]},
        {"os", "Sample.Calls.Over", ["null"], "(string)", ["typed"]},
        {"od", "Sample.Calls.Over", ["1"], "(double)", ["typed"]},
        {"w", "Sample.Calls.Wide", ["1"], "(long)", []},
        # Task<T>, Task, ValueTask<T>
        {"la", "Sample.Calls.LaterAsync", ["1"], "(int)", ["async"]},
        {"dn", "Sample.Calls.Done", [], "()", ["async"]},
        {"sn", "Sample.Calls.Soon", [~s|"s"|], "(string)", ["async"]},
        {"id", "Sample.Calls.Id", ["5"], "(T)", []},
        {"op", "Sample.Calls.Opt", ["1"], "(int, int)", []},
        {"pa", "Sample.Calls.Params", ["1", "2", "3"], "(params int[])", []}
      ])

    assert {:ok, %{repr: "exact", type: "int", display: "5"}} = r["a"].outcome
    assert {:ok, %{display: "7"}} = r["a3"].outcome
    assert {:ok, %{type: "float", display: "0.5"}} = r["h"].outcome
    assert {:ok, %{type: "int[]", display: "[|0; 1; 2|]"}} = r["r"].outcome
    assert {:ok, %{display: "ResizeArray [0; 1; 2; 3; 4]"}} = r["l"].outcome
    assert {:ok, %{type: "struct (int * string)", display: ~s|struct (4, "4")|}} = r["p"].outcome
    assert {:ok, %{display: ~s|"hello, x {not a brace}"|}} = r["g"].outcome
    assert {:ok, %{display: ~s|"int 1"|}} = r["oi"].outcome
    assert {:ok, %{display: ~s|"string "|}} = r["os"].outcome
    assert {:ok, %{display: ~s|"double 1"|}} = r["od"].outcome
    assert {:ok, %{type: "int64", display: "2L"}} = r["w"].outcome
    assert {:ok, %{type: "int", display: "2"}} = r["la"].outcome
    assert {:ok, %{type: "unit", display: "()"}} = r["dn"].outcome
    assert {:ok, %{type: "string", display: ~s|"s"|}} = r["sn"].outcome
    assert {:ok, %{display: "5"}} = r["id"].outcome
    assert {:ok, %{display: "11"}} = r["op"].outcome
    assert {:ok, %{display: "6"}} = r["pa"].outcome
    assert Book.get(book, :calls, "a").result == "5"
    untouched!(dir)
  end

  test "records written as their constructor's call: a later row's argument; compare same, changed; others binary or unsupported", %{dir: dir} do
    calls = [
      {"m", "Sample.Geo.Shapes.Mid", ["Sample.Geo.Point(1.0, 2.0)", "Sample.Geo.Point(3.0, 4.0)"], "(Point, Point)", []},
      {"b", "Sample.Calls.Fill", [~s|"x"|, "2"], "(string, int)", []},
      {"t", "Sample.Calls.Mark", [~s|"m"|], "(string)", []},
      {"n", "Sample.Calls.Anon", ["1"], "(int)", []}
    ]

    {book, r} = run(dir, calls)
    assert {:ok, %{repr: "exact", type: "Sample.Geo.Point", display: "Sample.Geo.Point(2.0, 3.0)"}} = r["m"].outcome
    assert {:ok, %{repr: "exact", display: ~s|Sample.Bag("x", ResizeArray [0; 1])|}} = r["b"].outcome
    assert {:ok, %{repr: "binary", display: "Tag { Text = m }"}} = r["t"].outcome
    assert {:ok, %{repr: "unsupported", display: "{ N = 1, S = 1 }"}} = r["n"].outcome

    # again: the same values (the Bag's list element by element)
    {book, r} = run(dir, calls, book)
    for id <- ~w(m b), do: assert(r[id].compare == "same", id)

    book = Book.put(book, :calls, "b", %{Book.get(book, :calls, "b") | args: [~s|"x"|, "3"]})
    {book, r} = run(dir, [{"b", "Sample.Calls.Fill", [~s|"x"|, "3"], "(string, int)", []}], book)
    assert r["b"].compare == "changed"

    # the stored record, embedded as its literal into another row
    {_book, r} = run(dir, [{"m2", "Sample.Geo.Shapes.Mid", ["⟦m⟧", "⟦m⟧"], "(Point, Point)", []}], book)
    assert {:ok, %{display: "Sample.Geo.Point(2.0, 3.0)"}} = r["m2"].outcome
  end

  test "failures each row's own, in C#'s terms: an exception, an instance method, internal, the overloads' counts and signatures", %{dir: dir} do
    {_book, r} =
      run(dir, [
        # first: nothing has loaded Sample.dll yet (Embody.reference)
        {"e1", "Sample.Calc.Hidden", ["1"], "(int)", []},
        {"e2", "Sample.Calc.Boom", ["1"], "(int)", []},
        {"e3", "Sample.Counter.Step", ["1"], "(int)", []},
        {"e4", "Sample.Calls.Over", ["1", "2", "3"], "(int)", []},
        {"e5", "Sample.Calc.Add", ["1", ~s|"x"|], "(int, int)", []},
        {"e6", "Sample.Nope.F", ["1"], "(int)", []},
        {"ok", "Sample.Calc.Add", ["2", "2"], "(int, int)", []}
      ])

    head = "the call did not compile: "
    assert {:error, ^head <> "Sample.Calc.Hidden is internal: only public static methods are called"} = r["e1"].outcome
    assert {:error, "System.InvalidOperationException: boom: 1"} = r["e2"].outcome
    assert {:error, ^head <> "Sample.Counter.Step is an instance method: only public static methods are called (int Step(int by))"} = r["e3"].outcome
    assert {:error, ^head <> "Sample.Calls.Over takes 1 argument(s), got 3: static string Over(int x); " <> _} = r["e4"].outcome
    assert {:error, ^head <> "the arguments do not fit static int Add(int a, int b); static int Add(int a, int b, int c)" <> _} = r["e5"].outcome
    assert {:error, ^head <> "no module Sample.Nope in what was loaded"} = r["e6"].outcome
    assert {:ok, %{display: "4"}} = r["ok"].outcome
  end

  test "an embody whose embody.cs speaks another protocol: the start ends at once, naming it", %{dir: dir} do
    old = Path.join(dir, "old_embody")
    File.mkdir_p!(old)
    real = XipeTotec.Repl.Embody.dir()
    File.cp!(Path.join(real, "embody.fsx"), Path.join(old, "embody.fsx"))
    File.write!(Path.join(old, "embody.cs"), String.replace(File.read!(Path.join(real, "embody.cs")), "Protocol = 1;", "Protocol = 0;"))
    before = System.get_env("XIPE_TOTEC_EMBODY_DIR")
    System.put_env("XIPE_TOTEC_EMBODY_DIR", old)

    try do
      assert {:error, {:boot_failed, {:exited_before_ready, "1", reason}}} = run(dir, [{"a", "Sample.Calc.Add", ["1", "2"], "(int, int)", []}])
      assert reason == "embody.cs at #{old}/embody.cs does not speak protocol 1 (EmbodyCs.Seam.Protocol): update embody (git pull) to the one this Xipe Totec was made with"
    after
      if before, do: System.put_env("XIPE_TOTEC_EMBODY_DIR", before), else: System.delete_env("XIPE_TOTEC_EMBODY_DIR")
    end
  end
end
