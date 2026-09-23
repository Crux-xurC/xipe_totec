ExUnit.start()

Code.require_file(Path.expand("../lib/dispatch.exs", __DIR__))

defmodule DispatchTest do
  use ExUnit.Case

  alias XipeTotec.{Book, Core, Dispatch}

  describe "scan/run" do
    setup do
      dir = Path.join(System.tmp_dir!(), "xipe_totec_dispatch_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "lib"))

      File.write!(Path.join(dir, "lib/a.ex"), """
      defmodule DispA do
        def f(x), do: x + 1
      end
      """)

      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "scans ctx.root and reports counts", %{dir: dir} do
      assert {:ok, book, result} = Dispatch.handle(Book.new(), "scan/run", %{}, %{root: dir})
      assert result == %{"paths" => ["lib/a.ex"], "sheets" => 1, "nodes" => 1, "links" => 0}
      assert map_size(book.nodes) == 1
    end
  end

  describe "row/add" do
    test "mints an id and returns the stored row" do
      book = Book.new() |> Core.put_node("n1", %{module: "M", name: "f", arity: 1})
      assert {:ok, new_book, %{"id" => id, "row" => row}} =
               Dispatch.handle(book, "row/add", %{"node" => "n1", "args" => ["1"]}, %{})

      assert is_binary(id) and byte_size(id) == 26
      assert row.node == "n1"
      assert row.args == ["1"]
      assert Book.get(new_book, :calls, id) == row
    end

    test "rejects non-string args instead of crashing" do
      assert {:error, book, %{"code" => "invalid_params"}} =
               Dispatch.handle(Book.new(), "row/add", %{"node" => "n1", "args" => [1]}, %{})

      assert book == Book.new()
    end

    test "rejects an unknown node (Old.md §32)" do
      assert {:error, book, %{"code" => "not_found"}} =
               Dispatch.handle(Book.new(), "row/add", %{"node" => "nope", "args" => ["1"]}, %{})

      assert book.calls == %{}
    end

    test "rejects args that don't match the node's arity, naming the function (Old.md §32)" do
      book = Book.new() |> Core.put_node("n1", %{module: "M", name: "f", arity: 1})

      assert {:error, ^book, %{"code" => "invalid_params", "message" => message}} =
               Dispatch.handle(book, "row/add", %{"node" => "n1", "args" => ["3", ""]}, %{})

      assert message =~ "M.f/1"
      assert message =~ "got 2"
    end

    test "accepts a 0-arity node with an empty args list" do
      book = Book.new() |> Core.put_node("n0", %{module: "M", name: "g", arity: 0})
      assert {:ok, _book, %{"row" => %{args: []}}} = Dispatch.handle(book, "row/add", %{"node" => "n0", "args" => []}, %{})
    end

    test "rejects a missing node/args shape" do
      assert {:error, _book, %{"code" => "invalid_params"}} =
               Dispatch.handle(Book.new(), "row/add", %{}, %{})
    end
  end

  describe "row/remove" do
    test "removes an existing call" do
      book = Book.new() |> Core.add_call("c1", %{node: "n1", args: []})
      assert {:ok, new_book, %{"id" => "c1"}} = Dispatch.handle(book, "row/remove", %{"id" => "c1"}, %{})
      assert Book.get(new_book, :calls, "c1") == nil
    end

    test "removing an unknown id is a no-op, not an error (Core.remove_call/2 is idempotent)" do
      book = Book.new()
      assert {:ok, ^book, %{"id" => "missing"}} = Dispatch.handle(book, "row/remove", %{"id" => "missing"}, %{})
    end
  end

  describe "effect/set" do
    test "sets a valid effect on an existing node" do
      book = Book.new() |> Core.put_node("n1", %{module: "M", name: "f", arity: 1})

      assert {:ok, new_book, %{"id" => "n1", "effect" => "pure"}} =
               Dispatch.handle(book, "effect/set", %{"id" => "n1", "effect" => "pure"}, %{})

      assert Book.get(new_book, :nodes, "n1").effect == "pure"
    end

    test "rejects an invalid effect value without crashing" do
      book = Book.new() |> Core.put_node("n1", %{module: "M", name: "f", arity: 1})

      assert {:error, ^book, %{"code" => "invalid_params"}} =
               Dispatch.handle(book, "effect/set", %{"id" => "n1", "effect" => "nonsense"}, %{})
    end

    test "an unknown node id is a clean not_found, not a crash" do
      book = Book.new()

      assert {:error, ^book, %{"code" => "not_found"}} =
               Dispatch.handle(book, "effect/set", %{"id" => "missing", "effect" => "pure"}, %{})
    end
  end

  describe "card/get and card/search" do
    setup do
      book =
        Book.new()
        |> Core.put_sheet("s1", %{path: "lib/shop/price.ex"})
        |> Core.put_node("n1", %{sheet: "s1", module: "Shop.Price", name: "add_tax", arity: 2})
        |> Core.add_call("c1", %{node: "n1", args: ["100"]})

      {:ok, book: book}
    end

    test "composes a card from the matched node's own calls and links", %{book: book} do
      address = %{"file" => "lib/shop/price.ex", "name" => "add_tax", "arity" => 2}
      assert {:ok, ^book, %{"matches" => [card]}} = Dispatch.handle(book, "card/get", address, %{})

      assert card["id"] == "n1"
      assert card["node"].module == "Shop.Price"
      assert [%{node: "n1", args: ["100"]}] = card["calls"]
      assert card["links"] == []
    end

    test "card/search behaves the same as card/get in v0 (no type reverse-lookup yet)", %{book: book} do
      address = %{"module" => "Shop.Price"}
      get_result = Dispatch.handle(book, "card/get", address, %{})
      search_result = Dispatch.handle(book, "card/search", address, %{})
      assert get_result == search_result
    end

    test "a row address composes the owning card too, entering through the call's node", %{book: book} do
      assert {:ok, ^book, %{"matches" => [card]}} = Dispatch.handle(book, "card/get", %{"row" => "c1"}, %{})

      assert card["id"] == "n1"
      assert card["node"].module == "Shop.Price"
      assert [%{node: "n1", args: ["100"]}] = card["calls"]
    end

    test "an unsupported address column is a clean error", %{book: book} do
      assert {:error, ^book, %{"code" => "unsupported_column", "message" => "hier"}} =
               Dispatch.handle(book, "card/get", %{"hier" => "01"}, %{})
    end

    test "non-map params is invalid_params, not a crash", %{book: book} do
      assert {:error, ^book, %{"code" => "invalid_params"}} = Dispatch.handle(book, "card/get", "n1", %{})
    end
  end

  describe "graph/neighbors and graph/export" do
    setup do
      book =
        Book.new()
        |> Core.put_node("n1", %{module: "M", name: "a", arity: 0})
        |> Core.put_node("n2", %{module: "M", name: "b", arity: 0})
        |> Book.put(:links, "l1", %{node: "n1", role: "to", ref: "n2", clause: nil, guard: nil})

      {:ok, book: book}
    end

    test "graph/neighbors defaults depth to 1 and direction to :both", %{book: book} do
      assert {:ok, ^book, %{"start" => ["n1"], "edges" => [%{"from" => "n1", "to" => "n2"}]}} =
               Dispatch.handle(book, "graph/neighbors", %{"address" => %{"name" => "a"}}, %{})
    end

    test "graph/neighbors accepts a string depth (CLI-shaped input) and an explicit direction", %{book: book} do
      assert {:ok, ^book, %{"edges" => []}} =
               Dispatch.handle(
                 book,
                 "graph/neighbors",
                 %{"address" => %{"name" => "a"}, "depth" => "1", "direction" => "in"},
                 %{}
               )
    end

    test "graph/neighbors rejects a bad direction instead of crashing", %{book: book} do
      assert {:error, ^book, %{"code" => "invalid_params"}} =
               Dispatch.handle(book, "graph/neighbors", %{"address" => %{"name" => "a"}, "direction" => "sideways"}, %{})
    end

    test "graph/neighbors needs an address key", %{book: book} do
      assert {:error, ^book, %{"code" => "invalid_params"}} = Dispatch.handle(book, "graph/neighbors", %{}, %{})
    end

    test "graph/export renders mermaid text", %{book: book} do
      assert {:ok, ^book, %{"format" => "mermaid", "text" => text}} =
               Dispatch.handle(book, "graph/export", %{"address" => %{"name" => "a"}, "format" => "mermaid"}, %{})

      assert text =~ "graph LR"
    end

    test "graph/export rejects an unrecognized format", %{book: book} do
      assert {:error, ^book, %{"code" => "invalid_params"}} =
               Dispatch.handle(book, "graph/export", %{"address" => %{"name" => "a"}, "format" => "yaml"}, %{})
    end
  end

  describe "cell/resolve" do
    setup do
      book =
        Book.new()
        |> Core.put_node("n1", %{module: "M", name: "f", arity: 1})
        |> Core.add_call("c1", %{node: "n1", args: ["1"]})
        |> Book.put(:calls, "c1", %{node: "n1", args: ["1"], result: "2", repr: "integer", state: "ok"})

      {:ok, book: book}
    end

    test "resolves a ⟦id⟧ token to the referenced call's value/repr/state", %{book: book} do
      assert {:ok, ^book, %{"value" => "2", "repr" => "integer", "state" => "ok"}} =
               Dispatch.handle(book, "cell/resolve", %{"ref" => "⟦c1⟧"}, %{})
    end

    test "an unknown id inside an otherwise well-formed token is a clean not_found", %{book: book} do
      assert {:error, ^book, %{"code" => "not_found"}} =
               Dispatch.handle(book, "cell/resolve", %{"ref" => "⟦missing⟧"}, %{})
    end

    test "a bare id (not wrapped in ⟦⟧) is invalid_params, not silently accepted", %{book: book} do
      assert {:error, ^book, %{"code" => "invalid_params"}} =
               Dispatch.handle(book, "cell/resolve", %{"ref" => "c1"}, %{})
    end

    test "a missing ref param is invalid_params", %{book: book} do
      assert {:error, ^book, %{"code" => "invalid_params"}} = Dispatch.handle(book, "cell/resolve", %{}, %{})
    end
  end

  describe "row/depends (Old.md §16.3/§16.4, not a v0.4 spec method)" do
    test "returns the upstream ⟦id⟧ chain, deepest-first, self included" do
      book =
        Book.new()
        |> Core.add_call("c1", %{node: "n1", args: ["⟦c2⟧ + 1"]})
        |> Core.add_call("c2", %{node: "n2", args: ["1"]})

      assert {:ok, ^book, %{"chain" => ["c2", "c1"]}} = Dispatch.handle(book, "row/depends", %{"call_ids" => ["c1"]}, %{})
    end

    test "call_ids must be a list of strings" do
      book = Book.new()
      assert {:error, ^book, %{"code" => "invalid_params"}} = Dispatch.handle(book, "row/depends", %{"call_ids" => "c1"}, %{})
      assert {:error, ^book, %{"code" => "invalid_params"}} = Dispatch.handle(book, "row/depends", %{}, %{})
    end
  end

  describe "row/set-result (Old.md §16.4/§19, the dependency-chain negotiation's stub-value step)" do
    test "writes a literal result with no evaluation, repr always \"exact\"" do
      book = Book.new() |> Core.add_call("c1", %{node: "n1", args: []})

      assert {:ok, new_book, %{"id" => "c1", "result" => "42"}} =
               Dispatch.handle(book, "row/set-result", %{"id" => "c1", "result" => "42"}, %{})

      row = Book.get(new_book, :calls, "c1")
      assert row.result == "42"
      assert row.repr == "exact"
      assert row.result_source == "user"
    end

    test "an unknown call id is a clean not_found, not a crash" do
      book = Book.new()

      assert {:error, ^book, %{"code" => "not_found"}} =
               Dispatch.handle(book, "row/set-result", %{"id" => "missing", "result" => "1"}, %{})
    end

    test "rejects a missing id/result shape" do
      book = Book.new()
      assert {:error, ^book, %{"code" => "invalid_params"}} = Dispatch.handle(book, "row/set-result", %{"id" => "c1"}, %{})
      assert {:error, ^book, %{"code" => "invalid_params"}} = Dispatch.handle(book, "row/set-result", %{}, %{})
    end
  end

  describe "not-yet-implemented and unknown methods" do
    test "a Tier 2-5 method is a distinct not_implemented error" do
      book = Book.new()
      assert {:error, ^book, %{"code" => "not_implemented"}} = Dispatch.handle(book, "eval/run", %{}, %{})
      assert {:error, ^book, %{"code" => "not_implemented"}} = Dispatch.handle(book, "row/update", %{}, %{})
    end

    test "a method outside §16.3 entirely is unknown_method" do
      book = Book.new()
      assert {:error, ^book, %{"code" => "unknown_method", "message" => "not/a/method"}} =
               Dispatch.handle(book, "not/a/method", %{}, %{})
    end
  end
end
