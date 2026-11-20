# Live verification of C# through `dotnet fsi`: embody.fsx with C#'s seam embody.cs (evolving.md §4.4).
# NOT swept into test/run.sh. Needs `dotnet` (the .NET 8 SDK, which builds net8.0 without fetching
# anything) on PATH and embody (../embody next to this checkout, or $XIPE_TOTEC_EMBODY_DIR); without
# `dotnet` every test is excluded. For example:
#
#     nix shell github:NixOS/nixpkgs/<xipe_totec's pin>#dotnet-sdk_8 -c elixir test/live/repl_csharp_test.exs
#
# Until C#'s launch exists (§4.4, 5), the seam and a copy of test/fixtures/csharp_sample/ are built here
# by hand, as the launch will: each a project of its own, from an empty package source, into the temp dir.
dotnet? = System.find_executable("dotnet") != nil
ExUnit.start(exclude: if(dotnet?, do: [], else: [:dotnet]), timeout: 300_000)
unless dotnet?, do: IO.puts("repl_csharp_test: no `dotnet` on PATH -- every test excluded")

Code.require_file(Path.expand("../../lib/repl/embody.exs", __DIR__))

defmodule ReplLiveCSharpTest do
  use ExUnit.Case

  alias XipeTotec.Repl.Embody

  @moduletag :dotnet
  @fixture_dir Path.expand("../fixtures/csharp_sample", __DIR__)
  @env [{"DOTNET_CLI_TELEMETRY_OPTOUT", "1"}, {"DOTNET_NOLOGO", "1"}, {"DOTNET_SKIP_FIRST_TIME_EXPERIENCE", "1"}]

  setup_all do
    dir = Path.join(System.tmp_dir!(), "xipe_totec_cs_live_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "empty"))
    File.cp_r!(@fixture_dir, Path.join(dir, "target"))
    File.mkdir_p!(Path.join(dir, "seam"))

    File.write!(Path.join(dir, "seam/EmbodyCs.csproj"), """
    <Project Sdk="Microsoft.NET.Sdk">
      <PropertyGroup>
        <TargetFramework>net8.0</TargetFramework>
        <AssemblyName>EmbodyCs</AssemblyName>
        <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
        <Nullable>enable</Nullable>
      </PropertyGroup>
      <ItemGroup><Compile Include="#{Embody.path("embody.cs")}" /></ItemGroup>
    </Project>
    """)

    for {project, out} <- [{"seam", "seam_out"}, {"target", "target_out"}] do
      {log, status} =
        System.cmd("dotnet", ["build", project, "--source", Path.join(dir, "empty"), "-o", Path.join(dir, out)],
          cd: dir, env: @env, stderr_to_stdout: true)

      assert status == 0, log
    end

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  # run `body` (F#) in fsi after embody.fsx, both dlls and the seam's registration; the output
  defp fsi(dir, body) do
    script = Path.join(dir, "t#{System.unique_integer([:positive])}.fsx")

    File.write!(script, """
    #load #{inspect(Embody.path("embody.fsx"))}
    #r #{inspect(Path.join(dir, "seam_out/EmbodyCs.dll"))}
    #r #{inspect(Path.join(dir, "target_out/Sample.dll"))}
    Embody.reference #{inspect(Path.join(dir, "target_out/Sample.dll"))}
    Embody.registerType typeof<EmbodyCs.Seam>
    let entry id (m: string) (n: string) k basis (f: unit -> 'T) =
        Embody.start id 5000 basis
        let _ = Embody.call f
        Embody.finish id m n k
    #{body}
    """)

    {out, 0} = System.cmd("dotnet", ["fsi", "--quiet", "--exec", script], cd: dir, env: @env, stderr_to_stdout: true)
    out
  end

  defp record(out, id) do
    out |> String.split("\n") |> Enum.drop_while(&(&1 != "XT_BEGIN_" <> id)) |> Enum.drop(1) |> Enum.take_while(&(&1 != "XT_END_" <> id))
    |> Map.new(fn line -> line |> String.split("=", parts: 2) |> List.to_tuple() end)
  end

  test "the seam's protocol is a constant the launch can read" do
    assert File.read!(Embody.path("embody.cs")) =~ ~r/public const int Protocol = 1;/
  end

  test "Await: Task<T>, Task and ValueTask<T> give their value (a later row gets the T)", %{dir: dir} do
    out =
      fsi(dir, """
      entry "a1" "Sample.Calls" "LaterAsync" 1 None (fun () -> EmbodyCs.Seam.Await(Sample.Calls.LaterAsync(1)))
      entry "a2" "Sample.Calls" "Done" 0 None (fun () -> EmbodyCs.Seam.Await(Sample.Calls.Done()))
      entry "a3" "Sample.Calls" "Soon" 1 None (fun () -> EmbodyCs.Seam.Await(Sample.Calls.Soon("s")))
      """)

    assert %{"repr" => "exact", "type" => "int", "display" => "2"} = record(out, "a1")
    assert %{"repr" => "exact", "type" => "unit", "display" => "()"} = record(out, "a2")
    assert %{"repr" => "exact", "type" => "string", "display" => ~s|"s"|} = record(out, "a3")
  end

  test "records: a positional one written as its constructor's call, read back, compared property by property; others not", %{dir: dir} do
    mid = "Sample.Geo.Shapes.Mid(Sample.Geo.Point(1.0, 2.0), Sample.Geo.Point(3.0, 4.0))"

    out =
      fsi(dir, """
      entry "r1" "Sample.Geo.Shapes" "Mid" 2 None (fun () -> #{mid})
      entry "r2" "Sample.Geo.Shapes" "Mid" 2 (Some ("exact", "Sample.Geo.Point(2.0, 3.0)")) (fun () -> #{mid})
      entry "r3" "Sample.Geo.Shapes" "Mid" 2 (Some ("exact", "Sample.Geo.Point(2.0, 3.5)")) (fun () -> #{mid})
      // the literal is a later call's argument as it is
      entry "r4" "Sample.Geo.Shapes" "Area" 1 None (fun () -> Sample.Geo.Shapes.Area(Sample.Geo.Circle(1.0)))
      entry "r5" "Sample.Geo.Shapes" "Mid" 2 None (fun () -> Sample.Geo.Shapes.Mid(Sample.Geo.Point(2.0, 3.0), Sample.Geo.Point(2.0, 3.0)))
      // a List inside: equal element by element (C#'s own == compares the list by reference)
      entry "b1" "Sample.Calls" "Fill" 2 (Some ("exact", "Sample.Bag(\\"x\\", ResizeArray [0; 1])")) (fun () -> Sample.Calls.Fill("x", 2))
      entry "b2" "Sample.Calls" "Fill" 2 (Some ("exact", "Sample.Bag(\\"x\\", ResizeArray [0; 2])")) (fun () -> Sample.Calls.Fill("x", 2))
      // a record set outside a primary constructor; an anonymous type
      entry "t1" "Sample.Calls" "Mark" 1 None (fun () -> Sample.Calls.Mark("m"))
      entry "n1" "Sample.Calls" "Anon" 1 None (fun () -> Sample.Calls.Anon(1))
      """)

    assert %{"repr" => "exact", "type" => "Sample.Geo.Point", "display" => "Sample.Geo.Point(2.0, 3.0)", "compare" => "none"} = record(out, "r1")
    assert %{"compare" => "same"} = record(out, "r2")
    assert %{"compare" => "changed"} = record(out, "r3")
    assert %{"display" => "3.14159265358979" <> _} = record(out, "r4")
    assert %{"display" => "Sample.Geo.Point(2.0, 3.0)"} = record(out, "r5")
    assert %{"repr" => "exact", "display" => ~s|Sample.Bag("x", ResizeArray [0; 1])|, "compare" => "same"} = record(out, "b1")
    assert %{"compare" => "changed"} = record(out, "b2")
    assert %{"repr" => "binary", "display" => "Tag { Text = m }"} = record(out, "t1")
    assert %{"repr" => "unsupported", "display" => "{ N = 1, S = 1 }"} = record(out, "n1")
  end

  test "why a call did not compile, in C#'s terms; F#'s for what is no C# type", %{dir: dir} do
    out =
      fsi(dir, """
      for (id, m, n, k) in [ ("d1", "Sample.Counter", "Step", 1); ("d2", "Sample.Calc", "Hidden", 1); ("d3", "Sample.Calls", "Over", 3)
                             ("d4", "Sample.Calls", "Nope", 1); ("d5", "Sample.Geo.Point", "X", 0); ("d6", "Sample.Calls", "Over", 1)
                             ("d7", "Sample.Nope", "f", 1) ] do
          Embody.start id 5000 None
          Embody.finish id m n k
      """)

    head = "the call did not compile: "
    assert out =~ "XT_ERROR_d1 crash #{head}Sample.Counter.Step is an instance method: only public static methods are called (int Step(int by))\n"
    assert out =~ "XT_ERROR_d2 crash #{head}Sample.Calc.Hidden is internal: only public static methods are called\n"

    assert out =~
             "XT_ERROR_d3 crash #{head}Sample.Calls.Over takes 1 argument(s), got 3: static string Over(int x); static string Over(string s); static string Over(double d)\n"

    assert out =~ "XT_ERROR_d4 crash #{head}Sample.Calls has no method Nope\n"
    assert out =~ "XT_ERROR_d5 crash #{head}Sample.Geo.Point.X is a property, not a method\n"
    assert out =~ "XT_ERROR_d6 crash #{head}the arguments do not fit static string Over(int x); static string Over(string s); static string Over(double d) (fsi's message is in the REPL output)\n"
    assert out =~ "XT_ERROR_d7 crash #{head}no module Sample.Nope in what was loaded"
  end
end
