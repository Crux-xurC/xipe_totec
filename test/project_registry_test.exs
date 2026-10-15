ExUnit.start()

Code.require_file(Path.expand("../lib/project_registry.exs", __DIR__))

defmodule ProjectRegistryTest do
  use ExUnit.Case

  alias XipeTotec.ProjectRegistry

  setup do
    root = Path.join(System.tmp_dir!(), "xipe_totec_project_registry_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "find/2 against a root that doesn't exist yet returns nil", %{root: root} do
    assert ProjectRegistry.find("/some/project", root) == nil
  end

  test "next_id/1 against a root that doesn't exist yet starts at 001 (000 is never assigned)", %{root: root} do
    assert ProjectRegistry.next_id(root) == "001"
  end

  test "register/2 assigns 001 to the first project, creates its directory and project.json", %{root: root} do
    id = ProjectRegistry.register("/abs/path/foo", root)
    assert id == "001"
    assert File.dir?(Path.join(root, "001_foo"))
    assert File.read!(Path.join([root, "001_foo", "project.json"])) =~ "/abs/path/foo"
  end

  test "register/2 is idempotent: the same path registered twice returns the same id, no duplicate directory", %{
    root: root
  } do
    id1 = ProjectRegistry.register("/abs/path/foo", root)
    id2 = ProjectRegistry.register("/abs/path/foo", root)

    assert id1 == id2
    assert File.ls!(root) == ["001_foo"]
  end

  test "register/2 assigns the next id to a different path", %{root: root} do
    id1 = ProjectRegistry.register("/abs/path/foo", root)
    id2 = ProjectRegistry.register("/abs/path/bar", root)

    assert id1 == "001"
    assert id2 == "002"
  end

  test "find/2 resolves a registered path back to its id", %{root: root} do
    id = ProjectRegistry.register("/abs/path/foo", root)
    assert ProjectRegistry.find("/abs/path/foo", root) == id
  end

  test "find/2 and register/2 normalize the path first, so '.'-relative and absolute forms of the same directory match" do
    root = Path.join(System.tmp_dir!(), "xipe_totec_project_registry_test_#{System.unique_integer([:positive])}")
    target = Path.join(System.tmp_dir!(), "xipe_totec_project_registry_target_#{System.unique_integer([:positive])}")
    File.mkdir_p!(target)
    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(target)
    end)

    id = ProjectRegistry.register(Path.join(target, "."), root)
    assert ProjectRegistry.find(target, root) == id
  end

  test "next_id/1 never reuses a lower id, even if the highest-numbered project was the only one ever created", %{
    root: root
  } do
    File.mkdir_p!(Path.join(root, "005_orphaned"))
    File.write!(Path.join([root, "005_orphaned", "project.json"]), ~s({"path":"/abs/path/orphaned"}))

    assert ProjectRegistry.next_id(root) == "006"
  end

  test "a stray directory under root with no 3-digit prefix is ignored", %{root: root} do
    File.mkdir_p!(Path.join(root, "not_a_project"))
    assert ProjectRegistry.next_id(root) == "001"
    assert ProjectRegistry.find("/abs/path/foo", root) == nil
  end

  # a project.json that is not readable JSON (2026-10-16, crux): named, never
  # a crash, and the path is not registered again under a new id
  test "a project.json that is not readable is named by find/2, lookup/2 and register/2", %{root: root} do
    id = ProjectRegistry.register("/abs/one", root)
    other = ProjectRegistry.register("/abs/two", root)
    broken = Path.join([root, "#{id}_one", "project.json"])
    File.write!(broken, ~s({"path": ))

    # the path asked for is another registered one: found all the same
    assert ProjectRegistry.find("/abs/two", root) == other
    # not found, and one entry can't be read: it might be that one
    assert {:error, message} = ProjectRegistry.find("/abs/three", root)
    assert message =~ broken and message =~ "fix it by hand"
    assert {:error, ^message} = ProjectRegistry.register("/abs/three", root)
    assert {:error, _} = ProjectRegistry.lookup(id, root)
    assert {_dir, "/abs/two"} = ProjectRegistry.lookup(other, root)
    # nothing new was registered
    assert length(File.ls!(root)) == 2
  end
end
