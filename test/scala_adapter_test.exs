ExUnit.start()

Code.require_file(Path.expand("../lib/repl/language/scala.exs", __DIR__))

defmodule ScalaAdapterTest do
  use ExUnit.Case, async: true

  alias XipeTotec.Repl.Language
  alias XipeTotec.Repl.Language.Scala
  alias XipeTotec.Repl.Scala.{BuildTool, EvalTemplate, Launch}

  @entry %{call_id: "c1", module: "sample.Calc", name: "add", args: ["1", "xt_c0"], shape: [2], limits: %{timeout: 5000, max_heap_words: 1}}

  describe "EvalTemplate" do
    test "three inputs: start, the call inside Embody.call, finish with the module, the name and the shape" do
      assert EvalTemplate.build(@entry) == """
             Embody.start("c1", 5000, None)
             val xt_c1 = Embody.call(() => sample.Calc.add((1), (xt_c0)))
             Embody.finish("c1", "sample.Calc", "add", List(2))
             """
    end

    test "the args split into parameter lists by the shape; none for a def without lists; one list without a shape" do
      call = &EvalTemplate.call_expression/1
      assert call.(%{module: "sample.Calc", name: "f", args: ["1", "2", "3"], shape: [2, 1]}) == "sample.Calc.f((1), (2))((3))"
      assert call.(%{module: "sample.Calc", name: "answer", args: [], shape: [0]}) == "sample.Calc.answer()"
      assert call.(%{module: "sample.Calc", name: "lazyNats", args: [], shape: []}) == "sample.Calc.lazyNats"
      assert call.(%{module: "sample.Calc", name: "f", args: ["1", "2"]}) == "sample.Calc.f((1), (2))"
      # a shape that does not fit the args (a node scanned again since): one list, the compiler says the rest
      assert call.(%{module: "M", name: "f", args: ["1"], shape: [2]}) == "M.f((1))"
    end

    test "names that are not identifiers, and keywords, in backticks; the empty package's top-level def" do
      call = &EvalTemplate.call_expression/1
      assert call.(%{module: "my-tool", name: "sq", args: ["3"], shape: [1]}) == "`my-tool`.sq((3))"
      assert call.(%{module: "M", name: "+", args: ["3"], shape: [1]}) == "M.`+`((3))"
      assert call.(%{module: "M", name: "type", args: [], shape: [0]}) == "M.`type`()"
      assert call.(%{module: "", name: "topLevel", args: ["1"], shape: [1]}) == "topLevel((1))"
    end

    test "a script's module is its path: the object named by it in backticks, nested objects after it" do
      call = &EvalTemplate.call_expression/1
      assert call.(%{module: "scripts/tool", name: "sq", args: ["3"], shape: [1]}) == "`scripts/tool`.sq((3))"
      assert call.(%{module: "scripts/tool.Text", name: "shout", args: ["s"], shape: [1]}) == "`scripts/tool`.Text.shout((s))"
      assert call.(%{module: "v1.2/tool.Text", name: "f", args: [], shape: [0]}) == "`v1.2/tool`.Text.f()"
      assert call.(%{module: "tool", name: "sq", args: ["3"], shape: [1]}) == "tool.sq((3))"
    end

    test "ids made a name; both bases; a newline in an argument kept off the lines; no shape: the args' count" do
      base = %{@entry | call_id: "c-1", args: [~s|"a\\"b"|, "List(1,\n2)"], shape: nil}
      text = EvalTemplate.build(base)
      assert text =~ ~s|val xt_c_1 = Embody.call(() => sample.Calc.add(("a\\"b"), (List(1, 2))))|
      assert text =~ ~s|List(2))\n|
      assert length(String.split(text, "\n", trim: true)) == 3
      assert EvalTemplate.build(Map.put(base, :basis, {:exact, ~s|"x"|})) =~ ~s|Embody.start("c-1", 5000, Some(("exact", "\\"x\\"")))|
      assert EvalTemplate.build(Map.put(base, :basis, {:binary, "AA=="})) =~ ~s|Some(("binary", "AA==")))|
    end

    test "an argument that would leave the REPL reading on is not sent: Embody.fail says why" do
      assert EvalTemplate.build(%{@entry | args: ["(1", "2"]}) == ~s|Embody.fail("c1", "the call was not sent: an unclosed (")\n|
    end

    test "check/1: brackets, strings, interpolations, chars, backquoted names, comments" do
      ok = [~s|List(1, 2)|, ~s|"a(b"|, ~s|"a\\"b"|, ~s|"""a"b"""|, ~s|""""q""""|, ~s|s"x${f(1)}y"|, ~s|s"${"}"}"|, ~s|"${"|,
            ~s|'('|, ~s|'\\''|, ~s|`odd name`|, ~s|Map(1 -> "}")|, ~s|f"$x%.2f"|, ~s|s"$$"|, ~s|x => x + 1|]
      for t <- ok, do: assert(EvalTemplate.check(t) == nil, t)

      assert EvalTemplate.check("(1") == "an unclosed ("
      assert EvalTemplate.check("List(1]") == "] closing ("
      assert EvalTemplate.check("1)") == ") without its opening"
      assert EvalTemplate.check(~s|"abc|) == "an unclosed string"
      assert EvalTemplate.check(~s|"""abc|) == "an unclosed string"
      assert EvalTemplate.check(~s|s"${f(1"|) == "an unclosed string"
      assert EvalTemplate.check(~s|s"${(1}"|) == "} closing ("
      assert EvalTemplate.check("`odd") == "an unclosed `name`"
      assert EvalTemplate.check("1 // c") == "a // comment"
      assert EvalTemplate.check("1 /* c */") == "a /* comment"
      assert EvalTemplate.check(~s|"//" + 1|) == nil
    end
  end

  describe "Launch" do
    test "the message: sh <start script>, nothing fetched, not interruptible, a new session after a timeout" do
      msg = Launch.build(cwd: "/p", script: "/t/start.sh", root: "/p", log: "/t/build.log", scripts: [])
      assert msg["argv"] == ["sh", "/t/start.sh"]
      assert msg["env"]["COURSIER_MODE"] == "offline"
      assert msg["interruptible"] == false
      assert msg["restart_after_timeout"] == true
      assert msg["exit_input"] == ":quit\n"
      assert msg["ready_probe"] =~ ~r{\A:load .*/embody\.scala\nEmbody\.setup\("/t/build\.log"\)\nEmbody\.ready\(\)\n\z}
    end

    test "scripts: their copies written in the REPL, then each tried and :load-ed, ahead of the ready probe" do
      msg = Launch.build(cwd: "/p", script: "/t/s.sh", root: "/p", log: "/t/l", scripts: ["a.sc", "d/b.sc"], scripts_dir: "/t/sc")

      assert msg["ready_probe"] =~
               ~s|Embody.Load.write("/p", "/t/sc", List("a.sc", "d/b.sc"))\nEmbody.trying("a.sc")\n:load /t/sc/a.sc\nEmbody.trying("d/b.sc")\n:load /t/sc/d/b.sc\nEmbody.ready()|
    end

    test "the start script: the build tool's part once, then java with the compiler and the class path, else scala on PATH" do
      script = Launch.start_script(root: "/p", dir: "/t", log: "/t/build.log", tool: BuildTool.Sbt, refusal: nil)
      assert script =~ "cd '/p' || exit 1"
      assert script =~ ~r{\A\[ -f '.*/embody\.scala' \] \|\| \{ echo 'no embody\.scala at }
      assert script =~ ~r{grep -q 'val protocol = 2\$' '.*/embody\.scala' \|\| \{ echo '.*does not speak protocol 2}
      assert script =~ "if [ ! -f '/t/done' ]; then"
      assert script =~ "sbt -Dsbt.server.autostart=false"
      assert script =~ ~s|exec "$j" -cp "$(cat '/t/jars'):$(cat '/t/cp')" dotty.tools.repl.Main -usejavacp|
      assert script =~ "exec scala\n"

      refused = Launch.start_script(root: "/p", dir: "/t", log: "/t/l", tool: BuildTool.Sbt, refusal: "an sbt server is running")
      refute refused =~ "sbt -D"
      assert refused =~ "echo 'XT_BUILD_ERROR an sbt server is running' >> '/t/l'"

      none = Launch.start_script(root: "/p", dir: "/t", log: "/t/l", tool: nil, refusal: nil)
      refute none =~ "sbt"
      refute none =~ "scala-cli"
    end

    test "string/1 escapes as a Scala literal" do
      assert Launch.string(~s|a"b\\c\nd\u0001|) == ~s|"a\\"b\\\\c\\nd\\u0001"|
    end
  end

  describe "BuildTool" do
    test "sbt: temporary tasks set and printed in one run, offline-safe flags; a run that prints nothing run again without -error" do
      cmds = BuildTool.Sbt.commands()
      assert Enum.take(cmds, -4) == ["print xtVersions", "print xtJava", "print xtCompilerJars", "print xtClasspath"]
      assert Enum.any?(cmds, &(&1 =~ "ScopeFilter(inProjects(r3: _*))"))
      script = BuildTool.Sbt.script("/p", "/t", "/t/build.log")
      assert script =~ "-batch -error"
      assert script =~ "[ -s '/t/sbt.out' ] || sbt"
      assert script =~ "XT_BUILD_NOTE left out of the REPL"
      assert script =~ ~s|echo "XT_BUILD_ERROR sbt exited $st"|
    end

    test "scala-cli: offline, no build server; the compiler of the class path's Scala version from a one-line project" do
      script = BuildTool.ScalaCli.script("/p", "/t", "/t/build.log")
      assert script =~ "scala-cli --power compile --server=false --offline --print-class-path '/p'"
      assert script =~ "scala-cli --power export --json --server=false --offline '/p'"
      assert script =~ "org.scala-lang::scala3-compiler:%s"
    end

    test "compiler_script: only java and the compiler's jars, nothing built (the scan's)" do
      sbt = BuildTool.Sbt.compiler_script("/p", "/t", "/t/l")
      assert sbt =~ "print xtCompilerJars"
      refute sbt =~ "xtClasspath"
      cli = BuildTool.ScalaCli.compiler_script("/p", "/t", "/t/l")
      assert cli =~ "export --json"
      refute cli =~ "--print-class-path '/p'"
    end
  end

  describe "Scanner.Scala" do
    test "collisions/1: a key defined in two places is told to each file, naming both; one place is no collision" do
      d = fn m, n, k, l -> %{"module_" => m, "name" => n, "anykey" => k, "line" => l} end

      answer = %{
        "a/Util.scala" => %{"defs" => [d.("util.Util", "f", "(Int)", 3), d.("util.Util", "g", "(Int)", 4)]},
        "b/Util.scala" => %{"defs" => [d.("util.Util", "f", "(Int)", 7), d.("util.Util", "f", "(String)", 8)]},
        "bad.scala" => %{"error" => "x"}
      }

      c = XipeTotec.Scanner.Scala.collisions(answer)
      assert Map.keys(c) |> Enum.sort() == ["a/Util.scala", "b/Util.scala"]
      assert [%{module: "util.Util", reason: reason}] = c["a/Util.scala"]
      assert reason =~ "util.Util.f(Int) is defined more than once (a/Util.scala:3, b/Util.scala:7)"
      assert c["b/Util.scala"] == c["a/Util.scala"]
    end
  end

  describe "Language.Scala" do
    test "a declaration with a REPL: extensions, build tools by marker, the adapter's modules" do
      assert Language.evaluated?(Scala)
      assert Scala.extensions() == ["scala", "sc"]
      assert Scala.repl() == "scala"
      assert Enum.map(Scala.build_tools(), & &1["name"]) == ["sbt", "scala-cli"]
      assert Scala.build_tool("sbt") == BuildTool.Sbt
      assert Scala.build_tool("scala-cli") == BuildTool.ScalaCli
      assert Scala.build_tool(nil) == nil
    end

    test "launch_opts: the scripts among the files, a temp dir removed by the cleanup" do
      root = Path.join(System.tmp_dir!(), "xt_scala_lo_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)

      try do
        {opts, cleanup} = Scala.launch_opts(root, nil, ["b.sc", "src/A.scala", "a.sc"])
        assert opts[:scripts] == ["a.sc", "b.sc"]
        assert File.exists?(opts[:script])
        cleanup.()
        refute File.exists?(opts[:script])
      after
        File.rm_rf!(root)
      end
    end

    test "sbt_server/1: a socket that answers refuses sbt; a file left by a killed server, or none, does not" do
      root = Path.join(System.tmp_dir!(), "xt_scala_srv_#{System.unique_integer([:positive])}")
      sock = Path.join(System.tmp_dir!(), "xt_srv_#{System.unique_integer([:positive])}.sock")
      File.mkdir_p!(Path.join(root, "project/target"))

      try do
        assert Scala.sbt_server(root) == nil
        File.write!(Path.join(root, "project/target/active.json"), ~s|{"uri":"local://#{sock}"}|)
        assert Scala.sbt_server(root) == nil

        {:ok, listen} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, sock}, active: false])

        try do
          assert Scala.sbt_server(root) =~ "an sbt server is running for this build (local://#{sock})"
        after
          :gen_tcp.close(listen)
        end
      after
        File.rm_rf!(root)
        File.rm(sock)
      end
    end
  end
end
