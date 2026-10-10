ExUnit.start()
# see test/run.sh
System.put_env("XIPE_TOTEC_LSP", "off")

Code.require_file(Path.expand("../lib/dispatch.exs", __DIR__))

# Default arguments: `def scale(x, k \\ 2)` is scale/1 and
# scale/2, the node is scale/2. A person declares the counts with arity/set
# (the scanner never does); a refused row/add shows what xipe_totec's own
# reading of the source says, and scan/run's arity_misses the calls that
# missed only by arity. Declared, the counts are what row/add accepts and
# what links match.
defmodule AritySetTest do
  use ExUnit.Case

  alias XipeTotec.{Book, Core, Dispatch}
  alias XipeTotec.Scanner.Elixir, as: ScanEx

  @source """
  defmodule ArityA do
    def scale(x, k \\\\ 2), do: x * k
    def double(x), do: scale(x)
    def triple(x), do: scale(x, 3)

    def pick(list, n \\\\ 0, dflt \\\\ nil)
    def pick([], _n, dflt), do: dflt
    def pick(list, n, _dflt), do: Enum.at(list, n)

    def plain(x), do: x
  end
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "xipe_totec_arity_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "lib/a.ex"), @source)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, book, result} = Dispatch.handle(Book.new(), "scan/run", %{}, %{root: dir})
    {:ok, dir: dir, book: book, result: result}
  end

  defp node_id(book, name), do: Enum.find_value(book.nodes, fn {id, n} -> if n.name == name, do: id end)
  defp linked?(book, from, to), do: Enum.any?(book.links, fn {_, l} -> l.node == from and l.ref == to end)

  test "default_arities: a head with defaults, with or without a body; none; not there" do
    assert ScanEx.default_arities(@source, "ArityA", "scale", 2) == [1, 2]
    assert ScanEx.default_arities(@source, "ArityA", "pick", 3) == [1, 2, 3]
    assert ScanEx.default_arities(@source, "ArityA", "plain", 1) == nil
    assert ScanEx.default_arities(@source, "ArityA", "nope", 1) == nil
    assert ScanEx.default_arities(@source, "Other", "scale", 2) == nil
    assert ScanEx.default_arities("defmodule (", "ArityA", "scale", 2) == nil
  end

  test "before arity/set: one node per function at its full arity; a call by default arguments is no link, said in arity_misses",
       %{book: book, result: result} do
    assert Core.node_label(Book.get(book, :nodes, node_id(book, "scale"))) == "ArityA.scale/2"
    refute linked?(book, node_id(book, "double"), node_id(book, "scale"))
    assert linked?(book, node_id(book, "triple"), node_id(book, "scale"))
    assert result["link_failures"] == []
    assert [%{"path" => "lib/a.ex", "module" => "ArityA", "node" => scale, "message" => msg}] = result["arity_misses"]
    assert scale == node_id(book, "scale")
    assert msg =~ "called as ArityA.scale/1, but the node is ArityA.scale/2"
    assert msg =~ "arity/set id=#{scale}"
  end

  test "row/add refused by arity shows the own analysis (with ctx.root), and nothing is set by it", %{dir: dir, book: book} do
    scale = node_id(book, "scale")
    assert {:error, ^book, %{"message" => msg}} = Dispatch.handle(book, "row/add", %{"node" => scale, "args" => ["3"]}, %{root: dir})
    assert msg =~ "takes 2 arg(s), got 1"
    assert msg =~ "the source shows default arguments, callable as 1..2: declare them first with arity/set id=#{scale} arities=[1,2]"
    # without the root (no source to read): the plain refusal
    assert {:error, _, %{"message" => plain}} = Dispatch.handle(book, "row/add", %{"node" => scale, "args" => ["3"]}, %{})
    refute plain =~ "the source shows default arguments"
    # a function without defaults: no hint
    assert {:error, _, %{"message" => m2}} = Dispatch.handle(book, "row/add", %{"node" => node_id(book, "plain"), "args" => []}, %{root: dir})
    refute m2 =~ "the source shows default arguments"
    assert Book.get(book, :nodes, scale)[:arities] == nil
  end

  test "arity/set: then row/add takes 1 or 2 args, the label shows them, a rescan keeps them and links the call", %{dir: dir, book: book} do
    scale = node_id(book, "scale")
    assert {:ok, book, %{"arities" => [1, 2], "label" => "ArityA.scale/1..2"}} =
             Dispatch.handle(book, "arity/set", %{"id" => scale, "arities" => ["2", "1"]}, %{})

    assert {:ok, book, %{"id" => r1}} = Dispatch.handle(book, "row/add", %{"node" => scale, "args" => ["3"]}, %{root: dir})
    assert {:ok, book, %{"id" => r2}} = Dispatch.handle(book, "row/add", %{"node" => scale, "args" => ["3", "5"]}, %{root: dir})
    # a row's label is the arity it calls
    assert Core.call_label(book, r1) == "ArityA.scale/1"
    assert Core.call_label(book, r2) == "ArityA.scale/2"
    assert {:error, _, %{"message" => m}} = Dispatch.handle(book, "row/add", %{"node" => scale, "args" => []}, %{root: dir})
    assert m =~ "takes 1..2 arg(s), got 0"

    assert {:ok, book, result} = Dispatch.handle(book, "scan/run", %{}, %{root: dir})
    assert node_id(book, "scale") == scale
    assert Book.get(book, :nodes, scale)[:arities] == [1, 2]
    assert linked?(book, node_id(book, "double"), scale)
    assert linked?(book, node_id(book, "triple"), scale)
    refute Map.has_key?(result, "arity_misses")

    # back to the defined arity alone
    assert {:ok, book, %{"arities" => [2], "label" => "ArityA.scale/2"}} =
             Dispatch.handle(book, "arity/set", %{"id" => scale, "arities" => [2]}, %{})
    assert Book.get(book, :nodes, scale)[:arities] == nil
  end

  test "arity/set refuses what does not fit", %{book: book} do
    scale = node_id(book, "scale")
    assert {:error, _, %{"code" => "not_found"}} = Dispatch.handle(book, "arity/set", %{"id" => "nope", "arities" => [1]}, %{})
    assert {:error, _, %{"message" => m1}} = Dispatch.handle(book, "arity/set", %{"id" => scale, "arities" => [1]}, %{})
    assert m1 =~ "must include 2"
    assert {:error, _, %{"message" => m2}} = Dispatch.handle(book, "arity/set", %{"id" => scale, "arities" => [1, 2, 3]}, %{})
    assert m2 =~ "at most 2"
    assert {:error, _, %{"message" => m3}} = Dispatch.handle(book, "arity/set", %{"id" => scale, "arities" => ["x"]}, %{})
    assert m3 =~ "whole numbers"
    assert {:error, _, _} = Dispatch.handle(book, "arity/set", %{"id" => scale}, %{})
    # a node told apart by name only (another language): no argument count to set
    book = Book.put(book, :nodes, "ml", %{module: "M", name: "f", anykey: nil, sheet: nil})
    assert {:error, _, %{"message" => m4}} = Dispatch.handle(book, "arity/set", %{"id" => "ml", "arities" => [1]}, %{})
    assert m4 =~ "no argument count"
  end
end
