ExUnit.start()

Code.require_file(Path.expand("../lib/protocol.exs", __DIR__))

defmodule ProtocolTest do
  use ExUnit.Case, async: true

  alias XipeTotec.Protocol

  test "decode: a request has both id and method" do
    text = ~s({"jsonrpc":"2.0","id":1,"method":"card/get","params":{"name":"add_tax"}})
    assert Protocol.decode(text) == {:ok, {:request, 1, "card/get", %{"name" => "add_tax"}}}
  end

  test "decode: params defaults to an empty map when omitted" do
    text = ~s({"jsonrpc":"2.0","id":1,"method":"scan/run"})
    assert Protocol.decode(text) == {:ok, {:request, 1, "scan/run", %{}}}
  end

  test "decode: a notify has method but no id" do
    text = ~s({"jsonrpc":"2.0","method":"notify/rowChanged","params":{"id":"c1"}})
    assert Protocol.decode(text) == {:ok, {:notify, "notify/rowChanged", %{"id" => "c1"}}}
  end

  test "decode: a response carries id + result, no method" do
    text = ~s({"jsonrpc":"2.0","id":7,"result":{"symbols":[]}})
    assert Protocol.decode(text) == {:ok, {:response, 7, {:ok, %{"symbols" => []}}}}
  end

  test "decode: an error response carries id + error, no method" do
    text = ~s({"jsonrpc":"2.0","id":7,"error":{"message":"nope"}})
    assert Protocol.decode(text) == {:ok, {:response, 7, {:error, %{"message" => "nope"}}}}
  end

  test "decode: malformed JSON is invalid_json, not a crash" do
    assert Protocol.decode("{not json") == {:error, :invalid_json}
  end

  test "decode: well-formed JSON with none of the recognized shapes is unrecognized_shape" do
    assert Protocol.decode(~s({"jsonrpc":"2.0"})) == {:error, :unrecognized_shape}
  end

  test "encode_response: ok and error round-trip through decode as a :response" do
    ok_text = Protocol.encode_response(3, {:ok, %{"a" => 1}})
    assert Protocol.decode(ok_text) == {:ok, {:response, 3, {:ok, %{"a" => 1}}}}

    err_text = Protocol.encode_response(3, {:error, %{"message" => "boom"}})
    assert Protocol.decode(err_text) == {:ok, {:response, 3, {:error, %{"message" => "boom"}}}}
  end

  test "encode_notify round-trips through decode as a :notify" do
    text = Protocol.encode_notify("notify/nodeChanged", %{"id" => "n1"})
    assert Protocol.decode(text) == {:ok, {:notify, "notify/nodeChanged", %{"id" => "n1"}}}
  end

  test "encode_request (server -> client provider/*) round-trips through decode as a :request" do
    text = Protocol.encode_request(9, "provider/symbols", %{"path" => "lib/a.ex"})
    assert Protocol.decode(text) == {:ok, {:request, 9, "provider/symbols", %{"path" => "lib/a.ex"}}}
  end

  test "wire_result: an eval result's Elixir-term outcomes become JSON-encodable status maps" do
    call = fn id, outcome -> %{call_id: id, outcome: outcome, compare: "none", evaluated_at: nil, session_gen: 1} end

    result = %{
      "results" => [
        call.("c1", {:ok, %{repr: "exact", type: "integer", display: "5", bin: nil}}),
        call.("c2", {:error, "boom"}),
        call.("c3", {:error, {:compile_error, "undefined variable"}}),
        call.("c4", :timeout),
        call.("c5", {:skipped, "c0"}),
        call.("c7", :aborted)
      ],
      "not_run" => []
    }

    wire = result |> Protocol.wire_result() |> JSON.encode!() |> JSON.decode!()

    assert Enum.map(wire["results"], & &1["outcome"]) == [
             %{"status" => "ok", "repr" => "exact", "type" => "integer", "display" => "5", "bin" => nil},
             %{"status" => "crash", "reason" => "boom"},
             %{"status" => "crash", "reason" => ~s({:compile_error, "undefined variable"})},
             %{"status" => "timeout"},
             %{"status" => "skipped", "upstream" => "c0"},
             %{"status" => "aborted"}
           ]

    assert hd(wire["results"])["call_id"] == "c1"
  end

  test "wire_result: any other result passes through unchanged" do
    assert Protocol.wire_result(%{"id" => "x"}) == %{"id" => "x"}
    assert Protocol.wire_result(nil) == nil
  end
end
