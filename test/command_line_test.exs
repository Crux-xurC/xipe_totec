ExUnit.start()

Code.require_file(Path.expand("../lib/command_line.exs", __DIR__))

defmodule CommandLineTest do
  use ExUnit.Case, async: true

  alias XipeTotec.CommandLine

  describe "parse_value/1" do
    test "[] is an empty list" do
      assert CommandLine.parse_value("[]") == []
    end

    test "[10] is a one-element list (Old.md §32: a 1-arity row/add was unwritable before)" do
      assert CommandLine.parse_value("[10]") == ["10"]
    end

    test "[1,2] is a two-element list" do
      assert CommandLine.parse_value("[1,2]") == ["1", "2"]
    end

    test "a bare comma-containing value is still a list" do
      assert CommandLine.parse_value("1,2") == ["1", "2"]
    end

    test "a plain value stays a string" do
      assert CommandLine.parse_value("10") == "10"
      assert CommandLine.parse_value("pure") == "pure"
    end

    test "an unclosed bracket is not a list" do
      assert CommandLine.parse_value("[10") == "[10"
    end
  end

  describe "parse/1" do
    test "splits on -- and keeps $n references as plain strings" do
      assert CommandLine.parse(["row/add", "node=n1", "args=[3]", "--", "eval", "call_ids=[$0.id]"]) == [
               %{"method" => "row/add", "params" => %{"node" => "n1", "args" => ["3"]}},
               %{"method" => "eval", "params" => %{"call_ids" => ["$0.id"]}}
             ]
    end

    test "a key with no = gets an empty string" do
      assert CommandLine.parse(["m", "flag"]) == [%{"method" => "m", "params" => %{"flag" => ""}}]
    end

    test "empty argv is an empty command list" do
      assert CommandLine.parse([]) == []
    end
  end
end
