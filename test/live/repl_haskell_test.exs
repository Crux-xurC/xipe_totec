# Live verification against a real GHCi, the Haskell
# counterpart of repl_iex_test.exs. NOT swept into test/run.sh. Needs `ghci`
# on PATH -- e.g. `nix shell nixpkgs#ghc -c elixir test/live/repl_haskell_test.exs`
# -- and embody.hs (~/my_app/embody, or $XIPE_TOTEC_EMBODY_DIR); without
# `ghci` every test is excluded, without `cabal` (`nixpkgs#cabal-install`)
# or `stack` that one.
#
# Target is test/fixtures/haskell_sample/: Target.hs (an export list hiding
# `hidden`), src/Geo/Shape.hs (imports Target), app/Main.hs (a `main` that
# must never run).
ghci? = System.find_executable("ghci") != nil
cabal? = System.find_executable("cabal") != nil
stack? = System.find_executable("stack") != nil
ExUnit.start(exclude: if(ghci?, do: [], else: [:ghci]) ++ if(cabal?, do: [], else: [:cabal]) ++ if(stack?, do: [], else: [:stack]))
unless ghci?, do: IO.puts("repl_haskell_test: no `ghci` on PATH -- every test excluded")
unless cabal?, do: IO.puts("repl_haskell_test: no `cabal` on PATH -- the cabal test excluded")
unless stack?, do: IO.puts("repl_haskell_test: no `stack` on PATH -- the stack test excluded")

Code.require_file(Path.expand("../../lib/repl/evaluator.exs", __DIR__))
Code.require_file(Path.expand("../../lib/repl/language/haskell.exs", __DIR__))

