Code.require_file("protocol.exs", __DIR__)
Code.require_file("serve_project.exs", __DIR__)
Code.require_file("serve_input.exs", __DIR__)

defmodule XipeTotec.Serve.Socket do
  @moduledoc """
  §16.1's WebSocket (localhost) entry, one `:cowboy_websocket` instance per
  accepted connection (Old.md §9, 2026-09-17). A thin transport shell:
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

  `state.dialogue` (`InOut.dialogue()`, `nil` if none held) is the other
  piece of connection-local state living here (Old.md §17, §17's "1
  connection = 1 dialogue" decision, 2026-09-20) -- every ordinary request
  now goes through `Project.request_dialogue/5` instead of `request/3`, so
  an unrelated method reaches `Dispatch`/`Pipeline`/`"eval"` exactly as
  before regardless of whether a dialogue happens to be held at the time
  (`InOut`'s own pass-through case). The reply envelope's `"from"`/
  `"dialogue"` fields are Old.md §17.2's adapter-mode encoding of
  `InOut`'s 2-bit tag; `outcome.ok?` decides whether `Protocol.encode_response/3`
  gets `{:ok, ...}` or `{:error, ...}`.

  `input` (2026-09-27) is handled here too, by `Serve.Input`: one line
  typed into tezcatl's dialogue window, answered with the text a person
  reads in `dialogue.text`. A line of commands runs in a process of its
  own and is answered when it ends (`state.inputs` holds its request id
  meanwhile), so this connection keeps answering other frames -- another
  window's, since tezcatl's windows share one connection -- while it runs.
  """

  @behaviour :cowboy_websocket

  alias XipeTotec.{Protocol, Serve.Input, Serve.Project}

  @impl true
  def init(req, _opts),
    do:
      {:cowboy_websocket, req, %{initialized: false, capabilities: nil, dialogue: nil, inputs: %{}},
       %{idle_timeout: :infinity}}

  @impl true
  def websocket_init(state) do
    :ok = Project.attach(self())
    {:ok, state}
  end

  @impl true
  def websocket_handle({:text, frame}, state) do
    case Protocol.decode(frame) do
      {:ok, {:request, id, "initialize", params}} ->
        result = %{"capabilities" => %{}, "project" => Project.info()}

        {:reply, {:text, Protocol.encode_response(id, {:ok, result})},
         %{state | initialized: true, capabilities: params}}

      {:ok, {:request, id, _method, _params}} when not state.initialized ->
        {:reply, {:text, Protocol.encode_response(id, {:error, not_initialized()})}, state}

      {:ok, {:request, id, "subscribe", _params}} ->
        {:reply, {:text, Protocol.encode_response(id, {:ok, %{}})}, state}

      {:ok, {:request, id, "input", %{"text" => text}}} when is_binary(text) ->
        case Input.start(text, state.dialogue) do
          {:now, new_dialogue, outcome} -> {:reply, {:text, reply(id, outcome)}, %{state | dialogue: new_dialogue}}
          {:later, ref, new_dialogue} ->
            {:ok, %{state | dialogue: new_dialogue} |> Map.update(:inputs, %{ref => id}, &Map.put(&1, ref, id))}
        end

      {:ok, {:request, id, "input", _params}} ->
        error = %{"code" => "invalid_params", "message" => "input needs text (string)"}
        {:reply, {:text, Protocol.encode_response(id, {:error, error})}, state}

      {:ok, {:request, id, method, params}} ->
        {new_dialogue, outcome} = Project.request_dialogue(state.dialogue, method, params)
        {:reply, {:text, reply(id, outcome)}, %{state | dialogue: new_dialogue}}

      {:ok, {:notify, _method, _params}} ->
        # §16.3's client -> server list is all requests -- a client sending
        # a notify has nothing this v0 does anything with.
        {:ok, state}

      {:ok, {:response, _id, _outcome}} ->
        # a reply to a provider/* request this server sent -- not built yet
        # (Old.md §9: deferred), so nothing is pending to match it to.
        {:ok, state}

      {:error, _reason} ->
        body = Protocol.encode_response(nil, {:error, %{"code" => "parse_error", "message" => "invalid frame"}})
        {:reply, {:text, body}, state}
    end
  end

  def websocket_handle(_frame, state), do: {:ok, state}

  @impl true
  def websocket_info({:xipe_out, text}, state), do: {:reply, {:text, text}, state}

  # a line `Serve.Input` ran off this process; `{:set, d}` when it started
  # or ended a dialogue
  def websocket_info({:xipe_input_done, ref, change, outcome}, state) do
    {id, inputs} = Map.pop(Map.get(state, :inputs, %{}), ref)
    state = if change == :keep, do: state, else: %{state | dialogue: elem(change, 1)}
    {:reply, {:text, reply(id, outcome)}, Map.put(state, :inputs, inputs)}
  end
  def websocket_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _req, _state) do
    Project.detach(self())
    :ok
  end

  # the response with the §17.2 envelope (InOut's outcome shape)
  defp reply(id, outcome) do
    envelope = %{
      "from" => nil,
      "dialogue" => %{"hold" => outcome.hold, "via_repl" => outcome.via_repl, "text" => outcome.text}
    }

    if outcome.ok? do
      Protocol.encode_response(id, {:ok, Protocol.wire_result(outcome.result) || %{}}, envelope)
    else
      Protocol.encode_response(id, {:error, outcome.error}, envelope)
    end
  end

  defp not_initialized, do: %{"code" => "not_initialized", "message" => "send initialize first"}
end
