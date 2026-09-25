Code.require_file("../transport.exs", __DIR__)

defmodule XipeTotec.Lsp.Transport.Relay do
  @moduledoc """
  `Lsp.Transport` over tezcatl's `/lsp` WebSocket relay (tezcatl's
  `lib/relay/lsp_socket.exs`): the first frame is
  `{"kind":"attach","path":<file relative to tezcatl's file root>,"lang":<id>}`,
  answered by `{"kind":"attached",...}` or `{"kind":"error","reason":...}`;
  every frame after that is a raw JSON-RPC message to or from the shared
  language server. The relay answers `initialize` from its own cache and
  the server's own requests (configuration etc.) itself, so a consumer
  only ever sees responses and notifications.

  `config`: `%{url: "ws://127.0.0.1:4100/lsp", fs_root: tezcatl's file root}`.
  The attach path must be relative to `fs_root` (tezcatl rejects absolute
  ones), so a project outside it can't be attached.
  """

  @behaviour XipeTotec.Lsp.Transport

  @connect_timeout 5_000

  @impl true
  def connect(_root, language, file, %{url: url, fs_root: fs_root}) when is_binary(url) do
    with {:ok, rel} <- relative(file, fs_root),
         {:ok, _} <- Application.ensure_all_started(:gun),
         %URI{host: host, port: port, path: path} when is_binary(host) <- URI.parse(url),
         {:ok, gun} <- :gun.open(String.to_charlist(host), port, %{protocols: [:http], retry: 0}),
         {:ok, conn} <- upgrade(gun, path || "/", url),
         :ok <- send_json(conn, %{"kind" => "attach", "path" => rel, "lang" => language}),
         {:ok, _attached} <- await_attached(conn) do
      {:ok, conn}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "#{url}: #{inspect(reason)}"}
      other -> {:error, "#{url}: #{inspect(other)}"}
    end
  end

  def connect(_root, _language, _file, _config), do: {:error, "no /lsp relay URL"}

  @impl true
  def request(conn, method, params, timeout) do
    id = System.unique_integer([:positive])
    :ok = send_json(conn, %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
    await_response(conn, id, System.monotonic_time(:millisecond) + timeout)
  end

  @impl true
  def notify(conn, method, params),
    do: send_json(conn, %{"jsonrpc" => "2.0", "method" => method, "params" => params})

  @impl true
  def close(%{gun: gun}) do
    :gun.close(gun)
    flush(gun)
  end

  # ---------------------------------------------------------------------

  defp relative(_file, nil), do: {:error, "tezcatl's file root is unknown (--fs-root / TEZCATL_FS_ROOT)"}

  defp relative(file, fs_root) do
    fs_root = Path.expand(fs_root)
    file = Path.expand(file)

    if String.starts_with?(file, fs_root <> "/"),
      do: {:ok, Path.relative_to(file, fs_root)},
      else: {:error, "#{file} is outside tezcatl's file root #{fs_root}"}
  end

  defp upgrade(gun, path, url) do
    case :gun.await_up(gun, @connect_timeout) do
      {:ok, _protocol} ->
        ref = :gun.ws_upgrade(gun, String.to_charlist(path))

        receive do
          {:gun_upgrade, ^gun, ^ref, ["websocket"], _headers} ->
            {:ok, %{gun: gun, ref: ref}}

          {:gun_response, ^gun, ^ref, _fin, status, _headers} ->
            :gun.close(gun)
            {:error, "#{url}: websocket upgrade refused (HTTP #{status})"}

          {:gun_error, ^gun, ^ref, reason} ->
            :gun.close(gun)
            {:error, "#{url}: #{inspect(reason)}"}
        after
          @connect_timeout ->
            :gun.close(gun)
            {:error, "#{url}: websocket upgrade timed out"}
        end

      {:error, reason} ->
        :gun.close(gun)
        {:error, "#{url}: #{inspect(reason)}"}
    end
  end

  defp send_json(%{gun: gun, ref: ref}, map), do: :gun.ws_send(gun, ref, {:text, JSON.encode!(map)})

  # the relay may first start the language server itself, so this waits
  # longer than the connection did
  defp await_attached(conn) do
    result =
      case next_frame(conn, System.monotonic_time(:millisecond) + @connect_timeout * 4) do
        {:ok, %{"kind" => "attached"} = msg} -> {:ok, msg}
        {:ok, %{"kind" => "error", "reason" => reason}} -> {:error, "/lsp attach: #{reason}"}
        {:ok, other} -> {:error, "/lsp attach: unexpected #{inspect(other)}"}
        {:error, reason} -> {:error, "/lsp attach: #{reason}"}
      end

    with {:error, _} <- result, do: close(conn)
    result
  end

  defp await_response(conn, id, deadline) do
    case next_frame(conn, deadline) do
      {:ok, %{"id" => ^id, "error" => %{"message" => message}}} -> {:error, message}
      {:ok, %{"id" => ^id} = msg} when not is_map_key(msg, "method") -> {:ok, msg["result"]}
      {:ok, %{"kind" => "exit"}} -> {:error, "language server exited"}
      {:ok, _notification_or_other} -> await_response(conn, id, deadline)
      {:error, reason} -> {:error, reason}
    end
  end

  defp next_frame(%{gun: gun, ref: ref}, deadline) do
    wait = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:gun_ws, ^gun, ^ref, {:text, text}} ->
        case JSON.decode(text) do
          {:ok, msg} -> {:ok, msg}
          {:error, _} -> {:ok, %{}}
        end

      {:gun_ws, ^gun, ^ref, {:close, _code, reason}} ->
        {:error, "relay closed the connection (#{reason})"}

      {:gun_down, ^gun, _protocol, reason, _killed} ->
        {:error, "relay connection lost (#{inspect(reason)})"}
    after
      wait -> {:error, "timed out waiting for the language server"}
    end
  end

  defp flush(gun) do
    receive do
      {tag, ^gun, _} when tag in [:gun_up] -> flush(gun)
      {tag, ^gun, _, _} when tag in [:gun_ws, :gun_error] -> flush(gun)
      {tag, ^gun, _, _, _} when tag in [:gun_down, :gun_upgrade] -> flush(gun)
    after
      0 -> :ok
    end
  end
end
