ExUnit.start()

Code.require_file(Path.expand("../lib/workspace.exs", __DIR__))

defmodule WorkspaceTest do
  use ExUnit.Case

  alias XipeTotec.{Info, ProjectRegistry, Workspace}

  setup do
    base = Path.join(System.tmp_dir!(), "xipe_totec_workspace_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)

    roots = %{registry: Path.join(base, "tables/project"), info: Path.join(base, "info.json")}
    proj_a = Path.join(base, "a")
    proj_b = Path.join(base, "b")
    File.mkdir_p!(proj_a)
    File.mkdir_p!(proj_b)
    File.write!(Path.join(proj_a, "m.exs"), "defmodule A do\n  def f(x), do: x\nend\n")
    File.write!(Path.join(proj_b, "notes.txt"), "hi\n")

    {:ok, roots: roots, proj_a: proj_a, proj_b: proj_b}
  end

  test "lookup/2 is the reverse of register/2", %{roots: roots, proj_a: a} do
    id = ProjectRegistry.register(a, roots.registry)
    assert {dir, ^a} = ProjectRegistry.lookup(id, roots.registry)
    assert Path.basename(dir) == "#{id}_a"
    assert ProjectRegistry.lookup("999", roots.registry) == nil
  end

  test "resolve/2 with nothing selected is an error pointing at `xipe choice project`", %{roots: roots} do
    assert {:error, message} = Workspace.resolve(nil, roots)
    assert message =~ "xipe choice project"
  end

  test "resolve/2 with an unregistered <dir> is an error, never an implicit registration", %{roots: roots, proj_a: a} do
    assert {:error, message} = Workspace.resolve(a, roots)
    assert message =~ "not a registered project"
    assert ProjectRegistry.find(a, roots.registry) == nil
  end

  test "choose/2 registers a new project, saves its surface table, and selects it", %{roots: roots, proj_a: a} do
    assert {project, :new} = Workspace.choose(a, roots)
    assert project.id == "001"
    assert project.path == a
    assert Path.dirname(project.store_file) == project.dir
    assert [%{"path" => "m.exs", "language" => "elixir"}] = XipeTotec.SurfaceTable.load(project.table_file)
    assert Info.load(roots.info)["project"] == "001"
    assert {:ok, ^project} = Workspace.resolve(nil, roots)
  end

  test "choose/2 on an already-registered project keeps its id and just switches the selection", %{roots: roots, proj_a: a, proj_b: b} do
    {pa, :new} = Workspace.choose(a, roots)
    {pb, :new} = Workspace.choose(b, roots)
    assert Info.load(roots.info)["project"] == pb.id

    assert {^pa, :existing} = Workspace.choose(a, roots)
    assert Info.load(roots.info)["project"] == pa.id
  end

  test "each project gets its own book file", %{roots: roots, proj_a: a, proj_b: b} do
    {pa, _} = Workspace.choose(a, roots)
    {pb, _} = Workspace.choose(b, roots)
    assert pa.store_file != pb.store_file
    assert {:ok, ^pa} = Workspace.resolve(a, roots)
  end

  test "generate_table/2 keeps row ids stable across regeneration and picks up new files", %{roots: roots, proj_a: a} do
    {_project, [row]} = Workspace.generate_table(a, roots)
    File.write!(Path.join(a, "n.exs"), "defmodule N do\nend\n")
    {_project, rows} = Workspace.generate_table(a, roots)
    assert Enum.find(rows, &(&1["path"] == "m.exs"))["id"] == row["id"]
    assert Enum.any?(rows, &(&1["path"] == "n.exs"))
  end

  test "resolve/2 preserves the other info.json fields", %{roots: roots, proj_a: a} do
    Info.save(%{"languages" => ["elixir"], "repls" => [], "project" => nil}, roots.info)
    Workspace.choose(a, roots)
    assert Info.load(roots.info)["languages"] == ["elixir"]
  end
end
