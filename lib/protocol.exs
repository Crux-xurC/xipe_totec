defmodule XipeTotec.Protocol do
  @moduledoc """
  The wire shape, encode/decode only -- no dispatch, no Book, no process
  state. Pure.

  Built to pass through a relay untouched: request, response and notify
  are each single self-contained JSON objects (no multi-frame messages),
  and a *response*, a *notify* (server -> client push, no reply expected)
  and a *provider request* (server -> client, `provider/*` -- Xipe Totec
  asking the client to do something, replied to
  later as an ordinary `{:response, ...}`) all travel over the same output
  channel. The receiver tells them apart from JSON shape alone:

    - has both `"id"` and `"method"`         -> a request  (client -> server,
                                                 or server -> client for
                                                 `provider/*`)
    - has `"method"`, no `"id"`               -> a notify   (server -> client
                                                 only, e.g. `notify/rowChanged`)
    - has `"id"` and (`"result"` or `"error"`),
      no `"method"`                           -> a response (either side,
                                                 whichever direction sent the
                                                 request)

  `source_hash` is not injected here -- this module doesn't know which file
  a response is about; a handler puts it in its own `result` map.
  """

  @type id :: String.t() | integer() | nil
  @type message ::
          {:request, id, String.t(), map()}
          | {:notify, String.t(), map()}
          | {:response, id, {:ok, term()} | {:error, map()}}

  @doc "Decode one wire frame. `{:error, :invalid_json | :unrecognized_shape}` on anything malformed."
  @spec decode(binary()) :: {:ok, message} | {:error, :invalid_json | :unrecognized_shape}
  def decode(text) when is_binary(text) do
    case JSON.decode(text) do
      {:ok, %{"method" => method, "id" => id} = msg} ->
        {:ok, {:request, id, method, Map.get(msg, "params", %{})}}

      {:ok, %{"method" => method} = msg} ->
        {:ok, {:notify, method, Map.get(msg, "params", %{})}}

      {:ok, %{"id" => id, "result" => result}} ->
        {:ok, {:response, id, {:ok, result}}}

      {:ok, %{"id" => id, "error" => error}} ->
        {:ok, {:response, id, {:error, error}}}

      {:ok, _other} ->
        {:error, :unrecognized_shape}

      {:error, _reason} ->
        {:error, :invalid_json}
    end
  end

  @doc """
  Encode a response to a client (or client-answered-provider) request `id`.
  `envelope` merges extra top-level fields
  in alongside `id`/`result`/`error` -- today only `Serve.Socket` passes
  one (`"from"`/`"dialogue"`, the `InOut` adapter-mode tag), so it defaults
  to `%{}` and every pre-existing 2-arity call site is unchanged.
  """
  @spec encode_response(id, {:ok, map()} | {:error, map()}, map()) :: binary()
  def encode_response(id, outcome, envelope \\ %{})

  def encode_response(id, {:ok, result}, envelope) when is_map(result) and is_map(envelope),
    do: JSON.encode!(Map.merge(envelope, %{"jsonrpc" => "2.0", "id" => id, "result" => result}))

  def encode_response(id, {:error, error}, envelope) when is_map(error) and is_map(envelope),
    do: JSON.encode!(Map.merge(envelope, %{"jsonrpc" => "2.0", "id" => id, "error" => error}))

  @doc """
  A method result made JSON-encodable for the wire. Every `Dispatch` result
  already is and passes through unchanged; the one that isn't is the
  `"eval"` pseudo-method's (`Runner`), whose `"results"` are
  `Evaluator.Result` maps carrying an Elixir-term `outcome`
  (`{:ok, %{...}}`, `:timeout`, `{:skipped, id}`, ...). The CLI prints those
  terms directly, so they are converted here, at the wire, rather than in
  `Runner`: each outcome becomes a map with a `"status"` named like the
  CLI's own labels (`ok`/`crash`/`timeout`/`max_heap`/`skipped`/
  `aborted`) plus that outcome's own fields.
  """
  @spec wire_result(map() | nil) :: map() | nil
  def wire_result(%{"results" => results} = result) when is_list(results),
    do: %{result | "results" => Enum.map(results, &wire_eval_call/1)}

  def wire_result(result), do: result

  defp wire_eval_call(%{call_id: _} = r) do
    %{
      "call_id" => r.call_id,
      "outcome" => wire_outcome(r.outcome),
      "compare" => r.compare,
      "evaluated_at" => r.evaluated_at,
      "session_gen" => r.session_gen
    }
  end

  defp wire_outcome({:ok, value}),
    do: %{"status" => "ok", "repr" => value.repr, "type" => value.type, "display" => value.display, "bin" => value.bin}

  defp wire_outcome({:error, reason}),
    do: %{"status" => "crash", "reason" => if(is_binary(reason), do: reason, else: inspect(reason))}

  defp wire_outcome({:skipped, upstream}), do: %{"status" => "skipped", "upstream" => upstream}
  defp wire_outcome(status) when status in [:timeout, :max_heap, :aborted], do: %{"status" => Atom.to_string(status)}

  @doc "Encode a server -> client push with no reply expected (`notify/*`)."
  @spec encode_notify(String.t(), map()) :: binary()
  def encode_notify(method, params) when is_binary(method) and is_map(params),
    do: JSON.encode!(%{"jsonrpc" => "2.0", "method" => method, "params" => params})

  @doc "Encode a server -> client request (`provider/*`) awaiting a `{:response, id, _}` reply."
  @spec encode_request(id, String.t(), map()) :: binary()
  def encode_request(id, method, params) when is_binary(method) and is_map(params),
    do: JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
end
