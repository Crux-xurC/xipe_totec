ExUnit.start()

Code.require_file(Path.expand("../lib/book.exs", __DIR__))
Code.require_file(Path.expand("../lib/address.exs", __DIR__))

defmodule AddressTest do
  use ExUnit.Case, async: true

  alias XipeTotec.{Address, Book}

  setup do
    book =
      Book.new()
      |> Book.put(:sheets, "s1", %{path: "lib/shop/price.ex"})
      |> Book.put(:sheets, "s2", %{path: "lib/shop/tax.ex"})
      |> Book.put(:nodes, "n1", %{sheet: "s1", module: "Shop.Price", name: "add_tax", arity: 2})
      |> Book.put(:nodes, "n2", %{sheet: "s1", module: "Shop.Price", name: "add_tax", arity: 1})
      |> Book.put(:nodes, "n3", %{sheet: "s2", module: "Shop.Tax", name: "add_tax", arity: 2})
      |> Book.put(:calls, "c1", %{node: "n1", args: ["100"]})

    {:ok, book: book}
  end

  test "empty address matches nothing", %{book: book} do
    assert Address.resolve(book, %{}) == {:ok, []}
  end

  test "file + name + arity narrows to a unique node (spec §6.1 example shape)", %{book: book} do
    address = %{"file" => "lib/shop/price.ex", "name" => "add_tax", "arity" => 2}
    assert {:ok, [{:nodes, "n1", _row}]} = Address.resolve(book, address)
  end

  test "a looser address returns several candidates", %{book: book} do
    {:ok, matches} = Address.resolve(book, %{"name" => "add_tax"})
    ids = matches |> Enum.map(fn {:nodes, id, _} -> id end) |> Enum.sort()
    assert ids == ["n1", "n2", "n3"]
  end

  test "arity accepts a numeric string (CLI-shaped input) same as an integer", %{book: book} do
    by_int = Address.resolve(book, %{"module" => "Shop.Price", "arity" => 1})
    by_str = Address.resolve(book, %{"module" => "Shop.Price", "arity" => "1"})
    assert by_int == by_str
    assert {:ok, [{:nodes, "n2", _}]} = by_int
  end

  test "a non-numeric arity string matches nothing rather than raising", %{book: book} do
    assert Address.resolve(book, %{"arity" => "two"}) == {:ok, []}
  end

  test "row bypasses node/file filtering and looks the call up directly", %{book: book} do
    assert Address.resolve(book, %{"row" => "c1"}) == {:ok, [{:calls, "c1", Book.get(book, :calls, "c1")}]}
    assert Address.resolve(book, %{"row" => "missing"}) == {:ok, []}
  end

  test "an unsupported column errors instead of silently matching everything", %{book: book} do
    assert Address.resolve(book, %{"hier" => "01.02"}) == {:error, {:unsupported_column, "hier"}}
    assert Address.resolve(book, %{"type" => "node"}) == {:error, {:unsupported_column, "type"}}
  end
end
