Code.require_file("../language.exs", __DIR__)
Code.require_file("../java/launch.exs", __DIR__)
Code.require_file("../java/eval_template.exs", __DIR__)
Code.require_file("../eval/scan/direct/scala.exs", __DIR__)
Code.require_file("../eval/field_drip/java.exs", __DIR__)
Code.require_file("../../scanner/java.exs", __DIR__)

defmodule XipeTotec.Repl.Language.Java do
  @moduledoc """
  Java's `Repl.Language` self-declaration. REPL: Scala 3's REPL, Scala's
  window, with `embody.scala` and Java's seam `embody.java` loaded into it
  ([D-java-adapter](../../../document/verification/lib-repl-language-java.exs.md#d-java-adapter);
  `evolving.md` §4.6).

  A maven project (`pom.xml`) is compiled offline by maven, every module's
  classes and dependencies put on the REPL's class path; the seam is
  compiled beside it in a temp dir, never written into the project. The
  calls are Java's public static methods (`pkg.Type.method(a, b)`), the
  arguments Scala expressions (`Array(1, 2)`, `"text"`,
  `sample.Point(1.0, 2.0)`).

  The build tool is maven (a `pom.xml` at the root); gradle is not yet
  read (its files are on the map only, the rows crash naming it). Nothing
  is fetched: maven's plugins and the dependencies must already be in its
  local repository (the project built once online). The JDK and Scala are
  the ones on `PATH`, which a project's environment (`project_env.json`)
  decides.
  """
  @behaviour XipeTotec.Repl.Language

  alias XipeTotec.Repl.Java.Launch

  @impl true
  def extensions, do: ["java"]

  @impl true
  def repl, do: "scala"

  @impl true
  def build_tools, do: [%{"name" => "maven", "markers" => ["pom.xml"]}]

  @impl true
  def scanner, do: [XipeTotec.Scanner.Java]

  @impl true
  def adapter do
    %{
      launch: XipeTotec.Repl.Java.Launch,
      eval_template: XipeTotec.Repl.Java.EvalTemplate,
      scan: XipeTotec.Repl.Eval.Scan.Direct.Scala,
      field_drip: XipeTotec.Repl.Eval.FieldDrip.Java
    }
  end

  # the start script, the seam, the class path files and the log in a temp
  # dir removed after the pass
  @impl true
  def launch_opts(root, build_tool, _files) do
    root = Path.expand(root)
    dir = Path.join(System.tmp_dir!(), "xipe_totec_java_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    log = Path.join(dir, "build.log")
    script = Path.join(dir, "start.sh")
    maven? = build_tool == "maven" or (build_tool == nil and File.exists?(Path.join(root, "pom.xml")))
    gradle? = Path.wildcard(Path.join(root, "build.gradle*")) != []
    File.write!(script, Launch.start_script(root: root, dir: dir, log: log, maven: maven?, gradle: gradle?))
    {[script: script, log: log], fn -> File.rm_rf!(dir) end}
  end
end
