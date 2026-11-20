Code.require_file("../embody.exs", __DIR__)
Code.require_file("../fsharp/launch.exs", __DIR__)

defmodule XipeTotec.Repl.CSharp.Launch do
  @moduledoc """
  C#'s `launch`, on F#'s: F# Interactive (`dotnet fsi --quiet`) with
  `embody.fsx` and C#'s seam `embody.cs`
  ([D-csharp-adapter](../../../document/verification/lib-repl-language-csharp.exs.md#d-csharp-adapter)).

  The REPL is started as `sh <start script>` (`start_script/1`, written by
  `Repl.Language.CSharp.launch_opts/3` into a temp dir removed after the
  pass). The script first checks embody: `embody.fsx` and `embody.cs`
  must be there, and `embody.cs` must speak protocol 1
  (`EmbodyCs.Seam.Protocol`); otherwise the start ends at once, naming the
  file and what to do, instead of never looking ready. The first time, it
  then

    1. builds the seam, a class library of its own compiling `embody.cs`
       (`seam/EmbodyCs.csproj` in the temp dir), into `seam_out/`;
    2. builds each of the target's project files into `out/` (`-o`: no
       `bin/` written into the project; `obj/` is);
    3. adds to the init file, for each assembly the builds produced, a
       `#r` and `Embody.reference` (a call that does not compile before any
       other has run still finds its types), and for the seam
       `Embody.registerType typeof<EmbodyCs.Seam>`.

  Both builds restore only from an empty package source: nothing is
  fetched; a package the target needs must already be in the NuGet cache.
  Their output goes to `build.log`. It then `exec`s `dotnet fsi --quiet
  --use:<init file>`. The rest -- the environment, the ready probe,
  interrupting, `restart_after_timeout` -- is F#'s (`build/1`).
  """

  alias XipeTotec.Repl.FSharp.Launch, as: FSharp

  # `EmbodyCs.Seam.Protocol` in the embody.cs this adapter speaks to
  @protocol 1

  @doc "The protocol this adapter speaks (`EmbodyCs.Seam.Protocol`)."
  @spec protocol() :: pos_integer()
  def protocol, do: @protocol

  @doc "F#'s launch message (no scripts to load). `opts`: `:cwd`, `:script`, `:env`."
  @spec build(keyword()) :: %{String.t() => term()}
  def build(opts), do: FSharp.build(Keyword.delete(opts, :loads))

  @doc "The init file's first part: `embody.fsx`'s, F#'s. The start script appends the references and the seam's registration."
  @spec init_file(String.t()) :: String.t()
  defdelegate init_file(log), to: FSharp

  @doc "The seam's project file: a class library compiling `embody` (the path of `embody.cs`) alone."
  @spec seam_project(String.t()) :: String.t()
  def seam_project(embody) do
    """
    <Project Sdk="Microsoft.NET.Sdk">
      <PropertyGroup>
        <TargetFramework>net8.0</TargetFramework>
        <AssemblyName>EmbodyCs</AssemblyName>
        <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
        <Nullable>enable</Nullable>
      </PropertyGroup>
      <ItemGroup><Compile Include="#{embody}" /></ItemGroup>
    </Project>
    """
  end

  @doc """
  The start script. `opts`: `:projects` (absolute paths of `*.csproj`),
  `:assemblies` (the assembly names they build), `:seam` (the seam's
  project file), `:dir` (the temp dir: `out/`, `seam_out/`, `done`),
  `:empty` (an empty directory, the only package source), `:log`, `:init`.
  """
  @spec start_script(keyword()) :: String.t()
  def start_script(opts) do
    dir = opts[:dir]
    out = Path.join(dir, "out")
    seam_out = Path.join(dir, "seam_out")
    log = opts[:log]
    init = opts[:init]
    fsx = XipeTotec.Repl.Embody.path("embody.fsx")
    cs = XipeTotec.Repl.Embody.path("embody.cs")
    hint = "(clone embody next to Xipe Totec, or set XIPE_TOTEC_EMBODY_DIR)"

    build = fn project, to ->
      "  dotnet build #{sh(project)} -o #{sh(to)} --source #{sh(opts[:empty])} --nologo -v q --disable-build-servers >> #{sh(log)} 2>&1\n"
    end

    # each line its own printf argument: printf repeats the format
    append = fn dll, lines -> "  [ -f #{sh(dll)} ] && printf '%s\\n' #{Enum.map_join(lines, " ", &sh/1)} >> #{sh(init)}\n" end
    seam_dll = Path.join(seam_out, "EmbodyCs.dll")

    references =
      Enum.map_join(opts[:assemblies], "", fn name ->
        dll = Path.join(out, name <> ".dll")
        append.(dll, ["#r #{string(dll)};;", "Embody.reference #{string(dll)};;"])
      end)

    """
    [ -f #{sh(fsx)} ] || { echo #{sh("no embody.fsx at " <> fsx <> ": C#'s methods cannot be evaluated " <> hint)}; exit 1; }
    [ -f #{sh(cs)} ] || { echo #{sh("no embody.cs at " <> cs <> ": C#'s methods cannot be evaluated " <> hint)}; exit 1; }
    grep -qF #{sh("public const int Protocol = #{@protocol};")} #{sh(cs)} || { echo #{sh("embody.cs at " <> cs <> " does not speak protocol #{@protocol} (EmbodyCs.Seam.Protocol): update embody (git pull) to the one this Xipe Totec was made with")}; exit 1; }
    if [ ! -f #{sh(Path.join(dir, "done"))} ]; then
      : > #{sh(log)}
    #{build.(opts[:seam], seam_out)}#{Enum.map_join(opts[:projects], "", &build.(&1, out))}#{append.(seam_dll, ["#r #{string(seam_dll)};;", "Embody.reference #{string(seam_dll)};;", "Embody.registerType typeof<EmbodyCs.Seam>;;"])}#{references}  : > #{sh(Path.join(dir, "done"))}
    fi
    exec dotnet fsi --quiet --use:#{sh(init)}
    """
  end

  defdelegate sh(text), to: FSharp
  defdelegate string(text), to: FSharp
end
