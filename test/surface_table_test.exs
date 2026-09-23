ExUnit.start()

Code.require_file(Path.expand("../lib/surface_table.exs", __DIR__))

defmodule SurfaceTableTest do
  use ExUnit.Case

  alias XipeTotec.SurfaceTable

  # What `xipe refresh -l` records in info.json today (Old.md §34) --
  # passed explicitly so these tests don't read the real info.json.
  @ext %{"ex" => ["elixir"], "exs" => ["elixir"]}

  setup do
    dir = Path.join(System.tmp_dir!(), "xipe_totec_surface_table_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib/repl"))
    File.write!(Path.join(dir, "main.exs"), "")
    File.write!(Path.join(dir, "lib/core.exs"), "")
    File.write!(Path.join(dir, "lib/repl/launch.exs"), "")
    File.write!(Path.join(dir, "README.md"), "")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "generate/2 walks every file, sorted by relative path", %{dir: dir} do
    rows = SurfaceTable.generate(dir, [], @ext)
    assert Enum.map(rows, & &1["path"]) == ["README.md", "lib/core.exs", "lib/repl/launch.exs", "main.exs"]
  end

  test "generate/2 fills depth as the relative path's segment count", %{dir: dir} do
    rows = SurfaceTable.generate(dir, [], @ext)
    by_path = Map.new(rows, &{&1["path"], &1["depth"]})

    assert by_path["main.exs"] == 1
    assert by_path["lib/core.exs"] == 2
    assert by_path["lib/repl/launch.exs"] == 3
  end

  test "generate/2 fills language from a known extension, nil for an unknown one", %{dir: dir} do
    rows = SurfaceTable.generate(dir, [], @ext)
    by_path = Map.new(rows, &{&1["path"], &1["language"]})

    assert by_path["main.exs"] == "elixir"
    assert by_path["lib/core.exs"] == "elixir"
    assert by_path["README.md"] == nil
  end

  test "generate/2 fills repl \"iex\" for elixir rows, nil for a non-elixir row, with no mix.exs at root", %{dir: dir} do
    rows = SurfaceTable.generate(dir, [], @ext)
    by_path = Map.new(rows, &{&1["path"], &1["repl"]})

    assert by_path["main.exs"] == "iex"
    assert by_path["lib/core.exs"] == "iex"
    assert by_path["README.md"] == nil
  end

  test "generate/2 leaves build_tool nil for elixir rows when the root has no mix.exs (scripts-mode)", %{dir: dir} do
    rows = SurfaceTable.generate(dir, [], @ext)
    by_path = Map.new(rows, &{&1["path"], &1["build_tool"]})

    assert by_path["main.exs"] == nil
    assert by_path["README.md"] == nil
  end

  test "generate/2 fills build_tool \"mix\" for elixir rows, still nil for a non-elixir row, when the root has a mix.exs",
       %{dir: dir} do
    File.write!(Path.join(dir, "mix.exs"), "")
    rows = SurfaceTable.generate(dir, [], @ext)
    by_path = Map.new(rows, &{&1["path"], &1["build_tool"]})

    assert by_path["main.exs"] == "mix"
    assert by_path["mix.exs"] == "mix"
    assert by_path["README.md"] == nil
  end

  test "generate/2 assigns every row a fresh id when old_rows is empty (the default)", %{dir: dir} do
    rows = SurfaceTable.generate(dir, [], @ext)
    assert Enum.all?(rows, &is_binary(&1["id"]))
    assert rows |> Enum.map(& &1["id"]) |> Enum.uniq() |> length() == length(rows)
  end

  test "generate/2 reuses an existing row's id for the same path across a rerun, minting a fresh one only for a new path",
       %{dir: dir} do
    old_rows = SurfaceTable.generate(dir, [], @ext)
    old_id_by_path = Map.new(old_rows, &{&1["path"], &1["id"]})

    File.write!(Path.join(dir, "lib/new_file.exs"), "")
    new_rows = SurfaceTable.generate(dir, old_rows, @ext)
    new_id_by_path = Map.new(new_rows, &{&1["path"], &1["id"]})

    for {path, id} <- old_id_by_path, do: assert(new_id_by_path[path] == id, "id for #{path} should be stable")
    assert Map.has_key?(new_id_by_path, "lib/new_file.exs")
    assert new_id_by_path["lib/new_file.exs"] not in Map.values(old_id_by_path)
  end

  test "load/1 on a missing file returns []" do
    assert SurfaceTable.load(Path.join(System.tmp_dir!(), "xipe_totec_no_such_surface_table.json")) == []
  end

  test "save/2 then load/1 round-trips", %{dir: dir} do
    rows = SurfaceTable.generate(dir, [], @ext)
    path = Path.join(dir, "surface_table.json")
    SurfaceTable.save(rows, path)
    assert SurfaceTable.load(path) == rows
  end

  test "generate/3 leaves language nil for an extension two languages both declare (P9, Old.md §34)", %{dir: dir} do
    File.write!(Path.join(dir, "x.h"), "")
    rows = SurfaceTable.generate(dir, [], Map.put(@ext, "h", ["c", "cpp"]))
    row = Enum.find(rows, &(&1["path"] == "x.h"))
    assert row["language"] == nil
    assert row["repl"] == nil
  end

  test "generate/3 with no extensions registered detects no language at all", %{dir: dir} do
    assert dir |> SurfaceTable.generate([], %{}) |> Enum.all?(&(&1["language"] == nil))
  end
end
