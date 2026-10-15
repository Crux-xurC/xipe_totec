ExUnit.start()
# see test/run.sh
System.put_env("XIPE_TOTEC_LSP", "off")

Code.require_file(Path.expand("../lib/project.exs", __DIR__))

defmodule ProjectTest do
  use ExUnit.Case

  alias XipeTotec.{Book, Project, Store}

  setup do
    dir = Path.join(System.tmp_dir!(), "xipe_totec_project_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib"))

    File.write!(Path.join(dir, "lib/a.ex"), """
    defmodule ProjA do
      def f(x), do: ProjB.g(x)
    end
    """)

    File.write!(Path.join(dir, "lib/b.ex"), """
    defmodule ProjB do
      def g(x), do: x + 1
    end
    """)

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "find_sheets/1 finds every .ex file, relative, sorted", %{dir: dir} do
    assert Project.find_sheets(dir) == ["lib/a.ex", "lib/b.ex"]
  end

  test "find_sheets/1 also finds .exs files (a scripts-mode project has nothing under .ex at all)", %{
    dir: dir
  } do
    File.write!(Path.join(dir, "lib/c.exs"), "defmodule ProjC do\n  def h(x), do: x\nend\n")
    assert Project.find_sheets(dir) == ["lib/a.ex", "lib/b.ex", "lib/c.exs"]
  end

  test "find_sheets/1 leaves out Mix's own files: mix.exs, deps/, _build/", %{dir: dir} do
    File.write!(Path.join(dir, "mix.exs"), "defmodule ProjMix.MixProject do\n  use Mix.Project\nend\n")
    File.mkdir_p!(Path.join(dir, "deps/dep/lib"))
    File.write!(Path.join(dir, "deps/dep/lib/dep.ex"), "defmodule Dep do\nend\n")
    File.mkdir_p!(Path.join(dir, "_build/dev"))
    File.write!(Path.join(dir, "_build/dev/x.exs"), "")
    File.write!(Path.join(dir, "lib/mix.exs"), "defmodule ProjNotMix do\nend\n")

    assert Project.find_sheets(dir) == ["lib/a.ex", "lib/b.ex", "lib/mix.exs"]
  end

  test "scan_dir/2 reports a module it can't compile for links instead of failing the whole scan", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "test"))

    # exits rather than raises at compile time -- the way mix.exs's
    # `use Mix.Project` does when Mix isn't running
    File.write!(Path.join(dir, "test/support.exs"), """
    defmodule ProjSupport do
      GenServer.call(:xipe_totec_no_such_server, :ping)
      def helper(x), do: ProjA.f(x)
    end
    """)

    File.write!(Path.join(dir, "lib/web.ex"), """
    defmodule ProjWeb do
      use NotLoaded.Controller
      def show(x), do: ProjB.g(x)
    end
    """)

    {book, _paths, failures} = Project.scan_dir(Book.new(), dir)

    assert [%{path: "lib/web.ex", module: "ProjWeb", reason: web_reason}, %{path: "test/support.exs", module: "ProjSupport", reason: support_reason}] =
             failures

    assert web_reason =~ "NotLoaded.Controller"
    assert support_reason =~ "no process"
    # the failed modules' functions are still cards; ProjA -> ProjB's link still resolved
    assert Enum.map(Book.all(book, :nodes), & &1.name) |> Enum.sort() == ["f", "g", "helper", "show"]
    assert [%{role: "to"}] = Book.all(book, :links)
  end

  test "scan_dir/2 resolves a cross-file link via the two-pass sequencing", %{dir: dir} do
    {book, paths, []} = Project.scan_dir(Book.new(), dir)
    assert paths == ["lib/a.ex", "lib/b.ex"]
    assert map_size(book.sheets) == 2
    assert map_size(book.nodes) == 2
    assert [%{role: "to"}] = Book.all(book, :links)
  end

  test "a call removed from the source drops its link on rescan, without touching other files' links", %{dir: dir} do
    File.write!(Path.join(dir, "lib/c.ex"), """
    defmodule ProjC do
      def h(x), do: ProjB.g(x)
    end
    """)

    {book1, _, []} = Project.scan_dir(Book.new(), dir)
    assert length(Book.all(book1, :links)) == 2

    # ProjA.f no longer calls ProjB.g; ProjC.h (scanned after lib/a.ex) still does
    File.write!(Path.join(dir, "lib/a.ex"), "defmodule ProjA do\n  def f(x), do: x\nend\n")
    {book2, _, []} = Project.scan_dir(book1, dir)

    h = Enum.find(Book.all(book2, :nodes), &(&1.name == "h"))
    assert [link] = Book.all(book2, :links)
    assert book2.nodes[link.node] == h
  end

  test "a module that stops compiling keeps the links it had, rather than losing them as stale", %{dir: dir} do
    {book1, _, []} = Project.scan_dir(Book.new(), dir)
    assert [link] = Book.all(book1, :links)

    File.write!(Path.join(dir, "lib/a.ex"), """
    defmodule ProjA do
      use NotLoaded.Thing
      def f(x), do: ProjB.g(x)
    end
    """)

    {book2, _, [%{module: "ProjA"}]} = Project.scan_dir(book1, dir)
    assert Book.all(book2, :links) == [link]
  end

  test "a file gone from the project takes its sheet, nodes and links with it on rescan", %{dir: dir} do
    {book1, _, []} = Project.scan_dir(Book.new(), dir)
    assert map_size(book1.sheets) == 2 and map_size(book1.nodes) == 2 and map_size(book1.links) == 1

    File.rm!(Path.join(dir, "lib/a.ex"))
    {book2, ["lib/b.ex"], []} = Project.scan_dir(book1, dir)

    assert [%{path: "lib/b.ex"}] = Book.all(book2, :sheets)
    assert [%{name: "g"}] = Book.all(book2, :nodes)
    assert book2.links == %{}
  end

  test "a renamed file keeps its functions' ids: they move onto the new sheet instead of being swept", %{dir: dir} do
    {book1, _, []} = Project.scan_dir(Book.new(), dir)
    f_id = Enum.find_value(book1.nodes, fn {id, row} -> row.name == "f" && id end)

    File.rename!(Path.join(dir, "lib/a.ex"), Path.join(dir, "lib/a2.ex"))
    {book2, _, []} = Project.scan_dir(book1, dir)

    assert book2.nodes[f_id].sheet == Book.find_sheet_by_path(book2, "lib/a2.ex")
    assert Book.find_sheet_by_path(book2, "lib/a.ex") == nil
    assert [%{node: ^f_id}] = Book.all(book2, :links)
  end

  test "each file is read by the scanner its surface-table language declares; unregistered languages are skipped",
       %{dir: dir} do
    # a toy language ("toy", *.toy) whose scanner turns every line into a node
    suffix = System.unique_integer([:positive])
    lang_dir = Path.join(System.tmp_dir!(), "xipe_totec_project_test_lang_#{suffix}")
    File.mkdir_p!(lang_dir)
    on_exit(fn -> File.rm_rf!(lang_dir) end)

    File.write!(Path.join(lang_dir, "toy.exs"), """
    defmodule ProjTestToyScanner#{suffix} do
      @behaviour XipeTotec.Scanner
      def scan_defs(book, sheet_id, file) do
        file.source
        |> String.split("\\n", trim: true)
        |> Enum.reduce({book, %{}}, fn name, {book, ids} ->
          id = "toy-" <> name
          row = %{sheet: sheet_id, module: "Toy", name: name, anykey: 0, span: nil, body_hash: nil, status: "live", effect: "unknown", effect_source: nil}
          {XipeTotec.Book.put(book, :nodes, id, row), Map.put(ids, {"Toy", name, 0}, id)}
        end)
      end
      def scan_links_report(book, _node_ids, _file), do: {book, []}
    end

    defmodule ProjTestToyLanguage#{suffix} do
      def extensions, do: ["toy"]
      def scanner, do: ProjTestToyScanner#{suffix}
    end
    """)

    # language_dir replaces the whole directory, so Elixir needs a stand-in
    # declaration there too -- same real scanner, loaded here the way the
    # real declaration loads it (not left to whichever test ran first)
    File.write!(Path.join(lang_dir, "elixir.exs"), """
    Code.require_file(#{inspect(Path.expand("../lib/scanner/elixir.exs", __DIR__))})

    defmodule ProjTestElixirLanguage#{suffix} do
      def extensions, do: ["ex", "exs"]
      def scanner, do: XipeTotec.Scanner.Elixir
    end
    """)

    File.write!(Path.join(dir, "lib/shapes.toy"), "circle\nsquare\n")
    File.write!(Path.join(dir, "lib/Main.hs"), "main = pure ()\n")

    info = %{"languages" => ["elixir", "toy"], "extensions" => %{"ex" => ["elixir"], "exs" => ["elixir"], "toy" => ["toy"]}}
    {book, paths, []} = Project.scan_dir(Book.new(), dir, info: info, language_dir: lang_dir)

    # Main.hs has no registered language, so no scanner ever sees it
    assert paths == ["lib/a.ex", "lib/b.ex", "lib/shapes.toy"]
    names = book.nodes |> Map.values() |> Enum.map(&{&1.module, &1.name}) |> Enum.sort()
    assert names == [{"ProjA", "f"}, {"ProjB", "g"}, {"Toy", "circle"}, {"Toy", "square"}]
  end

  test "with a saved surface table, scan_dir/3 reads only the files it lists", %{dir: dir} do
    table_file = Path.join(dir, "table.json")
    {_book, ["lib/a.ex", "lib/b.ex"], []} = Project.scan_dir(Book.new(), dir, table_file: table_file)
    assert File.exists?(table_file)

    # added after the table was saved: not scanned until the table is regenerated
    File.write!(Path.join(dir, "lib/c.ex"), "defmodule ProjC do\n  def h, do: 1\nend\n")
    {_book, ["lib/a.ex", "lib/b.ex"], []} = Project.scan_dir(Book.new(), dir, table_file: table_file)

    # a listed file gone: the table is regenerated first, picking up c.ex too
    File.rm!(Path.join(dir, "lib/b.ex"))
    {_book, ["lib/a.ex", "lib/c.ex"], _failures} = Project.scan_dir(Book.new(), dir, table_file: table_file)
  end

  test "rescanning an untouched project appends nothing", %{dir: dir} do
    store_path = Path.join(dir, "store.jsonl")
    book1 = Store.load(store_path)
    {book2, _, _} = Project.scan_dir(book1, dir)
    Project.persist_scan(store_path, book1, book2)

    size_after_first = File.stat!(store_path).size

    book3 = Store.load(store_path)
    {book4, _, _} = Project.scan_dir(book3, dir)
    Project.persist_scan(store_path, book3, book4)

    assert File.stat!(store_path).size == size_after_first
  end

  test "removing a file's function tombstones its node and link on rescan", %{dir: dir} do
    store_path = Path.join(dir, "store.jsonl")
    book1 = Store.load(store_path)
    {book2, _, _} = Project.scan_dir(book1, dir)
    Project.persist_scan(store_path, book1, book2)

    File.write!(Path.join(dir, "lib/a.ex"), """
    defmodule ProjA do
    end
    """)

    book3 = Store.load(store_path)
    {book4, _, _} = Project.scan_dir(book3, dir)
    Project.persist_scan(store_path, book3, book4)

    final = Store.load(store_path)
    assert map_size(final.nodes) == 1
    assert Book.all(final, :links) == []
  end

  # scan_failed naming the file, in the CLI as in the server (2026-10-16:
  # the CLI printed the parser's stack trace)
  test "a file with a syntax error, or one that cannot be read: {:error, message} naming it, nothing kept", %{dir: dir} do
    File.write!(Path.join(dir, "lib/broken.ex"), "defmodule Broken do\n  def x( end\nend\n")
    assert {:error, message} = Project.scan_dir_report(Book.new(), dir)
    assert message =~ "lib/broken.ex: "

    File.rm!(Path.join(dir, "lib/broken.ex"))
    locked = Path.join(dir, "lib/locked.ex")
    File.write!(locked, "defmodule Locked do\nend\n")
    File.chmod!(locked, 0o000)
    on_exit(fn -> File.chmod(locked, 0o600) end)
    assert {:error, message} = Project.scan_dir_report(Book.new(), dir)
    assert message =~ "lib/locked.ex: cannot be read (permission denied)"
  end
end
