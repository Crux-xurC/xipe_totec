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

  describe "run/5 against the real (today: stub) registry" do
    test "eval/run's single stub stage reports not_implemented, book untouched" do
      book = Book.new()
      assert {:error, ^book, %{"code" => "not_implemented", "message" => message}} = Pipeline.run("eval/run", book, %{}, %{})
      assert message =~ "\"eval\""
    end

    test "row/update's first stage (edit) is the one that reports not_implemented -- eval is never reached" do
      book = Book.new()
      assert {:error, ^book, %{"code" => "not_implemented", "message" => message}} = Pipeline.run("row/update", book, %{}, %{})
      assert message =~ "\"edit\""
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
