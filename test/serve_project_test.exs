ExUnit.start()
# see test/run.sh
System.put_env("XIPE_TOTEC_LSP", "off")

Code.require_file(Path.expand("../lib/serve_project.exs", __DIR__))

defmodule ServeProjectTest.ToyDialogue do
  # Same minimal fake as test/in_out_test.exs's ToyDialogue -- proves
  # request_dialogue/5's wiring (InOut -> Store persist -> notify
  # broadcast, all inside one GenServer.call) without a real dialogue
  # program.
  @behaviour XipeTotec.Dialogue

  @impl true
  def start(_params), do: {:hold, %{}, "continue?"}

  @impl true
  def answer(%{}, %{"choice" => "yes"}) do
    {:done, "done", [%{"method" => "row/add", "params" => %{"node" => "n0", "args" => []}}]}
  end
end

defmodule ServeProjectTest.RaisingDialogue do
  # a program with a bug: what Serve.Project must survive
  @behaviour XipeTotec.Dialogue

  @impl true
  def start(_params), do: raise("boom")

  @impl true
  def answer(_state, _params), do: raise("boom")
end

defmodule ServeProjectTest.GatedSender do
  # Answers each eval write with a canned success -- but only after the test
  # process (registered in :persistent_term) replies :go to a {:gate, pid},
  # so a test can hold a pass mid-evaluation and act while it's running.
  @behaviour XipeTotec.Repl.Sender

  def send(message) do
    handle = self()
    Kernel.send(handle, {handle, {:data, message["ready_pattern"] <> "\nXT_READY\n"}})
    {:ok, handle}
  end

  def write(handle, text) do
    case Regex.run(~r/XT_BEGIN_([^"\s]+)/, text) do
      [_, call_id] ->
        Kernel.send(:persistent_term.get({__MODULE__, :test}), {:gate, self(), call_id})
        receive do: (:go -> :ok)
        body = "XT_BEGIN_#{call_id}\nrepr=exact\ntype=integer\ncompare=none\ndisplay=1\nXT_END_#{call_id}\n"
        Kernel.send(handle, {handle, {:data, body}})

      nil ->
        if text == "System.halt()\n", do: Kernel.send(handle, {handle, {:data, "XT_EXIT 0\n"}})
    end

    :ok
  end

  def kill(_handle), do: :ok
  def interrupt(_handle), do: :ok
end

defmodule ServeProjectTest.SilentSender do
  # Boots, then never answers an entry: the pass waits on its REPL until
  # eval/cancel stops it.
  @behaviour XipeTotec.Repl.Sender

  def send(message) do
    handle = self()
    Kernel.send(handle, {handle, {:data, message["ready_pattern"] <> "\nXT_READY\n"}})
    {:ok, handle}
  end

  def write(_handle, text) do
    case Regex.run(~r/XT_BEGIN_([^"\s]+)/, text) do
      [_, call_id] -> Kernel.send(:persistent_term.get({ServeProjectTest.GatedSender, :test}), {:calling, call_id})
      nil -> :ok
    end

    :ok
  end

  def kill(_handle) do
    Kernel.send(:persistent_term.get({ServeProjectTest.GatedSender, :test}), :killed)
    :ok
  end

  def interrupt(_handle), do: :ok
end

defmodule ServeProjectTest do
  use ExUnit.Case

  alias XipeTotec.Serve.Project

  # Project is registered under its own module name (one `xipe serve` process
  # = one project) -- start/stop it around every test rather
  # than `async: true`, since two tests can't hold the same named GenServer
  # at once.
  setup context do
    dir = Path.join(System.tmp_dir!(), "xipe_totec_serve_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib"))
    store_file = Path.join(dir, "book.jsonl")

    # row/add requires an existing node with a matching arity (Dispatch):
    # seed the store before the project loads it.
    nodes =
      XipeTotec.Book.new()
      |> XipeTotec.Core.put_node("n0", %{sheet: "s0", module: "M", name: "f0", anykey: 0})
      |> XipeTotec.Core.put_node("n1", %{sheet: "s0", module: "M", name: "f1", anykey: 1})

    unless context[:empty_book], do: XipeTotec.Store.persist_diff(store_file, XipeTotec.Book.new(), nodes, [:nodes])

    opts = %{root: dir, store_file: store_file}
    opts = if programs = context[:programs], do: Map.put(opts, :programs, programs), else: opts

    opts =
      if context[:gated_eval] do
        :persistent_term.put({ServeProjectTest.GatedSender, :test}, self())
        Map.put(opts, :eval_opts, sender: ServeProjectTest.GatedSender, launch_opts: [], language: "elixir")
      else
        opts
      end

    opts =
      if context[:silent_eval] do
        :persistent_term.put({ServeProjectTest.GatedSender, :test}, self())

        opts
        |> Map.put(:eval_opts, sender: ServeProjectTest.SilentSender, launch_opts: [], language: "elixir")
        |> Map.put(:project_dir, dir)
      else
        opts
      end

    {:ok, pid} = Project.start_link(opts)
    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      # unique_integer restarts with every VM, so a dir left behind would be
      # reused -- stale book.jsonl and all -- by a later run in the same
      # TMPDIR (a long-lived `nix develop` shell)
      File.rm_rf!(dir)
    end)

    {:ok, dir: dir, store_file: store_file}
  end

  test "request/3 runs a Tier1 method and persists the change", %{store_file: store_file} do
    {:ok, %{"id" => call_id}} = Project.request("row/add", %{"node" => "n0", "args" => []})
    assert is_binary(call_id)
    folded = XipeTotec.Store.load(store_file)
    assert Map.has_key?(folded.calls, call_id)
  end

  test "a row the CLI wrote while the server runs is in the server's book after its next write", %{store_file: store_file} do
    # the CLI: load, change, persist_diff -- as main.exs does
    cli0 = XipeTotec.Store.load(store_file)
    cli1 = XipeTotec.Book.put(cli0, :calls, "from-cli", %{node: "n0", args: ["9"], result: nil, eval_count: 0})
    XipeTotec.Store.persist_diff(store_file, cli0, cli1, [:calls])
    # the server's next write catches up first
    {:ok, %{"id" => call_id}} = Project.request("row/add", %{"node" => "n0", "args" => []})
    book = Project.book()
    assert Map.has_key?(book.calls, "from-cli") and Map.has_key?(book.calls, call_id)
    assert XipeTotec.Store.load(store_file).calls |> Map.keys() |> Enum.sort() == book.calls |> Map.keys() |> Enum.sort()
  end

  test "a row the CLI wrote is there for the server's next read, and is broadcast", %{store_file: store_file} do
    :ok = Project.attach(self())
    cli0 = XipeTotec.Store.load(store_file)
    cli1 = XipeTotec.Book.put(cli0, :calls, "from-cli", %{node: "n0", args: ["9"], result: nil, eval_count: 0})
    XipeTotec.Store.persist_diff(store_file, cli0, cli1, [:calls])

    # a read, nothing written by the server
    assert {:ok, %{"rows" => rows}} = Project.request("row/list", %{})
    assert Enum.any?(rows, &(&1["id"] == "from-cli"))
    assert_receive {:xipe_out, text}
    assert {:ok, {:notify, "notify/rowChanged", %{"id" => "from-cli"}}} = XipeTotec.Protocol.decode(text)
    assert Map.has_key?(Project.book().calls, "from-cli")
  end

  @tag :empty_book
  test "a scan after the CLI's scan starts from the CLI's nodes: no second id for the same function",
       %{dir: dir, store_file: store_file} do
    File.write!(Path.join(dir, "calc.exs"), "defmodule ServeScanCalc do\n  def add(a, b), do: a + b\nend\n")
    assert {:ok, %{"nodes" => 1}} = Project.request("scan/run", %{})

    # a function is added and scanned from the CLI (its own load -> scan -> persist), a row put on it
    File.write!(Path.join(dir, "calc.exs"), "defmodule ServeScanCalc do\n  def add(a, b), do: a + b\n  def sq(a), do: a * a\nend\n")
    cli0 = XipeTotec.Store.load(store_file)
    {cli1, _paths, _failures} = XipeTotec.Project.scan_dir(cli0, dir)
    :ok = XipeTotec.Project.persist_scan(store_file, cli0, cli1)
    sq = XipeTotec.Book.find_node_by_natural_key(cli1, "ServeScanCalc", "sq", 1)
    assert is_binary(sq)

    # the server has not read the file since; its scan must not mint another node for sq
    assert {:ok, %{"nodes" => 2}} = Project.request("scan/run", %{})
    for book <- [Project.book(), XipeTotec.Store.load(store_file)] do
      assert (for {id, n} <- book.nodes, n.name == "sq", do: id) == [sq]
    end
  end

  @tag programs: %{"toy/raise" => ServeProjectTest.RaisingDialogue}
  test "a method that raises is answered internal_error; the server and its book live on", %{store_file: store_file} do
    pid = Process.whereis(Project)
    import ExUnit.CaptureIO

    assert capture_io(:stderr, fn ->
             {dialogue, outcome} = Project.request_dialogue(nil, "toy/raise", %{})
             assert dialogue == nil
             assert %{ok?: false, hold: false, error: %{"code" => "internal_error", "message" => message}} = outcome
             assert message =~ "toy/raise" and message =~ "boom"
           end) =~ "toy/raise raised"

    assert Process.whereis(Project) == pid
    assert {:ok, %{"id" => _}} = Project.request("row/add", %{"node" => "n0", "args" => []})
    assert map_size(XipeTotec.Store.load(store_file).calls) == 1
  end

  test "node/resolve with an arity that names nothing (a JSON null) is invalid_params, not a crash" do
    pid = Process.whereis(Project)
    assert {:error, %{"code" => "invalid_params", "message" => message}} =
             Project.request("node/resolve", %{"module" => "M", "name" => "f1", "arity" => nil})
    assert message =~ "arity"
    assert Process.whereis(Project) == pid
    assert {:ok, %{"id" => "n1"}} = Project.request("node/resolve", %{"module" => "M", "name" => "f1", "arity" => 1})
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
    # scan/run never touches :calls, and :sheets/:links have no notify method
    refute_receive {:xipe_out, _more}, 50
  end

  test "scan/run runs off the server: other requests are answered while it runs, and an effect/set made meanwhile survives it",
       %{dir: dir} do
    # Scanner.Elixir compiles each defmodule for its links, so this module's
    # body holds the scan until the test says :go -- only while the gate is set
    File.write!(Path.join(dir, "lib/slow.ex"), """
    defmodule ServeScanSlow do
      case :persistent_term.get({ServeProjectTest, :scan_gate}, nil) do
        nil -> :ok
        test -> send(test, {:scanning, self()}); receive do: (:go -> :ok)
      end

      def f(x), do: x
    end
    """)

    assert {:ok, %{"paths" => ["lib/slow.ex"]}} = Project.request("scan/run", %{})
    {:ok, %{"matches" => [%{"id" => node_id}]}} = Project.request("card/get", %{"module" => "ServeScanSlow", "name" => "f"})

    :persistent_term.put({ServeProjectTest, :scan_gate}, self())
    on_exit(fn -> :persistent_term.erase({ServeProjectTest, :scan_gate}) end)
    scan = Task.async(fn -> Project.request("scan/run", %{}) end)
    assert_receive {:scanning, compiling}, 5_000

    assert {:ok, _} = Project.request("effect/set", %{"id" => node_id, "effect" => "pure"})

    send(compiling, :go)
    assert {:ok, %{"paths" => ["lib/slow.ex"]}} = Task.await(scan)

    assert {:ok, %{"matches" => [%{"id" => ^node_id, "node" => %{effect: "pure"}}]}} =
             Project.request("card/get", %{"module" => "ServeScanSlow", "name" => "f"})
  end

  @tag capture_log: true
  test "a scan that crashes is answered with an error and the server keeps running", %{dir: dir} do
    # an unreadable source file makes Project.scan_dir_report/3's File.read! raise
    unreadable = Path.join(dir, "lib/locked.ex")
    File.write!(unreadable, "defmodule Locked do\nend\n")
    File.chmod!(unreadable, 0o000)
    on_exit(fn -> File.chmod(unreadable, 0o600) end)

    assert {:error, %{"code" => "scan_failed"}} = Project.request("scan/run", %{})
    assert {:ok, %{"matches" => [_]}} = Project.request("card/get", %{"module" => "M", "name" => "f1"})
  end

  test "row/update routes through Pipeline, not Dispatch's own @not_implemented" do
    # Dispatch's own @not_implemented would answer not_implemented; this
    # message comes from the pipeline's edit stage
    assert {:error, %{"code" => "invalid_params", "message" => message}} = Project.request("row/update", %{})
    assert message =~ "row/update needs id"
  end

  # the edit is applied (and broadcast) at once,
  # the evaluation of that row alone goes to the pass queue
  @tag :gated_eval
  test "row/update edits at once and queues an eval of that row only", %{store_file: store_file} do
    call_id = pure_call(["1"])
    {:ok, %{"id" => other}} = Project.request("row/add", %{"node" => "n1", "args" => ["⟦#{call_id}⟧"]})
    :ok = Project.attach(self())

    assert {:ok, %{"id" => ^call_id, "row" => %{args: ["4"]}, "pass_id" => pass_id, "status" => "started"}} =
             Project.request("row/update", %{"id" => call_id, "args" => ["4"]})

    assert %{"id" => ^call_id, "row" => %{"args" => ["4"]}} = next_notify("notify/rowChanged")
    assert XipeTotec.Store.load(store_file).calls[call_id].args == ["4"]

    assert_receive {:gate, pass_pid, ^call_id}, 2_000
    send(pass_pid, :go)

    assert %{"pass_id" => ^pass_id, "ok" => true, "result" => %{"results" => [%{"call_id" => ^call_id}]}} =
             next_notify("notify/passCompleted")

    assert XipeTotec.Store.load(store_file).calls[other].eval_count == 0
  end

  defp pure_call(args) do
    {:ok, _} = Project.request("effect/set", %{"id" => "n1", "effect" => "pure"})
    {:ok, %{"id" => call_id}} = Project.request("row/add", %{"node" => "n1", "args" => args})
    call_id
  end

  defp next_notify(method) do
    receive do
      {:xipe_out, text} ->
        case XipeTotec.Protocol.decode(text) do
          {:ok, {:notify, ^method, params}} -> params
          _ -> next_notify(method)
        end
    after
      2_000 -> flunk("no #{method}")
    end
  end

  @tag :gated_eval
  test "eval answers with a pass_id at once and the server keeps serving requests while the pass runs",
       %{store_file: store_file} do
    call_id = pure_call(["1"])
    :ok = Project.attach(self())

    assert {:ok, %{"pass_id" => pass_id, "status" => "started"}} = Project.request("eval", %{"call_ids" => [call_id]})

    # the pass is now held inside the REPL round trip ...
    assert_receive {:gate, pass_pid, ^call_id}, 2_000
    # ... and other requests are still answered meanwhile
    assert {:ok, %{"matches" => [_]}} = Project.request("card/get", %{"module" => "M", "name" => "f1"})

    send(pass_pid, :go)

    assert %{"id" => ^call_id, "row" => %{"result" => "1", "eval_count" => 1}} = next_notify("notify/rowChanged")

    assert %{"pass_id" => ^pass_id, "ok" => true, "result" => %{"results" => [%{"outcome" => %{"status" => "ok"}}]}} =
             next_notify("notify/passCompleted")

    assert XipeTotec.Store.load(store_file).calls[call_id].result == "1"
  end

  @tag :gated_eval
  test "a pass records the root's git commit, read when the pass starts", %{dir: dir, store_file: store_file} do
    git = fn args -> {out, 0} = System.cmd("git", ["-c", "user.name=t", "-c", "user.email=t@t" | args], cd: dir); String.trim(out) end
    git.(["init", "-q"])
    git.(["commit", "-q", "--allow-empty", "-m", "x"])
    sha = git.(["rev-parse", "HEAD"])

    call_id = pure_call(["1"])
    :ok = Project.attach(self())
    {:ok, %{"pass_id" => pass_id}} = Project.request("eval", %{"call_ids" => [call_id]})
    assert_receive {:gate, pass_pid, ^call_id}, 2_000
    send(pass_pid, :go)
    assert %{"pass_id" => ^pass_id, "ok" => true} = next_notify("notify/passCompleted")

    assert XipeTotec.Store.load(store_file).calls[call_id].commit == sha
  end

  @tag :gated_eval
  test "a second eval while one is running is queued and runs after it, in order" do
    call_id = pure_call(["1"])
    :ok = Project.attach(self())

    assert {:ok, %{"pass_id" => first, "status" => "started"}} = Project.request("eval", %{"call_ids" => [call_id]})
    assert {:ok, %{"pass_id" => second, "status" => "queued"}} = Project.request("eval/run", %{"call_ids" => [call_id]})

    assert_receive {:gate, pid1, ^call_id}, 2_000
    send(pid1, :go)
    assert %{"pass_id" => ^first} = next_notify("notify/passCompleted")

    assert_receive {:gate, pid2, ^call_id}, 2_000
    send(pid2, :go)
    assert %{"pass_id" => ^second, "ok" => true} = next_notify("notify/passCompleted")
  end

  @tag :gated_eval
  test "a result for a row removed while its pass was running is dropped, not folded back in",
       %{store_file: store_file} do
    call_id = pure_call(["1"])
    :ok = Project.attach(self())

    {:ok, %{"pass_id" => pass_id}} = Project.request("eval", %{"call_ids" => [call_id]})
    assert_receive {:gate, pass_pid, ^call_id}, 2_000
    {:ok, _} = Project.request("row/remove", %{"id" => call_id})
    send(pass_pid, :go)

    assert %{"pass_id" => ^pass_id, "ok" => true, "result" => %{"results" => []}} = next_notify("notify/passCompleted")
    refute Map.has_key?(XipeTotec.Store.load(store_file).calls, call_id)
  end

  @tag :silent_eval
  test "eval/cancel stops the running pass: its REPL is killed, nothing is recorded, and the next pass starts",
       %{store_file: store_file} do
    call_id = pure_call(["1"])
    :ok = Project.attach(self())

    {:ok, %{"pass_id" => first, "status" => "started"}} = Project.request("eval", %{"call_ids" => [call_id]})
    {:ok, %{"pass_id" => second, "status" => "queued"}} = Project.request("eval", %{"call_ids" => [call_id]})
    assert_receive {:calling, ^call_id}, 2_000

    assert {:ok, %{"pass_id" => ^first, "status" => "cancelling"}} = Project.request("eval/cancel", %{})
    assert %{"pass_id" => ^first, "ok" => false, "error" => %{"code" => "cancelled"}} = next_notify("notify/passCompleted")
    assert_received :killed
    assert XipeTotec.Store.load(store_file).calls[call_id][:result] == nil

    # the queued pass runs next, and can be stopped by its id
    assert_receive {:calling, ^call_id}, 2_000
    assert {dialogue, %{ok?: true, result: %{"pass_id" => ^second, "status" => "cancelling"}}} =
             Project.request_dialogue(nil, "eval/cancel", %{"pass_id" => second})

    assert dialogue == nil
    assert %{"pass_id" => ^second, "ok" => false, "error" => %{"code" => "cancelled"}} = next_notify("notify/passCompleted")
    assert {:ok, %{"running" => [], "queued" => []}} = Project.request("eval/status", %{})
  end

  @tag :silent_eval
  test "eval/cancel with a queued pass's id takes it out of the queue; its watcher is told", %{} do
    call_id = pure_call(["1"])
    :ok = Project.attach(self())

    {:ok, %{"pass_id" => first}} = Project.request("eval", %{"call_ids" => [call_id]})
    {_, %{result: %{"pass_id" => second, "status" => "queued"}}} = Project.request_dialogue(Project, nil, "eval", %{"call_ids" => [call_id]}, watch: self())
    assert_receive {:calling, ^call_id}, 2_000

    assert {:ok, %{"pass_id" => ^second, "status" => "dequeued"}} = Project.request("eval/cancel", %{"pass_id" => second})
    assert %{"pass_id" => ^second, "ok" => false, "error" => %{"code" => "cancelled"}} = next_notify("notify/passCompleted")
    assert_receive {:xipe_pass_done, ^second, %{ok?: false, error: %{"code" => "cancelled"}}}
    assert {:ok, %{"queued" => []}} = Project.request("eval/status", %{})

    # the running one was not touched
    refute_received :killed
    assert {:error, %{"code" => "no_pass"}} = Project.request("eval/cancel", %{"pass_id" => "no-such-pass"})
    assert {:ok, %{"pass_id" => ^first}} = Project.request("eval/cancel", %{})
    assert %{"pass_id" => ^first, "ok" => false} = next_notify("notify/passCompleted")
  end

  test "eval/cancel with nothing running is no_pass" do
    assert {:error, %{"code" => "no_pass"}} = Project.request("eval/cancel", %{})
  end

  test "roster names the tables search reads, with their flags and columns" do
    assert {:ok, %{"tables" => [surface, eval]}} = Project.request("roster", %{})
    assert %{"name" => "surface", "flag" => "-s", "columns" => ["id", "path" | _]} = surface
    assert %{"name" => "eval", "flag" => "-e"} = eval
    assert "result" in eval["columns"]
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
