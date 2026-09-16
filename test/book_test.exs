ExUnit.start()

Code.require_file(Path.expand("../lib/book.exs", __DIR__))

defmodule BookTest do
  use ExUnit.Case, async: true

  alias XipeTotec.Book

  test "put/get/delete/all round-trip per table" do
    book = Book.new()
    book = Book.put(book, :sheets, "s1", %{path: "lib/a.ex"})
    assert Book.get(book, :sheets, "s1") == %{path: "lib/a.ex"}
    assert Book.all(book, :sheets) == [%{path: "lib/a.ex"}]

    book = Book.delete(book, :sheets, "s1")
    assert Book.get(book, :sheets, "s1") == nil
    assert Book.all(book, :sheets) == []
  end

  test "find_sheet_by_path/2 finds the id for a matching path, nil otherwise" do
    book = Book.new() |> Book.put(:sheets, "s1", %{path: "lib/a.ex"})
    assert Book.find_sheet_by_path(book, "lib/a.ex") == "s1"
    assert Book.find_sheet_by_path(book, "lib/b.ex") == nil
  end

  test "find_node_by_natural_key/4 matches on (module, name, arity)" do
    book =
      Book.new()
      |> Book.put(:nodes, "n1", %{module: "Shop.Price", name: "add_tax", arity: 2})

    assert Book.find_node_by_natural_key(book, "Shop.Price", "add_tax", 2) == "n1"
    assert Book.find_node_by_natural_key(book, "Shop.Price", "add_tax", 1) == nil
  end

  test "link_id/4 is deterministic and distinguishes role/clause" do
    a = Book.link_id("n1", "to", "n2", 1)
    b = Book.link_id("n1", "to", "n2", 1)
    c = Book.link_id("n1", "to", "n2", 2)
    d = Book.link_id("n1", "from", "n2", nil)

    assert a == b
    assert a != c
    assert a != d
  end
end
