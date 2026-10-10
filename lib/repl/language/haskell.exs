Code.require_file("../language.exs", __DIR__)
Code.require_file("../haskell/launch.exs", __DIR__)
Code.require_file("../haskell/eval_template.exs", __DIR__)
Code.require_file("../eval/scan/direct/ghci.exs", __DIR__)
Code.require_file("../eval/field_drip/haskell.exs", __DIR__)
Code.require_file("../../scanner/haskell.exs", __DIR__)

defmodule XipeTotec.Repl.Language.Haskell do
  @moduledoc """
  Haskell's `Repl.Language` self-declaration. REPL: GHCi,
  with `embody.hs` loaded next to the project's modules.

  Every project is loaded the same way: GHCi `:load`s its `.hs` files
  (nothing runs -- Haskell has no top-level effects, and `main` isn't
  called), with each file's source root on the search path (`-i`: `src/`
  for `src/Geo/Shape.hs`, module `Geo.Shape`) and every module in scope as
  `*M`.

  The build tool only changes how GHCi is started: under
  `cabal exec --offline --` or `stack exec --`, so the packages the project
  depends on are visible to it, the project's own modules still loaded
  from their sources as above -- every component (library, executables,
  tests) at once, which `cabal repl` can't do with embody added (its
  multi-repl mode has no `:add`). The dependencies must already be there
  (built, or provided by the environment, e.g. nix's `ghcWithPackages`):
  `--offline` keeps cabal from fetching anything while evaluating. For
  cabal the project is built (`cabal build --offline all`) before GHCi
  starts -- `cabal exec` needs that once (`ghci/1`). cabal writes
  `dist-newstyle/` into the project, stack `.stack-work/`.

  Several files without a `module` header (or `module Main`) can't be
  loaded together; when there are several, none of them is loaded.
  """
  @behaviour XipeTotec.Repl.Language

  alias XipeTotec.Repl.Haskell.Launch
  alias XipeTotec.Scanner.Haskell, as: Scan

  @impl true
  def extensions, do: ["hs"]

  @impl true
  def repl, do: "ghci"

  @impl true
  def build_tools,
    do: [
      %{"name" => "stack", "markers" => ["stack.yaml"]},
      %{"name" => "cabal", "markers" => ["*.cabal", "cabal.project"]}
    ]

  @impl true
  def scanner, do: [XipeTotec.Scanner.Haskell]

  @impl true
  def adapter do
    %{
      launch: XipeTotec.Repl.Haskell.Launch,
      eval_template: XipeTotec.Repl.Haskell.EvalTemplate,
      scan: XipeTotec.Repl.Eval.Scan.Direct.Ghci,
      field_drip: XipeTotec.Repl.Eval.FieldDrip.Haskell
    }
  end

  # the GHCi script in a temp dir removed after the pass
  @impl true
  def launch_opts(root, build_tool, files) do
    root = Path.expand(root)
    loaded = load_plan(root, files)
    dir = Path.join(System.tmp_dir!(), "xipe_totec_haskell_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    script = Path.join(dir, "load.ghci")
    paths = Enum.map(loaded, &Path.join(root, &1.path))
    File.write!(script, Launch.script(paths, Enum.map(loaded, & &1.module)))
    include = loaded |> Enum.map(&Path.expand(&1.source_root, root)) |> Enum.uniq()
    {[argv: ghci(build_tool), script: script, include: include], fn -> File.rm_rf!(dir) end}
  end

  @doc """
  How GHCi is started for the project's build tool (`nil`: plain `ghci`).
  cabal: `cabal exec` fails until the project has been built once (its
  store's package database doesn't exist yet), so the project is built
  first -- offline, output dropped, its failure not stopping GHCi (the
  sources are loaded by GHCi either way), as dune builds for `dune ocaml
  top`. The GHCi flags `Launch` appends reach `ghci` through
  `"$@"`, so nothing is quoted by hand.
  """
  @spec ghci(String.t() | nil) :: [String.t()]
  def ghci("cabal"),
    do: ["sh", "-c", ~s|cabal build --offline all > /dev/null 2>&1; exec "$@"|, "sh"] ++ ~w(cabal exec --offline -- ghci)

  def ghci("stack"), do: ~w(stack exec -- ghci)
  def ghci(_none), do: ["ghci"]

  @doc """
  The files GHCi loads, each with its module and its source root (the
  directory its module path starts from): `%{path:, module:, source_root:}`.
  `Main` modules only when there is just one.
  """
  @spec load_plan(String.t(), [String.t()]) :: [map()]
  def load_plan(root, files) do
    plan =
      for path <- files, source = File.read(Path.join(root, path)), match?({:ok, _}, source) do
        {:ok, text} = source
        module = Scan.module_name(text)
        %{path: path, module: module, source_root: source_root(path, module)}
      end

    case Enum.count(plan, &(&1.module == "Main")) do
      n when n > 1 -> Enum.reject(plan, &(&1.module == "Main"))
      _ -> plan
    end
  end

  # src/Geo/Shape.hs, Geo.Shape -> src ; a path that doesn't end in the
  # module's own path -> the file's directory
  defp source_root(path, module) do
    dirs = path |> Path.dirname() |> Path.split() |> Enum.reject(&(&1 == "."))
    parents = module |> String.split(".") |> Enum.drop(-1)

    if Enum.take(dirs, -length(parents)) == parents and length(dirs) >= length(parents),
      do: dirs |> Enum.drop(-length(parents)) |> then(&if(&1 == [], do: ".", else: Path.join(&1))),
      else: Path.dirname(path)
  end
end
