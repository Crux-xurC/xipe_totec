ExUnit.start()

Code.require_file(Path.expand("../lib/serve_project.exs", __DIR__))

defmodule ServeProjectTest do
  use ExUnit.Case

  alias XipeTotec.Serve.Project

  # Project is registered under its own module name (one `xipe serve` process
  # = one project, prebuild.md §9) -- start/stop it around every test rather
  # than `async: true`, since two tests can't hold the same named GenServer
  # at once.
  setup do
    dir = Path.join(System.tmp_dir!(), "xipe_totec_serve_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib"))
    store_file = Path.join(dir, "book.jsonl")

    {:ok, pid} = Project.start_link(%{root: dir, store_file: store_file})
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, dir: dir, store_file: store_file}
  end

  test "request/3 runs a Tier1 method and persists the change", %{store_file: store_file} do
    {:ok, %{"id" => call_id}} = Project.request("row/add", %{"node" => "n0", "args" => []})
    assert is_binary(call_id)
    folded = XipeTotec.Store.load(store_file)
    assert Map.has_key?(folded.calls, call_id)
  end

  test "request/3 surfaces a Dispatch error without touching the book", %{store_file: store_file} do
    assert {:error, %{"code" => "invalid_params"}} = Project.request("row/add", %{})
    assert XipeTotec.Store.load(store_file).calls == %{}
  end

  test "attach/2 + a write broadcasts notify/rowChanged to the attached session" do
    :ok = Project.attach(self())
    {:ok, %{"id" => call_id}} = Project.request("row/add", %{"node" => "n0", "args" => ["1"]})

    assert_receive {:xipe_out, text}
    assert {:ok, {:notify, "notify/rowChanged", %{"id" => ^call_id} = params}} = XipeTotec.Protocol.decode(text)
    assert "args" in params["columns"]
  end

  test "detach/2 stops further broadcasts to that session" do
    :ok = Project.attach(self())
    :ok = Project.detach(self())
    {:ok, _} = Project.request("row/add", %{"node" => "n0", "args" => []})
    refute_receive {:xipe_out, _text}, 50
  end

  test "a session's death (no explicit detach) is cleaned up automatically" do
    parent = self()

    ghost =
      spawn(fn ->
        :ok = Project.attach(self())
        send(parent, :attached)
        receive do: (:die -> :ok)
      end)

    assert_receive :attached
    send(ghost, :die)
    # give the DOWN handler a moment to run before asserting no crash follows
    Process.sleep(20)

    {:ok, _} = Project.request("row/add", %{"node" => "n0", "args" => []})
    refute_receive {:xipe_out, _text}, 50
  end

  test "scan/run populates the book from ctx.root and notifies the new node (sheets/links aren't notify-worthy in v0)",
       %{dir: dir} do
    File.write!(Path.join(dir, "lib/a.ex"), """
    defmodule ServeScanA do
      def f(x), do: x + 1
    end
    """)

    :ok = Project.attach(self())
    assert {:ok, %{"sheets" => 1, "nodes" => 1}} = Project.request("scan/run", %{})

    assert_receive {:xipe_out, text}
    assert {:ok, {:notify, "notify/nodeChanged", %{"row" => %{"name" => "f"}}}} = XipeTotec.Protocol.decode(text)
    # scan/run never touches :calls, and :sheets/:links have no notify method in §16.3
    refute_receive {:xipe_out, _more}, 50
  end
end
