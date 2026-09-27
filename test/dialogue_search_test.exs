ExUnit.start()

Code.require_file(Path.expand("../lib/in_out.exs", __DIR__))

defmodule DialogueSearchTest do
  use ExUnit.Case, async: true

  alias XipeTotec.{Book, Core, EvalTable, InOut}
  alias XipeTotec.Dialogue.Search

  # lib/a.ex: M.f/1 (pure) with rows c1 (f(1) = 2) and c2 (f(⟦c1⟧), unevaluated)
  # lib/b.ex: M.g/0 (unclassified) with row c3
  # c4's function is gone (a rescan removed it)
  setup do
    dir = Path.join(System.tmp_dir!(), "xipe_totec_search_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "lib/a.ex"), "")
    File.write!(Path.join(dir, "lib/b.ex"), "")

    project_dir = Path.join(dir, "tables")
    File.mkdir_p!(project_dir)

    table = [
      %{"id" => "t1", "path" => "lib/a.ex", "depth" => 2, "language" => "elixir", "repl" => "iex", "build_tool" => nil},
      %{"id" => "t2", "path" => "lib/b.ex", "depth" => 2, "language" => "elixir", "repl" => "iex", "build_tool" => nil}
    ]

    XipeTotec.SurfaceTable.save(table, Path.join(project_dir, "table"))
    on_exit(fn -> File.rm_rf!(dir) end)

    book =
      Book.new()
      |> Core.put_sheet("s1", %{path: "lib/a.ex"})
      |> Core.put_sheet("s2", %{path: "lib/b.ex"})
      |> Core.put_node("n1", %{sheet: "s1", module: "M", name: "f", anykey: 1})
      |> Core.put_node("n2", %{sheet: "s2", module: "M", name: "g", anykey: 0})
      |> Core.set_effect("n1", "pure")
      |> Core.add_call("c1", %{node: "n1", args: ["1"]})
      |> Core.add_call("c2", %{node: "n1", args: ["⟦c1⟧"]})
      |> Core.add_call("c3", %{node: "n2", args: []})
      |> Core.add_call("c4", %{node: "gone", args: []})

    book = Book.put(book, :calls, "c1", %{Book.get(book, :calls, "c1") | result: "2", repr: "exact", eval_count: 1})

    {:ok, ctx: %{book: book, root: dir, project_dir: project_dir}, book: book, dir: dir, project_dir: project_dir}
  end

  # the turns of one search, each line's text collected
  defp turns(ctx, lines) do
    {:hold, state, _} = Search.start(%{}, ctx)

    Enum.map_reduce(lines, state, fn line, state ->
      case Search.answer(state, %{"text" => line}, ctx) do
        {:hold, state, text} -> {{:hold, text}, state}
        {:pass, state, line} -> {{:pass, line}, state}
        {:done, text, []} -> {{:done, text}, state}
      end
    end)
  end

  test "eval_table: each calc row with its function and path alongside", %{book: book} do
    rows = EvalTable.rows(book)
    assert Enum.map(rows, & &1["id"]) == ["c1", "c2", "c3", "c4"]
    assert %{"module" => "M", "name" => "f", "anykey" => 1, "effect" => "pure", "path" => "lib/a.ex", "result" => "2"} = hd(rows)
    assert %{"module" => nil, "path" => nil} = List.last(rows)
    assert Enum.all?(rows, &(Map.keys(&1) |> Enum.sort() == Enum.sort(EvalTable.columns())))
  end

  test "a surface table path to calc rows in two turns, then view", %{ctx: ctx} do
    {[t1, t2, t3, t4], _state} =
      turns(ctx, ["-s path lib/a.ex path", "-e path list id", "-e view id id name args", "y"])

    assert t1 == {:hold, "1件ヒットしました。（path: [lib/a.ex]）"}
    assert t2 == {:hold, "2件ヒットしました。（id: [c1, c2]）"}
    assert {:hold, "2件ヒットしました。\nid=c1  name=f  args=1\nid=c2  name=f  args=⟦c1⟧\n検索を終了しますか？y/n"} = t3
    assert t4 == {:done, "検索を終了しました。"}
  end

  test "matching: ~ is a substring, - an empty cell, a number compares as text", %{ctx: ctx} do
    {[down, gone, arity, unclassified], _} =
      turns(ctx, ["-e args ~⟦c1⟧ id", "-e module -", "-e anykey 1", "-e effect unknown id"])

    assert down == {:hold, "1件ヒットしました。（id: [c2]）"}
    assert gone == {:hold, "1件ヒットしました。（id: [c4]）"}
    assert arity == {:hold, "2件ヒットしました。（id: [c1, c2]）"}
    assert unclassified == {:hold, "1件ヒットしました。（id: [c3]）"}
  end

  test "get id keeps x, and a passed-on line has x replaced", %{ctx: ctx} do
    {[_, got, pass, bad], state} =
      turns(ctx, ["-e path lib/a.ex", "get id -2", "row/update id=x 'args=[⟦x⟧]' -- row/list call_ids=[x]", "get id -9"])

    assert {:hold, "検索結果の2番目の要素のIDを取得しました: c2" <> _} = got
    assert pass == {:pass, "row/update id=c2 args=[⟦c2⟧] -- row/list call_ids=[c2]"}
    assert bad == {:hold, "No match data"}
    assert state.x == "c2"
  end

  test "x before get id, an unknown column, list before any search", %{ctx: ctx} do
    {[no_x, column, no_list, plain], _} = turns(ctx, ["row/remove id=x", "-e nope 1", "-e id list id", "effect/set id=n2 effect=pure"])
    assert {:hold, "x がまだありません" <> _} = no_x
    assert {:hold, "列 nope はありません" <> _} = column
    assert {:hold, "保持しているリストがありません" <> _} = no_list
    # an x inside a word (effect=..., n2) is not the variable
    assert plain == {:pass, "effect/set id=n2 effect=pure"}
  end

  test "n after a view goes on; more than 10 hits show 10 and the count", %{ctx: ctx, book: book} do
    book = Enum.reduce(1..12, book, fn i, b -> Core.add_call(b, "d#{String.pad_leading("#{i}", 2, "0")}", %{node: "n2", args: []}) end)
    ctx = %{ctx | book: book}

    {[many, _view, go_on, again], _} = turns(ctx, ["-e name g", "-e view id id", "n", "-e name f"])
    assert {:hold, "13件ヒットしました。（id: [c3, d01, d02, d03, d04, d05, d06, d07, d08, d09]（ほか 3 件））"} = many
    assert go_on == {:hold, "検索を続けます。"}
    assert {:hold, "2件ヒットしました。" <> _} = again
  end

  test "-h lists both tables' columns", %{ctx: ctx} do
    {[{:hold, usage}], _} = turns(ctx, ["-h"])
    assert usage =~ "-s の列: id path depth language repl build_tool"
    assert usage =~ "-e の列: id node module"
  end

  test "through InOut: started with a first turn, quit dialogue ends it, a pass is left to the caller", %{book: book, dir: dir, project_dir: pd} do
    programs = InOut.programs()
    opts = [project_dir: pd]
    start = %{"method" => "dialogue/search", "params" => %{"line" => "-e effect pure"}}

    {dialogue, ^book, outcome} = InOut.handle(nil, book, dir, start, opts, programs)
    assert %{hold: true, text: "2件ヒットしました。（id: [c1, c2]）"} = outcome
    assert {Search, _} = dialogue

    pass = %{"method" => "dialogue/answer", "params" => %{"text" => "row/list"}}
    {dialogue, ^book, outcome} = InOut.handle(dialogue, book, dir, pass, opts, programs)
    assert %{hold: true, run: {:line, "row/list"}} = outcome

    {nil, ^book, outcome} = InOut.handle(dialogue, book, dir, %{"method" => "dialogue/quit", "params" => %{}}, opts, programs)
    assert %{hold: false, ok?: true, text: "対話を終了しました。"} = outcome
  end

  test "dialogue depends started with just a call_id builds its chain from the book", %{book: book, dir: dir} do
    start = %{"method" => "dialogue/depends", "params" => %{"call_id" => "c2"}}
    {dialogue, _book, outcome} = InOut.handle(nil, book, dir, start, [], InOut.programs())
    assert {XipeTotec.Dialogue.Depends, %{chain: [%{"id" => "c1"}, %{"id" => "c2"}]}} = dialogue
    assert outcome.text =~ "c1 に値を入れて評価しますか"

    {nil, _book, outcome} = InOut.handle(nil, book, dir, %{start | "params" => %{"call_id" => "zz"}}, [], InOut.programs())
    assert outcome.text =~ "zz はありません"
  end
end
