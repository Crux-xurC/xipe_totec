Code.require_file("../embody.exs", __DIR__)
Code.require_file("../scala/launch.exs", __DIR__)

defmodule XipeTotec.Repl.Java.Launch do
  @moduledoc """
  Java's `launch`, on Scala's: Scala 3's REPL with `embody.scala` and
  Java's seam `embody.java`
  ([D-java-adapter](../../../document/verification/lib-repl-language-java.exs.md#d-java-adapter)).

  The REPL is started as `sh <start script>` (`start_script/1`, written by
  `Repl.Language.Java.launch_opts/3` into a temp dir removed after the
  pass). The script first checks embody: `embody.scala` speaking Scala's
  adapter's protocol (`Embody.protocol`, the helper entry with it) and
  `embody.java` speaking this one's (`embodyjava.embody.PROTOCOL`);
  otherwise the start ends at once, naming the file and what to do. The
  first time, it then

    1. compiles the seam alone with `javac` into `seam/` (only the JDK);
    2. with a `pom.xml`, runs `mvn -o -q -B compile dependency:build-classpath`
       (offline: maven's plugins and the dependencies must be in its local
       repository), every module writing its class path into its own
       `target/xipe_totec.cp`, collected and removed; the classes are every
       module's `target/classes`. A failed build is named in the log
       (`XT_BUILD_ERROR`), and the REPL still starts: the rows then crash
       naming it;
    3. asks the `scala` on `PATH` for its home (`scala -e`): a Java project
       gives no Scala version, so the REPL is the pinned one.

  It then `exec`s `java -cp "<home>/lib/*:<seam>:<classes>:<cp>"
  dotty.tools.repl.Main -usejavacp` with the `java` on `PATH` (it must run
  the project's release): the target on the JVM's class path, so
  `embody.scala`'s read-back sees its types. Over stdin, Scala's lines and
  `Embody.registerType(classOf[embodyjava.embody])`. The rest -- the ready
  probe, not interruptible, `restart_after_timeout` -- is Scala's.
  """

  alias XipeTotec.Repl.Scala.Launch, as: Scala

  # `embodyjava.embody.PROTOCOL` in the embody.java this adapter speaks to
  @protocol 1

  @doc "The protocol this adapter speaks (`embodyjava.embody.PROTOCOL`)."
  @spec protocol() :: pos_integer()
  def protocol, do: @protocol

  @doc "Scala's launch message, the seam registered after `Embody.setup`. `opts`: `:cwd`, `:script`, `:log`, `:env`."
  @spec build(keyword()) :: %{String.t() => term()}
  def build(opts) do
    opts
    |> Keyword.drop([:scripts, :scripts_dir])
    |> Keyword.put(:after_setup, "Embody.registerType(classOf[embodyjava.embody])\n")
    |> Scala.build()
  end

  @doc """
  The start script. `opts`: `:root`, `:dir` (the temp dir: `seam/`,
  `home`, `classes`, `cp`, `done`), `:log`, `:maven` (whether to build with
  maven), `:gradle` (a gradle build found, which is not read yet).
  """
  @spec start_script(keyword()) :: String.t()
  def start_script(opts) do
    dir = opts[:dir]
    log = opts[:log]
    scala_file = XipeTotec.Repl.Embody.path("embody.scala")
    java_file = XipeTotec.Repl.Embody.path("embody.java")
    hint = "(clone embody next to Xipe Totec, or set XIPE_TOTEC_EMBODY_DIR)"
    update = "update embody (git pull) to the one this Xipe Totec was made with"
    [seam, home, classes, cp, done] = Enum.map(~w(seam home classes cp done), &Path.join(dir, &1))
    scala_protocol = Scala.protocol()

    maven =
      if opts[:maven] do
        """
          if command -v mvn > /dev/null; then
            find . -name xipe_totec.cp -path '*/target/*' -delete 2> /dev/null
            if mvn -o -q -B compile dependency:build-classpath -Dmdep.outputFile=target/xipe_totec.cp >> #{sh(log)} 2>&1; then :; else
              # the first error naming a file (maven's first [ERROR] line is a heading), else the first
              { grep -m 1 '^\\[ERROR\\] .*\\.java:' #{sh(log)} || grep -m 1 '\\[ERROR\\]' #{sh(log)}; } | sed 's/^\\[ERROR\\] */XT_BUILD_ERROR the build failed: /' >> #{sh(log)}
            fi
            find . -path '*/target/classes' -type d -not -path '*/.*' | sort | sed "s|^\\.|$PWD|" | tr '\\n' ':' > #{sh(classes)}
            find . -name xipe_totec.cp -path '*/target/*' -not -path '*/.*' | sort | while read -r f; do cat "$f"; printf ':'; rm -f "$f"; done > #{sh(cp)}
          else
            echo 'XT_BUILD_ERROR no mvn on PATH: the project was not built' >> #{sh(log)}
          fi
        """
      else
        if opts[:gradle],
          do: "  echo 'XT_BUILD_ERROR a gradle build is not read yet (maven only): the project was not built' >> #{sh(log)}\n",
          else: "  echo 'XT_BUILD_NOTE no build tool: nothing of the project is on the class path' >> #{sh(log)}\n"
      end

    """
    [ -f #{sh(scala_file)} ] || { echo #{sh("no embody.scala at " <> scala_file <> ": Java's methods cannot be evaluated " <> hint)}; exit 1; }
    grep -q #{sh("val protocol = #{scala_protocol}$")} #{sh(scala_file)} || { echo #{sh("embody.scala at " <> scala_file <> " does not speak protocol #{scala_protocol} (Embody.protocol): " <> update)}; exit 1; }
    [ -f #{sh(java_file)} ] || { echo #{sh("no embody.java at " <> java_file <> ": Java's methods cannot be evaluated " <> hint)}; exit 1; }
    grep -qF #{sh("public static final int PROTOCOL = #{@protocol};")} #{sh(java_file)} || { echo #{sh("embody.java at " <> java_file <> " does not speak protocol #{@protocol} (embodyjava.embody.PROTOCOL): " <> update)}; exit 1; }
    cd #{sh(opts[:root])} || exit 1
    if [ ! -f #{sh(done)} ]; then
      : > #{sh(log)}; : > #{sh(classes)}; : > #{sh(cp)}
      mkdir -p #{sh(seam)}
      javac -d #{sh(seam)} #{sh(java_file)} >> #{sh(log)} 2>&1 || echo 'XT_BUILD_ERROR embody.java did not compile (javac)' >> #{sh(log)}
    #{maven}  scala -e 'print(System.getProperty("scala.home"))' > #{sh(home)} 2>> #{sh(log)}
      : > #{sh(done)}
    fi
    h=$(cat #{sh(home)})
    [ -n "$h" ] && [ -d "$h/lib" ] || { echo 'no scala on PATH (Java is evaluated in Scala'"'"'s REPL): its home was not found'; exit 1; }
    exec java -cp "$h/lib/*:"#{sh(seam)}":$(cat #{sh(classes)})$(cat #{sh(cp)})" dotty.tools.repl.Main -usejavacp
    """
  end

  defdelegate sh(text), to: XipeTotec.Repl.Scala.BuildTool
  defdelegate string(text), to: Scala
end
