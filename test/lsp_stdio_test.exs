ExUnit.start()

Code.require_file(Path.expand("../lib/lsp/transport/stdio.exs", __DIR__))

defmodule LspStdioTest do
  use ExUnit.Case

  alias XipeTotec.Lsp.Transport.Stdio

  @server Path.expand("fixtures/fake_lsp_server.exs", __DIR__)

  setup do
    log = Path.join(System.tmp_dir!(), "xipe_totec_lsp_stdio_test_#{System.unique_integer([:positive])}.log")
    System.put_env("FAKE_LSP_LOG", log)
    on_exit(fn -> File.rm(log) end)
    {:ok, log: log}
  end

  test "does the relay's part itself: initialized after initialize, answers configuration, shutdown+exit on close",
       %{log: log} do
    assert {:ok, port} = Stdio.connect(System.tmp_dir!(), "fake", "unused", %{command: ["elixir", @server]})

    # the server asked for two configuration items before answering; stderr noise never showed up in the stream
    assert {:ok, %{"capabilities" => %{"documentSymbolProvider" => true}, "configurationAnswer" => [nil, nil]}} =
             Stdio.request(port, "initialize", %{}, 20_000)

    assert Stdio.request(port, "echo", %{"x" => 1}, 5_000) == {:ok, %{"x" => 1}}
    :ok = Stdio.notify(port, "textDocument/didOpen", %{})
    assert Stdio.close(port) == :ok

    assert File.read!(log) |> String.split("\n", trim: true) == ["initialized", "textDocument/didOpen", "exit"]
    refute Port.info(port)
  end

  test "a command that isn't on PATH is an error, not a crash" do
    assert Stdio.connect(".", "fake", "unused", %{command: ["xipe-totec-no-such-lsp"]}) ==
             {:error, "xipe-totec-no-such-lsp not found on PATH"}
  end
end
