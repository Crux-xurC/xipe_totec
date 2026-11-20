Code.require_file("../session.exs", __DIR__)

defmodule XipeTotec.Mcp.Upstream do
  @moduledoc """
  The MCP bridge's connection to a running `xipe start` (D-mcp-bridge): a
  WebSocket client, as tezcatl's relay is. It sends `Dispatch` methods as
  requests and keeps what the server pushes that the bridge needs:
  `notify/passCompleted`, by `pass_id`, so an evaluation's results can be
  given to a later status call (D-mcp-eval-wait).

  The server is found when a call needs it, not at start: by the port given
  (`--port`) or the live session's record (`tables/session.json`,
  `XipeTotec.Session`). A lost connection fails the calls waiting on it and
  is opened again by the next call, so `xipe start` may be started (or
  restarted) after the bridge.

  No `Origin` header is sent: the server refuses only browsers' handshakes
  (`XIPE_TOTEC_ALLOWED_ORIGINS`), and the bridge is a local program.
  """

  use GenServer

  @connect_timeout 5_000
  # passes kept after completion, oldest dropped first
  @kept_passes 200

  # ---- API -----------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Send one method and wait for its answer: `{:ok, result}` or `{:error, %{\"code\", \"message\"}}`."
  @spec call(String.t(), map(), timeout(), GenServer.server()) :: {:ok, term()} | {:error, map()}
  def call(method, params, timeout \\ 60_000, server \\ __MODULE__) do
    GenServer.call(server, {:call, method, params, timeout}, timeout + 1_000)
  catch
    :exit, {:timeout, _} -> {:error, %{"code" => "timeout", "message" => "#{method}: no answer from xipe start within #{div(timeout, 1000)} s"}}
  end

  @doc "What `initialize` said of the project served (connecting first if needed), or an error."
  @spec project(GenServer.server()) :: {:ok, map()} | {:error, map()}
  def project(server \\ __MODULE__), do: GenServer.call(server, :project, 15_000)

  @doc """
  The completion of `pass_id` (`notify/passCompleted`'s params), waiting up
  to `ms` for it; `:pending` when it has not come.
  """
  @spec await_pass(String.t(), non_neg_integer(), GenServer.server()) :: {:done, map()} | :pending
  def await_pass(pass_id, ms, server \\ __MODULE__) do
    GenServer.call(server, {:await_pass, pass_id, ms}, ms + 5_000)
  catch
    :exit, {:timeout, _} -> :pending
  end

  # ---- server --------------------------------------------------------------

  @impl true
  def init(opts) do
    case Application.ensure_all_started(:gun) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "gun failed to start: #{inspect(reason)}"
    end

    {:ok,
     %{
       port: Keyword.get(opts, :port),
       session_path: Keyword.get(opts, :session_path, XipeTotec.Session.default_path()),
       gun: nil,
       ws: nil,
       # what `initialize` said of the project served (id, root ...)
       project: nil,
       next_id: 1,
       # request id => {from, timer}
       pending: %{},
       # pass_id => params of notify/passCompleted, and the order they came in
       passes: %{},
       pass_order: :queue.new(),
       # pass_id => [{from, timer}]
       pass_waiters: %{}
     }}
  end

  @impl true
  def handle_call({:call, method, params, timeout}, from, state) do
    case ensure_connected(state) do
      {:ok, state} ->
        id = state.next_id
        frame = JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
        :gun.ws_send(state.gun, state.ws, {:text, frame})
        timer = Process.send_after(self(), {:call_timeout, id}, timeout)
        {:noreply, %{state | next_id: id + 1, pending: Map.put(state.pending, id, {from, timer, method})}}

      {:error, message, state} ->
        {:reply, {:error, %{"code" => "no_server", "message" => message}}, state}
    end
  end

  def handle_call(:project, _from, state) do
    case ensure_connected(state) do
      {:ok, state} -> {:reply, {:ok, state.project}, state}
      {:error, message, state} -> {:reply, {:error, %{"code" => "no_server", "message" => message}}, state}
    end
  end

  def handle_call({:await_pass, pass_id, ms}, from, state) do
    case Map.fetch(state.passes, pass_id) do
      {:ok, done} ->
        {:reply, {:done, done}, state}

      :error when ms == 0 ->
        {:reply, :pending, state}

      :error ->
        timer = Process.send_after(self(), {:pass_wait_over, pass_id, from}, ms)
        {:noreply, %{state | pass_waiters: Map.update(state.pass_waiters, pass_id, [{from, timer}], &[{from, timer} | &1])}}
    end
  end

  @impl true
  def handle_info({:gun_ws, gun, _ref, {:text, text}}, %{gun: gun} = state) do
    case JSON.decode(text) do
      {:ok, %{"id" => id} = msg} when not is_map_key(msg, "method") -> {:noreply, answer(state, id, msg)}
      {:ok, %{"method" => "notify/passCompleted", "params" => %{"pass_id" => pass_id} = params}} -> {:noreply, pass_done(state, pass_id, params)}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:call_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {{from, _timer, method}, pending} ->
        GenServer.reply(from, {:error, %{"code" => "timeout", "message" => "#{method}: no answer from xipe start in time"}})
        {:noreply, %{state | pending: pending}}

      {nil, _} ->
        {:noreply, state}
    end
  end

  def handle_info({:pass_wait_over, pass_id, from}, state) do
    waiters = Map.get(state.pass_waiters, pass_id, [])

    if Enum.any?(waiters, fn {f, _} -> f == from end) do
      GenServer.reply(from, :pending)
      rest = Enum.reject(waiters, fn {f, _} -> f == from end)
      {:noreply, %{state | pass_waiters: Map.put(state.pass_waiters, pass_id, rest)}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:gun_down, gun, _, _, _}, %{gun: gun} = state), do: {:noreply, drop(state, "the connection to xipe start was lost")}
  def handle_info({:DOWN, _, :process, gun, _}, %{gun: gun} = state), do: {:noreply, drop(state, "the connection to xipe start was lost")}
  def handle_info({:gun_ws, gun, _ref, {:close, _, _}}, %{gun: gun} = state), do: {:noreply, drop(state, "xipe start closed the connection")}
  def handle_info(_other, state), do: {:noreply, state}

  # ---- helpers -------------------------------------------------------------

  defp answer(state, id, msg) do
    case Map.pop(state.pending, id) do
      {{from, timer, _method}, pending} ->
        Process.cancel_timer(timer)

        reply =
          case msg do
            %{"error" => error} -> {:error, error}
            %{"result" => result} -> {:ok, result}
          end

        GenServer.reply(from, reply)
        %{state | pending: pending}

      {nil, _} ->
        state
    end
  end

  defp pass_done(state, pass_id, params) do
    {waiters, pass_waiters} = Map.pop(state.pass_waiters, pass_id, [])

    for {from, timer} <- waiters do
      Process.cancel_timer(timer)
      GenServer.reply(from, {:done, params})
    end

    order = :queue.in(pass_id, state.pass_order)

    {passes, order} =
      if :queue.len(order) > @kept_passes do
        {{:value, old}, order} = :queue.out(order)
        {Map.delete(state.passes, old), order}
      else
        {state.passes, order}
      end

    %{state | passes: Map.put(passes, pass_id, params), pass_order: order, pass_waiters: pass_waiters}
  end

  defp drop(state, message) do
    if state.gun, do: safe_close(state.gun)

    for {_id, {from, timer, method}} <- state.pending do
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, %{"code" => "no_server", "message" => "#{method}: #{message}"}})
    end

    %{state | gun: nil, ws: nil, pending: %{}}
  end

  defp ensure_connected(%{gun: gun, ws: ws} = state) when gun != nil and ws != nil, do: {:ok, state}

  defp ensure_connected(state) do
    with {:ok, port} <- target_port(state),
         {:ok, gun} <- open(port),
         {:ok, ws} <- upgrade(gun),
         {:ok, project} <- initialize(gun, ws) do
      Process.monitor(gun)
      {:ok, %{state | gun: gun, ws: ws, project: project}}
    else
      {:error, message} -> {:error, message, state}
    end
  end

  defp target_port(%{port: port}) when is_integer(port), do: {:ok, port}

  defp target_port(state) do
    case XipeTotec.Session.read(state.session_path) do
      {:ok, %{"port" => port}} when is_integer(port) -> {:ok, port}
      _ -> {:error, "no xipe start is running (start it on the project first: `xipe start`, or tezcatl's xipe window)"}
    end
  end

  defp open(port) do
    with {:ok, gun} <- :gun.open(~c"127.0.0.1", port, %{protocols: [:http], retry: 0}),
         {:ok, _} <- :gun.await_up(gun, @connect_timeout) do
      {:ok, gun}
    else
      {:error, reason} -> {:error, "xipe start on port #{port} could not be reached (#{inspect(reason)})"}
    end
  end

  defp upgrade(gun) do
    ref = :gun.ws_upgrade(gun, "/")

    receive do
      {:gun_upgrade, ^gun, ^ref, ["websocket"], _headers} ->
        {:ok, ref}

      {:gun_response, ^gun, ^ref, _, status, _headers} ->
        safe_close(gun)
        {:error, "xipe start refused the WebSocket (HTTP #{status})"}

      {:gun_error, ^gun, ^ref, reason} ->
        safe_close(gun)
        {:error, "the WebSocket to xipe start failed (#{inspect(reason)})"}
    after
      @connect_timeout ->
        safe_close(gun)
        {:error, "xipe start did not answer the WebSocket handshake"}
    end
  end

  # the server answers nothing else on a connection before `initialize`
  # (Serve.Socket); id 0 is never used by a call
  defp initialize(gun, ws) do
    frame = JSON.encode!(%{"jsonrpc" => "2.0", "id" => 0, "method" => "initialize", "params" => %{"client" => "xipe mcp"}})
    :gun.ws_send(gun, ws, {:text, frame})
    await_initialize(gun)
  end

  defp await_initialize(gun) do
    receive do
      {:gun_ws, ^gun, _ref, {:text, text}} ->
        case JSON.decode(text) do
          {:ok, %{"id" => 0, "result" => result}} -> {:ok, result["project"]}
          {:ok, %{"id" => 0, "error" => error}} -> safe_close(gun) && {:error, "xipe start refused initialize: #{error["message"]}"}
          _ -> await_initialize(gun)
        end
    after
      @connect_timeout ->
        safe_close(gun)
        {:error, "xipe start did not answer initialize"}
    end
  end

  defp safe_close(gun) do
    :gun.close(gun)
  catch
    _, _ -> :ok
  end
end
