ExUnit.start()

Code.require_file(Path.expand("../lib/info.exs", __DIR__))

defmodule InfoTest do
  use ExUnit.Case

  alias XipeTotec.Info

  setup do
    path = Path.join(System.tmp_dir!(), "xipe_totec_info_test_#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  test "load/1 on a missing file returns the empty scaffold", %{path: path} do
    assert Info.load(path) == %{"languages" => [], "extensions" => %{}, "repls" => []}
  end

  test "save/2 then load/1 round-trips", %{path: path} do
    info = %{"languages" => ["elixir"], "repls" => [], "project" => nil}
    Info.save(info, path)
    assert Info.load(path) == info
  end

  test "refresh_languages/1 records lib/repl/language/*.exs names and their extensions, leaving other keys untouched" do
    info = %{"languages" => [], "repls" => ["placeholder"], "project" => nil}
    refreshed = Info.refresh_languages(info)

    assert refreshed["languages"] == ["elixir", "haskell", "ocaml"]
    assert refreshed["extensions"] == %{"ex" => ["elixir"], "exs" => ["elixir"], "hs" => ["haskell"], "ml" => ["ocaml"]}
    # each language's REPL and build-tool priority list
    assert refreshed["language_repls"] == %{"elixir" => "iex", "haskell" => "ghci", "ocaml" => "ocaml"}

    assert refreshed["build_tools"] == %{
             "elixir" => [%{"name" => "mix", "markers" => ["mix.exs"]}],
             "haskell" => [
               %{"name" => "stack", "markers" => ["stack.yaml"]},
               %{"name" => "cabal", "markers" => ["*.cabal", "cabal.project"]}
             ],
             "ocaml" => [%{"name" => "dune", "markers" => ["dune-project"]}]
           }

    assert refreshed["repls"] == ["placeholder"]
  end

  test "refresh_languages/2 keeps a clashing extension as a list of every declaring language" do
    dir = Path.join(System.tmp_dir!(), "xipe_totec_info_lang_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    suffix = System.unique_integer([:positive])
    File.write!(Path.join(dir, "c.exs"), "defmodule InfoTestLangC#{suffix} do\n  def extensions, do: [\"c\", \"h\"]\nend\n")
    File.write!(Path.join(dir, "cpp.exs"), "defmodule InfoTestLangCpp#{suffix} do\n  def extensions, do: [\"cpp\", \"h\"]\nend\n")

    refreshed = Info.refresh_languages(%{}, dir)

    assert refreshed["languages"] == ["c", "cpp"]
    assert refreshed["extensions"] == %{"c" => ["c"], "cpp" => ["cpp"], "h" => ["c", "cpp"]}
    # declaring no repl/0 or build_tools/0 records nil / []
    assert refreshed["language_repls"] == %{"c" => nil, "cpp" => nil}
    assert refreshed["build_tools"] == %{"c" => [], "cpp" => []}
  end

  test "language_module/3 resolves only a registered language to its declaring module" do
    dir = Path.join(System.tmp_dir!(), "xipe_totec_info_langmod_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    suffix = System.unique_integer([:positive])
    File.write!(Path.join(dir, "toy.exs"), "defmodule InfoTestLangToy#{suffix} do\n  def extensions, do: [\"toy\"]\nend\n")

    assert {:ok, mod} = Info.language_module("toy", %{"languages" => ["toy"]}, dir)
    assert mod.extensions() == ["toy"]
    # present under dir but never registered (xipe refresh -l) -- P4
    assert Info.language_module("toy", %{"languages" => []}, dir) == {:error, :not_registered}
  end

  test "Elixir's declaration supplies its scanner, the iex adapter and mix-mode's empty launch_opts" do
    assert {:ok, mod} = Info.language_module("elixir", %{"languages" => ["elixir"]})

    assert mod.adapter() == %{
             launch: XipeTotec.Repl.Launch,
             eval_template: XipeTotec.Repl.EvalTemplate,
             scan: XipeTotec.Repl.Eval.Scan.Direct.Iex,
             field_drip: XipeTotec.Repl.Eval.FieldDrip.Elixir
           }

    # elixir-ls first, Elixir's own parser when no language server is reachable
    assert mod.scanner() == [XipeTotec.Scanner.Lsp.Elixir, XipeTotec.Scanner.Elixir]
    assert {[], cleanup} = mod.launch_opts("/nowhere", "mix", [])
    assert cleanup.() == :ok
  end

  test "refresh_repls/1 lists lib/repl/eval/scan/<transport>/*.exs as transport+repl pairs, leaving other keys untouched" do
    info = %{"languages" => ["placeholder"], "repls" => [], "project" => nil}
    refreshed = Info.refresh_repls(info)

    assert refreshed["repls"] == [
             %{"transport" => "direct", "repl" => "ghci"},
             %{"transport" => "direct", "repl" => "iex"},
             %{"transport" => "direct", "repl" => "ocaml"}
           ]
    assert refreshed["languages"] == ["placeholder"]
  end
end
