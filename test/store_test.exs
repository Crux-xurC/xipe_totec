ExUnit.start()

Code.require_file(Path.expand("../lib/book.exs", __DIR__))
Code.require_file(Path.expand("../lib/store.exs", __DIR__))

defmodule StoreTest do
  use ExUnit.Case

  alias XipeTotec.{Book, Store}

  setup do
    path = Path.join(System.tmp_dir!(), "xipe_totec_store_test_#{System.unique_integer([:positive])}.jsonl")
    on_exit(fn -> File.rm(path); File.rm(path <> ".lock") end)
    {:ok, path: path}
  end

  test "load/1 on a missing file returns an empty book", %{path: path} do
    book = Store.load(path)
    assert book.calls == %{}
  end

  test "append/2 then load/1 round-trips a row", %{path: path} do
    Store.append(path, %{type: "sheet", id: "s1", path: "lib/a.ex", status: "live"})
    book = Store.load(path)
    assert book.sheets["s1"] == %{path: "lib/a.ex", status: "live"}
  end

  test "a later row for the same {type, id} wins (append-log fold)", %{path: path} do
    Store.append(path, %{type: "call", id: "c1", args: ["1"], result: nil, eval_count: 0})
    Store.append(path, %{type: "call", id: "c1", args: ["1"], result: "2", eval_count: 1})
    book = Store.load(path)
    assert book.calls["c1"].result == "2"
    assert book.calls["c1"].eval_count == 1
  end

  test "a row with deleted: true removes the id on fold", %{path: path} do
    Store.append(path, %{type: "call", id: "c1", args: [], result: nil})
    Store.append(path, %{type: "call", id: "c1", deleted: true})
    book = Store.load(path)
    assert book.calls == %{}
  end

  test "a truncated final line is ignored, not raised", %{path: path} do
    Store.append(path, %{type: "sheet", id: "s1", path: "lib/a.ex"})
    File.write!(path, "{\"type\":\"sheet\",\"id\":\"s2\",\"pa", [:append])

    book = Store.load(path)
    assert Map.keys(book.sheets) == ["s1"]
  end

  test "blank lines are ignored", %{path: path} do
    File.write!(path, "\n\n", [:append])
    Store.append(path, %{type: "sheet", id: "s1", path: "lib/a.ex"})
    book = Store.load(path)
    assert Map.keys(book.sheets) == ["s1"]
  end

  test "load/1 reads a node row written before arity was renamed anykey as anykey", %{path: path} do
    File.write!(path, ~s({"type":"node","id":"n1","module":"M","name":"f","arity":2}\n))
    assert Store.load(path).nodes["n1"] == %{module: "M", name: "f", anykey: 2}
  end

  test "persist_diff/4 appends only what changed, tombstones drops, and respects the requested table scope", %{
    path: path
  } do
    old_book =
      Book.new()
      |> Book.put(:nodes, "n1", %{module: "M", name: "f", anykey: 1, effect: "unknown"})
      |> Book.put(:calls, "c1", %{node: "n1", args: []})
      |> Book.put(:calls, "c2", %{node: "n1", args: ["1"]})

    new_book =
      old_book
      # both tables change; only :calls is in the persist_diff scope below
      |> Book.put(:nodes, "n1", %{module: "M", name: "f", anykey: 1, effect: "pure"})
      |> Book.put(:calls, "c2", %{node: "n1", args: ["2"]})
      |> Book.put(:calls, "c3", %{node: "n1", args: []})
      |> Book.delete(:calls, "c1")

    Store.persist_diff(path, old_book, new_book, [:calls])
    folded = Store.load(path)

    assert folded.nodes == %{}, ":nodes was not in the requested scope, so its change was never appended"
    assert Map.keys(folded.calls) |> Enum.sort() == ["c2", "c3"]
    assert folded.calls["c2"].args == ["2"]
  end

  test "compact/1 rewrites the file to hold only current state", %{path: path} do
    Store.append(path, %{type: "call", id: "c1", args: ["1"], result: nil})
    Store.append(path, %{type: "call", id: "c1", args: ["1"], result: "2"})
    Store.compact(path)

    lines = File.read!(path) |> String.split("\n", trim: true)
    assert length(lines) == 1

    book = Store.load(path)
    assert book.calls["c1"].result == "2"
  end
  # -- 2026-10-09: a cut-off line, the write lock, catching up ----------------

  test "an append after a line cut off by a crash starts a line of its own (the cut line alone is lost)", %{path: path} do
    Store.append(path, %{type: "call", id: "a", args: []})
    File.write!(path, ~s({"type":"call","id":"b","ar), [:append])
    Store.append(path, %{type: "call", id: "c", args: []})
    assert Store.load(path).calls |> Map.keys() |> Enum.sort() == ["a", "c"]
  end

  test "a lock whose owner is gone is taken over; one held by a running owner is waited for", %{path: path} do
    File.write!(path <> ".lock", JSON.encode!(%{"os_pid" => "999999999", "os_started" => "never"}))
    assert Store.with_lock(path, fn -> :ran end) == :ran
    refute File.exists?(path <> ".lock")
    # held by a running process (this one, as another writer would see it)
    File.write!(path <> ".lock", JSON.encode!(XipeTotec.Session.owner()))
    assert_raise RuntimeError, ~r/is held by another process/, fn -> Store.with_lock(path, fn -> :ran end, 50) end
    File.rm!(path <> ".lock")
  end

  test "persist_diff_since: the rows another writer appended are folded in; ours win on the same row", %{path: path} do
    Store.append(path, %{type: "call", id: "c1", args: ["1"], result: nil})
    {server, pos} = Store.load_with_pos(path)
    # the CLI, meanwhile: a row of its own, and a change of c1
    cli0 = Store.load(path)
    cli1 = cli0 |> Book.put(:calls, "c2", %{args: ["2"], result: nil}) |> Book.put(:calls, "c1", %{args: ["1"], result: "cli"})
    Store.persist_diff(path, cli0, cli1, [:calls])
    # the server writes its change of c1 (from the book it read before)
    mine = Book.put(server, :calls, "c1", %{args: ["1"], result: "server"})
    {merged, pos2} = Store.persist_diff_since(path, pos, server, mine, [:calls])
    assert merged.calls["c2"].args == ["2"]
    assert merged.calls["c1"].result == "server"
    assert Store.load(path) == merged
    assert pos2 == File.stat!(path).size
    # nothing new: the book stays, the position too
    assert Store.persist_diff_since(path, pos2, merged, merged, [:calls]) == {merged, pos2}
  end
end
