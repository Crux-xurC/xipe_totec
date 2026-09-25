ExUnit.start()

Code.require_file(Path.expand("../lib/lsp/transport/relay.exs", __DIR__))

defmodule LspRelayTest.FakeLsp do
  # tezcatl's /lsp as a consumer sees it (lib/relay/lsp_socket.exs): an
  # attach frame first, then raw JSON-RPC. Every request is answered with
  # its method echoed back, after an unrelated notification (the relay
  # broadcasts the server's notifications to every consumer).
  @behaviour :cowboy_websocket

  def init(req, _opts), do: {:cowboy_websocket, req, %{attached: false}}

  def websocket_handle({:text, text}, %{attached: false} = state) do
    case JSON.decode!(text) do
      %{"kind" => "attach", "path" => "refuse/" <> _} ->
        {:reply, {:text, JSON.encode!(%{"kind" => "error", "reason" => "no LSP server configured"})}, state}

      %{"kind" => "attach", "path" => path, "lang" => lang} ->
        send(:persistent_term.get(:lsp_relay_test), {:attached, path, lang})
        {:reply, {:text, JSON.encode!(%{"kind" => "attached", "rootUri" => "file:///x", "serverId" => lang})}, %{state | attached: true}}
    end
  end

  def websocket_handle({:text, text}, state) do
    case JSON.decode!(text) do
      %{"id" => id, "method" => "fail"} ->
        {:reply, {:text, JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => -32601, "message" => "no such method"}})}, state}

      %{"id" => id, "method" => method} ->
        noise = JSON.encode!(%{"jsonrpc" => "2.0", "method" => "window/logMessage", "params" => %{"message" => "hi"}})
        reply = JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => %{"echo" => method}})
        {:reply, [{:text, noise}, {:text, reply}], state}

      %{"method" => method} ->
        send(:persistent_term.get(:lsp_relay_test), {:notified, method})
        {:ok, state}
    end
  end

  def websocket_info(_msg, state), do: {:ok, state}
end

defmodule LspRelayTest do
  use ExUnit.Case

  alias XipeTotec.Lsp.Transport.Relay

  setup_all do
    {:ok, _} = Application.ensure_all_started(:cowboy)
    dispatch = :cowboy_router.compile([{:_, [{"/lsp", LspRelayTest.FakeLsp, []}]}])
    {:ok, _} = :cowboy.start_clear(:lsp_relay_test, %{socket_opts: [{:ip, {127, 0, 0, 1}}, {:port, 0}]}, %{env: %{dispatch: dispatch}})
    port = :ranch.get_port(:lsp_relay_test)
    on_exit(fn -> :cowboy.stop_listener(:lsp_relay_test) end)
    {:ok, url: "ws://127.0.0.1:#{port}/lsp"}
  end

  setup do
    :persistent_term.put(:lsp_relay_test, self())
    :ok
  end

  test "attaches with the file's path relative to tezcatl's file root, then requests and notifies", %{url: url} do
    assert {:ok, conn} = Relay.connect("/fs/proj", "elixir", "/fs/proj/lib/a.ex", %{url: url, fs_root: "/fs"})
    assert_receive {:attached, "proj/lib/a.ex", "elixir"}

    # the logMessage notification sent ahead of each reply is skipped
    assert Relay.request(conn, "textDocument/documentSymbol", %{}, 2_000) == {:ok, %{"echo" => "textDocument/documentSymbol"}}
    assert Relay.request(conn, "initialize", %{}, 2_000) == {:ok, %{"echo" => "initialize"}}
    assert Relay.request(conn, "fail", %{}, 2_000) == {:error, "no such method"}

    :ok = Relay.notify(conn, "textDocument/didOpen", %{})
    assert_receive {:notified, "textDocument/didOpen"}
    assert Relay.close(conn) == :ok
  end

  test "a refused attach, a file outside the file root, and an unreachable relay are errors", %{url: url} do
    assert {:error, "/lsp attach: no LSP server configured"} =
             Relay.connect("/fs/refuse", "cobol", "/fs/refuse/a.cob", %{url: url, fs_root: "/fs"})

    assert {:error, message} = Relay.connect("/elsewhere", "elixir", "/elsewhere/a.ex", %{url: url, fs_root: "/fs"})
    assert message =~ "outside tezcatl's file root"

    assert {:error, message} = Relay.connect("/fs/p", "elixir", "/fs/p/a.ex", %{url: url, fs_root: nil})
    assert message =~ "file root is unknown"

    assert {:error, message} = Relay.connect("/fs/p", "elixir", "/fs/p/a.ex", %{url: "ws://127.0.0.1:1/lsp", fs_root: "/fs"})
    assert message =~ "ws://127.0.0.1:1/lsp"
  end
end
