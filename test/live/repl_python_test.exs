# Live verification against a real `python -i`, the Python counterpart of
# repl_iex_test.exs. NOT swept into test/run.sh. Needs `python3` on PATH and
# embody.py (../embody next to this checkout, or $XIPE_TOTEC_EMBODY_DIR);
# without `python3` every test is excluded.
#
# Target is a copy of test/fixtures/python_sample/ (a top level that writes
# files and prints, which must never run): target.py, and the src-layout
# package geo (geo/__init__.py, geo/shape.py importing target and .units).
python? = System.find_executable("python3") != nil
ExUnit.start(exclude: if(python?, do: [], else: [:python]))
unless python?, do: IO.puts("repl_python_test: no `python3` on PATH -- every test excluded")

Code.require_file(Path.expand("../../lib/repl/evaluator.exs", __DIR__))
Code.require_file(Path.expand("../../lib/repl/language/python.exs", __DIR__))

defmodule ReplLivePythonTest do
  use ExUnit.Case

  alias XipeTotec.{Book, Core}
  alias XipeTotec.Repl.Evaluator
  alias XipeTotec.Repl.Language.Python

  @moduletag :python
  @fixture_dir Path.expand("../fixtures/python_sample", __DIR__)
  @files ["target.py", "src/geo/__init__.py", "src/geo/shape.py", "src/geo/units.py"]

  setup do
    dir = Path.join(System.tmp_dir!(), "xipe_totec_python_live_#{System.unique_integer([:positive])}")
    File.cp_r!(@fixture_dir, dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp pure_node(module, name), do: %{module: module, name: name, anykey: nil, effect: "pure", effect_source: "user"}

  # one pass over `calls` ([{id, "module.name" | "name" (target), args}]);
  # the results by call id. A row already in `book` keeps its value.
  defp run(dir, calls, book \\ Book.new(), opts \\ []) do
    book =
      Enum.reduce(calls, book, fn {id, node, args}, book ->
        {module, name} =
          case String.split(node, ".") do
            [n] -> {"target", n}
            parts -> {parts |> Enum.drop(-1) |> Enum.join("."), List.last(parts)}
          end

        book = Core.put_node(book, "n_" <> node, pure_node(module, name))
        if Book.get(book, :calls, id), do: book, else: Core.add_call(book, id, %{node: "n_" <> node, args: args})
      end)

    {launch_opts, cleanup} = Python.launch_opts(dir, nil, @files)

    try do
      {:ok, book, results} =
        Evaluator.run_pass(
          book,
          "pass1",
          [
            cwd: dir,
            call_ids: Enum.map(calls, &elem(&1, 0)),
            launch_opts: launch_opts,
            launch_module: XipeTotec.Repl.Python.Launch,
            eval_template_module: XipeTotec.Repl.Python.EvalTemplate,
            scan_module: XipeTotec.Repl.Eval.Scan.Direct.Python,
            field_drip_module: XipeTotec.Repl.Eval.FieldDrip.Python
          ] ++ opts
        )

      {book, Map.new(results, &{&1.call_id, &1})}
    after
      cleanup.()
    end
  end

  defp untouched!(dir) do
    assert File.ls!(dir) |> Enum.sort() == ["src", "target.py"]
    assert File.ls!(Path.join(dir, "src/geo")) |> Enum.sort() == ["__init__.py", "shape.py", "units.py"]
  end

  test "exact values and their types; references within the pass; a src-layout package; nothing of the top level runs", %{dir: dir} do
    {book, r} =
      run(dir, [
        {"a", "add", ["2", "3"]},
        {"q", "square", ["⟦a⟧"]},
        {"h", "_hidden", ["4"]},
        {"s", "geo.units.scale", ["⟦a⟧"]},
        {"g", "geo.shape.grow", ["2"]},
        {"m", "multi", [~s|"x"|]}
      ])

    assert {:ok, %{repr: "exact", type: "int", display: "5"}} = r["a"].outcome
    assert {:ok, %{display: "25"}} = r["q"].outcome
    # FACTOR, a literal constant, is loaded
    assert {:ok, %{display: "12"}} = r["h"].outcome
    assert {:ok, %{display: "10"}} = r["s"].outcome
    assert {:ok, %{display: "8"}} = r["g"].outcome
    assert {:ok, %{repr: "exact", type: "list", display: ~s|['x', (1, 2)]|}} = r["m"].outcome
    assert Book.get(book, :calls, "a").result == "5"
    untouched!(dir)
  end

  test "values that don't read back: a pickle (binary) or nothing (unsupported)", %{dir: dir} do
    {_book, r} = run(dir, [{"c", "cyc", []}, {"p", "point", ["3"]}, {"f", "lam", []}, {"n", "naturals", []}, {"w", "later", ["1"]}])

    assert {:ok, %{repr: "binary", type: "list", display: "[[...]]", bin: bin}} = r["c"].outcome
    assert is_binary(bin)
    assert {:ok, %{repr: "binary", type: "target.Point"}} = r["p"].outcome
    assert {:ok, %{repr: "unsupported", type: "function"}} = r["f"].outcome
    assert {:ok, %{repr: "unsupported", type: "itertools.count", display: "count(0)"}} = r["n"].outcome
    # an async function gives its coroutine, not awaited
    assert {:ok, %{repr: "unsupported", type: "coroutine"}} = r["w"].outcome
  end

  test "an exception, a type error, a call that doesn't parse, a name not loaded, and a timeout are each row's own", %{dir: dir} do
    {_book, r} =
      run(dir, [
        {"e1", "boom", []},
        {"e2", "add", ["1", ~s|"x"|]},
        {"e3", "add", ["[1", "2"]},
        {"e4", "spin", []},
        {"e5", "add", ["2", "2"]}
      ])

    assert {:error, "ValueError: bad\\nsecond"} = r["e1"].outcome
    assert {:error, "TypeError: " <> _} = r["e2"].outcome
    assert {:error, "SyntaxError: " <> _} = r["e3"].outcome
    assert :timeout = r["e4"].outcome
    assert {:ok, %{display: "4"}} = r["e5"].outcome
  end

  test "compare against the previous value: same, changed; a float within tolerance; a binary value", %{dir: dir} do
    {book, _} = run(dir, [{"c", "add", ["1", "2"]}, {"f", "floaty", []}, {"p", "point", ["3"]}])
    {book, r} = run(dir, [{"c", "add", ["1", "2"]}, {"f", "floaty", []}, {"p", "point", ["3"]}], book)
    assert r["c"].compare == "same"
    assert r["f"].compare == "same"
    assert r["p"].compare == "same"

    book = Book.put(book, :calls, "c", %{Book.get(book, :calls, "c") | args: ["2", "2"]})
    {_book, r} = run(dir, [{"c", "add", ["2", "2"]}], book)
    assert r["c"].compare == "changed"
  end
end
