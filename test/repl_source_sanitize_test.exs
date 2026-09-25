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
end
