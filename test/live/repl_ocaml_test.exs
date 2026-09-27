# Live verification against a real plain `ocaml` toplevel (Old.md §42, §43),
# the OCaml counterpart of repl_iex_test.exs. NOT swept into test/run.sh. Needs
# `ocaml` on PATH, and `dune` for the dune test -- e.g.
# `nix shell nixpkgs#ocaml nixpkgs#dune_3 -c elixir test/live/repl_ocaml_test.exs`;
# without them those tests are excluded.
#
# Target is test/fixtures/ocaml_sample/: geometry.ml (with top-level side
# effects that must never run) and area.ml (uses Geometry but sorts before
# it, so loading has to retry).
ocaml? = System.find_executable("ocaml") != nil
dune? = System.find_executable("dune") != nil
ExUnit.start(exclude: if(ocaml?, do: [], else: [:ocaml]) ++ if(dune?, do: [], else: [:dune]))
unless ocaml?, do: IO.puts("repl_ocaml_test: no `ocaml` on PATH -- every test excluded")
unless dune?, do: IO.puts("repl_ocaml_test: no `dune` on PATH -- the dune test excluded")

Code.require_file(Path.expand("../../lib/repl/evaluator.exs", __DIR__))
Code.require_file(Path.expand("../../lib/repl/language/ocaml.exs", __DIR__))

