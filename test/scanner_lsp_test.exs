ExUnit.start()

Code.require_file(Path.expand("../lib/project.exs", __DIR__))
Code.require_file(Path.expand("../lib/scanner/lsp/elixir.exs", __DIR__))

defmodule ScannerLspTest.FakeTransport do
  # Answers like elixir-ls 0.30.0 did for the same sources (shapes copied
  # from a live session, 2026-09-25): hierarchical documentSymbol with
  # short nested module names and `name/arity` functions, fully named
  # callee items whose ranges are junk. `config` picks the variant.
  @behaviour XipeTotec.Lsp.Transport

  def connect(_root, _language, _file, %{refuse: reason}), do: {:error, reason}
  def connect(_root, _language, _file, config), do: {:ok, config}

  def request(config, "initialize", _params, _timeout),
    do: {:ok, %{"capabilities" => %{"documentSymbolProvider" => true, "callHierarchyProvider" => config[:call_hierarchy] != false}}}

  def request(_config, "textDocument/documentSymbol", %{"textDocument" => %{"uri" => uri}}, _timeout) do
    {:ok,
     case Path.basename(uri) do
       "calc.ex" ->
         [
           module("Calc", [
             fun("add/2", "def", 1),
             fun("add/3", "def", 2),
             fun("square/1", "def", 3),
             fun("mul/2", "defp", 4),
             fun("total/1", "def", 5),
             module("Inner", [fun("twice/1", "def", 8)])
           ])
         ]

       "helper.ex" ->
         [module("Helper", [fun("sq_plus/1", "def", 1)])]
     end}
  end

  def request(_config, "textDocument/prepareCallHierarchy", %{"textDocument" => %{"uri" => uri}, "position" => %{"line" => line}}, _timeout),
    do: {:ok, [%{"name" => "item@#{Path.basename(uri)}:#{line}"}]}

  def request(_config, "callHierarchy/outgoingCalls", %{"item" => %{"name" => item}}, _timeout) do
    callees =
      case item do
        "item@calc.ex:3" -> ["Calc.mul/2"]
        "item@calc.ex:5" -> ["Calc.add/2", "Enum.reduce/3"]
        "item@calc.ex:8" -> ["Calc.add/2"]
        "item@helper.ex:1" -> ["Calc.square/1"]
        _ -> []
      end

    {:ok, for(name <- callees, do: %{"fromRanges" => [], "to" => %{"name" => name, "kind" => 12, "range" => junk_range()}})}
  end

  def notify(_config, method, params) do
    Process.put(:notified, [{method, params["textDocument"]["uri"]} | Process.get(:notified, [])])
    :ok
  end

  def close(_config) do
    Process.put(:closed, true)
    :ok
  end

  defp module(name, children), do: %{"name" => name, "kind" => 2, "detail" => "defmodule", "range" => range(0, 10), "selectionRange" => range(0, 0), "children" => children}
  defp fun(name, detail, line), do: %{"name" => name, "kind" => 12, "detail" => detail, "range" => range(line, line), "selectionRange" => range(line, line), "children" => []}
  defp range(from, to), do: %{"start" => %{"line" => from, "character" => 2}, "end" => %{"line" => to, "character" => 20}}
  defp junk_range, do: %{"start" => %{"line" => 0, "character" => 133}, "end" => %{"line" => 0, "character" => 133}}
end

