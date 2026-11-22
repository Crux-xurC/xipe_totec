ExUnit.start()
# see test/run.sh
System.put_env("XIPE_TOTEC_LSP", "off")

Code.require_file(Path.expand("../lib/mcp/server.exs", __DIR__))

# D-mcp-tools, D-mcp-eval-wait, D-mcp-effects: the bridge's tools over a
# fake `xipe start` (the methods it is sent are recorded), and the MCP
# messages the server answers. The real server is tried by hand
# (document/mcp.md).
defmodule McpTest do
  use ExUnit.Case

  alias XipeTotec.Mcp.{Server, Tools}

  @cards [
    %{"id" => "N1", "label" => "Calc.add/2", "module" => "Calc", "name" => "add", "anykey" => 2, "path" => "lib/calc.ex", "line" => 2, "effect" => "pure", "effect_source" => "user", "rows" => 1, "visibility" => "public"},
    %{"id" => "N2", "label" => "Calc.add/3", "module" => "Calc", "name" => "add", "anykey" => 3, "path" => "lib/calc.ex", "line" => 3, "effect" => "unknown", "rows" => 0, "visibility" => "public"},
    %{"id" => "N3", "label" => "Shop.Price.Total(int, int)", "module" => "Shop.Price", "name" => "Total", "anykey" => "(int, int)", "path" => "src/Price.cs", "line" => 9, "effect" => "unknown", "rows" => 0}
  ]

  @info %{"extensions" => %{"ex" => ["elixir"], "cs" => ["csharp"]}, "language_repls" => %{"elixir" => "iex", "csharp" => "fsi"}}

  defp io(answers \\ %{}, await \\ fn _, _ -> :pending end) do
    test = self()

    call = fn method, params ->
      send(test, {:sent, method, params})

      case Map.get(answers, method) do
        nil when method == "card/list" -> {:ok, %{"cards" => @cards}}
        nil -> {:ok, %{}}
        fun when is_function(fun, 1) -> fun.(params)
        answer -> answer
      end
    end

    %{call: call, await: await, info: @info}
  end

  defp sent do
    receive do
      {:sent, m, p} -> [{m, p} | sent()]
    after
      0 -> []
    end
  end

  test "about ten tools, each with an object schema; none for a person's or an expectation's methods" do
    names = Enum.map(Tools.list(), & &1["name"])
    assert length(names) == 11
    assert Enum.all?(Tools.list(), &(&1["inputSchema"]["type"] == "object"))

    for name <- names, do: refute(name =~ ~r/effect_set|set_prev|set_result|include_writes|remove|export/)
  end

  test "a function is named by id, by label, or by Module.name when only one has it" do
    assert {:ok, %{"id" => "N3", "language" => "C#", "arguments_written_in" => "F#"}} =
             Tools.call("get_function", %{"function" => "Shop.Price.Total(int, int)"}, io(%{"card/get" => {:ok, %{"matches" => []}}}))

    assert {:ok, %{"id" => "N1", "arguments_written_in" => "Elixir"}} =
             Tools.call("get_function", %{"function" => "N1"}, io(%{"card/get" => {:ok, %{"matches" => []}}}))

    assert {:error, m} = Tools.call("get_function", %{"function" => "Calc.add"}, io())
    assert m =~ "names 2 functions" and m =~ "N1" and m =~ "N2"

    assert {:error, m} = Tools.call("get_function", %{"function" => "Nope.f/1"}, io())
    assert m =~ "search_functions"
  end

  test "search_functions narrows card/list by label or path, with a limit" do
    assert {:ok, %{"total" => 2, "functions" => [%{"id" => "N1"}]}} =
             Tools.call("search_functions", %{"query" => "calc.ADD", "limit" => 1}, io())

    assert {:ok, %{"total" => 1}} = Tools.call("search_functions", %{"query" => "price.cs"}, io())
  end

  test "a project without functions: scan comes first, said by search and by naming a function" do
    empty = io(%{"card/list" => {:ok, %{"cards" => []}}})
    assert {:error, m} = Tools.call("search_functions", %{"query" => "add"}, empty)
    assert m =~ "not scanned" and m =~ "scan"
    assert {:error, m} = Tools.call("get_function", %{"function" => "Calc.add/2"}, empty)
    assert m =~ "not scanned"
  end

  test "check_rows: row/check's failures are the answer; a function's rows only; none is not every row" do
    rows = {:ok, %{"rows" => [%{"id" => "R1", "node" => "N1"}, %{"id" => "R2", "node" => "N2"}]}}
    failed = [%{"id" => "R2", "label" => "Calc.add/3", "reasons" => ["changed"]}]

    answers = %{
      "row/list" => rows,
      "row/check" => fn
        %{"call_ids" => ["R1"]} -> {:ok, %{"checked" => 1, "on" => ["changed"]}}
        %{"call_ids" => ["R1", "R2"]} -> {:error, %{"code" => "check_failed", "message" => "1 of 2 row(s): ...", "data" => %{"failed" => failed}}}
      end
    }

    assert {:ok, %{"checked" => 2, "failed" => ^failed}} = Tools.call("check_rows", %{"on" => ["changed"]}, io(answers))
    assert {"row/check", %{"on" => ["changed"], "call_ids" => ["R1", "R2"]}} in sent()

    assert {:ok, %{"checked" => 1, "failed" => []}} = Tools.call("check_rows", %{"on" => ["changed"], "function" => "Calc.add/2"}, io(answers))
    assert {:ok, %{"checked" => 1, "failed" => []}} = Tools.call("check_rows", %{"on" => ["changed"], "rows" => ["R1"]}, io(answers))

    _ = sent()
    no_rows = io(%{"row/list" => {:ok, %{"rows" => []}}})
    assert {:ok, %{"checked" => 0, "failed" => []}} = Tools.call("check_rows", %{"function" => "Calc.add/2"}, no_rows)
    refute Enum.any?(sent(), &match?({"row/check", _}, &1))

    assert {:error, "unknown call id: R9"} =
             Tools.call("check_rows", %{"rows" => ["R9"]}, io(%{"row/check" => {:error, %{"code" => "not_found", "message" => "unknown call id: R9"}}}))
  end

  test "add_row marks the row as the agent's; propose_class goes to effect/propose" do
    {:ok, %{"row" => "R1"}} = Tools.call("add_row", %{"function" => "Calc.add/2", "args" => ["1", "2"]}, io(%{"row/add" => {:ok, %{"id" => "R1"}}}))
    assert {"row/add", %{"node" => "N1", "args" => ["1", "2"], "origin" => "agent"}} in sent()

    {:ok, _} =
      Tools.call("propose_class", %{"function" => "N2", "effect" => "pure", "reason" => "adds"}, io(%{"effect/propose" => {:ok, %{"effect" => "pure", "reason" => "adds"}}}))

    assert {"effect/propose", %{"id" => "N2", "effect" => "pure", "reason" => "adds"}} in sent()
  end

  test "evaluate never includes writes; done within the wait gives results, else a pass_id" do
    done = %{
      "pass_id" => "P1",
      "ok" => true,
      "result" => %{
        "results" => [%{"call_id" => "R1", "compare" => "none", "outcome" => %{"status" => "ok", "display" => "3", "type" => "integer", "repr" => "exact", "bin" => nil}}],
        "not_run" => [%{"id" => "R2", "reason" => "effect not classified"}]
      }
    }

    answers = %{"eval" => {:ok, %{"pass_id" => "P1", "status" => "started"}}}

    assert {:ok, %{"status" => "done", "results" => [%{"row" => "R1", "value" => "3"}], "not_run" => [%{"row" => "R2"}]}} =
             Tools.call("evaluate", %{"rows" => ["R1", "R2"], "include_writes" => true}, io(answers, fn "P1", 20_000 -> {:done, done} end))

    assert [{"eval", %{"call_ids" => ["R1", "R2"]}}] = sent()

    assert {:ok, %{"pass_id" => "P1", "status" => "started"}} =
             Tools.call("evaluate", %{"rows" => ["R1"], "wait_seconds" => 999}, io(answers, fn "P1", 55_000 -> :pending end))
  end

  test "evaluation_status: running, queued, or not known to the bridge" do
    status = {:ok, %{"running" => [%{"pass_id" => "P1", "phase" => "boot", "seconds" => 4, "call_ids" => ["R1"]}], "queued" => [%{"pass_id" => "P2"}]}}
    io = io(%{"eval/status" => status})

    assert {:ok, %{"status" => "running", "phase" => "boot"}} = Tools.call("evaluation_status", %{"pass_id" => "P1"}, io)
    assert {:ok, %{"status" => "queued"}} = Tools.call("evaluation_status", %{"pass_id" => "P2"}, io)
    assert {:error, m} = Tools.call("evaluation_status", %{"pass_id" => "P9"}, io)
    assert m =~ "list_rows"
  end

  test "a server's error is the tool's error; wrong arguments say so" do
    io = io(%{"row/set-args" => {:error, %{"code" => "not_found", "message" => "unknown call id: R9"}}})
    assert {:error, "unknown call id: R9"} = Tools.call("set_row_args", %{"row" => "R9", "args" => ["1"]}, io)
    assert {:error, m} = Tools.call("add_row", %{"function" => "N1"}, io)
    assert m =~ "missing or wrong arguments"
    assert {:error, "no tool \"effect_set\""} = Tools.call("effect_set", %{}, io)
  end

  test "what an approval covers is said: arguments are approved by no one, callees may have changed (2026-11-23)" do
    %{"result" => r} = Server.handle(%{"id" => 1, "method" => "initialize", "params" => %{"protocolVersion" => "2025-03-26"}}, %{})
    assert r["instructions"] =~ "not approved until get_function"
    assert r["instructions"] =~ "approved by no one"
    assert r["instructions"] =~ "evaluate its rows again once"
    desc = Map.new(Tools.list(), &{&1["name"], &1["description"]})
    assert desc["add_row"] =~ "approved by no one"
    assert desc["set_row_args"] =~ "no one approves them"
    assert desc["evaluate"] =~ "not the arguments"
  end

  test "the server: initialize, tools/list, a tool call, an unknown method, notifications" do
    %{"result" => r} = Server.handle(%{"id" => 1, "method" => "initialize", "params" => %{"protocolVersion" => "2025-03-26"}}, %{})
    assert r["protocolVersion"] == "2025-03-26"
    assert r["capabilities"] == %{"tools" => %{"listChanged" => false}}

    %{"result" => r} = Server.handle(%{"id" => 1, "method" => "initialize", "params" => %{"protocolVersion" => "1999-01-01"}}, %{})
    assert r["protocolVersion"] == "2025-06-18"

    assert %{"result" => %{"tools" => [_ | _]}} = Server.handle(%{"id" => 2, "method" => "tools/list"}, %{})
    assert %{"error" => %{"code" => -32601}} = Server.handle(%{"id" => 3, "method" => "resources/list"}, %{})
    assert nil == Server.handle(%{"method" => "notifications/initialized"}, %{})

    {:async, 4, fun} = Server.handle(%{"id" => 4, "method" => "tools/call", "params" => %{"name" => "search_functions", "arguments" => %{"query" => "add"}}}, io())
    assert %{"isError" => false, "content" => [%{"type" => "text", "text" => text}], "structuredContent" => %{"total" => 2}} = fun.()
    assert {:ok, %{"total" => 2}} = JSON.decode(text)

    assert %{"isError" => true, "content" => [%{"text" => "boom"}]} = Server.tool_result({:error, "boom"})
  end
end
