Code.require_file("../embody.exs", __DIR__)

defmodule XipeTotec.Repl.FSharp.Launch do
  @moduledoc """
  F#'s `launch`: the project built by `dotnet build` and its scripts cut
  down to their definitions, then F# Interactive (`dotnet fsi --quiet`) --
  the same JSON-able message `Repl.Launch` builds
  ([D-fsharp-adapter](../../../document/verification/lib-repl-language-fsharp.exs.md#d-fsharp-adapter)).

  The REPL is started as `sh <start script>` (`start_script/1`, written by
  `Repl.Language.FSharp.launch_opts/3` into a temp dir removed after the
  pass). The first time, the script

    1. builds each project file into the temp dir's `out/` (`-o`: no `bin/`
       written into the project; `obj/` is), restoring only from an empty
       package source -- FSharp.Core comes with the SDK; any other package
       must already be in the NuGet cache, nothing is fetched;
    2. writes each script's definitions-only copy under `fsx/`
       (`embody.fsx`'s `Embody.Load.write`: its top level does not run);
    3. adds to the init file a `#r` for each project assembly the build
       produced.

  The build's and the copies' output go to `build.log`, not to the REPL's.
  It then `exec`s `dotnet fsi --quiet --use:<init file>`. The copies are
  `#load`-ed over stdin, ahead of the `ready_probe`, each its own
  submission: fsi stops reading an init file at its first error, and over
  stdin one script that does not compile leaves the others loaded. A
  second start in the same pass (after a `timeout`:
  `restart_after_timeout`) finds the work done and only starts fsi again.

    * no banner to wait for (`ready_pattern: nil`); `ready_probe` makes
      fsi print `XT_READY` once the init file is done
    * `DOTNET_CLI_TELEMETRY_OPTOUT` (no network), `DOTNET_NOLOGO`,
      `DOTNET_SKIP_FIRST_TIME_EXPERIENCE`; `--disable-build-servers` and
      `MSBUILDDISABLENODEREUSE`, so no MSBuild node or compiler server
      outlives the build
    * interruptible: SIGINT makes fsi print `- Interrupt` and read on with
      its bindings (checked with the .NET 8 SDK). An entry's own time limit
      already stops a running loop (`embody.fsx`'s `call`)
    * `restart_after_timeout`: the time limit aborts the call where it is
      (`ControlledExecution`), and a thread in a native wait runs on; the
      rest of the pass goes on in a new session
  """

  @doc """
  `opts`: `:cwd` (required), `:script` (the start script), `:loads`
  (`[{script, copy}]`: each script's path relative to the project and its
  definitions-only copy), `:env`.
  """
  @spec build(keyword()) :: %{String.t() => term()}
  def build(opts) do
    loads =
      Enum.map_join(Keyword.get(opts, :loads, []), "", fn {rel, copy} ->
        "Embody.trying #{string(rel)};;\n#load #{string(copy)}\nEmbody.loaded #{string(rel)};;\n"
      end)

    %{
      "kind" => "repl/launch",
      "argv" => ["sh", Keyword.fetch!(opts, :script)],
      "env" =>
        Map.merge(
          %{
            "DOTNET_CLI_TELEMETRY_OPTOUT" => "1",
            "DOTNET_NOLOGO" => "1",
            "DOTNET_SKIP_FIRST_TIME_EXPERIENCE" => "1",
            "MSBUILDDISABLENODEREUSE" => "1"
          },
          Keyword.get(opts, :env, %{})
        ),
      "cwd" => Keyword.fetch!(opts, :cwd),
      "files" => [],
      "ready_pattern" => nil,
      # the marker split so an echo of the line can't be taken for it
      "ready_probe" => loads <> ~s|printfn "%s" ("XT_" + "READY");;\n|,
      "exit_input" => "exit 0;;\n",
      "interruptible" => true,
      "restart_after_timeout" => true
    }
  end

  @doc """
  The init file's first part: load `embody.fsx` and tell it where the
  build's log is. The start script appends the `#r` lines.
  """
  @spec init_file(String.t()) :: String.t()
  def init_file(log) do
    """
    #load #{string(XipeTotec.Repl.Embody.path("embody.fsx"))}
    Embody.setup #{string(log)};;
    """
  end

  @doc """
  The start script. `opts`: `:root`, `:projects` (absolute paths of
  `*.fsproj`), `:assemblies` (the assembly names they build), `:scripts`
  (`.fsx` paths relative to `root`), `:dir` (the temp dir: `out/`, `fsx/`,
  `done`), `:empty` (an empty directory, the only package source), `:log`,
  `:init`.
  """
  @spec start_script(keyword()) :: String.t()
  def start_script(opts) do
    dir = opts[:dir]
    out = Path.join(dir, "out")
    fsx = Path.join(dir, "fsx")
    log = opts[:log]
    init = opts[:init]

    builds =
      Enum.map_join(opts[:projects], "", fn project ->
        "  dotnet build #{sh(project)} -o #{sh(out)} --source #{sh(opts[:empty])} --nologo -v q --disable-build-servers >> #{sh(log)} 2>&1\n"
      end)

    copies =
      case opts[:scripts] do
        [] ->
          ""

        scripts ->
          prep = Path.join(dir, "prep.fsx")
          list = "[" <> Enum.map_join(scripts, "; ", &string/1) <> "]"

          body = """
          #load #{string(XipeTotec.Repl.Embody.path("embody.fsx"))}
          Embody.Load.write #{string(opts[:root])} #{string(fsx)} #{list}
          """

          "  printf '%s' #{sh(body)} > #{sh(prep)}\n  dotnet fsi --quiet --exec #{sh(prep)} >> #{sh(log)} 2>&1\n"
      end

    references =
      Enum.map_join(opts[:assemblies], "", fn name ->
        dll = Path.join(out, name <> ".dll")
        "  [ -f #{sh(dll)} ] && printf '%s\\n' #{sh("#r " <> string(dll) <> ";;")} >> #{sh(init)}\n"
      end)

    """
    if [ ! -f #{sh(Path.join(dir, "done"))} ]; then
      : > #{sh(log)}
    #{builds}#{copies}#{references}  : > #{sh(Path.join(dir, "done"))}
    fi
    exec dotnet fsi --quiet --use:#{sh(init)}
    """
  end

  @doc "A single-quoted shell word."
  @spec sh(String.t()) :: String.t()
  def sh(text), do: "'" <> String.replace(text, "'", "'\\''") <> "'"

  @doc "An F# string literal for `text` (double-quoted, escapes for `\\\\`, `\"` and control characters)."
  @spec string(String.t()) :: String.t()
  def string(text) do
    escaped =
      text
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")
      |> String.replace(~r/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/, fn <<c>> -> "\\u" <> String.pad_leading(Integer.to_string(c, 16), 4, "0") end)

    "\"" <> escaped <> "\""
  end
end
