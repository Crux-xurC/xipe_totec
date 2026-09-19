ExUnit.start()

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

  test "find_sheets/1 also finds .exs files (a scripts-mode project, e.g. crux's own, has nothing under .ex at all)", %{
    dir: dir
  } do
    File.write!(Path.join(dir, "lib/c.exs"), "defmodule ProjC do\n  def h(x), do: x\nend\n")
    assert Project.find_sheets(dir) == ["lib/a.ex", "lib/b.ex", "lib/c.exs"]
  end

  test "scan_dir/2 resolves a cross-file link via the two-pass sequencing", %{dir: dir} do
    {book, paths} = Project.scan_dir(Book.new(), dir)
    assert paths == ["lib/a.ex", "lib/b.ex"]
    assert map_size(book.sheets) == 2
    assert map_size(book.nodes) == 2
    assert [%{role: "to"}] = Book.all(book, :links)
  end

  test "rescanning an untouched project appends nothing", %{dir: dir} do
    store_path = Path.join(dir, "store.jsonl")
    book1 = Store.load(store_path)
    {book2, _} = Project.scan_dir(book1, dir)
    Project.persist_scan(store_path, book1, book2)

    size_after_first = File.stat!(store_path).size

    book3 = Store.load(store_path)
    {book4, _} = Project.scan_dir(book3, dir)
    Project.persist_scan(store_path, book3, book4)

    assert File.stat!(store_path).size == size_after_first
  end

  test "removing a file's function tombstones its node and link on rescan", %{dir: dir} do
    store_path = Path.join(dir, "store.jsonl")
    book1 = Store.load(store_path)
    {book2, _} = Project.scan_dir(book1, dir)
    Project.persist_scan(store_path, book1, book2)

    File.write!(Path.join(dir, "lib/a.ex"), """
    defmodule ProjA do
    end
    """)

    book3 = Store.load(store_path)
    {book4, _} = Project.scan_dir(book3, dir)
    Project.persist_scan(store_path, book3, book4)

    final = Store.load(store_path)
    assert map_size(final.nodes) == 1
    assert Book.all(final, :links) == []
  end
end
