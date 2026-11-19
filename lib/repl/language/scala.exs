Code.require_file("../language.exs", __DIR__)
Code.require_file("../scala/launch.exs", __DIR__)
Code.require_file("../scala/eval_template.exs", __DIR__)
Code.require_file("../eval/scan/direct/scala.exs", __DIR__)
Code.require_file("../eval/field_drip/scala.exs", __DIR__)
Code.require_file("../../scanner/scala.exs", __DIR__)

defmodule XipeTotec.Repl.Language.Scala do
  @moduledoc """
  Scala 3's `Repl.Language` self-declaration. REPL: Scala 3's
  (`dotty.tools.repl.Main`) with `embody.scala` loaded into it
  ([D-scala-adapter](../../../document/verification/lib-repl-language-scala.exs.md#d-scala-adapter)).

  A project is built by its own build tool, which gives the class path and
  the compiler of the project's Scala version (`Repl.Scala.BuildTool.Sbt`,
  `.ScalaCli`); nothing is fetched. Its scripts (`.sc`) are loaded with
  only their definitions, as F#'s `.fsx`. A project with no build tool
  (scripts alone) is evaluated in `scala` on `PATH`.

  sbt keeps no lock against a second instance: when an sbt server runs on
  the build (`project/target/active.json` naming a socket that answers --
  an sbt shell, Metals' sbt connection), sbt is not started and the calls
  `crash` naming it, so the user's own build is not broken by a compile
  beside it. Checked each time the REPL is started for a pass.
  """
  @behaviour XipeTotec.Repl.Language

  alias XipeTotec.Repl.Scala.{BuildTool, Launch}

  @impl true
  def extensions, do: ["scala", "sc"]

  @impl true
  def repl, do: "scala"

  @impl true
  def build_tools,
    do: [
      %{"name" => "sbt", "markers" => ["build.sbt"]},
      %{"name" => "scala-cli", "markers" => ["project.scala"]}
    ]

  @impl true
  def scanner, do: [XipeTotec.Scanner.Scala]

  @impl true
  def adapter do
    %{
      launch: XipeTotec.Repl.Scala.Launch,
      eval_template: XipeTotec.Repl.Scala.EvalTemplate,
      scan: XipeTotec.Repl.Eval.Scan.Direct.Scala,
      field_drip: XipeTotec.Repl.Eval.FieldDrip.Scala
    }
  end

  @doc "The module that gets the class path for a build tool's name (`nil`: none)."
  @spec build_tool(String.t() | nil) :: module() | nil
  def build_tool("sbt"), do: BuildTool.Sbt
  def build_tool("scala-cli"), do: BuildTool.ScalaCli
  def build_tool(_), do: nil

  # the start script, the build's files, the scripts' copies and the log in
  # a temp dir removed after the pass
  @impl true
  def launch_opts(root, build_tool, files) do
    root = Path.expand(root)
    dir = Path.join(System.tmp_dir!(), "xipe_totec_scala_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    log = Path.join(dir, "build.log")
    script = Path.join(dir, "start.sh")
    scripts = files |> Enum.filter(&(Path.extname(&1) == ".sc")) |> Enum.sort()
    refusal = if build_tool == "sbt", do: sbt_server(root)

    File.write!(script, Launch.start_script(root: root, dir: dir, log: log, tool: build_tool(build_tool), refusal: refusal))

    {[script: script, root: root, log: log, scripts: scripts, scripts_dir: Path.join(dir, "sc")], fn -> File.rm_rf!(dir) end}
  end

  @doc "Why sbt must not be started on the build at `root`, or `nil` (`Repl.Scala.BuildTool.Sbt.server/1`)."
  @spec sbt_server(String.t()) :: String.t() | nil
  defdelegate sbt_server(root), to: BuildTool.Sbt, as: :server
end
