Code.require_file("protocol.exs", __DIR__)
Code.require_file("serve_project.exs", __DIR__)

defmodule XipeTotec.Serve.Socket do
  @moduledoc """
  §16.1's WebSocket (localhost) entry, one `:cowboy_websocket` instance per
  accepted connection (prebuild.md §9, 2026-09-17). A thin transport shell:
  decode/encode via `Protocol`, forward real work to the single
  `Serve.Project` GenServer. No auth, no Origin check -- spec §16.1: "いず
  れもローカルホストのみで待ち受け、認証は設けず" (every §16.1 entry point
  is localhost-only, no auth by design), unlike tezcatl's `LspSocket`/
  `BrowserSocket`, which *do* check Origin because a browser tab can reach
  them cross-origin. This socket is dialed into directly (by tezcatl's own
  `/xipe` relay, or any other localhost client), never embedded in a page.

  `initialize`'s session state (`initialized?`, the client's declared
  capabilities) lives here, not in `Serve.Project` -- decided 2026-09-17
  because Xipe Totec is meant to work as an independent tool with several
  simultaneous, unrelated entry points (§16.1: stdio / WS / LSP-stdio /
  MCP), each naturally its own session; `Serve.Project` only ever holds the
  one thing every entry point shares, the `Book`.

  `subscribe` is intercepted here too rather than reaching `Dispatch`: v0
  broadcasts every `notify/*` to every attached session unconditionally
  (`Serve.Project`), so subscribing doesn't change anything yet -- it's
  accepted and acknowledged so a client doesn't have to special-case v0,
  but is a no-op until per-topic filtering exists.
  """

  @behaviour :cowboy_websocket

  alias XipeTotec.{Protocol, Serve.Project}

  @impl true
  def init(req, _opts),
    do: {:cowboy_websocket, req, %{initialized: false, capabilities: nil}, %{idle_timeout: :infinity}}

  @impl true
  def websocket_init(state) do
    :ok = Project.attach(self())
    {:ok, state}
  end

  @impl true
  def websocket_handle({:text, frame}, state) do
    case Protocol.decode(frame) do
      {:ok, {:request, id, "initialize", params}} ->
        {:reply, {:text, Protocol.encode_response(id, {:ok, %{"capabilities" => %{}}})},
         %{state | initialized: true, capabilities: params}}

      {:ok, {:request, id, _method, _params}} when not state.initialized ->
        {:reply, {:text, Protocol.encode_response(id, {:error, not_initialized()})}, state}

      {:ok, {:request, id, "subscribe", _params}} ->
        {:reply, {:text, Protocol.encode_response(id, {:ok, %{}})}, state}

      {:ok, {:request, id, method, params}} ->
        result = Project.request(method, params)
        {:reply, {:text, Protocol.encode_response(id, result)}, state}

      {:ok, {:notify, _method, _params}} ->
        # §16.3's client -> server list is all requests -- a client sending
        # a notify has nothing this v0 does anything with.
        {:ok, state}

      {:ok, {:response, _id, _outcome}} ->
        # a reply to a provider/* request this server sent -- not built yet
        # (prebuild.md §9: deferred), so nothing is pending to match it to.
        {:ok, state}

      {:error, _reason} ->
        body = Protocol.encode_response(nil, {:error, %{"code" => "parse_error", "message" => "invalid frame"}})
        {:reply, {:text, body}, state}
    end
  end

  def websocket_handle(_frame, state), do: {:ok, state}

  @impl true
  def websocket_info({:xipe_out, text}, state), do: {:reply, {:text, text}, state}
  def websocket_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _req, _state) do
    Project.detach(self())
    :ok
  end

  defp not_initialized, do: %{"code" => "not_initialized", "message" => "send initialize first"}
end
