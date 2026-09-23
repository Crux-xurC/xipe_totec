ExUnit.start()

Code.require_file(Path.expand("../lib/serve_project.exs", __DIR__))

defmodule ServeProjectTest.ToyDialogue do
  # Same minimal fake as test/in_out_test.exs's ToyDialogue -- proves
  # request_dialogue/5's wiring (InOut -> Store persist -> notify
  # broadcast, all inside one GenServer.call) without a real dialogue
  # program existing yet (Old.md §16.4 step 4 is still unbuilt).
  @behaviour XipeTotec.Dialogue

  @impl true
  def start(_params), do: {:hold, %{}, "continue?"}

  @impl true
  def answer(%{}, %{"choice" => "yes"}) do
    {:done, "done", [%{"method" => "row/add", "params" => %{"node" => "n0", "args" => []}}]}
  end
end

defmodule ServeProjectTest do
  use ExUnit.Case

  alias XipeTotec.Serve.Project

  # Project is registered under its own module name (one `xipe serve` process
  # = one project, Old.md §9) -- start/stop it around every test rather
  # than `async: true`, since two tests can't hold the same named GenServer
  # at once.
  setup context do
    dir = Path.join(System.tmp_dir!(), "xipe_totec_serve_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib"))
    store_file = Path.join(dir, "book.jsonl")

    # row/add requires an existing node with a matching arity (Dispatch,
    # Old.md §32): seed the store before the project loads it.
    nodes =
      XipeTotec.Book.new()
      |> XipeTotec.Core.put_node("n0", %{sheet: "s0", module: "M", name: "f0", arity: 0})
      |> XipeTotec.Core.put_node("n1", %{sheet: "s0", module: "M", name: "f1", arity: 1})

    unless context[:empty_book], do: XipeTotec.Store.persist_diff(store_file, XipeTotec.Book.new(), nodes, [:nodes])

    opts = %{root: dir, store_file: store_file}
    opts = if programs = context[:programs], do: Map.put(opts, :programs, programs), else: opts

    {:ok, pid} = Project.start_link(opts)
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
    {:ok, %{"id" => call_id}} = Project.request("row/add", %{"node" => "n1", "args" => ["1"]})

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

  @tag :empty_book
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

  test "eval/run and row/update route through Pipeline, not Dispatch's own @not_implemented" do
    # same proof as RunnerTest's equivalent case: Dispatch's own
    # @not_implemented has no concept of "stages", so a message naming a
    # stage can only have come from Pipeline
    assert {:error, %{"code" => "not_implemented", "message" => eval_run_message}} = Project.request("eval/run", %{})
    assert eval_run_message =~ "\"eval\""

    assert {:error, %{"code" => "not_implemented", "message" => row_update_message}} = Project.request("row/update", %{})
    assert row_update_message =~ "\"edit\""
  end

  test "request_dialogue/5 with no programs registered still routes an ordinary command straight through, tagged 01",
       %{store_file: store_file} do
    {dialogue, outcome} = Project.request_dialogue(nil, "row/add", %{"node" => "n0", "args" => []})

    assert dialogue == nil
    assert outcome.hold == false
    assert outcome.via_repl == false
    assert outcome.ok? == true
    assert Map.has_key?(XipeTotec.Store.load(store_file).calls, outcome.result["id"])
  end

  @tag programs: %{"toy/negotiate" => ServeProjectTest.ToyDialogue}
  test "request_dialogue/5 holds across a GenServer.call boundary and finishes by persisting through Store",
       %{store_file: store_file} do
    :ok = Project.attach(self())

    {dialogue, outcome} = Project.request_dialogue(nil, "toy/negotiate", %{})
    assert {ServeProjectTest.ToyDialogue, %{}} = dialogue
    assert outcome.hold == true
    assert outcome.text == "continue?"
    # holding does not touch Book, so no notify fires yet
    refute_receive {:xipe_out, _}, 50

    {dialogue, outcome} = Project.request_dialogue(dialogue, "dialogue/answer", %{"choice" => "yes"})
    assert dialogue == nil
    assert outcome.hold == false
    assert outcome.via_repl == true
    assert [%{ok?: true}] = outcome.result["outcomes"]

    assert_receive {:xipe_out, text}
    assert {:ok, {:notify, "notify/rowChanged", _}} = XipeTotec.Protocol.decode(text)
    assert map_size(XipeTotec.Store.load(store_file).calls) == 1
  end
end
