ExUnit.start()

Code.require_file(Path.expand("../lib/repl/language/fsharp.exs", __DIR__))

defmodule FSharpAdapterTest do
  use ExUnit.Case, async: true

  alias XipeTotec.{Book, Scanner}
  alias XipeTotec.Repl.Language
  alias XipeTotec.Repl.Language.FSharp
  alias XipeTotec.Repl.FSharp.{EvalTemplate, Launch}

  @fixture_dir Path.expand("fixtures/fsharp_sample", __DIR__)
  @files ["scripts/more.fsx", "scripts/tool.fsx", "src/Calc.fs", "src/Geo.fs"]

  describe "EvalTemplate" do
    test "three submissions: start, the function applied to each argument inside Embody.call, finish with the module, the name and the count" do
      entry = %{call_id: "c1", module: "Sample.Calc", name: "add", args: ["1", "xt_c0"], limits: %{timeout: 5000, max_heap_words: 1}}

      assert EvalTemplate.build(entry) == """
             Embody.start "c1" 5000 None;;
             let xt_c1 = Embody.call (fun () -> Sample.Calc.add (1) (xt_c0));;
             Embody.finish "c1" "Sample.Calc" "add" 2;;
             """
    end

    test "a tuple is one argument; names that are not identifiers in double backticks; active patterns as they are" do
      assert EvalTemplate.call_expression(%{module: "Sample.Calc", name: "addPair", args: ["1, 2"]}) == "Sample.Calc.addPair (1, 2)"
      assert EvalTemplate.call_expression(%{module: "My-tool", name: "sq", args: ["3"]}) == "``My-tool``.sq (3)"
      assert EvalTemplate.call_expression(%{module: "M", name: "(|Even|Odd|)", args: ["3"]}) == "M.(|Even|Odd|) (3)"
      assert EvalTemplate.call_expression(%{module: "M", name: "f'", args: ["()"]}) == "M.f' (())"
    end

    test "a static member (a node with a shape) is called as a method, its arguments split into the curried groups" do
      call = &EvalTemplate.call_expression(%{module: "Sample.Conv", name: &1, args: &2, shape: &3})
      assert call.("Show", ["1.5", "2"], [2]) == "Sample.Conv.Show((1.5), (2))"
      assert call.("Scale", ["2.0", "xt_c0"], [1, 1]) == "Sample.Conv.Scale((2.0))((xt_c0))"
      assert call.("Origin", [], [0]) == "Sample.Conv.Origin()"
      assert call.("Sum", ["1, 2"], [1]) == "Sample.Conv.Sum((1, 2))"
      # a shape that does not fit the arguments: one group (row/add refuses such a row first)
      assert call.("Show", ["1", "2"], [1]) == "Sample.Conv.Show((1), (2))"

      entry = %{call_id: "c2", module: "Sample.Conv", name: "Show", args: ["1"], shape: [1], limits: %{timeout: 5000, max_heap_words: 1}}
      assert EvalTemplate.build(entry) =~ ~s|let xt_c2 = Embody.call (fun () -> Sample.Conv.Show((1)));;\nEmbody.finish "c2" "Sample.Conv" "Show" 1;;|
    end

    test "ids made a name; both bases in parentheses; a newline in an argument kept off the lines" do
      base = %{call_id: "c-1", module: "M", name: "s", args: [~s|"a\\"b"|, "[|1;\n2|]"], limits: %{timeout: 10, max_heap_words: 1}}
      text = EvalTemplate.build(base)
      assert text =~ ~s|let xt_c_1 = Embody.call (fun () -> M.s ("a\\"b") ([\|1; 2\|]));;|
      assert length(String.split(text, "\n", trim: true)) == 3
      assert EvalTemplate.build(Map.put(base, :basis, {:exact, ~s|"x"|})) =~ ~s|Embody.start "c-1" 10 (Some ("exact", "\\"x\\""));;|
      assert EvalTemplate.build(Map.put(base, :basis, {:binary, "AA=="})) =~ ~s|(Some ("binary", "AA=="));;|
    end

    test "an argument that would leave fsi reading on is not sent: Embody.fail reports it" do
      for {arg, why} <- [
            {"[|1; 2", "an unclosed ["},
            {"(1, 2))", ") without its opening"},
            {"[1; 2)", ") closing ["},
            {~s|"abc|, "an unclosed string"},
            {~s|"""a""|, "an unclosed string"},
            {"1;; 2", "a ;; outside a string"},
            {"1 // x", "a // comment"},
            {"(* x *) 1", "a (* comment"}
          ] do
        assert EvalTemplate.check(arg) == why, arg

        assert EvalTemplate.build(%{call_id: "c9", module: "M", name: "f", args: [arg], limits: %{timeout: 1, max_heap_words: 1}}) ==
                 ~s|Embody.fail "c9" "the call was not sent: #{why}";;\n|
      end

      for ok <- [~s|"a;;b // (c"|, ~s|"""raw " ("""|, "'('", "'\\''", "[|1; 2|]", "(+) 1", "List.map (fun x -> x) [1]", "Some 'a'", "(*)", "{ Sample.Point.X = 1.0; Y = 2.0 }"] do
        assert EvalTemplate.check(ok) == nil, ok
      end
    end
  end

  describe "Launch" do
    test "sh with the start script; telemetry off; no banner, a probe, exit 0;;, interruptible, a new session after a timeout" do
      message = Launch.build(cwd: "/p", script: "/tmp/x/start.sh", env: %{"PATH" => "/bin"})
      assert message["argv"] == ["sh", "/tmp/x/start.sh"]
      assert message["env"]["DOTNET_CLI_TELEMETRY_OPTOUT"] == "1"
      assert message["env"]["MSBUILDDISABLENODEREUSE"] == "1"
      assert message["env"]["PATH"] == "/bin"

      assert %{"files" => [], "ready_pattern" => nil, "exit_input" => "exit 0;;\n", "interruptible" => true, "restart_after_timeout" => true} =
               message

      assert message["ready_probe"] == ~s|printfn "%s" ("XT_" + "READY");;\n|
    end

    test "the scripts' copies are loaded over stdin ahead of the probe, each its own submission" do
      message = Launch.build(cwd: "/p", script: "/t/start.sh", loads: [{"scripts/a.fsx", "/t/fsx/scripts/a.fsx"}, {"b.fsx", "/t/fsx/b.fsx"}])

      assert message["ready_probe"] == """
             Embody.trying "scripts/a.fsx";;
             #load "/t/fsx/scripts/a.fsx"
             Embody.loaded "scripts/a.fsx";;
             Embody.trying "b.fsx";;
             #load "/t/fsx/b.fsx"
             Embody.loaded "b.fsx";;
             printfn "%s" ("XT_" + "READY");;
             """
    end

    test "the init file loads embody.fsx and names the build's log" do
      text = Launch.init_file("/tmp/x/build.log")
      assert text =~ ~s|#load "#{XipeTotec.Repl.Embody.path("embody.fsx")}"\n|
      assert text =~ ~s|Embody.setup "/tmp/x/build.log";;\n|
    end

    test "the start script, once per pass: builds, the scripts' definitions-only copies, #r lines; then fsi" do
      text =
        Launch.start_script(
          root: "/p",
          projects: ["/p/A.fsproj", "/p/it's/B.fsproj"],
          assemblies: ["A", "Bee"],
          scripts: ["scripts/tool.fsx"],
          dir: "/t",
          empty: "/t/none",
          log: "/t/build.log",
          init: "/t/init.fsx"
        )

      assert text =~ "if [ ! -f '/t/done' ]; then\n"
      assert text =~ "dotnet build '/p/A.fsproj' -o '/t/out' --source '/t/none' --nologo -v q --disable-build-servers >> '/t/build.log' 2>&1\n"
      assert text =~ ~S|dotnet build '/p/it'\''s/B.fsproj'|
      assert text =~ ~s|Embody.Load.write "/p" "/t/fsx" ["scripts/tool.fsx"]|
      assert text =~ "dotnet fsi --quiet --exec '/t/prep.fsx' >> '/t/build.log' 2>&1\n"
      assert text =~ ~s|[ -f '/t/out/Bee.dll' ] && printf '%s\\n' '#r "/t/out/Bee.dll";;' >> '/t/init.fsx'\n|
      # the copies are loaded over stdin (Launch.build's ready_probe), not by the init file
      refute text =~ "/t/fsx/scripts/tool.fsx"
      assert text =~ "  : > '/t/done'\nfi\n"
      assert String.ends_with?(text, "exec dotnet fsi --quiet --use:'/t/init.fsx'\n")

      # no scripts: no copies
      refute Launch.start_script(root: "/p", projects: [], assemblies: [], scripts: [], dir: "/t", empty: "/e", log: "/l", init: "/i") =~ "prep.fsx"
    end

    test "F# string literals escape quotes, backslashes and control characters" do
      assert Launch.string(~s|a"b\\c\nd\u0001|) == ~S|"a\"b\\c\nd\u0001"|
    end
  end

  describe "Language" do
    test "fs and fsx files, the fsi REPL, dotnet by its project or solution file, one scanner and adapter" do
      assert Language.evaluated?(FSharp)
      assert FSharp.extensions() == ["fs", "fsx"]
      assert FSharp.repl() == "fsi"
      assert [%{"name" => "dotnet", "markers" => ["*.fsproj", "*.sln", "*.slnx"]}] = FSharp.build_tools()
      assert FSharp.scanner() == [Scanner.FSharp]
      assert FSharp.adapter().launch == Launch
      assert FSharp.adapter().eval_template == EvalTemplate
    end

    test "launch_opts writes the start script and init file in a temp dir the cleanup removes; the scripts are the .fsx files" do
      {opts, cleanup} = FSharp.launch_opts(@fixture_dir, "dotnet", @files)
      script = opts[:script]
      assert [{"scripts/more.fsx", more}, {"scripts/tool.fsx", _}] = opts[:loads]
      assert more == Path.join(Path.dirname(script), "fsx/scripts/more.fsx")
      dir = Path.dirname(script)
      text = File.read!(script)
      assert text =~ "dotnet build '#{Path.join(@fixture_dir, "Sample.fsproj")}'"
      assert text =~ "/out/Sample.dll"
      assert text =~ ~s|["scripts/more.fsx"; "scripts/tool.fsx"]|
      refute text =~ "Calc.fs\""
      assert File.read!(Path.join(dir, "init.fsx")) =~ "Embody.setup"
      assert File.dir?(Path.join(dir, "no-packages"))
      cleanup.()
      refute File.exists?(dir)
    end

    test "project files outside bin/, obj/ and hidden directories; the assembly name from the project file" do
      dir = Path.join(System.tmp_dir!(), "xt_fs_projects_#{System.unique_integer([:positive])}")

      for p <- ["A.fsproj", "src/B/B.fsproj", "bin/C.fsproj", "obj/x/D.fsproj", ".git/E.fsproj"] do
        File.mkdir_p!(Path.dirname(Path.join(dir, p)))
        File.write!(Path.join(dir, p), "<Project/>")
      end

      assert FSharp.projects(dir) == [Path.join(dir, "A.fsproj"), Path.join(dir, "src/B/B.fsproj")]
      assert FSharp.assembly_name(Path.join(dir, "A.fsproj")) == "A"
      assert FSharp.assembly_name(Path.join(@fixture_dir, "Sample.fsproj")) == "Sample"
      File.rm_rf!(dir)
    end
  end

  describe "Scanner.FSharp (scan.fsx's answer given)" do
    # what scan.fsx answers, as JSON gives it
    defp answer do
      def = fn module, name, args, refs, opts ->
        %{
          "module_" => module,
          "name" => name,
          "args" => args,
          "public" => Keyword.get(opts, :public, true),
          "key" => Keyword.get(opts, :key),
          "shape" => Keyword.get(opts, :shape),
          "line" => Keyword.get(opts, :line, 1),
          "endLine" => 1,
          "hash" => "h",
          "scopes" => Keyword.get(opts, :scopes, [module]),
          "opens" => Keyword.get(opts, :opens, []),
          "refs" => refs
        }
      end

      %{
        "src/Geo.fs" => %{
          "path" => "src/Geo.fs",
          "error" => nil,
          "defs" => [
            def.("Sample.Geo", "area", 1, ["shape", "Circle"], scopes: ["Sample.Geo", "Sample"]),
            def.("Sample.Conv", "Show", 1, ["x"], scopes: ["Sample"], key: "(int)", shape: [1]),
            def.("Sample.Conv", "Show", 1, ["x"], scopes: ["Sample"], key: "(string)", shape: [1]),
            def.("Sample.Conv", "Origin", 1, ["Point.Of"], scopes: ["Sample"], key: "()", shape: [0]),
            def.("Sample.Point", "Of", 1, [], scopes: ["Sample"], key: "(float, float)", shape: [2]),
            def.("Sample.Geo.Inner", "label", 1, ["s.ToUpper", "area"], scopes: ["Sample.Geo.Inner", "Sample.Geo", "Sample"])
          ]
        },
        "src/Calc.fs" => %{
          "path" => "src/Calc.fs",
          "error" => nil,
          "defs" => [
            def.("Sample.Calc", "add", 2, ["op_Addition", "a", "b"], scopes: ["Sample.Calc", "Sample"]),
            def.("Sample.Calc", "add3", 3, ["add", "a"], scopes: ["Sample.Calc", "Sample"]),
            def.("Sample.Calc", "unitArea", 1, ["Geo.area", "Circle"], scopes: ["Sample.Calc", "Sample"]),
            def.("Sample.Calc", "inner", 1, ["Inner.label"], scopes: ["Sample.Calc", "Sample"], opens: ["Geo"]),
            def.("Sample.Calc", "secret", 1, [], scopes: ["Sample.Calc", "Sample"], public: false)
          ]
        },
        "scripts/more.fsx" => %{
          "path" => "scripts/more.fsx",
          "error" => nil,
          "defs" => [def.("More", "cube", 1, ["Tool.sq", "x"], scopes: ["More"])]
        },
        "scripts/tool.fsx" => %{"path" => "scripts/tool.fsx", "error" => nil, "defs" => [def.("Tool", "sq", 1, ["op_Multiply"], scopes: ["Tool"])]},
        "bad.fsx" => %{"path" => "bad.fsx", "error" => "bad.fsx(1,5): unexpected", "defs" => []}
      }
    end

    defp file(path), do: %{root: @fixture_dir, path: path, source: "", ctx: %{files: answer()}}

    test "definitions: module, name, anykey = the curried arguments, visibility; a file that did not parse raises its error" do
      assert [%{module: "Sample.Calc", name: "add", anykey: 2, visibility: "public"} | _] = Scanner.FSharp.defs(file("src/Calc.fs"))
      assert %{visibility: "private"} = Enum.find(Scanner.FSharp.defs(file("src/Calc.fs")), &(&1.name == "secret"))
      assert_raise RuntimeError, "bad.fsx(1,5): unexpected", fn -> Scanner.FSharp.defs(file("bad.fsx")) end
    end

    test "static members: anykey the parameters' types, a shape, overloads each a node of their own" do
      geo = Scanner.FSharp.defs(file("src/Geo.fs"))
      shows = for %{name: "Show"} = d <- geo, do: {d.anykey, d.shape}
      assert shows == [{"(int)", [1]}, {"(string)", [1]}]
      assert %{anykey: 1, shape: nil} = Enum.find(geo, &(&1.name == "area"))

      {book, _} = Scanner.FSharp.scan_defs(Book.new(), "src/Geo.fs", file("src/Geo.fs"))
      assert [%{shape: [1]}, %{shape: [1]}] = for({_, %{name: "Show"} = n} <- book.nodes, do: n)
    end

    test "links: the own module, the enclosing ones, opens (also inside the namespace), the name as written" do
      paths = ["scripts/more.fsx", "scripts/tool.fsx", "src/Calc.fs", "src/Geo.fs"]
      book = Enum.reduce(paths, Book.new(), fn path, book -> elem(Scanner.FSharp.scan_defs(book, path, file(path)), 0) end)
      ids = for {id, n} <- book.nodes, into: %{}, do: {{n.module, n.name, n.anykey}, id}
      book = Enum.reduce(paths, book, fn path, book -> book |> Scanner.FSharp.scan_links_report(ids, file(path)) |> elem(0) end)

      edges =
        for {_, l} <- book.links do
          n = Book.get(book, :nodes, l.node)
          r = Book.get(book, :nodes, l.ref)
          {"#{n.module}.#{n.name}", "#{r.module}.#{r.name}"}
        end

      assert Enum.sort(edges) ==
               Enum.sort([
                 {"Sample.Calc.add3", "Sample.Calc.add"},
                 # Geo.area from Sample.Calc: Sample is an enclosing scope
                 {"Sample.Calc.unitArea", "Sample.Geo.area"},
                 # open Geo inside namespace Sample, then Inner.label
                 {"Sample.Calc.inner", "Sample.Geo.Inner.label"},
                 # area from Sample.Geo.Inner: the enclosing module
                 {"Sample.Geo.Inner.label", "Sample.Geo.area"},
                 # a static member from another: Point.Of in namespace Sample
                 {"Sample.Conv.Origin", "Sample.Point.Of"},
                 # one script's module from another's
                 {"More.cube", "Tool.sq"}
               ])
    end

    test "resolve: the innermost scope wins" do
      index = %{{"A.B", "f"} => [{"A.B", "f", 1}], {"A", "f"} => [{"A", "f", 1}]}
      assert Scanner.FSharp.resolve("f", ["A.B", "A"], [], index) == [{"A.B", "f", 1}]
      assert Scanner.FSharp.resolve("f", ["A"], [], index) == [{"A", "f", 1}]
      assert Scanner.FSharp.resolve("B.f", ["A"], [], index) == [{"A.B", "f", 1}]
      assert Scanner.FSharp.resolve("g", ["A"], [], index) == []
    end
  end
end
