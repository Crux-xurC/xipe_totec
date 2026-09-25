# A stand-in language server for test/lsp_stdio_test.exs: LSP base protocol
# on stdin/stdout. Before answering `initialize` it asks the client for
# `workspace/configuration` (as real servers do) and reports the answer
# back through the initialize result; it records every notification it
# gets in the file named by FAKE_LSP_LOG; `shutdown` then `exit` ends it.
defmodule FakeLsp do
  def run, do: loop("")

  defp loop(buffer) do
    case read(buffer) do
      {:ok, msg, rest} -> handle(msg) && loop(rest)
      :eof -> System.halt(1)
    end
  end

  defp read(buffer) do
    case :binary.match(buffer, "\r\n\r\n") do
      {at, 4} ->
        [_, n] = Regex.run(~r/Content-Length: *(\d+)/i, binary_part(buffer, 0, at))
        n = String.to_integer(n)

        if byte_size(buffer) >= at + 4 + n,
          do: {:ok, JSON.decode!(binary_part(buffer, at + 4, n)), binary_part(buffer, at + 4 + n, byte_size(buffer) - at - 4 - n)},
          else: more(buffer)

      :nomatch ->
        more(buffer)
    end
  end

  defp more(buffer) do
    case IO.binread(:stdio, 1) do
      :eof -> :eof
      data -> read(buffer <> data)
    end
  end

  defp send_msg(msg) do
    body = JSON.encode!(Map.put(msg, "jsonrpc", "2.0"))
    IO.binwrite(:stdio, "Content-Length: #{byte_size(body)}\r\n\r\n" <> body)
  end

  defp handle(%{"method" => "initialize", "id" => id}) do
    send_msg(%{"id" => "cfg-1", "method" => "workspace/configuration", "params" => %{"items" => [%{"section" => "a"}, %{"section" => "b"}]}})
    {:ok, %{"result" => answer}, _} = read("")
    IO.puts(:stderr, "noise on stderr that must not reach the client")
    send_msg(%{"id" => id, "result" => %{"capabilities" => %{"documentSymbolProvider" => true}, "configurationAnswer" => answer}})
  end

  defp handle(%{"method" => "shutdown", "id" => id}), do: send_msg(%{"id" => id, "result" => nil})
  defp handle(%{"method" => "exit"}), do: log("exit") && System.halt(0)

  defp handle(%{"method" => "echo", "id" => id, "params" => params}) do
    send_msg(%{"method" => "window/logMessage", "params" => %{"message" => "before the reply"}})
    send_msg(%{"id" => id, "result" => params})
  end

  defp handle(%{"method" => method}), do: log(method)

  defp log(line) do
    File.write!(System.fetch_env!("FAKE_LSP_LOG"), line <> "\n", [:append])
    true
  end
end

FakeLsp.run()
