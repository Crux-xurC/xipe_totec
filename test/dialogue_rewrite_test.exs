ExUnit.start()
# see test/run.sh
System.put_env("XIPE_TOTEC_LSP", "off")

Code.require_file(Path.expand("../lib/in_out.exs", __DIR__))
Code.require_file(Path.expand("../lib/input.exs", __DIR__))
Code.require_file(Path.expand("../lib/outcome_text.exs", __DIR__))

defmodule DialogueRewriteTest do
  use ExUnit.Case, async: true

  alias XipeTotec.{Book, Core, Dispatch, InOut, Input, OutcomeText, Tables}
  alias XipeTotec.Dialogue.Rewrite

  setup do
    book =
      Book.new()
      |> Core.put_sheet("s1", %{path: "lib/calc.ex"})
      |> Core.put_node("n_add", %{sheet: "s1", module: "Calc", name: "add", anykey: 2, effect: "pure"})
      |> Core.add_call("c1", %{node: "n_add", args: ["1", "2"]})
      |> Core.add_call("c2", %{node: "n_add", args: ["3", "4"]})

    %{ctx: %{book: book, root: "/nonexistent", project_dir: nil}}
  end

  defp turns(ctx, params, lines) do
    Enum.reduce(lines, Rewrite.start(params, ctx), fn line, turn ->
      {:hold, state, _text} = turn
      Rewrite.answer(state, %{"text" => line}, ctx)
    end)
  end

  describe "asked in turn" do
    test "the row (only one table can be rewritten, so it isn't asked), the row shown, the column, the value", %{ctx: ctx} do
      assert {:hold, %{table: "eval"}, "row? (its id in the eval_table)"} = Rewrite.start(%{}, ctx)

      assert {:hold, %{row: "c1"}, text} = turns(ctx, %{}, ["c1"])
      assert [row, "column? (args | effect | prev | result)"] = String.split(text, "\n")
      assert row =~ "id=c1  node=n_add  module=Calc  name=add  anykey=2  effect=pure"
      assert row =~ "args=1, 2"

      assert {:hold, %{column: "prev"}, "prev? (the line is taken as it is)"} = turns(ctx, %{}, ["c1", "prev"])

      assert {:hold, _, "row/set-prev\n  id = c1  (Calc.add/2)\n  prev = {:ok, \"a, b\"}\nRun it? (y/n)"} =
               turns(ctx, %{}, ["c1", "prev", ~s({:ok, "a, b"})])

      assert {:done, "Running row/set-prev.", [%{"method" => "row/set-prev", "params" => %{"id" => "c1", "prev" => ~s({:ok, "a, b"})}}]} =
               turns(ctx, %{}, ["c1", "prev", ~s({:ok, "a, b"}), "y"])

      assert {:done, "Nothing was run.", []} = turns(ctx, %{}, ["c1", "prev", "3", "n"])
    end

    test "a wrong answer says so and asks again", %{ctx: ctx} do
      assert {:hold, %{row: nil}, "no row c9 in the eval_table\nrow? (its id in the eval_table)"} = turns(ctx, %{}, ["c9"])
      assert {:hold, %{column: nil}, "compare can't be rewritten (it is what an evaluation or a scan found)\ncolumn?" <> _} = turns(ctx, %{}, ["c1", "compare"])
      assert {:hold, %{column: nil}, "no such column: nope\ncolumn?" <> _} = turns(ctx, %{}, ["c1", "nope"])
    end

    test "args are a list, counted against the row's function when it closes", %{ctx: ctx} do
      assert {:hold, _, "args? (a list of 2: { alone to open, one per line, } alone to close)"} = turns(ctx, %{}, ["c1", "args"])
      assert {:hold, _, text} = turns(ctx, %{}, ["c1", "args", "{", "9", "}"])
      assert text =~ "Calc.add/2 takes 2 arg(s), got 1"

      assert {:done, _, [%{"method" => "row/set-args", "params" => %{"id" => "c1", "args" => ["[1,2]", "9"]}}]} =
               turns(ctx, %{}, ["c1", "args", "{", "[1,2]", "9", "}", "y"])
    end

    test "effect is the function's: said before the value is asked, written with the node's id", %{ctx: ctx} do
      assert {:hold, _, text} = turns(ctx, %{}, ["c1", "effect"])
      assert text == "effect is not this row's alone (node n_add): every row with it is affected\neffect? (pure | reads | writes)"

      assert {:done, _, [%{"method" => "effect/set", "params" => %{"id" => "n_add", "effect" => "reads"}}]} =
               turns(ctx, %{}, ["c1", "effect", "reads", "y"])
    end
  end

  describe "what the starting line gave" do
    test "is not asked for; the row is still shown", %{ctx: ctx} do
      assert {:hold, %{table: "eval", row: nil}, "row?" <> _} = Rewrite.start(%{"table" => "-e"}, ctx)
      assert {:hold, %{row: "c2"}, text} = Rewrite.start(%{"table" => "eval", "row" => "c2"}, ctx)
      assert text =~ "id=c2"
      assert text =~ "column? ("

      assert {:hold, %{column: "result", inner: inner}, text} = Rewrite.start(%{"table" => "-e", "row" => "c2", "column" => "result"}, ctx)
      assert inner != nil
      assert [row, "result? (the line is taken as it is)"] = String.split(text, "\n")
      assert row =~ "id=c2"
    end

    test "a wrong one is said and its question asked; what follows it is not taken", %{ctx: ctx} do
      assert {:hold, %{table: nil}, "no such table: -x\ntable? (-e the eval_table)"} = Rewrite.start(%{"table" => "-x", "row" => "c1"}, ctx)
      assert {:hold, %{table: nil}, "nothing in the surface table can be rewritten\ntable? (-e the eval_table)"} = Rewrite.start(%{"table" => "-s"}, ctx)
      assert {:hold, %{table: "eval", row: nil}, "row?" <> _} = turns(ctx, %{"table" => "-s"}, ["-e"])
      assert {:hold, %{row: nil, column: nil}, "no row c9 in the eval_table\nrow?" <> _} = Rewrite.start(%{"table" => "-e", "row" => "c9", "column" => "prev"}, ctx)
    end
  end

  describe "the two writes it needs" do
    test "row/set-prev sets the expectation, marked as a person's; an unknown row is not_found", %{ctx: ctx} do
      assert {:ok, book, %{"id" => "c1", "prev" => "3"}} = Dispatch.handle(ctx.book, "row/set-prev", %{"id" => "c1", "prev" => "3"}, %{})
      assert %{prev: "3", prev_source: "user", eval_count: 0} = Book.get(book, :calls, "c1")
      assert {:error, _, %{"code" => "not_found"}} = Dispatch.handle(ctx.book, "row/set-prev", %{"id" => "c9", "prev" => "3"}, %{})
      assert {:error, _, %{"code" => "invalid_params"}} = Dispatch.handle(ctx.book, "row/set-prev", %{"id" => "c1"}, %{})
    end

    test "row/set-args changes the arguments only, checked as row/add's are", %{ctx: ctx} do
      book = Core.set_result(ctx.book, "c1", "3")
      assert {:ok, new_book, %{"id" => "c1", "args" => ["5", "6"]}} = Dispatch.handle(book, "row/set-args", %{"id" => "c1", "args" => ["5", "6"]}, %{})
      assert %{args: ["5", "6"], result: "3", eval_count: 0} = Book.get(new_book, :calls, "c1")

      assert {:error, ^book, %{"code" => "invalid_params", "message" => message}} = Dispatch.handle(book, "row/set-args", %{"id" => "c1", "args" => ["5"]}, %{})
      assert message =~ "takes 2 arg(s), got 1"
      assert {:error, _, %{"code" => "not_found"}} = Dispatch.handle(book, "row/set-args", %{"id" => "c9", "args" => []}, %{})
    end

    test "a row of a running pass is refused by both", %{ctx: ctx} do
      dir = Path.join(System.tmp_dir!(), "xipe_totec_rewrite_test_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, h} = XipeTotec.Passes.start(dir, "p1", "elixir", ["c1"])
      pctx = %{root: dir, project_dir: dir}

      assert {:error, _, %{"code" => "row_in_pass"}} = Dispatch.handle(ctx.book, "row/set-prev", %{"id" => "c1", "prev" => "3"}, pctx)
      assert {:error, _, %{"code" => "row_in_pass"}} = Dispatch.handle(ctx.book, "row/set-args", %{"id" => "c1", "args" => ["5", "6"]}, pctx)
      XipeTotec.Passes.finish(h)
    end
  end

  describe "wired in" do
    test "every rewritable column names a method that takes that id and value", %{} do
      for table <- Tables.all(), {column, write} <- table.writes do
        assert column in table.columns
        assert write.id_from in table.columns
        params = XipeTotec.Methods.get(write.method).params |> Enum.map(& &1.name)
        assert write.id in params and write.value in params, "#{column} -> #{write.method}"
      end
    end

    test "roster lists what can be rewritten", %{ctx: ctx} do
      assert {:ok, _, %{"tables" => [surface, eval]}} = Dispatch.handle(ctx.book, "roster", %{}, %{})
      assert surface["writes"] == %{}
      assert eval["writes"] == %{"args" => "row/set-args", "result" => "row/set-result", "prev" => "row/set-prev", "effect" => "effect/set"}

      text = OutcomeText.text([%{method: "roster", ok?: true, result: %{"tables" => [surface, eval]}, error: nil}])
      assert text =~ "rewritable: args effect prev result"
      refute text =~ "build_tool  rewritable"
    end

    test "InOut runs the finished write", %{ctx: ctx} do
      {dialogue, book, %{hold: true}} = InOut.handle(nil, ctx.book, ctx.root, %{"method" => "dialogue/rewrite", "params" => %{"table" => "-e", "row" => "c1", "column" => "prev"}})

      {dialogue, book, %{hold: true}} = InOut.handle(dialogue, book, ctx.root, %{"method" => "dialogue/answer", "params" => %{"text" => "[1, 2]"}})
      {nil, new_book, %{hold: false, ok?: true}} = InOut.handle(dialogue, book, ctx.root, %{"method" => "dialogue/answer", "params" => %{"text" => "y"}})
      assert Book.get(new_book, :calls, "c1").prev == "[1, 2]"
    end

    test "the window's line: the table, row and column may be given, never the value" do
      assert {:commands, [%{"method" => "dialogue/rewrite", "params" => %{}}]} = Input.parse("dialogue rewrite")

      assert {:commands, [%{"method" => "dialogue/rewrite", "params" => %{"table" => "-e", "row" => "c1", "column" => "prev"}}]} =
               Input.parse("dialogue rewrite -e c1 prev")

      assert {:error, "dialogue rewrite: write dialogue rewrite" <> _} = Input.parse("dialogue rewrite -e c1 prev 3")
    end
  end
end
