ExUnit.start()

Code.require_file(Path.expand("../lib/scanner/elixir.exs", __DIR__))
Code.require_file(Path.expand("../lib/repl/source_sanitize.exs", __DIR__))

defmodule ReplSourceSanitizeTest do
  use ExUnit.Case

  alias XipeTotec.Repl.SourceSanitize

  setup do
    dir = Path.join(System.tmp_dir!(), "xipe_totec_sanitize_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "a plain defmodule form survives the round-trip and compiles", %{dir: dir} do
    File.write!(Path.join(dir, "calc.exs"), "defmodule SanCalc do\n  def add(a, b), do: a + b\nend\n")

    {tmp_dir, [path]} = SourceSanitize.sanitize(dir, ["calc.exs"])
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    assert File.exists?(path)
    Code.compile_file(path)
    assert SanCalc.add(2, 3) == 5
  end

  test "a script's top-level side effect is never executed (review finding: Fix F had reopened one layer up)", %{
    dir: dir
  } do
    marker = Path.join(dir, "ran.marker")

    File.write!(Path.join(dir, "dangerous.exs"), """
    defmodule SanDangerous do
      def ok, do: :ok
    end

    File.write!(#{inspect(marker)}, "boom")
    """)

    {tmp_dir, [path]} = SourceSanitize.sanitize(dir, ["dangerous.exs"])
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    Code.compile_file(path)

    refute File.exists?(marker)
    assert SanDangerous.ok() == :ok
  end

  test "multiple files get distinct, order-preserving output paths", %{dir: dir} do
    File.write!(Path.join(dir, "a.exs"), "defmodule SanA do\nend\n")
    File.write!(Path.join(dir, "b.exs"), "defmodule SanB do\nend\n")

    {tmp_dir, [a, b]} = SourceSanitize.sanitize(dir, ["a.exs", "b.exs"])
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    assert a != b
    assert Path.basename(a) =~ "a.exs"
    assert Path.basename(b) =~ "b.exs"
  end

  test "modules compile under the original file's path, lines and __DIR__ (not the temp copy's)", %{dir: dir} do
    source = Path.join(dir, "where.exs")

    File.write!(source, """
    defmodule SanWhere do
      # a comment and a one-liner: both reflowed by Macro.to_string
      @dir __DIR__
      def dir, do: @dir
      def file, do: __ENV__.file
      def line, do: __ENV__.line
    end
    """)

    {tmp_dir, [path]} = SourceSanitize.sanitize(dir, ["where.exs"])
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    Code.compile_file(path)

    assert SanWhere.dir() == dir
    assert SanWhere.file() == source
    assert SanWhere.line() == 6
  end

  test "a crash's stacktrace points at the original file and line", %{dir: dir} do
    source = Path.join(dir, "crash.exs")
    File.write!(source, "defmodule SanCrash do\n  def zero, do: 0\n  def avg(list), do: Enum.sum(list) / length(list)\nend\n")

    {tmp_dir, [path]} = SourceSanitize.sanitize(dir, ["crash.exs"])
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    Code.compile_file(path)

    {_, _, _, location} =
      try do
        SanCrash.avg([])
      rescue
        ArithmeticError -> __STACKTRACE__ |> Enum.find(&match?({SanCrash, :avg, 1, _}, &1))
      end

    assert location[:file] == String.to_charlist(source)
    assert location[:line] == 3
  end

  test "the loader keeps exactly the top-level forms Scanner.only_defmodules/1 keeps", %{dir: dir} do
    marker = Path.join(dir, "ran.marker")

    source = """
    import Kernel, warn: false
    defmodule SanKeepA do
      def a, do: :a
    end
    alias SanKeepA, as: A
    File.write!(#{inspect(marker)}, "boom")
    defmodule SanKeepB do
      defmodule Inner do
        def i, do: :i
      end
    end
    x = 1 + 1
    """

    File.write!(Path.join(dir, "mixed.exs"), source)
    {tmp_dir, [path]} = SourceSanitize.sanitize(dir, ["mixed.exs"])
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    expected =
      source
      |> Code.string_to_quoted!()
      |> XipeTotec.Scanner.Elixir.only_defmodules()
      |> Enum.map(fn {:defmodule, _, [{:__aliases__, _, parts} | _]} -> Module.concat(parts) end)

    assert Enum.sort(expected) == [SanKeepA, SanKeepB]
    Code.compile_file(path)

    # the loader's own compile_file result doesn't list what its nested
    # compile_quoted defined, so check the modules themselves
    assert Enum.all?(expected, &Code.ensure_loaded?/1)
    assert SanKeepB.Inner.i() == :i
    refute File.exists?(marker)
  end

  test "a file that doesn't parse fails in sanitize/2, before any REPL is launched", %{dir: dir} do
    File.write!(Path.join(dir, "broken.exs"), "defmodule SanBroken do\n  def x, do:\n")
    before = Path.wildcard(Path.join(System.tmp_dir!(), "xipe_totec_eval_*"))
    raised =
      try do
        SourceSanitize.sanitize(dir, ["broken.exs"])
        nil
      rescue
        e in [SyntaxError, TokenMissingError] -> e
      end

    assert raised
    assert Exception.message(raised) =~ "broken.exs"
    # no temp dir left behind by the failed call
    assert Path.wildcard(Path.join(System.tmp_dir!(), "xipe_totec_eval_*")) -- before == []
  end
end
