defmodule XipeTotec.Repl.Scala.BuildTool do
  @moduledoc """
  Where a Scala project's class path comes from: one module per build tool,
  each writing the same three files into the pass's temp dir, so another
  tool (mill; maven and gradle when Scala's REPL is Java's window) is one
  more module beside these
  ([D-scala-adapter](../../../document/verification/lib-repl-language-scala.exs.md#d-scala-adapter)).

    * `java` -- the `java` to start the REPL with (empty: `java` on `PATH`)
    * `jars` -- the project's Scala 3 compiler and library jars
      (`:`-separated; empty: no compiler known, the REPL is `scala` on
      `PATH`, the pinned one)
    * `cp` -- the project's run-time class path (its classes and
      dependencies)

  and anything it has to say into the build's log: a line containing
  `[error]` (a build that failed), `XT_BUILD_ERROR <why>` or
  `XT_BUILD_NOTE <what>`, which `embody.scala` names when a call does not
  compile. Nothing is fetched (`COURSIER_MODE=offline`, `--offline`); the
  build writes into the project as an IDE's build does (sbt's `target/`,
  scala-cli's `.scala-build/`), keeping incremental compilation.
  """

  @doc "Shell lines (run at the project's root by the start script) that write `java`, `jars` and `cp` under `dir` and append to `log`."
  @callback script(root :: String.t(), dir :: String.t(), log :: String.t()) :: String.t()

  @doc """
  Shell lines (run at the project's root) that write only `java` and `jars` under `dir`, without
  building: the scan reads the sources with the project's own compiler.
  """
  @callback compiler_script(root :: String.t(), dir :: String.t(), log :: String.t()) :: String.t()

  @doc "A single-quoted shell word."
  @spec sh(String.t()) :: String.t()
  def sh(text), do: "'" <> String.replace(text, "'", "'\\''") <> "'"

  # an ESC, for stripping a tool's colours from what goes into the log
  @doc false
  def strip_colours, do: ~s|sed "s/$(printf '\\033')\\[[0-9;]*m//g"|
end

