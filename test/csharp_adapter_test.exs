ExUnit.start()

Code.require_file(Path.expand("../lib/repl/language/csharp.exs", __DIR__))

defmodule CSharpAdapterTest do
  use ExUnit.Case, async: true

  alias XipeTotec.Scanner
  alias XipeTotec.Repl.Language
  alias XipeTotec.Repl.Language.CSharp
  alias XipeTotec.Repl.CSharp.{EvalTemplate, Launch}

  @fixture_dir Path.expand("fixtures/csharp_sample", __DIR__)

  describe "EvalTemplate" do
    test "F#'s three submissions with C#'s call: the static method, each argument in parentheses" do
      entry = %{call_id: "c1", module: "Sample.Calc", name: "Add", anykey: "(int, int)", shape: [2], marks: [], args: ["1", "xt_c0"], limits: %{timeout: 5000, max_heap_words: 1}}

      assert EvalTemplate.build(entry) == """
             Embody.start "c1" 5000 None;;
             let xt_c1 = Embody.call (fun () -> Sample.Calc.Add((1), (xt_c0)));;
             Embody.finish "c1" "Sample.Calc" "Add" 2;;
             """

      assert EvalTemplate.call_expression(%{module: "Sample.Calc", name: "UnitArea", args: []}) == "Sample.Calc.UnitArea()"
    end

    test "async: the call inside EmbodyCs.Seam.Await" do
      assert EvalTemplate.call_expression(%{module: "Sample.Calls", name: "LaterAsync", anykey: "(int)", marks: ["async"], args: ["1"]}) ==
               "EmbodyCs.Seam.Await(Sample.Calls.LaterAsync((1)))"
    end

    test "typed: each argument its parameter's F# type where C#'s has one without doubt; out parameters not written" do
      call = &EvalTemplate.call_expression(%{module: "M", name: "F", anykey: &1, marks: ["typed"], args: &2})
      assert call.("(string)", ["null"]) == "M.F(((null) : string))"
      assert call.("(double, long)", ["1", "2"]) == "M.F(((1) : float), ((2) : int64))"
      assert call.("(int, out int)", ["1"]) == "M.F(((1) : int))"
      # a project's type and a type parameter are left to fsi; ref too
      assert call.("(Point, T, ref int)", ["p", "t", "r"]) == "M.F((p), (t), (r))"
      # not marked: as it is
      assert EvalTemplate.call_expression(%{module: "M", name: "F", anykey: "(string)", marks: [], args: ["null"]}) == "M.F((null))"
    end

    test "C#'s type names as F#'s" do
      for {cs, fs} <- [
            {"int", "int"},
            {"System.Int32", "int"},
            {"float", "float32"},
            {"double", "float"},
            {"object", "obj"},
            {"int[]", "int[]"},
            {"params int[]", nil},
            {"int?", "System.Nullable<int>"},
            {"List<int>", "System.Collections.Generic.List<int>"},
            {"Dictionary<string, List<double>>", "System.Collections.Generic.Dictionary<string, System.Collections.Generic.List<float>>"},
            {"List<Point>", nil},
            {"(int, string)", nil},
            {"Point", nil},
            {"T", nil}
          ] do
        assert EvalTemplate.fsharp_type(cs) == fs, cs
      end
    end

    test "an argument that would leave fsi reading on is not sent (F#'s check)" do
      assert EvalTemplate.build(%{call_id: "c9", module: "M", name: "F", args: ["[|1"], limits: %{timeout: 1, max_heap_words: 1}}) ==
               ~s|Embody.fail "c9" "the call was not sent: an unclosed [";;\n|
    end
  end

  describe "Launch" do
    test "F#'s launch message, no scripts to load" do
      message = Launch.build(cwd: "/p", script: "/t/start.sh", loads: [{"a.fsx", "/t/a.fsx"}])
      assert message["argv"] == ["sh", "/t/start.sh"]
      assert message["ready_probe"] == ~s|printfn "%s" ("XT_" + "READY");;\n|
      assert message["restart_after_timeout"]
    end

    test "the seam's project compiles embody.cs alone" do
      text = Launch.seam_project("/e/embody.cs")
      assert text =~ "<AssemblyName>EmbodyCs</AssemblyName>"
      assert text =~ "<EnableDefaultCompileItems>false</EnableDefaultCompileItems>"
      assert text =~ ~s|<Compile Include="/e/embody.cs" />|
    end

    test "the start script: embody checked first (missing, another protocol); the seam and the projects built once; #r, Embody.reference, the seam registered" do
      text =
        Launch.start_script(
          projects: ["/p/A.csproj"],
          assemblies: ["Alpha"],
          seam: "/t/seam/EmbodyCs.csproj",
          dir: "/t",
          empty: "/t/none",
          log: "/t/build.log",
          init: "/t/init.fsx"
        )

      cs = XipeTotec.Repl.Embody.path("embody.cs")
      [first, second, third | _] = String.split(text, "\n")
      assert first =~ "[ -f '#{XipeTotec.Repl.Embody.path("embody.fsx")}' ] || { echo 'no embody.fsx at "
      assert second =~ "[ -f '#{cs}' ] || { echo 'no embody.cs at #{cs}: C#'\\''s methods cannot be evaluated (clone embody"
      assert third =~ "grep -qF 'public const int Protocol = #{Launch.protocol()};' '#{cs}' || { echo "
      assert third =~ "does not speak protocol #{Launch.protocol()} (EmbodyCs.Seam.Protocol): update embody (git pull)"
      assert third =~ "exit 1; }"

      assert text =~ "if [ ! -f '/t/done' ]; then\n"
      assert text =~ "dotnet build '/t/seam/EmbodyCs.csproj' -o '/t/seam_out' --source '/t/none' --nologo -v q --disable-build-servers >> '/t/build.log' 2>&1\n"
      assert text =~ "dotnet build '/p/A.csproj' -o '/t/out' --source '/t/none'"

      assert text =~
               ~s|[ -f '/t/seam_out/EmbodyCs.dll' ] && printf '%s\\n' '#r "/t/seam_out/EmbodyCs.dll";;' 'Embody.reference "/t/seam_out/EmbodyCs.dll";;' 'Embody.registerType typeof<EmbodyCs.Seam>;;' >> '/t/init.fsx'\n|

      assert text =~ ~s|[ -f '/t/out/Alpha.dll' ] && printf '%s\\n' '#r "/t/out/Alpha.dll";;' 'Embody.reference "/t/out/Alpha.dll";;' >> '/t/init.fsx'\n|
      assert String.ends_with?(text, "fi\nexec dotnet fsi --quiet --use:'/t/init.fsx'\n")
    end

    test "the protocol checked is embody.cs's own" do
      assert File.read!(XipeTotec.Repl.Embody.path("embody.cs")) =~ "public const int Protocol = #{Launch.protocol()};"
    end
  end

  describe "Language" do
    test "cs files, F#'s fsi as the REPL, dotnet by its project or solution file, C#'s scanner and adapter" do
      assert Language.evaluated?(CSharp)
      assert CSharp.extensions() == ["cs"]
      assert CSharp.repl() == "fsi"
      assert [%{"name" => "dotnet", "markers" => ["*.csproj", "*.sln", "*.slnx"]}] = CSharp.build_tools()
      assert CSharp.scanner() == [Scanner.CSharp]
      assert CSharp.adapter().launch == Launch
      assert CSharp.adapter().eval_template == EvalTemplate
    end

    test "launch_opts writes the start script, the init file and the seam's project in a temp dir the cleanup removes" do
      {opts, cleanup} = CSharp.launch_opts(@fixture_dir, "dotnet", ["src/Calc.cs"])
      dir = Path.dirname(opts[:script])
      text = File.read!(opts[:script])
      assert text =~ "dotnet build '#{Path.join(@fixture_dir, "CsharpSample.csproj")}'"
      # the fixture's <AssemblyName>
      assert text =~ "/out/Sample.dll"
      assert File.read!(Path.join(dir, "seam/EmbodyCs.csproj")) =~ XipeTotec.Repl.Embody.path("embody.cs")
      assert File.read!(Path.join(dir, "init.fsx")) =~ "Embody.setup"
      assert opts[:loads] == nil
      cleanup.()
      refute File.exists?(dir)
    end

    test "project files outside bin/, obj/ and hidden directories" do
      dir = Path.join(System.tmp_dir!(), "xt_cs_projects_#{System.unique_integer([:positive])}")

      for p <- ["A.csproj", "src/B/B.csproj", "bin/C.csproj", "obj/x/D.csproj", ".git/E.csproj", "F.fsproj"] do
        File.mkdir_p!(Path.dirname(Path.join(dir, p)))
        File.write!(Path.join(dir, p), "<Project/>")
      end

      assert CSharp.projects(dir) == [Path.join(dir, "A.csproj"), Path.join(dir, "src/B/B.csproj")]
      assert XipeTotec.Repl.Language.FSharp.assembly_name(Path.join(dir, "A.csproj")) == "A"
      File.rm_rf!(dir)
    end
  end
end
