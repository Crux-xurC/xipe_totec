ExUnit.start()

Code.require_file(Path.expand("../lib/in_out.exs", __DIR__))

defmodule InOutTest.ToyDialogue do
  # A minimal fake Dialogue program (mirrors ReplEvaluatorTest's
  # ToyLanguage) -- proves InOut's wiring/holding/2-bit derivation without
  # any real dialogue program existing yet (Old.md §17: the
  # dependency-chain negotiation is step 4, InOut is step 3).
  @behaviour XipeTotec.Dialogue

  @impl true
  def start(_params), do: {:hold, %{step: 1}, "step 1?"}

  @impl true
  def answer(%{step: 1}, %{"choice" => "continue"}), do: {:hold, %{step: 2}, "step 2?"}

  def answer(%{step: 2}, %{"choice" => "finish_internal"}), do: {:done, "done, no commands", []}

  def answer(%{step: 2}, %{"choice" => "finish_repl"}) do
    {:done, "done, running commands",
     [%{"method" => "row/add", "params" => %{"node" => "Toy.f/1", "args" => ["1"]}}]}
  end
end

defmodule InOutTest do
  use ExUnit.Case, async: true

  alias XipeTotec.{Book, InOut}
  alias InOutTest.ToyDialogue

  @programs %{"toy/negotiate" => ToyDialogue}

  # row/add now requires the node to exist with a matching arity
  # (Dispatch, Old.md §32), so every book a row/add reaches carries these.
  defp book do
    Book.new()
    |> XipeTotec.Core.put_node("N", %{module: "M", name: "n", arity: 1})
    |> XipeTotec.Core.put_node("N0", %{module: "M", name: "n0", arity: 0})
    |> XipeTotec.Core.put_node("Toy.f/1", %{module: "Toy", name: "f", arity: 1})
  end

  test "an ordinary command with no dialogue held passes straight through, tagged 01" do
    {dialogue, book, outcome} =
      InOut.handle(nil, book(), ".", %{"method" => "row/add", "params" => %{"node" => "N", "args" => ["1"]}})

    assert dialogue == nil
    assert outcome.hold == false
    assert outcome.via_repl == false
    assert outcome.ok? == true
    assert map_size(book.calls) == 1
  end

  test "a Pipeline-routed method (eval/run, still a stub) is tagged 00 -- via_repl, not held" do
    {dialogue, _book, outcome} = InOut.handle(nil, book(), ".", %{"method" => "eval/run", "params" => %{}})

    assert dialogue == nil
    assert outcome.hold == false
    assert outcome.via_repl == true
    # the pipeline's "eval" stage is still a stub (Old.md §15) -- this
    # only proves the tag, not that eval/run itself works yet.
    assert outcome.ok? == false
  end

  test "starting a registered dialogue holds, tagged 11, and returns the program's question" do
    {dialogue, _book, outcome} =
      InOut.handle(nil, book(), ".", %{"method" => "toy/negotiate", "params" => %{}}, [], @programs)

    assert {ToyDialogue, %{step: 1}} = dialogue
    assert outcome.hold == true
    assert outcome.via_repl == false
    assert outcome.text == "step 1?"
  end

  test "an unrelated command reaches Dispatch normally while a dialogue is held, dialogue untouched" do
    {dialogue, _book, _q} =
      InOut.handle(nil, book(), ".", %{"method" => "toy/negotiate", "params" => %{}}, [], @programs)

    {still_held, book, outcome} =
      InOut.handle(dialogue, book(), ".", %{"method" => "row/add", "params" => %{"node" => "N0", "args" => []}}, [], @programs)

    assert still_held == dialogue
    assert outcome.hold == false
    assert outcome.ok? == true
    assert map_size(book.calls) == 1
  end

  test "answering a held dialogue can keep holding across multiple turns" do
    {dialogue, book, _} = InOut.handle(nil, book(), ".", %{"method" => "toy/negotiate", "params" => %{}}, [], @programs)

    {dialogue, book, outcome} =
      InOut.handle(dialogue, book, ".", %{"method" => "dialogue/answer", "params" => %{"choice" => "continue"}}, [], @programs)

    assert {ToyDialogue, %{step: 2}} = dialogue
    assert outcome.hold == true
    assert outcome.text == "step 2?"
    assert book.calls == %{}
  end

  test "finishing with no commands releases the dialogue, tagged 01" do
    {dialogue, book, _} = InOut.handle(nil, book(), ".", %{"method" => "toy/negotiate", "params" => %{}}, [], @programs)
    {dialogue, book, _} = InOut.handle(dialogue, book, ".", %{"method" => "dialogue/answer", "params" => %{"choice" => "continue"}}, [], @programs)

    {dialogue, _book, outcome} =
      InOut.handle(dialogue, book, ".", %{"method" => "dialogue/answer", "params" => %{"choice" => "finish_internal"}}, [], @programs)

    assert dialogue == nil
    assert outcome.hold == false
    assert outcome.via_repl == false
    assert outcome.text == "done, no commands"
  end

  test "finishing with commands releases the dialogue, tagged 00, and runs them immediately" do
    {dialogue, book, _} = InOut.handle(nil, book(), ".", %{"method" => "toy/negotiate", "params" => %{}}, [], @programs)
    {dialogue, book, _} = InOut.handle(dialogue, book, ".", %{"method" => "dialogue/answer", "params" => %{"choice" => "continue"}}, [], @programs)

    {dialogue, book, outcome} =
      InOut.handle(dialogue, book, ".", %{"method" => "dialogue/answer", "params" => %{"choice" => "finish_repl"}}, [], @programs)

    assert dialogue == nil
    assert outcome.hold == false
    assert outcome.via_repl == true
    assert outcome.text == "done, running commands"
    assert [%{ok?: true}] = outcome.result["outcomes"]
    assert map_size(book.calls) == 1
  end

  test "run_to_completion/7 drives a whole negotiation with injected answer/print callbacks, no IO" do
    answers = ["continue", "finish_repl"]
    queue = Agent.start_link(fn -> answers end) |> elem(1)
    texts = Agent.start_link(fn -> [] end) |> elem(1)

    next_answer = fn ->
      [choice | rest] = Agent.get(queue, & &1)
      Agent.update(queue, fn _ -> rest end)
      %{"choice" => choice}
    end

    on_text = fn text -> Agent.update(texts, &(&1 ++ [text])) end

    {book, outcome} =
      InOut.run_to_completion(book(), ".", %{"method" => "toy/negotiate", "params" => %{}}, [], @programs, next_answer, on_text)

    assert outcome.hold == false
    assert outcome.via_repl == true
    assert map_size(book.calls) == 1
    assert Agent.get(texts, & &1) == ["step 1?", "step 2?", "done, running commands"]
  end

  test "\"dialogue/answer\" with nothing held is a clean error, dialogue stays nil" do
    {dialogue, _book, outcome} = InOut.handle(nil, book(), ".", %{"method" => "dialogue/answer", "params" => %{}})

    assert dialogue == nil
    assert outcome.ok? == false
    assert outcome.error["code"] == "no_pending_dialogue"
  end
end
