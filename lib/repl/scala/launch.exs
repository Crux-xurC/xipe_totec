Code.require_file("../embody.exs", __DIR__)
Code.require_file("build_tool.exs", __DIR__)

defmodule XipeTotec.Repl.Scala.Launch do
  @moduledoc """
  Scala's `launch`: the project's class path from its build tool, then
  Scala 3's REPL with `embody.scala` -- the same JSON-able message
  `Repl.Launch` builds
  ([D-scala-adapter](../../../document/verification/lib-repl-language-scala.exs.md#d-scala-adapter)).

  The REPL is started as `sh <start script>` (`start_script/1`, written by
  `Repl.Language.Scala.launch_opts/3` into a temp dir removed after the
  pass). The first time, the script runs the build tool's part
  (`Repl.Scala.BuildTool.*`), which writes the `java`, the compiler's
  `jars` and the class path `cp` into the temp dir, its messages into
  `build.log`. It then `exec`s

    * `java -cp <jars>:<cp> dotty.tools.repl.Main -usejavacp`: the project's
      own Scala version (a compiler cannot read newer TASTy), the target on
      the JVM's class path so `embody.scala`'s ScriptEngine reads values of
      its types back; or
    * `scala` on `PATH` (the pinned one) when no compiler is known: no
      build tool (scripts alone), or the build did not run (an sbt server
      running on the build, a failed build) -- the calls then `crash`
      naming why.

  Over stdin, ahead of the `ready_probe`: `:load` of `embody.scala`, the
  build's log given to it, and the scripts' definitions-only copies
  (`Embody.Load.write`, then a `:load` of each copy). A second start in the
  same pass (after a `timeout`: `restart_after_timeout`) finds the build
  done and only starts the REPL.

    * `ready_pattern: nil`; `ready_probe` has `embody.scala` print
      `XT_READY` once all that is read (no embody: the start fails)
    * not interruptible: SIGINT ends Scala's REPL
    * `restart_after_timeout`: the JVM cannot stop a running thread; the
      call's thread runs on after its `timeout`, and the rest of the pass
      goes on in a new session
  """

  alias XipeTotec.Repl.Scala.BuildTool

  # `Embody.protocol` in the embody.scala this adapter speaks to
  @protocol 1

  @doc """
  `opts`: `:cwd` (required), `:script` (the start script), `:root`,
  `:scripts_dir` (where the copies go), `:scripts` (`.sc` paths relative to
  the root), `:log`, `:env`.
  """
  @spec build(keyword()) :: %{String.t() => term()}
  def build(opts) do
    scripts = Keyword.get(opts, :scripts, [])
    log = Keyword.get(opts, :log, "")

    loads =
      case scripts do
        [] ->
          ""

        _ ->
          dir = Keyword.fetch!(opts, :scripts_dir)
          list = "List(" <> Enum.map_join(scripts, ", ", &string/1) <> ")"

          "Embody.Load.write(#{string(Keyword.fetch!(opts, :root))}, #{string(dir)}, #{list})\n" <>
            Enum.map_join(scripts, "", fn rel -> "Embody.trying(#{string(rel)})\n:load #{Path.join(dir, rel)}\n" end)
      end

    %{
      "kind" => "repl/launch",
      "argv" => ["sh", Keyword.fetch!(opts, :script)],
      "env" => Map.merge(%{"COURSIER_MODE" => "offline"}, Keyword.get(opts, :env, %{})),
      "cwd" => Keyword.fetch!(opts, :cwd),
      "files" => [],
      "ready_pattern" => nil,
      # embody prints the marker: without embody.scala (not found, not
      # compiled) the REPL never looks ready, and the start fails naming why
      # instead of every entry waiting for a record
      "ready_probe" =>
        ":load #{XipeTotec.Repl.Embody.path("embody.scala")}\nEmbody.setup(#{string(log)})\n" <>
          loads <> "Embody.ready()\n",
      "exit_input" => ":quit\n",
      "interruptible" => false,
      "restart_after_timeout" => true
    }
  end

  @doc """
  The start script. `opts`: `:root`, `:dir` (the temp dir), `:log`,
  `:tool` (a `Repl.Scala.BuildTool` module, or `nil`), `:refusal` (why the
  build tool is not run -- an sbt server running on the build -- or `nil`).
  """
  @spec start_script(keyword()) :: String.t()
  def start_script(opts) do
    dir = opts[:dir]
    log = opts[:log]
    sh = &BuildTool.sh/1
    [java, jars, cp] = Enum.map(["java", "jars", "cp"], &Path.join(dir, &1))

    build =
      cond do
        opts[:refusal] -> "  echo #{sh.("XT_BUILD_ERROR " <> opts[:refusal])} >> #{sh.(log)}\n"
        opts[:tool] -> opts[:tool].script(opts[:root], dir, log) |> String.replace(~r/^/m, "  ")
        true -> ""
      end

    embody = XipeTotec.Repl.Embody.path("embody.scala")

    """
    [ -f #{sh.(embody)} ] || { echo #{sh.("no embody.scala at " <> embody <> ": Scala's functions cannot be evaluated (clone embody next to Xipe Totec, or set XIPE_TOTEC_EMBODY_DIR)")}; exit 1; }
    grep -q #{sh.("val protocol = #{@protocol}$")} #{sh.(embody)} || { echo #{sh.("embody.scala at " <> embody <> " does not speak protocol #{@protocol} (Embody.protocol): update embody (git pull) to the one this Xipe Totec was made with")}; exit 1; }
    cd #{sh.(opts[:root])} || exit 1
    if [ ! -f #{sh.(Path.join(dir, "done"))} ]; then
      : > #{sh.(log)}
      : > #{sh.(java)}; : > #{sh.(jars)}; : > #{sh.(cp)}
    #{build}  : > #{sh.(Path.join(dir, "done"))}
    fi
    if [ -s #{sh.(jars)} ]; then
      j=$(cat #{sh.(java)}); [ -n "$j" ] || j=java
      exec "$j" -cp "$(cat #{sh.(jars)}):$(cat #{sh.(cp)})" dotty.tools.repl.Main -usejavacp
    fi
    exec scala
    """
  end

  @doc "A Scala string literal for `text` (double-quoted; `\\\\`, `\"` and control characters escaped)."
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
