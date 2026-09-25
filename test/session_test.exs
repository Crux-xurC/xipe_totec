ExUnit.start()

Code.require_file(Path.expand("../lib/session.exs", __DIR__))

defmodule SessionTest do
  use ExUnit.Case

  alias XipeTotec.Session

  setup do
    path = Path.join(System.tmp_dir!(), "xipe_totec_session_test_#{System.unique_integer([:positive])}/session.json")
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    {:ok, path: path}
  end

  # the pid of a process that has already exited
  defp dead_pid do
    {out, 0} = System.cmd("sh", ["-c", "echo $$"])
    String.trim(out)
  end

  test "write/2 then read/1 gives back this process's record", %{path: path} do
    Session.write(%{"port" => 4200, "project" => "001", "root" => "/p", "lsp" => nil, "fs_root" => nil}, path)

    assert {:ok, record} = Session.read(path)
    assert record["os_pid"] == System.pid()
    assert record["project"] == "001"
    assert record["lsp"] == nil
    assert {:ok, _, _} = DateTime.from_iso8601(record["started_at"])
  end

  test "no file, or an unreadable one, is no session", %{path: path} do
    assert Session.read(path) == :none
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "not json")
    assert Session.read(path) == :none
  end

  test "a record whose process is gone is no session (a Ctrl-C'd start leaves one behind)", %{path: path} do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(%{"os_pid" => dead_pid(), "port" => 4200, "project" => "001"}))
    assert Session.read(path) == :none
  end

  test "clear/1 removes only this process's own record", %{path: path} do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(%{"os_pid" => "1", "project" => "001"}))
    Session.clear(path)
    assert File.exists?(path)

    Session.write(%{"project" => "001"}, path)
    Session.clear(path)
    refute File.exists?(path)
  end
end
