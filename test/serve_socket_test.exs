ExUnit.start()
# see test/run.sh
System.put_env("XIPE_TOTEC_LSP", "off")

Code.require_file(Path.expand("../lib/serve_socket.exs", __DIR__))

defmodule ServeSocketTest.ToyDialogue do
  # Same fake as serve_project_test.exs's -- Serve.Socket is a thin
  # transport shell (moduledoc), so this only needs to prove that a
  # dialogue held via Serve.Project actually survives round-tripping
  # through Serve.Socket's own state between two websocket_handle/2 calls,
  # and that the §17.2 reply envelope ("from"/"dialogue") comes out right.
  @behaviour XipeTotec.Dialogue

  @impl true
  def start(_params), do: {:hold, %{}, "continue?"}

  @impl true
  def answer(%{}, %{"choice" => "yes"}), do: {:done, "done", []}
end

defmodule ServeSocketTest do
  use ExUnit.Case

  alias XipeTotec.Serve.{Project, Socket}

  # Serve.Project is a named GenServer (Old.md §9), same
  # one-at-a-time reasoning as serve_project_test.exs. Socket's own
  # callbacks (websocket_handle/2 etc.) are plain functions over a state
  # map -- no cowboy/real WS connection needed to exercise them directly.
  setup do
    dir = Path.join(System.tmp_dir!(), "xipe_totec_socket_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    store_file = Path.join(dir, "book.jsonl")

    # row/add requires an existing node with a matching arity (Dispatch,
    # Old.md §32): seed the store before the project loads it.
    nodes =
      XipeTotec.Book.new()
      |> XipeTotec.Core.put_node("n0", %{sheet: "s0", module: "M", name: "f0", anykey: 0})
      |> XipeTotec.Core.put_node("n1", %{sheet: "s0", module: "M", name: "f1", anykey: 1})

    XipeTotec.Store.persist_diff(store_file, XipeTotec.Book.new(), nodes, [:nodes])

    {:ok, pid} =
      Project.start_link(%{root: dir, store_file: store_file, programs: %{"toy/negotiate" => ServeSocketTest.ToyDialogue}})

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {:ok, state: %{initialized: true, capabilities: %{}, dialogue: nil}}
  end

  defp request(method, params, id \\ 1), do: JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})

  test "an ordinary request carries a 01-tagged dialogue envelope and dialogue stays nil", %{state: state} do
    {:reply, {:text, body}, new_state} =
      Socket.websocket_handle({:text, request("row/add", %{"node" => "n0", "args" => []})}, state)

    assert new_state.dialogue == nil
    assert {:ok, %{"result" => result, "dialogue" => %{"hold" => false, "via_repl" => false}, "from" => nil}} = JSON.decode(body)
    assert is_binary(result["id"])
  end

  test "starting a registered dialogue holds it in Socket's own state across calls", %{state: state} do
    {:reply, {:text, body1}, state} = Socket.websocket_handle({:text, request("toy/negotiate", %{})}, state)

    assert {:ok, %{"dialogue" => %{"hold" => true, "text" => "continue?"}}} = JSON.decode(body1)
    assert {ServeSocketTest.ToyDialogue, %{}} = state.dialogue

    {:reply, {:text, body2}, state} =
      Socket.websocket_handle({:text, request("dialogue/answer", %{"choice" => "yes"})}, state)

    assert {:ok, %{"dialogue" => %{"hold" => false, "text" => "done"}}} = JSON.decode(body2)
    assert state.dialogue == nil
  end
end
