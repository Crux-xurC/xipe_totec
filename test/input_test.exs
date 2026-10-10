ExUnit.start()

Code.require_file(Path.expand("../lib/input.exs", __DIR__))

defmodule InputTest do
  use ExUnit.Case, async: true

  alias XipeTotec.{Help, Input}

  describe "words/1" do
    test "splits on whitespace, quotes keep spaces and are removed" do
      assert {:ok, ["do", "row/add", "id=$0.id", "a b", "x=1 2"]} = Input.words(~s(  do row/add 'id=$0.id'  "a b" x='1 2' ))
      assert {:ok, []} = Input.words("   ")
      assert {:ok, [""]} = Input.words("''")
      assert {:error, _} = Input.words("row/add 'oops")
    end
  end

  describe "parse/1" do
    test "help and help <command>" do
      assert {:text, text} = Input.parse("help")
      assert text == Help.text(:window)
      assert {:text, "row/add node=<node id> args=[...]\n" <> _} = Input.parse("help row/add")
      assert {:text, "do " <> _} = Input.parse("xipe help do")
      assert {:error, _} = Input.parse("help nope")
    end

    test "a leading xipe is allowed" do
      assert Input.parse("xipe scan") == Input.parse("scan")
    end

    test "show, scan and version" do
      assert :show = Input.parse("show")
      assert {:commands, [%{"method" => "scan/run", "params" => %{}}]} = Input.parse("scan")
      assert {:text, "xipe " <> _} = Input.parse("version")
      assert {:error, _} = Input.parse("scan /some/dir")
    end

    test "eval: ids and --include-writes, as the CLI" do
      assert {:commands, [%{"method" => "eval", "params" => %{"call_ids" => [], "include_writes" => false}}]} = Input.parse("eval")

      assert {:commands, [%{"method" => "eval", "params" => %{"call_ids" => ["a", "b"], "include_writes" => true}}]} =
               Input.parse("eval a --include-writes b")

      assert {:error, message} = Input.parse("eval --mix")
      assert message =~ "--mix"
    end

    test "do, and a method without do, are xipe do's command list" do
      expected =
        {:commands,
         [
           %{"method" => "row/add", "params" => %{"node" => "n1", "args" => ["1", "2"]}},
           %{"method" => "eval", "params" => %{"call_ids" => ["$0.id"]}}
         ]}

      assert Input.parse("do row/add node=n1 args=1,2 -- eval 'call_ids=[$0.id]'") == expected
      assert Input.parse("row/add node=n1 args=1,2 -- eval call_ids=[$0.id]") == expected
      # any word with a slash is a method name: the server says whether it knows it
      assert {:commands, [%{"method" => "dialogue/depends"}]} = Input.parse("dialogue/depends")
      assert {:error, _} = Input.parse("do")
      assert {:error, _} = Input.parse("do --dir /x row/list")
    end

    test "without do, scan and eval may be steps of a -- list" do
      assert {:commands, [%{"method" => "scan/run", "params" => %{}}, %{"method" => "row/list", "params" => %{}}]} =
               Input.parse("scan -- row/list")

      assert {:commands,
              [
                %{"method" => "scan/run"},
                %{"method" => "node/resolve", "params" => %{"name" => "triple"}},
                %{"method" => "eval", "params" => %{"call_ids" => ["$1.id"]}}
              ]} = Input.parse("scan -- node/resolve name=triple -- eval 'call_ids=[$1.id]'")

      # eval's shorthand inside a list: bare ids and --include-writes, also with call_ids=
      assert {:commands, [%{"method" => "row/list"}, %{"method" => "eval", "params" => %{"call_ids" => ["a", "b"], "include_writes" => true}}]} =
               Input.parse("row/list -- eval a --include-writes b")

      assert {:commands, [%{"method" => "eval", "params" => %{"call_ids" => ["a", "b"]}}, %{"method" => "row/check", "params" => %{"on" => "changed"}}]} =
               Input.parse("eval call_ids=[a] b -- row/check on=changed")

      assert {:commands, [%{"method" => "row/list"}, %{"method" => "scan/run"}]} = Input.parse("row/list -- scan")

      # a step that is neither a method nor scan/eval, or scan with arguments
      assert {:error, message} = Input.parse("scan -- show")
      assert message =~ "show"
      assert {:error, _} = Input.parse("row/list -- scan /dir")
      assert {:error, message} = Input.parse("row/list -- eval --mix")
      assert message =~ "--mix"

      # with do the line stays exactly `xipe do`'s: no shorthands
      assert {:commands, [%{"method" => "scan"}, %{"method" => "row/list"}]} = Input.parse("do scan -- row/list")
    end

    test "commands that need a terminal are refused, saying so" do
      for line <- ["choice project /x", "table generate", "start", "serve --port 1", "config", "refresh -a"] do
        assert {:error, message} = Input.parse(line)
        assert message =~ "a terminal command, run as xipe", line
      end
    end

    test "search and dialogue depends start dialogues; quit dialogue with none held is said" do
      assert {:commands, [%{"method" => "dialogue/search", "params" => %{"line" => ""}}]} = Input.parse("search")

      assert {:commands, [%{"method" => "dialogue/search", "params" => %{"line" => "-e args '~⟦a b⟧' id"}}]} =
               Input.parse("xipe search -e args '~⟦a b⟧' id")

      assert {:commands, [%{"method" => "dialogue/depends", "params" => %{"call_id" => "c1"}}]} = Input.parse("dialogue depends c1")
      assert {:error, _} = Input.parse("dialogue depends /dir c1")
      assert {:error, "no dialogue is held"} = Input.parse("quit dialogue")
    end

    test "anything else is an unknown command" do
      assert {:error, message} = Input.parse("frobnicate")
      assert message =~ "frobnicate"
      assert {:error, _} = Input.parse("")
    end
  end
end
