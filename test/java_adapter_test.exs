ExUnit.start()

Code.require_file(Path.expand("../lib/repl/language/java.exs", __DIR__))

defmodule JavaAdapterTest do
  use ExUnit.Case, async: true

  alias XipeTotec.Scanner
  alias XipeTotec.Repl.Language
  alias XipeTotec.Repl.Language.Java
  alias XipeTotec.Repl.Java.{EvalTemplate, Launch}

  @fixture_dir Path.expand("fixtures/java_sample", __DIR__)

  describe "EvalTemplate" do
    test "Scala's three inputs with Java's call: the static method, each argument in parentheses" do
      entry = %{call_id: "c1", module: "sample.Calc", name: "add", anykey: "(int, int)", shape: [2], marks: [], args: ["1", "xt_c0"], limits: %{timeout: 5000, max_heap_words: 1}}

      assert EvalTemplate.build(entry) == """
             Embody.start("c1", 5000, None)
             val xt_c1 = Embody.call(() => sample.Calc.add((1), (xt_c0)))
             Embody.finish("c1", "sample.Calc", "add", List(2))
             """

      assert EvalTemplate.call_expression(%{module: "sample.Calc", name: "spin", args: []}) == "sample.Calc.spin()"
      # a Java name that is a Scala keyword, in backticks
      assert EvalTemplate.call_expression(%{module: "sample.Calc", name: "type", args: ["1"]}) == "sample.Calc.`type`((1))"
    end

    test "async: inside embodyjava.embody.await; varargs: the last argument spread" do
      assert EvalTemplate.call_expression(%{module: "sample.Calc", name: "later", marks: ["async"], args: ["1"]}) ==
               "embodyjava.embody.await(sample.Calc.later((1)))"

      assert EvalTemplate.call_expression(%{module: "sample.Calc", name: "sum", marks: ["varargs"], args: ["Array(1, 2)"]}) ==
               "sample.Calc.sum((Array(1, 2))*)"
    end

    test "typed: each argument its parameter's Scala type where Java's has one without doubt" do
      call = &EvalTemplate.call_expression(%{module: "M", name: "f", anykey: &1, marks: ["typed"], args: &2})
      assert call.("(String)", ["null"]) == "M.f(((null): String))"
      assert call.("(long, double)", ["1", "2"]) == "M.f(((1): Long), ((2): Double))"
      assert call.("(Point, T)", ["p", "t"]) == "M.f((p), (t))"
      assert EvalTemplate.call_expression(%{module: "M", name: "f", anykey: "(String)", marks: [], args: ["null"]}) == "M.f((null))"
    end

    test "Java's type names as Scala's" do
      for {java, scala} <- [
            {"int", "Int"},
            {"boolean", "Boolean"},
            {"String", "String"},
            {"java.lang.String", "String"},
            {"Integer", "java.lang.Integer"},
            {"int[]", "Array[Int]"},
            {"String[]", "Array[String]"},
            {"List<Integer>", "java.util.List[java.lang.Integer]"},
            {"java.util.Map<String, List<Long>>", "java.util.Map[String, java.util.List[java.lang.Long]]"},
            {"List<int>", nil},
            {"List<Point>", nil},
            {"int...", nil},
            {"Point", nil},
            {"T", nil}
          ] do
        assert EvalTemplate.scala_type(java) == scala, java
      end
    end

    test "an argument that would leave the REPL reading on is not sent (Scala's check)" do
      assert EvalTemplate.build(%{call_id: "c9", module: "M", name: "f", args: ["(1"], limits: %{timeout: 1, max_heap_words: 1}}) ==
               ~s|Embody.fail("c9", "the call was not sent: an unclosed (")\n|
    end
  end

  describe "Launch" do
    test "Scala's launch message, the seam registered after Embody.setup, no scripts" do
      message = Launch.build(cwd: "/p", script: "/t/start.sh", log: "/t/build.log", scripts: ["a.sc"], scripts_dir: "/t/sc")
      assert message["argv"] == ["sh", "/t/start.sh"]
      probe = message["ready_probe"]
      assert probe =~ ~s|Embody.setup("/t/build.log")\nEmbody.registerType(classOf[embodyjava.embody])\nEmbody.ready()\n|
      refute probe =~ "a.sc"
      assert message["restart_after_timeout"]
      refute message["interruptible"]
    end

    test "the start script: both embody files and their protocols checked first; the seam, maven, Scala's home once; the REPL on the JVM's class path" do
      text = Launch.start_script(root: "/p", dir: "/t", log: "/t/build.log", maven: true)
      [l1, l2, l3, l4 | _] = String.split(text, "\n")
      scala_file = XipeTotec.Repl.Embody.path("embody.scala")
      java_file = XipeTotec.Repl.Embody.path("embody.java")
      assert l1 =~ "[ -f '#{scala_file}' ] || { echo 'no embody.scala at "
      assert l2 =~ "grep -q 'val protocol = #{XipeTotec.Repl.Scala.Launch.protocol()}$' '#{scala_file}'"
      assert l3 =~ "[ -f '#{java_file}' ] || { echo 'no embody.java at "
      assert l4 =~ "grep -qF 'public static final int PROTOCOL = #{Launch.protocol()};' '#{java_file}' || { echo "
      assert l4 =~ "does not speak protocol #{Launch.protocol()} (embodyjava.embody.PROTOCOL): update embody (git pull)"

      assert text =~ "if [ ! -f '/t/done' ]; then\n"
      assert text =~ "javac -d '/t/seam' '#{java_file}' >> '/t/build.log' 2>&1 || echo 'XT_BUILD_ERROR embody.java did not compile (javac)'"
      assert text =~ "mvn -o -q -B compile dependency:build-classpath -Dmdep.outputFile=target/xipe_totec.cp >> '/t/build.log' 2>&1"
      assert text =~ "XT_BUILD_ERROR the build failed: "
      assert text =~ ~s|scala -e 'print(System.getProperty("scala.home"))' > '/t/home'|
      assert String.ends_with?(text, ~s|exec java -cp "$h/lib/*:"'/t/seam'":$(cat '/t/classes')$(cat '/t/cp')" dotty.tools.repl.Main -usejavacp\n|)

      # no build tool; a gradle build named
      refute Launch.start_script(root: "/p", dir: "/t", log: "/l", maven: false) =~ "mvn"
      assert Launch.start_script(root: "/p", dir: "/t", log: "/l", maven: false, gradle: true) =~ "a gradle build is not read yet (maven only)"
    end

    test "the protocols checked are embody's own" do
      assert File.read!(XipeTotec.Repl.Embody.path("embody.java")) =~ "public static final int PROTOCOL = #{Launch.protocol()};"
      assert File.read!(XipeTotec.Repl.Embody.path("embody.scala")) =~ "val protocol = #{XipeTotec.Repl.Scala.Launch.protocol()}\n"
    end
  end

  describe "Language" do
    test "java files, Scala's REPL, maven by its pom.xml, Java's scanner and adapter" do
      assert Language.evaluated?(Java)
      assert Java.extensions() == ["java"]
      assert Java.repl() == "scala"
      assert [%{"name" => "maven", "markers" => ["pom.xml"]}] = Java.build_tools()
      assert Java.scanner() == [Scanner.Java]
      assert Java.adapter().launch == Launch
      assert Java.adapter().eval_template == EvalTemplate
    end

    test "launch_opts writes the start script in a temp dir the cleanup removes; maven when a pom.xml is there" do
      {opts, cleanup} = Java.launch_opts(@fixture_dir, nil, ["src/main/java/sample/Calc.java"])
      dir = Path.dirname(opts[:script])
      assert File.read!(opts[:script]) =~ "mvn -o -q -B compile"
      assert opts[:log] == Path.join(dir, "build.log")
      cleanup.()
      refute File.exists?(dir)
    end
  end
end