defmodule ReplLiveHaskellTest do
  use ExUnit.Case

  alias XipeTotec.{Book, Core}
  alias XipeTotec.Repl.{Evaluator, Session}
  alias XipeTotec.Repl.Language.Haskell
  alias XipeTotec.Repl.Sender.Direct

  @moduletag :ghci
  @fixture_dir Path.expand("../fixtures/haskell_sample", __DIR__)
  @files ["Target.hs", "app/Main.hs", "src/Geo/Shape.hs"]

  defp pure_node(module, name), do: %{module: module, name: name, anykey: nil, effect: "pure", effect_source: "user"}

  # one pass over `calls` ([{id, "Module.name" | "name" (Target), args}]);
  # the results by call id. A row already in `book` keeps its value.
  defp run(calls, book \\ Book.new()) do
    book =
      Enum.reduce(calls, book, fn {id, node, args}, book ->
        {module, name} =
          case String.split(node, ".") do
            [n] -> {"Target", n}
            parts -> {parts |> Enum.drop(-1) |> Enum.join("."), List.last(parts)}
          end

        book = Core.put_node(book, "n_" <> node, pure_node(module, name))
        if Book.get(book, :calls, id), do: book, else: Core.add_call(book, id, %{node: "n_" <> node, args: args})
      end)

    {launch_opts, cleanup} = Haskell.launch_opts(@fixture_dir, nil, @files)

    try do
      {:ok, book, results} =
        Evaluator.run_pass(book, "pass1",
          cwd: @fixture_dir,
          call_ids: Enum.map(calls, &elem(&1, 0)),
          launch_opts: launch_opts,
          launch_module: XipeTotec.Repl.Haskell.Launch,
          eval_template_module: XipeTotec.Repl.Haskell.EvalTemplate,
          scan_module: XipeTotec.Repl.Eval.Scan.Direct.Ghci,
          field_drip_module: XipeTotec.Repl.Eval.FieldDrip.Haskell
        )

      {book, Map.new(results, &{&1.call_id, &1})}
    after
      cleanup.()
    end
  end

  test "exact values and their types; references within the pass; unexported and Main functions" do
    {book, r} =
      run([
        {"a", "add", ["2", "3"]},
        {"q", "square", ["⟦a⟧"]},
        {"s", "shapes", ["3"]},
        {"t", "Geo.Shape.total", ["⟦s⟧"]},
        {"m", "table", []},
        {"h", "hidden", ["4"]},
        {"g", "Main.greet", [~s|"x"|]}
      ])

    assert {:ok, %{repr: "exact", type: "Int", display: "5"}} = r["a"].outcome
    assert {:ok, %{display: "25"}} = r["q"].outcome
    assert {:ok, %{repr: "exact", type: "[Shape]", display: "[Circle 0.0,Rect {w = 1, h = 2},Circle 2.0]"}} = r["s"].outcome
    assert {:ok, %{display: "14.0"}} = r["t"].outcome
    assert {:ok, %{repr: "exact", type: "Map [Char] Int", display: ~s|fromList [("a",1),("b",2)]|}} = r["m"].outcome
    assert {:ok, %{display: "400"}} = r["h"].outcome
    assert {:ok, %{display: ~s|"hello x 6"|}} = r["g"].outcome
    assert Book.get(book, :calls, "a").result == "5"
  end

  test "values that don't read back: an infinite list is cut, a function or a type without Show shows its type" do
    {_book, r} = run([{"n", "nats", []}, {"f", "adder", ["1"]}, {"o", "opaque", []}])

    assert {:ok, %{repr: "unsupported", type: "[Integer]", display: "[0,1,2," <> _ = nats}} = r["n"].outcome
    assert String.length(nats) == 2000
    assert {:ok, %{repr: "unsupported", type: "Int -> Int", display: "Int -> Int"}} = r["f"].outcome
    assert {:ok, %{repr: "unsupported", type: "Opaque", display: "Opaque"}} = r["o"].outcome
  end

  test "an exception, a type error, a call that doesn't parse, and a timeout are each row's own; the pass goes on" do
    {_book, r} =
      run([
        {"e1", "first", ["[] :: [Int]"]},
        {"e2", "add", ["1.5", "2"]},
        {"e3", "add", ["(1", "2"]},
        {"e4", "spin", ["0"]},
        {"e5", "add", ["2", "2"]}
      ])

    assert {:error, "first: empty list" <> _} = r["e1"].outcome
    assert {:error, e2} = r["e2"].outcome
    assert e2 =~ "No instance for ‘Fractional Int’"
    assert {:error, e3} = r["e3"].outcome
    assert e3 =~ "Variable not in scope: xt_e3"
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

  # a cabal project, copied (cabal writes dist-newstyle/ into
  # it; CABAL_DIR is a temp dir too), never built before: built, then GHCi
  # under `cabal exec --offline`, the project's own modules -- library and
  # executable -- still loaded from their sources
  @tag :cabal
  test "a cabal project: GHCi started under cabal exec, every component loaded" do
    dir = Path.join(System.tmp_dir!(), "xipe_totec_cabal_live_#{System.unique_integer([:positive])}")
    File.cp_r!(@fixture_dir, dir)
    System.put_env("CABAL_DIR", Path.join(dir, ".cabal-home"))

    File.write!(Path.join(dir, "sample.cabal"), """
    cabal-version: 2.4
    name: sample
    version: 0.1.0.0
    library
      exposed-modules: Target, Geo.Shape
      hs-source-dirs: ., src
      build-depends: base, containers
      default-language: Haskell2010
    executable sample
      main-is: Main.hs
      hs-source-dirs: app
      build-depends: base, sample
      default-language: Haskell2010
    """)

    {launch_opts, cleanup} = Haskell.launch_opts(dir, "cabal", @files)
    assert Enum.take(launch_opts[:argv], -5) == ~w(cabal exec --offline -- ghci)

    book =
      Book.new()
      |> Core.put_node("m", pure_node("Target", "table"))
      |> Core.put_node("g", pure_node("Main", "greet"))
      |> Core.add_call("c1", %{node: "m", args: []})
      |> Core.add_call("c2", %{node: "g", args: [~s|"x"|]})

    try do
      {:ok, _book, results} =
        Evaluator.run_pass(book, "pass1",
          cwd: dir,
          call_ids: ["c1", "c2"],
          launch_opts: launch_opts,
          boot_timeout_ms: 120_000,
          launch_module: XipeTotec.Repl.Haskell.Launch,
          eval_template_module: XipeTotec.Repl.Haskell.EvalTemplate,
          scan_module: XipeTotec.Repl.Eval.Scan.Direct.Ghci,
          field_drip_module: XipeTotec.Repl.Eval.FieldDrip.Haskell
        )

      r = Map.new(results, &{&1.call_id, &1.outcome})
      assert {:ok, %{display: ~s|fromList [("a",1),("b",2)]|}} = r["c1"]
      assert {:ok, %{display: ~s|"hello x 6"|}} = r["c2"]
    after
      cleanup.()
      System.delete_env("CABAL_DIR")
      File.rm_rf!(dir)
    end
  end

  # a stack project with a compiler-only resolver and the system GHC (no
  # snapshot or GHC to download); STACK_ROOT is a temp dir
  @tag :stack
  test "a stack project: GHCi started under stack exec" do
    dir = Path.join(System.tmp_dir!(), "xipe_totec_stack_live_#{System.unique_integer([:positive])}")
    File.cp_r!(@fixture_dir, dir)
    System.put_env("STACK_ROOT", Path.join(dir, ".stack-root"))
    ghc_version = "ghc" |> System.cmd(["--numeric-version"]) |> elem(0) |> String.trim()
    File.write!(Path.join(dir, "stack.yaml"), "resolver: ghc-#{ghc_version}\nsystem-ghc: true\ninstall-ghc: false\npackages: []\n")

    {launch_opts, cleanup} = Haskell.launch_opts(dir, "stack", @files)
    assert launch_opts[:argv] == ~w(stack exec -- ghci)
    book = Book.new() |> Core.put_node("a", pure_node("Target", "add")) |> Core.add_call("c1", %{node: "a", args: ["2", "3"]})

    try do
      {:ok, _book, results} =
        Evaluator.run_pass(book, "pass1",
          cwd: dir,
          call_ids: ["c1"],
          launch_opts: launch_opts,
          boot_timeout_ms: 120_000,
          launch_module: XipeTotec.Repl.Haskell.Launch,
          eval_template_module: XipeTotec.Repl.Haskell.EvalTemplate,
          scan_module: XipeTotec.Repl.Eval.Scan.Direct.Ghci,
          field_drip_module: XipeTotec.Repl.Eval.FieldDrip.Haskell
        )

      assert [%{outcome: {:ok, %{display: "5"}}}] = results
    after
      cleanup.()
      System.delete_env("STACK_ROOT")
      File.rm_rf!(dir)
    end
  end

  test "loading runs no main; SIGINT stops an evaluation, not GHCi" do
    {launch_opts, cleanup} = Haskell.launch_opts(@fixture_dir, nil, @files)
    message = XipeTotec.Repl.Haskell.Launch.build([{:cwd, @fixture_dir} | launch_opts])
    {:ok, handle} = Direct.send(message)

    try do
      assert :ok = Session.await_ready(Direct, handle, message, 60_000)
      Direct.write(handle, "print (Target.spin 0)\n")
      Process.sleep(500)
      Direct.interrupt(handle)
      Direct.write(handle, ~s|putStrLn ("still" ++ "-here")\n|)
      out = collect_until(handle, "still-here", "", 10_000)

      assert out =~ "Interrupted."
      refute out =~ "MAIN RAN"
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
