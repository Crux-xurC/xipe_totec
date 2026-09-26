ExUnit.start()

Code.require_file(Path.expand("../lib/book.exs", __DIR__))
Code.require_file(Path.expand("../lib/id.exs", __DIR__))
Code.require_file(Path.expand("../lib/scanner/elixir.exs", __DIR__))

defmodule ScannerTest do
  use ExUnit.Case

  alias XipeTotec.Book
  alias XipeTotec.Scanner.Elixir, as: Scanner

  @source """
  defmodule XipeScanFixture do
    def f(x) do
      g(x) + 1
    end

    defp g(x) do
      x * 2
    end
  end
  """

  test "scan/3 registers one node per def/defp with module/name/arity" do
    {book, _node_ids} = Scanner.scan(Book.new(), "s1", @source)
    nodes = Book.all(book, :nodes) |> Enum.sort_by(& &1.name)

    assert [%{name: "f", anykey: 1, module: "XipeScanFixture"}, %{name: "g", anykey: 1}] =
             Enum.map(nodes, &Map.take(&1, [:name, :anykey, :module]))
  end

  test "functions only: def/defp/defdelegate become nodes, guarded heads by their own name, macros and guards don't" do
    source = """
    defmodule XipeScanKinds do
      def pos(x) when x > 0, do: x
      defp neg(x) when x < 0, do: x
      defdelegate size(list), to: Kernel, as: :length
      defmacro dbl(x), do: quote(do: unquote(x) * 2)
      defguard is_small(x) when x < 10
    end
    """

    {book, _node_ids} = Scanner.scan(Book.new(), "s1", source)
    nodes = book |> Book.all(:nodes) |> Enum.map(&{&1.name, &1.anykey, &1.visibility}) |> Enum.sort()

    assert nodes == [{"neg", 1, "private"}, {"pos", 1, "public"}, {"size", 1, "public"}]
  end

  test "scan/3 records a link for an intra-file call to a known node" do
    {book, node_ids} = Scanner.scan(Book.new(), "s1", @source)
    f_id = node_ids[{"XipeScanFixture", "f", 1}]
    g_id = node_ids[{"XipeScanFixture", "g", 1}]

    assert [%{node: ^f_id, ref: ^g_id, role: "to"}] = Book.all(book, :links)
  end

  test "a call to something outside the project produces no link row" do
    source = """
    defmodule XipeScanFixture2 do
      def f(x), do: Enum.map(x, &(&1 + 1))
    end
    """

    {book, _} = Scanner.scan(Book.new(), "s1", source)
    assert Book.all(book, :links) == []
  end

  test "rescanning with the same natural key reuses the existing node id" do
    {book1, ids1} = Scanner.scan(Book.new(), "s1", @source)
    {book2, ids2} = Scanner.scan(book1, "s1", @source)

    assert ids1[{"XipeScanFixture", "f", 1}] == ids2[{"XipeScanFixture", "f", 1}]
    assert map_size(book2.nodes) == map_size(book1.nodes)
  end

  test "top-level code outside any defmodule is never executed (fix F)" do
    source = """
    send(self(), :should_not_run)

    defmodule XipeScanFixture3 do
      def f(x), do: x
    end
    """

    Scanner.scan(Book.new(), "s1", source)
    refute_received :should_not_run
  end

  test "scan_defs/3 then scan_links/3 across two sheets resolves a cross-file call" do
    a = """
    defmodule XipeScanA do
      def f(x), do: XipeScanB.g(x)
    end
    """

    b = """
    defmodule XipeScanB do
      def g(x), do: x + 1
    end
    """

    {book, ids_a} = Scanner.scan_defs(Book.new(), "sa", a)
    {book, ids_b} = Scanner.scan_defs(book, "sb", b)
    ids = Map.merge(ids_a, ids_b)

    book = Scanner.scan_links(book, ids, a)
    book = Scanner.scan_links(book, ids, b)

    f_id = ids[{"XipeScanA", "f", 1}]
    g_id = ids[{"XipeScanB", "g", 1}]

    assert [%{node: ^f_id, ref: ^g_id}] = Book.all(book, :links)
  end

  test "a nested module is named the way Elixir names it, and its calls are linked" do
    source = """
    defmodule XipeScanOuter do
      def add(a, b), do: a + b

      defmodule Inner do
        def twice(x), do: XipeScanOuter.add(x, x)
      end
    end
    """

    {book, ids} = Scanner.scan(Book.new(), "s1", source)

    assert Map.has_key?(ids, {"XipeScanOuter.Inner", "twice", 1})
    assert [%{node: from, ref: to}] = Book.all(book, :links)
    assert from == ids[{"XipeScanOuter.Inner", "twice", 1}]
    assert to == ids[{"XipeScanOuter", "add", 2}]
  end
end
