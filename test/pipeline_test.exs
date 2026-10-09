ExUnit.start()

Code.require_file(Path.expand("../lib/book.exs", __DIR__))
Code.require_file(Path.expand("../lib/pipeline.exs", __DIR__))

defmodule PipelineTest do
  use ExUnit.Case

  alias XipeTotec.{Book, Pipeline}

  # These tests run with CWD at the repo root (test/run.sh's convention),
  # so they exercise the real pipelines.json committed there -- not a
  # fixture copy. That's deliberate: this file's job is partly to prove
  # the checked-in registry itself is well-formed and has the two entries
  # crux asked for today.
  describe "load_registry/0 and handles?/1 against the real pipelines.json" do
    test "the registry has eval/run and row/update, row/update is edit-then-eval" do
      registry = Pipeline.load_registry()
      assert registry["eval/run"] == ["eval"]
      assert registry["row/update"] == ["edit", "eval"]
    end

    test "handles?/1 is true for registered methods, false for everything else" do
      assert Pipeline.handles?("eval/run")
      assert Pipeline.handles?("row/update")
      refute Pipeline.handles?("row/add")
      refute Pipeline.handles?("not/a/real/method")
    end
  end

  # 2026-09-26 (Old.md §37): the real stages
  describe "run/5 against the real registry" do
    setup do
      book =
        Book.new()
        |> XipeTotec.Core.put_node("n1", %{module: "M", name: "f", anykey: 1, effect: "pure", effect_source: "user"})
        |> XipeTotec.Core.add_call("c1", %{node: "n1", args: ["1"]})
        |> XipeTotec.Core.add_call("c2", %{node: "n1", args: ["⟦c1⟧"]})

      # stands in for Runner's "eval": records what it was asked to evaluate
      eval = fn book, eval_params ->
        send(self(), {:evaluated, eval_params})
        {book, %{ok?: true, result: %{"results" => [], "not_run" => []}, error: nil}}
      end

      {:ok, book: book, ctx: %{root: ".", eval: eval}}
    end

    test "row/update edits the row's args, then evaluates that row only", %{book: book, ctx: ctx} do
      assert {:ok, new_book, %{"id" => "c1", "row" => row, "results" => []}} =
               Pipeline.run("row/update", book, %{"id" => "c1", "args" => ["5"]}, ctx)

      assert row.args == ["5"]
      assert Book.get(new_book, :calls, "c1").args == ["5"]
      # not c2, which references c1 (Old.md §36)
      assert_received {:evaluated, %{"call_ids" => ["c1"], "include_writes" => false}}
    end

    test "row/update's edit checks the args like row/add; eval is never reached", %{book: book, ctx: ctx} do
      assert {:error, ^book, %{"code" => "invalid_params", "message" => message}} =
               Pipeline.run("row/update", book, %{"id" => "c1", "args" => ["1", "2"]}, ctx)

      assert message =~ "takes 1 arg(s)"
      assert {:error, _, %{"code" => "not_found"}} = Pipeline.run("row/update", book, %{"id" => "nope", "args" => ["1"]}, ctx)
      assert {:error, _, %{"code" => "invalid_params"}} = Pipeline.run("row/update", book, %{}, ctx)
      refute_received {:evaluated, _}
    end

    test "eval/run evaluates the given rows, or every row with none", %{book: book, ctx: ctx} do
      assert {:ok, _, _} = Pipeline.run("eval/run", book, %{"call_ids" => ["c2"]}, ctx)
      assert_received {:evaluated, %{"call_ids" => ["c2"]}}
      assert {:ok, _, _} = Pipeline.run("eval/run", book, %{}, ctx)
      assert_received {:evaluated, %{"call_ids" => []}}
    end

    test "eval_params keeps a nil call_ids nil (a $n.path that found nothing), never every row" do
      assert %{"call_ids" => nil} = Pipeline.eval_params(%{"call_ids" => nil})
      assert %{"call_ids" => []} = Pipeline.eval_params(%{})
      assert %{"call_ids" => ["c1"]} = Pipeline.eval_params(%{"call_ids" => "c1"})
    end

    test "without a REPL in ctx the eval stage refuses cleanly", %{book: book} do
      assert {:error, ^book, %{"code" => "no_repl"}} = Pipeline.run("eval/run", book, %{}, %{root: "."})
    end

    test "prepare/4 runs the stages before eval and says what to evaluate", %{book: book} do
      assert {:ok, new_book, %{"id" => "c1"}, %{"call_ids" => ["c1"]}} =
               Pipeline.prepare("row/update", book, %{"id" => "c1", "args" => ["7"]}, %{})

      assert Book.get(new_book, :calls, "c1").args == ["7"]
      assert {:ok, ^book, %{}, %{"call_ids" => ["c1"]}} = Pipeline.prepare("eval/run", book, %{"call_ids" => ["c1"]}, %{})
      assert {:error, _, %{"code" => "unknown_method"}} = Pipeline.prepare("nope", book, %{}, %{})
    end

    test "a method with no registry entry is a clean unknown_method, not a crash" do
      book = Book.new()
      assert {:error, ^book, %{"code" => "unknown_method", "message" => "not/a/real/method"}} =
               Pipeline.run("not/a/real/method", book, %{}, %{})
    end
  end

  describe "run/5 with injected stage handlers -- proves the sequencing/threading logic itself" do
    test "stages run in order, each seeing the book the previous one returned" do
      track = fn book, params, _ctx, tag ->
        {:ok, Book.put(book, :sheets, tag, %{path: tag}), params}
      end

      handlers = %{
        "edit" => fn book, params, ctx -> track.(book, params, ctx, "edit") end,
        "eval" => fn book, params, ctx -> track.(book, params, ctx, "eval") end
      }

      assert {:ok, final_book, %{}} = Pipeline.run("row/update", Book.new(), %{}, %{}, handlers)
      assert Map.keys(final_book.sheets) |> Enum.sort() == ["edit", "eval"]
    end

    test "the last stage's result is the pipeline's own result" do
      handlers = %{
        "edit" => fn book, _params, _ctx -> {:ok, book, %{"stage" => "edit"}} end,
        "eval" => fn book, _params, _ctx -> {:ok, book, %{"stage" => "eval"}} end
      }

      assert {:ok, _book, %{"stage" => "eval"}} = Pipeline.run("row/update", Book.new(), %{}, %{}, handlers)
    end

    test "a failing stage stops the pipeline -- a later stage never runs" do
      handlers = %{
        "edit" => fn book, _params, _ctx -> {:error, book, %{"code" => "invalid_params", "message" => "bad edit"}} end,
        "eval" => fn _book, _params, _ctx -> flunk("eval stage must not run after edit failed") end
      }

      assert {:error, _book, %{"code" => "invalid_params"}} = Pipeline.run("row/update", Book.new(), %{}, %{}, handlers)
    end

    test "a stage name with no handler in the injected map is a clean unknown_stage, not a crash" do
      assert {:error, _book, %{"code" => "unknown_stage"}} = Pipeline.run("row/update", Book.new(), %{}, %{}, %{})
    end
  end
end