defmodule ReplLiveOcamlTest do
  use ExUnit.Case

  alias XipeTotec.{Book, Core}
  alias XipeTotec.Repl.{Evaluator, Session}
  alias XipeTotec.Repl.Language.Ocaml
  alias XipeTotec.Repl.Sender.Direct

  @moduletag :ocaml
  @fixture_dir Path.expand("../fixtures/ocaml_sample", __DIR__)
  @files ["area.ml", "geometry.ml"]

  defp pure_node(module, name), do: %{module: module, name: name, anykey: nil, effect: "pure", effect_source: "user"}

  # one pass over `calls` ([{id, node_name, args}], nodes in Geometry unless
  # "Area.") with the real toplevel; the outcomes by call id
  defp run(calls, book \\ Book.new()) do
    book =
      Enum.reduce(calls, book, fn {id, node, args}, book ->
        {module, name} = case String.split(node, ".") do
          [m, n] -> {m, n}
          [n] -> {"Geometry", n}
        end

        book = Core.put_node(book, "n_" <> node, pure_node(module, name))
        # a row already in `book` keeps its previous value (compare)
        if Book.get(book, :calls, id), do: book, else: Core.add_call(book, id, %{node: "n_" <> node, args: args})
      end)

    {launch_opts, cleanup} = Ocaml.launch_opts(@fixture_dir, nil, @files)

    try do
      {:ok, book, results} =
        Evaluator.run_pass(book, "pass1",
          cwd: @fixture_dir,
          call_ids: Enum.map(calls, &elem(&1, 0)),
          launch_opts: launch_opts,
          launch_module: XipeTotec.Repl.Ocaml.Launch,
          eval_template_module: XipeTotec.Repl.Ocaml.EvalTemplate,
          scan_module: XipeTotec.Repl.Eval.Scan.Direct.Ocaml,
          field_drip_module: XipeTotec.Repl.Eval.FieldDrip.Ocaml
        )

      {book, Map.new(results, &{&1.call_id, &1})}
    after
      cleanup.()
    end
  end

  test "values, their types, and whether they read back (repr)" do
    {book, r} =
      run([
        {"c1", "add", ["1", "2"]},
        {"c2", "area", ["Geometry.Circle 2."]},
        {"c3", "shapes", ["3"]},
        {"c4", "origin", []},
        {"c5", "adder", ["1"]}
      ])

    assert {:ok, %{repr: "exact", type: "int", display: "3"}} = r["c1"].outcome
    assert {:ok, %{repr: "exact", type: "float", display: "12."}} = r["c2"].outcome
    assert {:ok, %{repr: "exact", type: "Geometry.shape list", display: "[Geometry.Circle 0.; Geometry.Square 1.; Geometry.Circle 2.]"}} = r["c3"].outcome
    assert {:ok, %{repr: "exact", type: "Geometry.point", display: "{Geometry.x = 0; y = 0}"}} = r["c4"].outcome
    # a function prints as <fun>: nothing to read back
    assert {:ok, %{repr: "unsupported", type: "int -> int", display: "<fun>"}} = r["c5"].outcome
    assert Book.get(book, :calls, "c1").result == "3"
  end

  test "a row referring to one evaluated earlier in the same pass; Area loads though it sorts before Geometry" do
    {_book, r} = run([{"s", "shapes", ["3"]}, {"t", "Area.total", ["⟦s⟧"]}, {"a", "add", ["1", "2"]}, {"q", "square", ["⟦a⟧"]}])
    assert {:ok, %{display: "13."}} = r["t"].outcome
    assert {:ok, %{display: "9"}} = r["q"].outcome
  end

  test "an exception, a type error, and a timeout are that row's own outcome; the pass goes on" do
    {_book, r} =
      run([
        {"e1", "first", ["[]"]},
        {"e2", "add", ["1.5", "2"]},
        {"e3", "add", ["(1"]},
        {"e4", "spin", ["0"]},
        {"e5", "add", ["2", "2"]}
      ])

    assert {:error, "Exception: Failure \"hd\"."} = r["e1"].outcome
    assert {:error, e2} = r["e2"].outcome
    assert e2 =~ "Error: The constant 1.5 has type float but an expression was expected of type int"
    assert {:error, e3} = r["e3"].outcome
    assert e3 =~ "Syntax error"
    assert :timeout = r["e4"].outcome
    assert {:ok, %{display: "4"}} = r["e5"].outcome
  end

  test "compare against the previous value: same, changed" do
    {book, _} = run([{"c", "add", ["1", "2"]}])
    {_book, r} = run([{"c", "add", ["1", "2"]}], book)
    assert r["c"].compare == "same"

    book = Book.put(book, :calls, "c", %{Book.get(book, :calls, "c") | args: ["2", "2"]})
    {_book, r} = run([{"c", "add", ["2", "2"]}], book)
    assert r["c"].compare == "changed"
  end

  # a dune project, copied (dune writes _build/ into it): Str from dune's
  # dependencies, the library's own modules from their sources, Mylib.Words
  # through the alias, bin/main.ml loading only once the alias exists
  @tag :dune
  test "a dune project: dependencies through dune, sources without their effects, the library's name" do
    dir = Path.join(System.tmp_dir!(), "xipe_totec_dune_live_#{System.unique_integer([:positive])}")
    File.cp_r!(Path.expand("../fixtures/ocaml_dune", __DIR__), dir)
    files = ["bin/main.ml", "lib/stats.ml", "lib/words.ml"]
    {launch_opts, cleanup} = Ocaml.launch_opts(dir, "dune", files)

    book =
      Book.new()
      |> Core.put_node("w", pure_node("Words", "count"))
      |> Core.put_node("s", pure_node("Stats", "longest"))
      |> Core.put_node("m", pure_node("Main", "greet"))
      |> Core.put_node("q", pure_node("Mylib.Words", "split"))
      |> Core.add_call("c1", %{node: "w", args: [~s|"a b, c"|]})
      |> Core.add_call("c2", %{node: "s", args: [~s|"a bbb cc"|]})
      |> Core.add_call("c3", %{node: "m", args: [~s|"x y"|]})
      |> Core.add_call("c4", %{node: "q", args: [~s|"p q"|]})

    try do
      {:ok, _book, results} =
        Evaluator.run_pass(book, "pass1",
          cwd: dir,
          call_ids: ["c1", "c2", "c3", "c4"],
          launch_opts: launch_opts,
          boot_timeout_ms: 60_000,
          launch_module: XipeTotec.Repl.Ocaml.Launch,
          eval_template_module: XipeTotec.Repl.Ocaml.EvalTemplate,
          scan_module: XipeTotec.Repl.Eval.Scan.Direct.Ocaml,
          field_drip_module: XipeTotec.Repl.Eval.FieldDrip.Ocaml
        )

      r = Map.new(results, &{&1.call_id, &1.outcome})
      assert {:ok, %{display: "3"}} = r["c1"]
      assert {:ok, %{display: ~s|"bbb"|}} = r["c2"]
      assert {:ok, %{display: ~s|"hello x y (2)"|}} = r["c3"]
      assert {:ok, %{display: ~s|["p"; "q"]|}} = r["c4"]
    after
      cleanup.()
      File.rm_rf!(dir)
    end
  end

  test "loading the project runs none of its top-level effects; SIGINT stops a phrase, not the toplevel" do
    {launch_opts, cleanup} = Ocaml.launch_opts(@fixture_dir, nil, @files)
    message = XipeTotec.Repl.Ocaml.Launch.build([{:cwd, @fixture_dir} | launch_opts])
    {:ok, handle} = Direct.send(message)

    try do
      assert :ok = Session.await_ready(Direct, handle, message, 15_000)
      Direct.write(handle, "let _ = Geometry.spin 0;;\n")
      Process.sleep(500)
      Direct.interrupt(handle)
      Direct.write(handle, ~s|print_endline ("still" ^ "-here");;\n|)
      out = collect_until(handle, "still-here", "", 5_000)

      assert out =~ "Interrupted."
      refute out =~ "GEOMETRY SIDE EFFECT"
      assert :ok = Session.close(Direct, handle, message["exit_input"], 5_000)
    after
      if Process.alive?(handle), do: Direct.kill(handle)
      cleanup.()
    end
  end

  defp collect_until(handle, needle, buffer, timeout) do
    if String.contains?(buffer, needle) do
      buffer
    else
      receive do
        {^handle, {:data, chunk}} -> collect_until(handle, needle, buffer <> chunk, timeout)
      after
        timeout -> flunk("never saw #{inspect(needle)}: #{inspect(buffer)}")
      end
    end
  end
end
