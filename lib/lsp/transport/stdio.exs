Code.require_file("../transport.exs", __DIR__)
Code.require_file("../../project_env.exs", __DIR__)

defmodule XipeTotec.Lsp.Transport.Stdio do
  @moduledoc """
  `Lsp.Transport` that starts the language server itself and speaks LSP over
  its stdin/stdout (the base protocol: `Content-Length` headers) -- for
  scanning without tezcatl. Slower than
  `Lsp.Transport.Relay`: every scan starts a fresh server.

  Without a relay in between, this transport does the relay's part of the
  conversation itself:

    * after the `initialize` response, sends the `initialized` notification
    * answers the server's own requests: `workspace/configuration` with one
      `null` per requested item, anything else with `null`
    * `close/1` sends `shutdown` and `exit`, then closes the port

  The server's stderr is discarded (elixir-ls prints its own compile
  warnings there on every start).

  `config`: `%{command: [executable | args]}` -- the dialect's
  `Scanner.Lsp.Dialect.lsp_command/0`, looked up on PATH -- plus an optional
  `env` (the project's environment, `ProjectEnv`) the server runs in, whose
  `PATH` the command is looked up on first.
  """

  @behaviour XipeTotec.Lsp.Transport

  @shutdown_timeout 5_000

  @impl true
  def connect(root, _language, _file, %{command: [exe | args]} = config) do
    env = Map.get(config, :env, %{})

    case XipeTotec.ProjectEnv.find_executable(exe, env) do
      nil ->
        {:error, "#{exe} not found on PATH"}

      path ->
        # sh only to drop stderr: `exec` replaces it, so the port's OS
        # process is the server itself
        port =
          Port.open({:spawn_executable, System.find_executable("sh")}, [
            :binary,
            :exit_status,
            :use_stdio,
            {:cd, root},
            # false unsets one (a project's `null`, ProjectEnv)
            {:env, Enum.map(env, fn {k, v} -> {String.to_charlist(k), if(v == false, do: false, else: String.to_charlist(v))} end)},
            {:args, ["-c", ~s(exec "$0" "$@" 2>/dev/null), path | args]}
          ])

        Process.put({__MODULE__, port}, "")
        {:ok, port}
    end
  end

  def connect(_root, _language, _file, _config), do: {:error, "no language server command"}

  @impl true
  def request(port, method, params, timeout) do
    id = System.unique_integer([:positive])
    write(port, %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
    result = await_response(port, id, System.monotonic_time(:millisecond) + timeout)

    if method == "initialize" and match?({:ok, _}, result),
      do: notify(port, "initialized", %{})

    result
  end

  @impl true
  def notify(port, method, params) do
    write(port, %{"jsonrpc" => "2.0", "method" => method, "params" => params})
    :ok
  end

  @impl true
  def close(port) do
    if Port.info(port) do
      request(port, "shutdown", nil, @shutdown_timeout)
      notify(port, "exit", nil)

      receive do
        {^port, {:exit_status, _}} -> :ok
      after
        @shutdown_timeout -> Port.close(port)
      end
    end

    Process.delete({__MODULE__, port})
    :ok
  catch
    # the port already went away (the server exited on its own)
    :error, :badarg -> :ok
  end

  # ---------------------------------------------------------------------

  defp write(port, message) do
    body = JSON.encode!(message)
    Port.command(port, "Content-Length: #{byte_size(body)}\r\n\r\n" <> body)
  end

  defp await_response(port, id, deadline) do
    case next_message(port, deadline) do
      {:ok, %{"id" => ^id, "error" => %{"message" => message}}} ->
        {:error, message}

      {:ok, %{"id" => ^id} = msg} when not is_map_key(msg, "method") ->
        {:ok, msg["result"]}

      {:ok, %{"id" => server_id, "method" => method} = msg} ->
        write(port, %{"jsonrpc" => "2.0", "id" => server_id, "result" => default_answer(method, msg["params"])})
        await_response(port, id, deadline)

      {:ok, _notification} ->
        await_response(port, id, deadline)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp default_answer("workspace/configuration", %{"items" => items}) when is_list(items),
    do: Enum.map(items, fn _ -> nil end)

  defp default_answer(_method, _params), do: nil

  # one whole message off the buffered stdout, reading more as needed
  defp next_message(port, deadline) do
    buffer = Process.get({__MODULE__, port}, "")

    case parse(buffer) do
      {:ok, message, rest} ->
        Process.put({__MODULE__, port}, rest)
        {:ok, message}

      :more ->
        wait = max(deadline - System.monotonic_time(:millisecond), 0)

        receive do
          {^port, {:data, data}} ->
            Process.put({__MODULE__, port}, buffer <> data)
            next_message(port, deadline)

          {^port, {:exit_status, status}} ->
            {:error, "language server exited (status #{status})"}
        after
          wait -> {:error, "timed out waiting for the language server"}
        end
    end
  end

  defp parse(buffer) do
    case :binary.match(buffer, "\r\n\r\n") do
      :nomatch ->
        :more

      {at, 4} ->
        start = at + 4

        case Regex.run(~r/Content-Length: *(\d+)/i, binary_part(buffer, 0, at)) do
          # a header block without Content-Length: skip it
          nil ->
            {:ok, %{}, binary_part(buffer, start, byte_size(buffer) - start)}

          [_, length] ->
            length = String.to_integer(length)

            if byte_size(buffer) >= start + length do
              body = binary_part(buffer, start, length)
              rest = binary_part(buffer, start + length, byte_size(buffer) - start - length)

              case JSON.decode(body) do
                {:ok, message} -> {:ok, message, rest}
                {:error, _} -> {:ok, %{}, rest}
              end
            else
              :more
            end
        end
    end
  end
end
