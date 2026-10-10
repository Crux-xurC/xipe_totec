ExUnit.start()
# see test/run.sh
System.put_env("XIPE_TOTEC_LSP", "off")

Code.require_file(Path.expand("../lib/serve_socket.exs", __DIR__))

defmodule ServeInputTest.ToyDialogue do
  # "continue?" until answered "yes"; reads a typed line itself
  @behaviour XipeTotec.Dialogue

  @impl true
  def start(_params), do: {:hold, %{}, "continue? (yes/no)"}

  @impl true
  def answer(%{}, %{"choice" => "yes"}), do: {:done, "done", []}
  def answer(state, _params), do: {:hold, state, "yes or no, please"}

  @impl true
  def parse_answer(line), do: %{"choice" => String.trim(line)}
end

defmodule ServeInputTest.PlainDialogue do
  # no parse_answer/1: the line arrives as %{"text" => line}
  @behaviour XipeTotec.Dialogue

  @impl true
  def start(_params), do: {:hold, %{}, "say something"}

  @impl true
  def answer(%{}, %{"text" => text}), do: {:done, "heard #{text}", []}
end

defmodule ServeInputTest.InstantSender do
  # every eval write answered at once with the value 1
  @behaviour XipeTotec.Repl.Sender

  def send(message) do
    handle = self()
    Kernel.send(handle, {handle, {:data, message["ready_pattern"] <> "\nXT_READY\n"}})
    {:ok, handle}
  end

  def write(handle, text) do
    case Regex.run(~r/XT_BEGIN_([^"\s]+)/, text) do
      [_, call_id] ->
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

defmodule ServeInputTest do
  use ExUnit.Case

  alias XipeTotec.Serve.{Project, Socket}

  # Serve.Project is a named GenServer: one test at a time (see serve_socket_test.exs)
  setup do
    dir = Path.join(System.tmp_dir!(), "xipe_totec_input_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    store_file = Path.join(dir, "book.jsonl")

    nodes =
      XipeTotec.Book.new()
      |> XipeTotec.Core.put_node("n0", %{sheet: "s0", module: "M", name: "f0", anykey: 0})
      |> XipeTotec.Core.put_node("n1", %{sheet: "s0", module: "M", name: "f1", anykey: 1})

    XipeTotec.Store.persist_diff(store_file, XipeTotec.Book.new(), nodes, [:nodes])

    {:ok, pid} =
      Project.start_link(%{
        root: dir,
        store_file: store_file,
        project_id: "042",
        programs:
          Map.merge(XipeTotec.InOut.programs(), %{"toy/negotiate" => ServeInputTest.ToyDialogue, "toy/plain" => ServeInputTest.PlainDialogue}),
        eval_opts: [sender: ServeInputTest.InstantSender, launch_opts: [], language: "elixir"]
      })

    on_exit(fn ->
      # linked to the test process, it may be going down on its own already
      try do
        GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end

      File.rm_rf!(dir)
    end)

    {:ok, dir: dir, store_file: store_file, state: %{initialized: true, capabilities: %{}, dialogue: nil, inputs: %{}}}
  end

  defp frame(text, id), do: JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => "input", "params" => %{"text" => text}})

  # one `input` through Serve.Socket, waiting for a reply that comes later
  defp input(state, text, id \\ 1) do
    case Socket.websocket_handle({:text, frame(text, id)}, state) do
      {:reply, {:text, body}, state} ->
        {JSON.decode!(body), state}

      {:ok, state} ->
        receive do
          {:xipe_input_done, _ref, _dialogue, _outcome} = done ->
            {:reply, {:text, body}, state} = Socket.websocket_info(done, state)
            {JSON.decode!(body), state}
        after
          5_000 -> flunk("no reply to input #{inspect(text)}")
        end
    end
  end

  test "help answers with the window's lines in dialogue.text", %{state: state} do
    {reply, _state} = input(state, "help", 7)
    assert %{"id" => 7, "result" => %{}, "dialogue" => %{"hold" => false, "text" => text}} = reply
    assert text == XipeTotec.Help.text(:window)
    assert text =~ "\nrow/add: make a calc row"
  end

  test "a line that can't be read is an input_error", %{state: state} do
    {reply, _state} = input(state, "choice project /x")
    assert %{"error" => %{"code" => "input_error", "message" => message}} = reply
    assert message =~ "a terminal command, run as xipe choice project"

    {reply, _state} = input(state, "row/add 'unclosed")
    assert %{"error" => %{"code" => "input_error"}} = reply
  end

  test "input without text is invalid_params", %{state: state} do
    body = JSON.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "input", "params" => %{}})
    {:reply, {:text, body}, _state} = Socket.websocket_handle({:text, body}, state)
    assert %{"error" => %{"code" => "invalid_params"}} = JSON.decode!(body)
  end

  test "a command list runs like xipe do, $refs included, answered with the CLI's lines", %{state: state, store_file: store_file} do
    {reply, _state} = input(state, "effect/set id=n1 effect=pure -- row/add node=n1 args=[5] -- row/list 'call_ids=[$1.id]'")

    assert %{"result" => %{"outcomes" => [o1, o2, o3]}, "dialogue" => %{"text" => text, "via_repl" => false}} = reply
    assert %{"method" => "effect/set", "ok" => true} = o1
    assert %{"method" => "row/add", "ok" => true, "result" => %{"id" => call_id}} = o2
    assert %{"method" => "row/list", "result" => %{"rows" => [%{"id" => ^call_id, "args" => ["5"]}]}} = o3
    assert text =~ "effect/set  ok"
    assert text =~ "xipe: 3 command(s), 3 ok"

    # through Serve.Project: persisted like any request
    assert XipeTotec.Store.load(store_file).calls[call_id].args == ["5"]
  end

  test "an eval waits for its pass: the next command sees the value", %{state: state} do
    {reply, _state} =
      input(state, "effect/set id=n1 effect=pure -- row/add node=n1 args=[5] -- eval 'call_ids=[$1.id]' -- row/check on=unevaluated,error")

    assert %{"result" => %{"outcomes" => [_, %{"result" => %{"id" => call_id}}, eval, check]}, "dialogue" => dialogue} = reply
    assert %{"method" => "eval", "ok" => true, "result" => %{"pass_id" => _, "results" => [%{"call_id" => ^call_id, "outcome" => %{"status" => "ok"}}]}} = eval
    assert %{"method" => "row/check", "ok" => true} = check
    assert dialogue["via_repl"] == true
    assert dialogue["text"] =~ "eval call #{call_id}  ok       repr=exact  1"
  end

  test "row/update keeps its edited row and reports the pass", %{state: state} do
    {reply, state} = input(state, "effect/set id=n1 effect=pure -- row/add node=n1 args=[5]")
    %{"result" => %{"outcomes" => [_, %{"result" => %{"id" => call_id}}]}} = reply

    {reply, _state} = input(state, "row/update id=#{call_id} args=[6]")
    assert %{"result" => %{"outcomes" => [%{"method" => "row/update", "ok" => true, "result" => result}]}} = reply
    assert %{"id" => ^call_id, "row" => %{"args" => ["6"]}, "results" => [%{"call_id" => ^call_id}]} = result
    refute Map.has_key?(result, "status")
  end

  test "show prints the server's book", %{state: state} do
    {reply, _state} = input(state, "show")
    assert %{"dialogue" => %{"text" => "project 042  " <> text}} = reply
    assert text =~ "M.f1/1"
  end

  test "a dialogue started from a line is held, and the next line answers it", %{state: state} do
    {reply, state} = input(state, "toy/negotiate")
    assert %{"dialogue" => %{"hold" => true, "text" => "continue? (yes/no)\n"}} = reply
    assert {ServeInputTest.ToyDialogue, %{}} = state.dialogue

    # held: even a line that reads as a command is the answer
    {reply, state} = input(state, "help")
    assert %{"dialogue" => %{"hold" => true, "text" => "yes or no, please"}} = reply

    {reply, state} = input(state, "yes")
    assert %{"dialogue" => %{"hold" => false, "text" => "done"}} = reply
    assert state.dialogue == nil
  end

  test "a dialogue without parse_answer gets the line as text", %{state: state} do
    {_reply, state} = input(state, "toy/plain")
    {reply, state} = input(state, "hello there")
    assert %{"dialogue" => %{"hold" => false, "text" => "heard hello there"}} = reply
    assert state.dialogue == nil
  end

  test "search from the window: turns, a command passed on with x, an eval waited for, quit dialogue", %{state: state} do
    {reply, state} = input(state, "search")
    assert %{"dialogue" => %{"hold" => true, "text" => "Search started" <> _}} = reply

    # an ordinary command line inside the search runs (and the search stays held)
    {reply, state} = input(state, "effect/set id=n1 effect=pure -- row/add node=n1 args=[5]")
    assert %{"dialogue" => %{"hold" => true, "text" => text}} = reply
    assert text =~ "xipe: 2 command(s), 2 ok"
    assert {XipeTotec.Dialogue.Search, _} = state.dialogue

    {reply, state} = input(state, "-e node n1")
    assert %{"dialogue" => %{"hold" => true, "text" => "1 hit(s)." <> _}} = reply

    {_reply, state} = input(state, "get id")
    call_id = elem(state.dialogue, 1).x

    {reply, state} = input(state, "eval x")
    assert %{"dialogue" => %{"hold" => true, "via_repl" => true, "text" => text}} = reply
    assert text =~ "eval call #{call_id}  ok"

    {reply, state} = input(state, "-e result 1 id")
    assert %{"dialogue" => %{"text" => "1 hit(s). (id: [" <> _}} = reply

    {reply, state} = input(state, "quit dialogue")
    assert %{"dialogue" => %{"hold" => false, "text" => "The dialogue has ended."}} = reply
    assert state.dialogue == nil
  end

  test "dialogue depends from the window: its commands run in the pass queue", %{state: state} do
    {reply, state} = input(state, "effect/set id=n1 effect=pure -- row/add node=n1 args=[5] -- row/add node=n1 'args=[⟦$1.id⟧]'")
    %{"result" => %{"outcomes" => [_, %{"result" => %{"id" => upstream}}, %{"result" => %{"id" => target}}]}} = reply

    {reply, state} = input(state, "dialogue depends #{target}")
    assert %{"dialogue" => %{"hold" => true, "text" => question}} = reply
    assert question =~ "Supply a value for #{upstream} and evaluate?"

    {reply, state} = input(state, "y 7")
    assert %{"dialogue" => %{"hold" => false, "via_repl" => true, "text" => text}} = reply
    assert text =~ "Supplying a value for"
    assert text =~ "row/set-result  ok"
    assert text =~ "eval call #{target}  ok"
    assert state.dialogue == nil
  end

  test "an unknown method is reported in the text, the rest still runs", %{state: state} do
    {reply, _state} = input(state, "no/such -- row/list")
    assert %{"result" => %{"outcomes" => [%{"ok" => false}, %{"ok" => true}]}, "dialogue" => %{"text" => text}} = reply
    assert text =~ "no/such  error"
    assert text =~ "xipe: 2 command(s), 1 ok"
  end
end
