Code.require_file("../language.exs", __DIR__)
Code.require_file("fsharp.exs", __DIR__)
Code.require_file("../csharp/launch.exs", __DIR__)
Code.require_file("../csharp/eval_template.exs", __DIR__)
Code.require_file("../eval/scan/direct/fsi.exs", __DIR__)
Code.require_file("../eval/field_drip/csharp.exs", __DIR__)
Code.require_file("../../scanner/csharp.exs", __DIR__)

defmodule XipeTotec.Repl.Language.CSharp do
  @moduledoc """
  C#'s `Repl.Language` self-declaration. REPL: F# Interactive (`dotnet
  fsi`), F#'s window, with `embody.fsx` and C#'s seam `embody.cs` loaded
  into it ([D-csharp-adapter](../../../document/verification/lib-repl-language-csharp.exs.md#d-csharp-adapter);
  `evolving.md` §4.4).

  Every project file (`*.csproj`, outside `bin/` and `obj/`) is built
  with `dotnet build` into a temp dir and `#r`-ed, as F#'s are; the seam
  is built beside it, never written into the project. The calls are C#'s
  public static methods (`Ns.Type.Method(a, b)`), the arguments F#
  expressions (`[|1; 2|]`, `"text"`, `Sample.Geo.Point(1.0, 2.0)`).

  The build tool is `dotnet` (a `*.csproj`, `*.sln` or `*.slnx` at the
  root); every project file is built either way. Nothing is fetched:
  packages are restored from an empty source, so they must already be in
  the NuGet cache. The SDK is the one on `PATH`, which a project's
  environment (`project_env.json`) decides.
  """
  @behaviour XipeTotec.Repl.Language

  alias XipeTotec.Repl.CSharp.Launch
  alias XipeTotec.Repl.Language.FSharp

  @impl true
  def extensions, do: ["cs"]

  @impl true
  def repl, do: "fsi"

  @impl true
  def build_tools, do: [%{"name" => "dotnet", "markers" => ["*.csproj", "*.sln", "*.slnx"]}]

  @impl true
  def scanner, do: [XipeTotec.Scanner.CSharp]

  @impl true
  def adapter do
    %{
      launch: XipeTotec.Repl.CSharp.Launch,
      eval_template: XipeTotec.Repl.CSharp.EvalTemplate,
      scan: XipeTotec.Repl.Eval.Scan.Direct.Fsi,
      field_drip: XipeTotec.Repl.Eval.FieldDrip.CSharp
    }
  end

  # the start script, init file, the seam's project, build output and log
  # in a temp dir removed after the pass
  @impl true
  def launch_opts(root, _build_tool, _files) do
    root = Path.expand(root)
    dir = Path.join(System.tmp_dir!(), "xipe_totec_csharp_#{System.unique_integer([:positive])}")
    empty = Path.join(dir, "no-packages")
    File.mkdir_p!(empty)
    File.mkdir_p!(Path.join(dir, "seam"))
    seam = Path.join(dir, "seam/EmbodyCs.csproj")
    File.write!(seam, Launch.seam_project(XipeTotec.Repl.Embody.path("embody.cs")))
    log = Path.join(dir, "build.log")
    init = Path.join(dir, "init.fsx")
    script = Path.join(dir, "start.sh")
    projects = projects(root)
    File.write!(init, Launch.init_file(log))

    File.write!(
      script,
      Launch.start_script(
        projects: projects,
        assemblies: Enum.map(projects, &FSharp.assembly_name/1),
        seam: seam,
        dir: dir,
        empty: empty,
        log: log,
        init: init
      )
    )

    {[script: script], fn -> File.rm_rf!(dir) end}
  end

  @doc "The project files under `root` (absolute, sorted), leaving out `bin/`, `obj/` and hidden directories."
  @spec projects(String.t()) :: [String.t()]
  def projects(root) do
    root
    |> Path.join("**/*.csproj")
    |> Path.wildcard()
    |> Enum.reject(fn path ->
      path |> Path.relative_to(root) |> Path.split() |> Enum.drop(-1) |> Enum.any?(&(&1 in ["bin", "obj"] or String.starts_with?(&1, ".")))
    end)
    |> Enum.sort()
  end
end
