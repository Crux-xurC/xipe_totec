Code.require_file("../language.exs", __DIR__)
Code.require_file("../fsharp/launch.exs", __DIR__)
Code.require_file("../fsharp/eval_template.exs", __DIR__)
Code.require_file("../eval/scan/direct/fsi.exs", __DIR__)
Code.require_file("../eval/field_drip/fsharp.exs", __DIR__)
Code.require_file("../../scanner/fsharp.exs", __DIR__)

defmodule XipeTotec.Repl.Language.FSharp do
  @moduledoc """
  F#'s `Repl.Language` self-declaration. REPL: F# Interactive (`dotnet
  fsi`) with `embody.fsx` loaded into it
  ([D-fsharp-adapter](../../../document/verification/lib-repl-language-fsharp.exs.md#d-fsharp-adapter)).

  A project's code is built by its own build tool and referenced: every
  project file (`*.fsproj`, outside `bin/` and `obj/`) is built with
  `dotnet build` into a temp dir and `#r`-ed. Its scripts (`.fsx`) are
  loaded with only their definitions (`embody.fsx`'s `Embody.Load`): as
  Elixir's scripts-mode compiles only the `defmodule` parts, loading runs
  none of their top level. A `.fs` file that no project file builds is on
  the map only.

  The build tool is `dotnet` (a `*.fsproj`, `*.sln` or `*.slnx` at the
  root); every project file is built either way, and a project of scripts
  alone has none. Nothing is fetched: packages are restored from an empty
  source (FSharp.Core comes with the SDK; any other package must already
  be in the NuGet cache). The SDK is the one on `PATH`, which a project's
  environment (`project_env.json`) decides.
  """
  @behaviour XipeTotec.Repl.Language

  alias XipeTotec.Repl.FSharp.Launch

  @impl true
  def extensions, do: ["fs", "fsx"]

  @impl true
  def repl, do: "fsi"

  @impl true
  def build_tools, do: [%{"name" => "dotnet", "markers" => ["*.fsproj", "*.sln", "*.slnx"]}]

  @impl true
  def scanner, do: [XipeTotec.Scanner.FSharp]

  @impl true
  def adapter do
    %{
      launch: XipeTotec.Repl.FSharp.Launch,
      eval_template: XipeTotec.Repl.FSharp.EvalTemplate,
      scan: XipeTotec.Repl.Eval.Scan.Direct.Fsi,
      field_drip: XipeTotec.Repl.Eval.FieldDrip.FSharp
    }
  end

  # the start script, init file, build output, script copies and log in a
  # temp dir removed after the pass
  @impl true
  def launch_opts(root, _build_tool, files) do
    root = Path.expand(root)
    dir = Path.join(System.tmp_dir!(), "xipe_totec_fsharp_#{System.unique_integer([:positive])}")
    empty = Path.join(dir, "no-packages")
    File.mkdir_p!(empty)
    log = Path.join(dir, "build.log")
    init = Path.join(dir, "init.fsx")
    script = Path.join(dir, "start.sh")
    projects = projects(root)
    scripts = files |> Enum.filter(&(Path.extname(&1) == ".fsx")) |> Enum.sort()
    File.write!(init, Launch.init_file(log))

    File.write!(
      script,
      Launch.start_script(
        root: root,
        projects: projects,
        assemblies: Enum.map(projects, &assembly_name/1),
        scripts: scripts,
        dir: dir,
        empty: empty,
        log: log,
        init: init
      )
    )

    loads = for rel <- scripts, do: {rel, Path.join([dir, "fsx", rel])}
    {[script: script, loads: loads], fn -> File.rm_rf!(dir) end}
  end

  @doc "The project files under `root` (absolute, sorted), leaving out `bin/`, `obj/` and hidden directories."
  @spec projects(String.t()) :: [String.t()]
  def projects(root) do
    root
    |> Path.join("**/*.fsproj")
    |> Path.wildcard()
    |> Enum.reject(fn path ->
      path |> Path.relative_to(root) |> Path.split() |> Enum.drop(-1) |> Enum.any?(&(&1 in ["bin", "obj"] or String.starts_with?(&1, ".")))
    end)
    |> Enum.sort()
  end

  @doc "The assembly a project file (`*.fsproj`, also C#'s `*.csproj`) builds: its `<AssemblyName>`, else the file's name."
  @spec assembly_name(String.t()) :: String.t()
  def assembly_name(project) do
    with {:ok, text} <- File.read(project),
         [_, name] <- Regex.run(~r{<AssemblyName>\s*([^<$]+?)\s*</AssemblyName>}, text) do
      name
    else
      _ -> Path.basename(project, Path.extname(project))
    end
  end
end
