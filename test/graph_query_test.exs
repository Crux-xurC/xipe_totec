ExUnit.start()

Code.require_file(Path.expand("../lib/graph_query.exs", __DIR__))

defmodule GraphQueryTest do
  use ExUnit.Case, async: true

  alias XipeTotec.{Book, GraphQuery}

  # n1 -> n2 -> n3 (n1 "to" n2, n2 "to" n3), plus an unrelated n4
  setup do
    book =
      Book.new()
      |> Book.put(:nodes, "n1", %{module: "M", name: "a", arity: 0})
      |> Book.put(:nodes, "n2", %{module: "M", name: "b", arity: 0})
      |> Book.put(:nodes, "n3", %{module: "M", name: "c", arity: 0})
      |> Book.put(:nodes, "n4", %{module: "M", name: "unrelated", arity: 0})
      |> Book.put(:links, "l1", %{node: "n1", role: "to", ref: "n2", clause: nil, guard: nil})
      |> Book.put(:links, "l2", %{node: "n2", role: "to", ref: "n3", clause: nil, guard: nil})
      |> Book.put(:calls, "c1", %{node: "n1", args: ["1"], result: "2"})

    {:ok, book: book}
  end

  describe "neighbors/4" do
    test "depth 0 is just the start node(s), no edges", %{book: book} do
      assert {:ok, %{"start" => ["n1"], "nodes" => nodes, "edges" => []}} =
               GraphQuery.neighbors(book, %{"name" => "a"}, 0)

      assert Map.keys(nodes) == ["n1"]
    end

    test "direction :out walks only outgoing edges", %{book: book} do
      assert {:ok, %{"start" => ["n1"], "edges" => edges}} = GraphQuery.neighbors(book, %{"name" => "a"}, 2, :out)
      assert Enum.sort(edges) == Enum.sort([%{"from" => "n1", "to" => "n2"}, %{"from" => "n2", "to" => "n3"}])
    end

    test "direction :in walks only incoming edges (there is no stored \"from\" role)", %{book: book} do
      assert {:ok, %{"start" => ["n3"], "edges" => edges}} = GraphQuery.neighbors(book, %{"name" => "c"}, 2, :in)
      assert Enum.sort(edges) == Enum.sort([%{"from" => "n2", "to" => "n3"}, %{"from" => "n1", "to" => "n2"}])
    end

    test "depth limits how far the walk goes", %{book: book} do
      assert {:ok, %{"nodes" => nodes}} = GraphQuery.neighbors(book, %{"name" => "a"}, 1, :out)
      assert Map.keys(nodes) |> Enum.sort() == ["n1", "n2"]
    end

    test "an unrelated node has no neighbors", %{book: book} do
      assert {:ok, %{"start" => ["n4"], "nodes" => nodes, "edges" => []}} =
               GraphQuery.neighbors(book, %{"name" => "unrelated"}, 3)

      assert Map.keys(nodes) == ["n4"]
    end

    test "an Address error passes straight through", %{book: book} do
      assert {:error, {:unsupported_column, "hier"}} = GraphQuery.neighbors(book, %{"hier" => "01"}, 1)
    end
  end

  describe "export/4" do
    test "json is the neighbors result, encoded", %{book: book} do
      assert {:ok, text} = GraphQuery.export(book, %{"name" => "a"}, 1, "json")
      assert {:ok, decoded} = JSON.decode(text)
      assert decoded["start"] == ["n1"]
    end

    test "mermaid renders a graph LR block with the node label and an edge arrow", %{book: book} do
      assert {:ok, text} = GraphQuery.export(book, %{"name" => "a"}, 1, "mermaid")
      assert text =~ "graph LR"
      assert text =~ "M.a/0"
      assert text =~ "n1 --> n2"
    end

    test "dot renders a digraph block", %{book: book} do
      assert {:ok, text} = GraphQuery.export(book, %{"name" => "a"}, 1, "dot")
      assert text =~ "digraph xipe {"
      assert text =~ ~s("n1" -> "n2";)
    end

    test "doctest falls back to the stored result when there's a calc row", %{book: book} do
      assert {:ok, text} = GraphQuery.export(book, %{"name" => "a"}, 0, "doctest")
      assert text =~ "# M.a/0"
      assert text =~ "iex> a(1)"
      assert text =~ "2"
    end

    test "doctest notes an unevaluated call rather than crashing on a nil result", %{book: book} do
      assert {:ok, text} = GraphQuery.export(book, %{"name" => "unrelated"}, 0, "doctest")
      assert text =~ "(no calc rows yet)"
    end

    test "an unrecognized format is a clean error", %{book: book} do
      assert {:error, {:bad_format, "yaml"}} = GraphQuery.export(book, %{"name" => "a"}, 1, "yaml")
    end
  end
end