defmodule ScannerLspTest do
  use ExUnit.Case

  alias XipeTotec.{Book, Project}
  alias XipeTotec.Scanner.Lsp.Elixir, as: Dialect
  alias ScannerLspTest.FakeTransport

  setup do
    dir = Path.join(System.tmp_dir!(), "xipe_totec_scanner_lsp_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib"))
    on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(Path.join(dir, "lib/calc.ex"), """
    defmodule Calc do
      def add(a, b), do: a + b
      def add(a, b, c), do: a + b + c
      def square(x), do: mul(x, x)
      defp mul(a, b), do: a * b
      def total(list), do: Enum.reduce(list, 0, &add/2)

      defmodule Inner do
        def twice(x), do: Calc.add(x, x)
      end
    end
    """)

    File.write!(Path.join(dir, "lib/helper.ex"), """
    defmodule Helper do
      def sq_plus(x), do: Calc.square(x) + 1
    end
    """)

    {:ok, dir: dir}
  end

  defp scan(book, dir, config), do: Project.scan_dir_report(book, dir, scanner_opts: [transport: FakeTransport, transport_config: config])

  defp label(book, id), do: XipeTotec.Core.node_label(book.nodes[id])

  test "cards come from documentSymbol and links from outgoingCalls, matched by name", %{dir: dir} do
    report = scan(Book.new(), dir, %{})

    assert report.scanners["elixir"] == %{"scanner" => "XipeTotec.Scanner.Lsp.Elixir", "skipped" => [], "via" => "ScannerLspTest.FakeTransport"}
    assert report.link_failures == []

    labels = report.book.nodes |> Map.values() |> Enum.map(&XipeTotec.Core.node_label/1) |> Enum.sort()

    # nested module named in full; defp included; anykey = arity
    assert labels ==
             ~w(Calc.Inner.twice/1 Calc.add/2 Calc.add/3 Calc.mul/2 Calc.square/1 Calc.total/1 Helper.sq_plus/1)

    edges = for l <- Book.all(report.book, :links), do: {label(report.book, l.node), label(report.book, l.ref)}

    # Enum.reduce/3 has no node, so no link; Helper -> Calc crosses files
    assert Enum.sort(edges) == [
             {"Calc.Inner.twice/1", "Calc.add/2"},
             {"Calc.square/1", "Calc.mul/2"},
             {"Calc.total/1", "Calc.add/2"},
             {"Helper.sq_plus/1", "Calc.square/1"}
           ]

    # every opened file closed again, and the connection with them
    opened = for {"textDocument/didOpen", uri} <- Process.get(:notified), do: uri
    closed = for {"textDocument/didClose", uri} <- Process.get(:notified), do: uri
    assert Enum.sort(opened) == Enum.sort(closed) and length(opened) == 2
    assert Process.get(:closed)
  end

  test "the same functions keep their ids whether elixir-ls or Elixir's own parser read them", %{dir: dir} do
    via_lsp = scan(Book.new(), dir, %{}).book
    via_parser = scan(via_lsp, dir, %{refuse: "no relay"}).book

    assert Map.keys(via_parser.nodes) |> Enum.sort() == Map.keys(via_lsp.nodes) |> Enum.sort()
  end

  test "a server without callHierarchy still gives cards, reports every module, and keeps the links it had",
       %{dir: dir} do
    before = scan(Book.new(), dir, %{}).book
    report = scan(before, dir, %{call_hierarchy: false})

    assert map_size(report.book.nodes) == 7
    assert report.book.links == before.links
    assert report.link_failures |> Enum.map(& &1.module) |> Enum.sort() == ["Calc", "Calc.Inner", "Helper"]
    assert hd(report.link_failures).reason =~ "callHierarchy"
  end

  test "a relay that can't be reached hands the files to Elixir's own parser, and says why", %{dir: dir} do
    report = scan(Book.new(), dir, %{refuse: "ws://127.0.0.1:4100/lsp: econnrefused"})

    assert report.scanners["elixir"] == %{
             "scanner" => "XipeTotec.Scanner.Elixir",
             "skipped" => [%{"scanner" => "XipeTotec.Scanner.Lsp.Elixir", "reason" => "ScannerLspTest.FakeTransport: ws://127.0.0.1:4100/lsp: econnrefused"}]
           }

    assert map_size(report.book.nodes) == 7
  end

  test "the Elixir dialect reads elixir-ls names" do
    assert Dialect.definition(%{"kind" => 12, "detail" => "def", "name" => "add/2"}, ["Calc", "Inner"]) ==
             %{module: "Calc.Inner", name: "add", anykey: 2}

    assert Dialect.definition(%{"kind" => 12, "detail" => "@spec", "name" => "add/2"}, ["Calc"]) == nil
    assert Dialect.definition(%{"kind" => 2, "detail" => "defmodule", "name" => "Calc"}, []) == nil
    assert Dialect.callee_key(%{"name" => "Calc.Inner.twice/1"}) == {"Calc.Inner", "twice", 1}
    assert Dialect.callee_key(%{"name" => "valid?/1"}) == nil
  end
end
