defmodule XipeTotec.Protocol do
  @moduledoc """
  spec §16.3 wire shape, encode/decode only -- no dispatch, no Book, no
  process state. Pure, testable the same way `Core` is (Old.md §9,
  2026-09-17).

  §16.2's relay-compatibility rules shape this module directly: request,
  response and notify are each single self-contained JSON objects (no
  multi-frame messages), and a *response*, a *notify* (server -> client push,
  no reply expected) and a *provider request* (server -> client, §16.3's
  `provider/*` -- Xipe Totec asking the client to do something, replied to
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

  `source_hash` (spec §16.3: "すべての応答に、対象ファイルのsource_hashを
  含める") is not injected here -- this module doesn't know which file a
  given response is about, so that field is each handler's job to put in
  its own `result` map.
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
  `envelope` (Old.md §17.2, 2026-09-20) merges extra top-level fields
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

  @doc "Encode a server -> client push with no reply expected (`notify/*`)."
  @spec encode_notify(String.t(), map()) :: binary()
  def encode_notify(method, params) when is_binary(method) and is_map(params),
    do: JSON.encode!(%{"jsonrpc" => "2.0", "method" => method, "params" => params})

  @doc "Encode a server -> client request (`provider/*`) awaiting a `{:response, id, _}` reply."
  @spec encode_request(id, String.t(), map()) :: binary()
  def encode_request(id, method, params) when is_binary(method) and is_map(params),
    do: JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
end