defmodule XipeTotec.Repl.Scala.BuildTool.Sbt do
  @moduledoc """
  sbt (1.4 or later: `print`). One `sbt -batch -error` run defines
  temporary tasks with `set` and prints them -- output for machines, nothing
  written to the build's files. It prints every project's Scala version
  first (settings: they print even when a build fails), then the compiler
  jars of the newest Scala 3 project and the class path of all the Scala 3
  projects together (a project of another version is left out, its files
  on the map only; a log line names it), and the JVM sbt ran on. A run that
  fails with nothing printed (`-error` hides sbt's own parse errors) is run
  once more without `-error`, into the log.
  """
  @behaviour XipeTotec.Repl.Scala.BuildTool

  import XipeTotec.Repl.Scala.BuildTool, only: [sh: 1]

  @three "x.get(r / scalaVersion).startsWith(\"3.\")"
  @flags "-Dsbt.server.autostart=false -Dsbt.supershell=false -Dsbt.color=false -batch"

  @doc "The `set` and `print` commands of the run, in order."
  @spec commands() :: [String.t()]
  def commands do
    [
      ~s|set Global / TaskKey[String]("xtVersions") := Def.taskDyn { val x = Project.extract(state.value); Def.task { "XT_VERSIONS=" + x.structure.allProjectRefs.map(r => r.project + "=" + x.get(r / scalaVersion)).mkString(" ") } }.value|,
      ~s|set Global / TaskKey[String]("xtJava") := "XT_JAVA=" + sys.props("java.home") + "/bin/java"|,
      ~s|set Global / TaskKey[String]("xtCompilerJars") := Def.taskDyn { val x = Project.extract(state.value); val r3 = x.structure.allProjectRefs.filter(r => #{@three}); val top = r3.sortBy { r => val v = x.get(r / scalaVersion).split("[.-]").map(s => scala.util.Try(s.toInt).getOrElse(0)).padTo(3, 0); (v(0), v(1), v(2)) }.lastOption; top match { case Some(r) => Def.task { "XT_JARS=" + (r / scalaInstance).value.allJars.map(_.getAbsolutePath).mkString(java.io.File.pathSeparator) }; case None => Def.task { "XT_JARS=" } } }.value|,
      ~s|set Global / TaskKey[String]("xtClasspath") := Def.taskDyn { val x = Project.extract(state.value); val r3 = x.structure.allProjectRefs.filter(r => #{@three}); Def.task { "XT_CP=" + (Runtime / fullClasspath).all(ScopeFilter(inProjects(r3: _*))).value.flatten.map(_.data.getAbsolutePath).distinct.mkString(java.io.File.pathSeparator) } }.value|,
      "print xtVersions",
      "print xtJava",
      "print xtCompilerJars",
      "print xtClasspath"
    ]
  end

  @doc """
  Why sbt must not be started on the build at `root`, or `nil`: an sbt
  server answering at the socket `project/target/active.json` names. A file
  left by a server that was killed names a socket nobody answers: `nil`.
  """
  @spec server(String.t()) :: String.t() | nil
  def server(root) do
    with {:ok, text} <- File.read(Path.join([root, "project", "target", "active.json"])),
         {:ok, %{"uri" => uri}} when is_binary(uri) <- JSON.decode(text),
         true <- answers?(uri) do
      "an sbt server is running for this build (#{uri}): close the sbt shell, or Metals' sbt connection, and evaluate again"
    else
      _ -> nil
    end
  end

  defp answers?("local://" <> path), do: connects?({:local, path}, 0)

  defp answers?("tcp://" <> hostport) do
    with [host, port] <- String.split(hostport, ":", parts: 2),
         {port, _} <- Integer.parse(port) do
      connects?(String.to_charlist(host), port)
    else
      _ -> false
    end
  end

  defp answers?(_), do: false

  defp connects?(address, port) do
    case :gen_tcp.connect(address, port, [:binary, active: false], 1000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _} ->
        false
    end
  end

  @impl true
  def compiler_script(_root, dir, log) do
    out = Path.join(dir, "sbt.out")
    [_versions, java, jars | _] = commands()
    cmds = Enum.map_join([java, jars, "print xtJava", "print xtCompilerJars"], " ", &sh/1)

    """
    sbt #{@flags} -error #{cmds} > #{sh(out)} 2>&1 || cat #{sh(out)} >> #{sh(log)}
    grep -o 'XT_JAVA=.*' #{sh(out)} | head -n 1 | sed 's/^XT_JAVA=//' > #{sh(Path.join(dir, "java"))}
    grep -o 'XT_JARS=.*' #{sh(out)} | head -n 1 | sed 's/^XT_JARS=//' > #{sh(Path.join(dir, "jars"))}
    """
  end

  @impl true
  def script(_root, dir, log) do
    out = Path.join(dir, "sbt.out")
    flags = @flags
    cmds = Enum.map_join(commands(), " ", &sh/1)

    pick = fn key, file ->
      ~s|grep -o 'XT_#{key}=.*' #{sh(out)} \| head -n 1 \| sed 's/^XT_#{key}=//' > #{sh(Path.join(dir, file))}\n|
    end

    """
    sbt #{flags} -error #{cmds} > #{sh(out)} 2>&1; st=$?
    #{pick.("JAVA", "java")}#{pick.("JARS", "jars")}#{pick.("CP", "cp")}grep -v 'XT_[A-Z]*=' #{sh(out)} >> #{sh(log)}
    left=$(grep -o 'XT_VERSIONS=.*' #{sh(out)} | head -n 1 | sed 's/^XT_VERSIONS=//' | tr ' ' '\\n' | grep -v '=3\\.' | tr '\\n' ' ')
    [ -n "$left" ] && echo "XT_BUILD_NOTE left out of the REPL (not Scala 3; on the map only): $left" >> #{sh(log)}
    if [ $st -ne 0 ]; then
      [ -s #{sh(out)} ] || sbt #{flags} #{cmds} >> #{sh(log)} 2>&1
      echo "XT_BUILD_ERROR sbt exited $st" >> #{sh(log)}
    fi
    """
  end
end

defmodule XipeTotec.Repl.Scala.BuildTool.ScalaCli do
  @moduledoc """
  scala-cli. The Scala version from `export --json` (machine output, no
  build), the run-time class path from `compile --print-class-path`
  (offline, without its build server), and the compiler's jars the same
  way, from a one-line project in the temp dir that depends on
  `scala3-compiler` of that version (already in the cache once scala-cli
  compiled the project with it). The REPL runs on `java` on `PATH`.
  """
  @behaviour XipeTotec.Repl.Scala.BuildTool

  import XipeTotec.Repl.Scala.BuildTool, only: [sh: 1, strip_colours: 0]

  @run "scala-cli --power compile --server=false --offline --print-class-path"
  @quiet "grep -v 'experimental\\|bear in mind\\|bugs or have feedback\\|sub-command\\|option$'"

  # the version, then the compiler's jars; `ok` stays 0 when both were had
  defp compiler(root, dir, log) do
    compiler = Path.join(dir, "compiler")

    """
    ver=$(scala-cli --power export --json --server=false --offline #{sh(root)} 2>> #{sh(log)} | sed -n 's/^ *"scalaVersion": *"\\([^"]*\\)".*/\\1/p' | head -n 1)
    : > #{sh(Path.join(dir, "java"))}
    if [ -n "$ver" ]; then
      mkdir -p #{sh(compiler)}
      printf '//> using scala %s\\n//> using dep org.scala-lang::scala3-compiler:%s\\n' "$ver" "$ver" > #{sh(Path.join(compiler, "project.scala"))}
      echo 'object XtCompiler' > #{sh(Path.join(compiler, "XtCompiler.scala"))}
      #{@run} #{sh(compiler)} 2> #{sh(Path.join(dir, "compiler.err"))} | tail -n 1 > #{sh(Path.join(dir, "jars"))}
      #{strip_colours()} #{sh(Path.join(dir, "compiler.err"))} | #{@quiet} >> #{sh(log)}
    else
      echo "XT_BUILD_ERROR scala-cli gave no Scala version (export --json)" >> #{sh(log)}
    fi
    """
  end

  @impl true
  def compiler_script(root, dir, log), do: compiler(root, dir, log)

  @impl true
  def script(root, dir, log) do
    cp = Path.join(dir, "cp")
    err = Path.join(dir, "scala-cli.err")

    """
    #{@run} #{sh(root)} > #{sh(cp <> ".out")} 2> #{sh(err)}; st=$?
    #{strip_colours()} #{sh(err)} | #{@quiet} >> #{sh(log)}
    if [ $st -eq 0 ]; then
      tail -n 1 #{sh(cp <> ".out")} > #{sh(cp)}
    #{compiler(root, dir, log) |> String.replace(~r/^/m, "  ")}else
      [ -s #{sh(log)} ] || echo "[error] scala-cli exited $st" >> #{sh(log)}
      echo "XT_BUILD_ERROR scala-cli exited $st" >> #{sh(log)}
    fi
    """
  end
end
